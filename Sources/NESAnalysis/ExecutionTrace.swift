import Foundation
import NESCore

/// Code coverage and control-flow facts gathered by actually running the game.
///
/// Static analysis of Zelda plateaus at ~27% of PRG because MMC1 banking makes
/// a bare address ambiguous and the game dispatches through `JMP (indirect)`
/// and RTS-pushed addresses that cannot be resolved without running. Execution
/// resolves both exactly: the CPU knows which bank is live and where a dispatch
/// actually went.
///
/// So playing the game *is* the discovery mechanism. Walk into a dungeon and
/// the dungeon's code reveals itself, correctly attributed to its bank.
public struct ExecutionTrace: Codable, Sendable {

    /// Flat PRG offsets that began an executed instruction.
    public var executedOffsets: Set<Int> = []

    /// Routines entered via JSR, as bank:address.
    public var routines: Set<String> = []

    /// Where each indirect jump was observed to land. Keyed by the jump site.
    /// These are exactly the edges static analysis cannot see.
    public var indirectTargets: [String: Set<String>] = [:]

    /// Total instructions observed, across all merged sessions.
    public var instructionCount: Int = 0

    /// Human-readable note about how this trace was produced.
    public var sessions: [String] = []

    public init() {}

    /// Combines another session's findings into this trace.
    public mutating func merge(_ other: ExecutionTrace) {
        executedOffsets.formUnion(other.executedOffsets)
        routines.formUnion(other.routines)
        for (site, targets) in other.indirectTargets {
            indirectTargets[site, default: []].formUnion(targets)
        }
        instructionCount += other.instructionCount
        sessions.append(contentsOf: other.sessions)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> ExecutionTrace {
        try JSONDecoder().decode(ExecutionTrace.self, from: Data(contentsOf: url))
    }
}

/// Records an `ExecutionTrace` from a running machine.
///
/// Attach via `NES.onInstruction`. Coverage is kept in a flat byte array rather
/// than a Set because this runs on every instruction — several million times a
/// second — and set hashing would dominate the emulator's own cost.
public final class ExecutionTracer {

    private let prgROM: [UInt8]
    private let bankCount: Int
    private let lastBank: Int

    /// One byte per PRG offset: was an instruction started here?
    private var covered: [UInt8]
    private var instructionCount = 0

    private var routines = Set<BankedAddress>()
    private var indirectTargets: [BankedAddress: Set<BankedAddress>] = [:]

    /// Set when the previous instruction was a dispatch whose destination is
    /// only knowable by seeing where execution went next.
    private var pendingDispatchSite: BankedAddress?

    public init(cartridge: Cartridge) {
        self.prgROM = cartridge.prgROM
        self.bankCount = cartridge.prgBankCount16K
        self.lastBank = cartridge.prgBankCount16K - 1
        self.covered = [UInt8](repeating: 0, count: cartridge.prgROM.count)
    }

    /// Folds (bank, PC) to a flat PRG offset the same way the static analyzer
    /// does, so the two coverage sets are directly comparable.
    @inline(__always)
    private func flatOffset(bank: Int, pc: UInt16) -> Int? {
        switch pc {
        case 0x8000...0xBFFF: return bank * 0x4000 + Int(pc - 0x8000)
        case 0xC000...0xFFFF: return lastBank * 0x4000 + Int(pc - 0xC000)
        default: return nil     // RAM-resident code; not a ROM offset
        }
    }

    /// Called before each instruction executes.
    public func record(bank: Int, pc: UInt16) {
        instructionCount += 1

        // The instruction *after* a dispatch is its resolved destination —
        // which is precisely the edge static analysis cannot follow.
        if let site = pendingDispatchSite {
            let resolvedBank = pc >= 0xC000 ? lastBank : bank
            indirectTargets[site, default: []]
                .insert(BankedAddress(bank: resolvedBank, address: pc))
            pendingDispatchSite = nil
        }

        guard let offset = flatOffset(bank: bank, pc: pc), offset < prgROM.count else {
            return
        }
        covered[offset] = 1

        let instruction = Opcodes[prgROM[offset]]
        switch instruction.mnemonic {
        case .JSR:
            // Target is in the operand, readable straight from ROM.
            guard offset + 2 < prgROM.count else { break }
            let target = UInt16(prgROM[offset + 1]) | (UInt16(prgROM[offset + 2]) << 8)
            let targetBank = target >= 0xC000 ? lastBank : bank
            routines.insert(BankedAddress(bank: targetBank, address: target))

        case .JMP where instruction.mode == .indirect:
            pendingDispatchSite = BankedAddress(bank: bank, address: pc)

        case .RTS:
            // Zelda dispatches by pushing an address and returning to it, so
            // an RTS destination is not always a real return. Recording them
            // costs little and catches the table-driven jumps.
            pendingDispatchSite = BankedAddress(bank: bank, address: pc)

        default:
            break
        }
    }

    /// Snapshots what has been observed so far.
    public func trace(note: String = "") -> ExecutionTrace {
        var result = ExecutionTrace()
        result.instructionCount = instructionCount
        if !note.isEmpty { result.sessions = [note] }

        for (offset, seen) in covered.enumerated() where seen != 0 {
            result.executedOffsets.insert(offset)
        }
        result.routines = Set(routines.map(\.description))
        for (site, targets) in indirectTargets {
            result.indirectTargets[site.description] = Set(targets.map(\.description))
        }
        return result
    }
}

// MARK: - Reporting

extension ExecutionTrace {

    /// Compares this trace against a purely static analysis and describes what
    /// running the game revealed.
    public func report(cartridge: Cartridge, static staticAnalysis: ROMAnalyzer.Analysis) -> String {
        let total = cartridge.prgROM.count
        let staticBytes = staticAnalysis.codeBytes
        let dynamicBytes = executedOffsets
        let combined = staticBytes.union(dynamicBytes)

        let novel = dynamicBytes.subtracting(staticBytes)
        let unexecuted = staticBytes.subtracting(dynamicBytes)

        func percent(_ count: Int) -> String {
            String(format: "%.1f%%", Double(count) / Double(total) * 100)
        }

        var lines: [String] = []
        lines.append("Coverage")
        lines.append("  static only:   \(staticBytes.count) bytes  (\(percent(staticBytes.count)))")
        lines.append("  executed:      \(dynamicBytes.count) bytes  (\(percent(dynamicBytes.count)))")
        lines.append("  combined:      \(combined.count) bytes  (\(percent(combined.count)))")
        lines.append("")
        lines.append("  newly found by running:  \(novel.count) bytes")
        lines.append("  static-only, never run:  \(unexecuted.count) bytes")
        lines.append("  instructions observed:   \(instructionCount)")

        lines.append("")
        lines.append("Routines")
        lines.append("  static (JSR targets):    \(staticAnalysis.routines.count)")
        lines.append("  observed at runtime:     \(routines.count)")
        let staticRoutineNames = Set(staticAnalysis.routines.map(\.description))
        let newRoutines = routines.subtracting(staticRoutineNames)
        lines.append("  not seen statically:     \(newRoutines.count)")

        if !indirectTargets.isEmpty {
            lines.append("")
            lines.append("Resolved dispatch sites  (the wall static analysis hits)")
            for site in indirectTargets.keys.sorted().prefix(12) {
                let targets = indirectTargets[site]!.sorted()
                let shown = targets.prefix(6).joined(separator: " ")
                let more = targets.count > 6 ? " (+\(targets.count - 6) more)" : ""
                lines.append("  \(site) -> \(shown)\(more)")
            }
            let siteCount = indirectTargets.count
            let edgeCount = indirectTargets.values.reduce(0) { $0 + $1.count }
            lines.append("  \(siteCount) sites, \(edgeCount) distinct edges")
        }

        lines.append("")
        lines.append("Per-bank coverage  (static -> combined)")
        for bank in 0..<cartridge.prgBankCount16K {
            let range = bank * 0x4000 ..< (bank + 1) * 0x4000
            let staticCount = range.count { staticBytes.contains($0) }
            let combinedCount = range.count { combined.contains($0) }
            let staticPercent = Double(staticCount) / Double(0x4000) * 100
            let combinedPercent = Double(combinedCount) / Double(0x4000) * 100
            let gain = combinedPercent - staticPercent
            let bar = String(repeating: "#", count: Int(combinedPercent / 4))
            lines.append(String(format: "  bank %d: %5.1f%% -> %5.1f%%  (%+5.1f)  %@",
                                bank, staticPercent, combinedPercent, gain, bar))
        }

        return lines.joined(separator: "\n")
    }
}
