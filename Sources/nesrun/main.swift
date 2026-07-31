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
      nesrun run     <rom.nes> [--frames <n>] [--out <frame.ppm>]

    COMMANDS:
      info     Parse the iNES header and print cartridge geometry.
      analyze  Recursive-descent trace from the interrupt vectors; reports
               code/data split and the routine inventory.
      disasm   Emit an annotated listing for one 16KB PRG bank.
      run      Boot the ROM headlessly for N frames and dump the framebuffer.
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

case "run":
    let frames = Int(flag("--frames", in: args) ?? "60") ?? 60
    let outPath = flag("--out", in: args) ?? "frame.ppm"

    let nes: NES
    do {
        nes = try NES(cartridge: cartridge)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    // Scripted input: "--press start@70,a@200" holds each button for 8 frames
    // from the given frame. Enough to drive past menus and reach gameplay,
    // which is where scrolling and sprite-0 hit actually get exercised.
    var presses: [(button: NESButton, frame: Int)] = []
    if let script = flag("--press", in: args) {
        for entry in script.split(separator: ",") {
            let parts = entry.split(separator: "@")
            guard parts.count == 2, let atFrame = Int(parts[1]) else { continue }
            let button: NESButton? = switch parts[0].lowercased() {
            case "a": .a
            case "b": .b
            case "start": .start
            case "select": .select
            case "up": .up
            case "down": .down
            case "left": .left
            case "right": .right
            default: nil
            }
            if let button { presses.append((button, atFrame)) }
        }
    }

    print("Booting \(romPath) for \(frames) frames...")
    let start = Date()
    for frame in 0..<frames {
        for press in presses {
            if frame == press.frame { nes.controller1.press(press.button) }
            if frame == press.frame + 8 { nes.controller1.release(press.button) }
        }
        nes.stepFrame()
    }
    let elapsed = Date().timeIntervalSince(start)

    let fps = Double(frames) / elapsed
    print(String(format: "Ran %d frames in %.2fs — %.0f fps (%.0fx real time)",
                 frames, elapsed, fps, fps / 60.0))
    print(String(format: "CPU cycles: %d   PPU frame: %d", nes.cycles, nes.ppu.frame))

    // Distinct colours in the output is the quickest signal that the PPU is
    // doing something rather than emitting a flat field.
    let unique = Set(nes.framebuffer)
    print("Distinct colours on screen: \(unique.count)")

    let bg = (0..<16).map { String(format: "%02X", nes.ppu.paletteRAM[$0]) }
    let sp = (16..<32).map { String(format: "%02X", nes.ppu.paletteRAM[$0]) }
    print("Palette BG:  \(bg.joined(separator: " "))")
    print("Palette SPR: \(sp.joined(separator: " "))")
    print(String(format: "PPUCTRL: %02X  PPUMASK: %02X",
                 nes.ppu.control.rawValue, nes.ppu.mask.rawValue))

    writePPM(nes.framebuffer, to: outPath)
    print("Wrote \(outPath)")

case "paltrace":
    // Diagnostic: log every write that reaches palette memory, so a transfer
    // landing at the wrong address is immediately visible.
    let limit = Int(flag("--frames", in: args) ?? "45") ?? 45
    let nes = try! NES(cartridge: cartridge)
    var frame = 0
    var lines: [String] = []
    nes.ppu.onPaletteWrite = { addr, value in
        lines.append(String(format: "f%-3d $%04X <- $%02X", frame, addr, value))
    }
    for _ in 0..<limit { nes.stepFrame(); frame += 1 }
    print("\(lines.count) palette writes in \(limit) frames")
    for line in lines.prefix(80) { print("  \(line)") }

default:
    usage()
}

/// Dumps the framebuffer as a binary PPM — trivially viewable and needs no
/// image library.
func writePPM(_ framebuffer: [UInt32], to path: String) {
    var data = Data("P6\n256 240\n255\n".utf8)
    for pixel in framebuffer {
        data.append(UInt8(pixel & 0xFF))          // R
        data.append(UInt8((pixel >> 8) & 0xFF))   // G
        data.append(UInt8((pixel >> 16) & 0xFF))  // B
    }
    try? data.write(to: URL(fileURLWithPath: path))
}
