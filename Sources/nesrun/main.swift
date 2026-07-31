import Foundation
import NESCore

// Minimal hand-rolled CLI; no external dependencies while the core is in flux.

func usage() -> Never {
    print("""
    nesrun — decompilation harness for the loz project

    USAGE:
      nesrun info    <rom.nes>
      nesrun analyze <rom.nes>
      nesrun disasm  <rom.nes> --bank <n> [--out <file.asm>]

    COMMANDS:
      info     Parse the iNES header and print cartridge geometry.
      analyze  Recursive-descent trace from the interrupt vectors; reports
               code/data split and the routine inventory.
      disasm   Emit an annotated listing for one 16KB PRG bank.
    """)
    exit(1)
}

func loadCartridge(_ path: String) -> Cartridge {
    let url = URL(fileURLWithPath: path)
    do {
        return try Cartridge(contentsOf: url)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

func flag(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { usage() }

let command = args[0]
let romPath = args[1]
let cartridge = loadCartridge(romPath)

switch command {

case "info":
    print(cartridge.summary)
    let analyzer = ROMAnalyzer(cartridge: cartridge)
    let v = analyzer.vectors
    print(String(format: "\nVectors:\n  NMI:   $%04X\n  RESET: $%04X\n  IRQ:   $%04X",
                 v.nmi, v.reset, v.irq))

case "analyze":
    print(cartridge.summary)
    print("\nTracing from interrupt vectors...\n")

    let analyzer = ROMAnalyzer(cartridge: cartridge)
    let start = Date()
    let analysis = analyzer.analyze()
    let elapsed = Date().timeIntervalSince(start)

    let total = cartridge.prgROM.count
    let code = analysis.codeBytes.count
    let pct = Double(code) / Double(total) * 100

    print(String(format: "Analyzed %d KB in %.2fs\n", total / 1024, elapsed))
    print(String(format: "  Code bytes:        %6d  (%.1f%%)", code, pct))
    print(String(format: "  Data/unreached:    %6d  (%.1f%%)", total - code, 100 - pct))
    print(String(format: "  Instructions:      %6d", analysis.opcodeStarts.count))
    print(String(format: "  Routines (JSR):    %6d", analysis.routines.count))
    print(String(format: "  Branch targets:    %6d", analysis.jumpTargets.count))
    print(String(format: "  Indirect JMPs:     %6d   <- need runtime dispatch",
                 analysis.unresolvedIndirectJumps.count))
    if !analysis.callsOutsideROM.isEmpty {
        let list = analysis.callsOutsideROM.sorted()
            .map { String(format: "$%04X", $0) }.joined(separator: " ")
        print("  Calls outside ROM: \(list)")
    }

    // Per-bank breakdown — shows which banks are code-heavy vs data (graphics,
    // level layouts, text), which is the map for planning decompilation order.
    print("\nPer-bank coverage:")
    for bank in 0..<cartridge.prgBankCount16K {
        let base = bank * 0x4000
        let bankCode = (base..<base + 0x4000).count { analysis.codeBytes.contains($0) }
        let bankPct = Double(bankCode) / Double(0x4000) * 100
        let routines = analysis.routines.filter { $0.bank == bank }.count
        let bar = String(repeating: "#", count: Int(bankPct / 4))
        print(String(format: "  bank %d: %5.1f%% code  %3d routines  %@",
                     bank, bankPct, routines, bar))
    }

case "disasm":
    guard let bankArg = flag("--bank", in: args), let bank = Int(bankArg) else { usage() }
    guard bank >= 0 && bank < cartridge.prgBankCount16K else {
        FileHandle.standardError.write(
            "error: bank must be 0..\(cartridge.prgBankCount16K - 1)\n".data(using: .utf8)!)
        exit(1)
    }

    let analyzer = ROMAnalyzer(cartridge: cartridge)
    let analysis = analyzer.analyze()
    let lines = analyzer.listing(bank: bank, analysis: analysis)
    let text = lines.joined(separator: "\n") + "\n"

    if let out = flag("--out", in: args) {
        try! text.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
        print("Wrote \(lines.count) lines to \(out)")
    } else {
        print(text)
    }

default:
    usage()
}
