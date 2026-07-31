import Foundation

/// A location in PRG-ROM, identified by bank plus the CPU address it is seen at.
/// Under MMC1 a bare CPU address is ambiguous — $8000 means eight different
/// things — so every reference the analyzer tracks carries its bank.
public struct BankedAddress: Hashable, Comparable, CustomStringConvertible {
    public let bank: Int
    public let address: UInt16

    public init(bank: Int, address: UInt16) {
        self.bank = bank
        self.address = address
    }

    public var description: String {
        String(format: "%02X:%04X", bank, address)
    }

    public static func < (a: BankedAddress, b: BankedAddress) -> Bool {
        (a.bank, a.address) < (b.bank, b.address)
    }
}

/// One decoded instruction with its raw bytes.
public struct DisassembledLine {
    public let location: BankedAddress
    public let bytes: [UInt8]
    public let instruction: Instruction
    /// The operand's target, when it names a ROM location we can resolve.
    public let target: UInt16?

    public var mnemonicText: String {
        instruction.mnemonic.rawValue + (instruction.mnemonic.isUndocumented ? "*" : "")
    }

    public var operandText: String {
        let b = bytes
        func byte(_ i: Int) -> UInt8 { i < b.count ? b[i] : 0 }
        let lo = UInt16(byte(1))
        let word = lo | (UInt16(byte(2)) << 8)

        switch instruction.mode {
        case .implied:         return ""
        case .accumulator:     return "A"
        case .immediate:       return String(format: "#$%02X", byte(1))
        case .zeroPage:        return String(format: "$%02X", byte(1))
        case .zeroPageX:       return String(format: "$%02X,X", byte(1))
        case .zeroPageY:       return String(format: "$%02X,Y", byte(1))
        case .relative:        return String(format: "$%04X", target ?? 0)
        case .absolute:        return String(format: "$%04X", word)
        case .absoluteX:       return String(format: "$%04X,X", word)
        case .absoluteY:       return String(format: "$%04X,Y", word)
        case .indirect:        return String(format: "($%04X)", word)
        case .indexedIndirect: return String(format: "($%02X,X)", byte(1))
        case .indirectIndexed: return String(format: "($%02X),Y", byte(1))
        }
    }

    /// `07:C123  A9 42     LDA #$42`
    public var text: String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let operand = operandText
        let mnemonic = operand.isEmpty ? mnemonicText : "\(mnemonicText) \(operand)"
        return "\(location)  \(hex.padded(to: 8))  \(mnemonic)"
    }
}

private extension String {
    func padded(to n: Int) -> String {
        count >= n ? self : self + String(repeating: " ", count: n - count)
    }
}

/// Static analysis over a cartridge's PRG-ROM: what is code, what is data, and
/// where the routine boundaries fall.
///
/// This is the first step of decompilation — you cannot port routines you have
/// not identified. Deliberately conservative: it only marks bytes as code when
/// control flow demonstrably reaches them.
public final class ROMAnalyzer {

    public struct Analysis {
        /// Flat PRG offsets that begin an instruction.
        public var opcodeStarts: Set<Int> = []
        /// Flat PRG offsets covered by any instruction (opcode or operand).
        public var codeBytes: Set<Int> = []
        /// Every JSR target found — the routine inventory to be decompiled.
        public var routines: Set<BankedAddress> = []
        /// Branch and JMP destinations.
        public var jumpTargets: Set<BankedAddress> = []
        /// `JMP (indirect)` sites whose destination is not statically known.
        public var unresolvedIndirectJumps: Set<BankedAddress> = []
        /// Addresses outside ROM that were called — RAM-resident code stubs.
        public var callsOutsideROM: Set<UInt16> = []
    }

    private let cartridge: Cartridge
    private let bankCount: Int
    private let lastBank: Int
    private var analysis = Analysis()

    public init(cartridge: Cartridge) {
        self.cartridge = cartridge
        self.bankCount = cartridge.prgBankCount16K
        self.lastBank = cartridge.prgBankCount16K - 1
    }

    // MARK: Address mapping

    /// Under MMC1 PRG mode 3 (Zelda's), $8000-$BFFF is the switchable bank and
    /// $C000-$FFFF is hardwired to the last bank.
    private func flatOffset(_ address: UInt16, contextBank: Int) -> Int? {
        switch address {
        case 0x8000...0xBFFF:
            return contextBank * 0x4000 + Int(address - 0x8000)
        case 0xC000...0xFFFF:
            return lastBank * 0x4000 + Int(address - 0xC000)
        default:
            return nil
        }
    }

    private func byte(at address: UInt16, contextBank: Int) -> UInt8? {
        guard let off = flatOffset(address, contextBank: contextBank),
              off < cartridge.prgROM.count else { return nil }
        return cartridge.prgROM[off]
    }

    // MARK: Entry points

    /// The three hardware vectors, which always live at the top of the last bank.
    public var vectors: (nmi: UInt16, reset: UInt16, irq: UInt16) {
        let base = lastBank * 0x4000
        func word(_ o: Int) -> UInt16 {
            UInt16(cartridge.prgROM[base + o]) | (UInt16(cartridge.prgROM[base + o + 1]) << 8)
        }
        return (word(0x3FFA), word(0x3FFC), word(0x3FFE))
    }

    // MARK: Tracing

    public func analyze() -> Analysis {
        analysis = Analysis()

        let v = vectors
        // Vectors resolve in the fixed bank, but the switchable half could hold
        // any bank at the time; seed with the last bank and let discovered
        // targets fan out from there.
        var seeds: [(UInt16, Int)] = [
            (v.reset, lastBank), (v.nmi, lastBank), (v.irq, lastBank),
        ]

        // Pass 1: trace everything reachable with the fixed bank as context.
        for (addr, bank) in seeds { trace(from: addr, contextBank: bank) }

        // Pass 2: every routine we found in the switchable window could belong
        // to any bank, since we cannot statically know which bank was live.
        // Re-trace those entry points against each bank. Over-approximates, but
        // that is the right bias: better to disassemble a byte that turns out to
        // be data than to miss a routine entirely.
        let switchableEntries = (analysis.routines.union(analysis.jumpTargets))
            .filter { (0x8000...0xBFFF).contains($0.address) }
            .map(\.address)

        seeds = []
        for bank in 0..<bankCount where bank != lastBank {
            for addr in Set(switchableEntries) { seeds.append((addr, bank)) }
        }
        for (addr, bank) in seeds { trace(from: addr, contextBank: bank) }

        return analysis
    }

    private func trace(from start: UInt16, contextBank: Int) {
        var worklist: [UInt16] = [start]
        var visited = Set<UInt16>()

        while let addr = worklist.popLast() {
            var pc = addr
            // Walk straight-line code until we hit a terminator.
            flow: while true {
                if visited.contains(pc) { break }
                visited.insert(pc)

                guard let offset = flatOffset(pc, contextBank: contextBank),
                      let opcode = byte(at: pc, contextBank: contextBank)
                else { break }

                let insn = Opcodes[opcode]
                let length = insn.length

                analysis.opcodeStarts.insert(offset)
                for i in 0..<length { analysis.codeBytes.insert(offset + i) }

                // Operand word, if this instruction has one.
                let operandWord: UInt16? = {
                    guard length == 3 else { return nil }
                    guard let lo = byte(at: pc &+ 1, contextBank: contextBank),
                          let hi = byte(at: pc &+ 2, contextBank: contextBank) else { return nil }
                    return UInt16(lo) | (UInt16(hi) << 8)
                }()

                let next = pc &+ UInt16(length)

                switch insn.mnemonic {
                case .JSR:
                    if let target = operandWord {
                        record(target, contextBank: contextBank, as: .routine)
                        if flatOffset(target, contextBank: contextBank) != nil {
                            worklist.append(target)
                        } else {
                            analysis.callsOutsideROM.insert(target)
                        }
                    }
                    pc = next   // a JSR returns; keep going

                case .JMP:
                    if insn.mode == .absolute, let target = operandWord {
                        record(target, contextBank: contextBank, as: .jump)
                        if flatOffset(target, contextBank: contextBank) != nil {
                            worklist.append(target)
                        }
                    } else {
                        // JMP ($xxxx) — target lives in RAM or a table. This is
                        // exactly where static analysis gives up and the runtime
                        // dispatch table earns its keep.
                        analysis.unresolvedIndirectJumps.insert(
                            BankedAddress(bank: contextBank, address: pc))
                    }
                    break flow  // no fall-through

                case .BPL, .BMI, .BVC, .BVS, .BCC, .BCS, .BNE, .BEQ:
                    if let operand = byte(at: pc &+ 1, contextBank: contextBank) {
                        let target = UInt16(truncatingIfNeeded:
                            Int(next) + Int(Int8(bitPattern: operand)))
                        record(target, contextBank: contextBank, as: .jump)
                        if flatOffset(target, contextBank: contextBank) != nil {
                            worklist.append(target)
                        }
                    }
                    pc = next   // branches fall through when not taken

                case .RTS, .RTI, .BRK, .KIL:
                    break flow

                default:
                    pc = next
                }
            }
        }
    }

    private enum RefKind { case routine, jump }

    private func record(_ address: UInt16, contextBank: Int, as kind: RefKind) {
        // A $C000+ target always resolves in the fixed bank regardless of context.
        let bank = address >= 0xC000 ? lastBank : contextBank
        let ref = BankedAddress(bank: bank, address: address)
        switch kind {
        case .routine: analysis.routines.insert(ref)
        case .jump:    analysis.jumpTargets.insert(ref)
        }
    }

    // MARK: Listing

    /// Linear disassembly of one 16KB bank. Bytes the analyzer proved to be
    /// code are decoded; everything else is emitted as data.
    public func listing(bank: Int, analysis: Analysis) -> [String] {
        let base = bank * 0x4000
        // $C000 for the fixed bank, $8000 for a switchable one.
        let displayBase: UInt16 = bank == lastBank ? 0xC000 : 0x8000
        var lines: [String] = []
        var offset = 0

        while offset < 0x4000 {
            let flat = base + offset
            let address = displayBase &+ UInt16(offset)

            if analysis.opcodeStarts.contains(flat) {
                let opcode = cartridge.prgROM[flat]
                let insn = Opcodes[opcode]
                let length = min(insn.length, 0x4000 - offset)
                let bytes = Array(cartridge.prgROM[flat ..< flat + length])

                var target: UInt16?
                if insn.mode == .relative, bytes.count >= 2 {
                    let next = address &+ 2
                    target = UInt16(truncatingIfNeeded:
                        Int(next) + Int(Int8(bitPattern: bytes[1])))
                }

                let line = DisassembledLine(
                    location: BankedAddress(bank: bank, address: address),
                    bytes: bytes, instruction: insn, target: target)

                let ref = BankedAddress(bank: bank, address: address)
                if analysis.routines.contains(ref) {
                    lines.append("")
                    lines.append(String(format: "; ---- routine %@ ----", ref.description))
                } else if analysis.jumpTargets.contains(ref) {
                    lines.append(String(format: "; -- branch target %@", ref.description))
                }

                lines.append(line.text)
                offset += length
            } else {
                // Emit unreached bytes 16 to a row as data.
                let end = min(offset + 16, 0x4000)
                var run = end
                for i in offset..<end where analysis.opcodeStarts.contains(base + i) {
                    run = i
                    break
                }
                let bytes = Array(cartridge.prgROM[base + offset ..< base + run])
                guard !bytes.isEmpty else { offset += 1; continue }
                let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                lines.append("\(BankedAddress(bank: bank, address: address))  .db \(hex)")
                offset = run
            }
        }
        return lines
    }
}
