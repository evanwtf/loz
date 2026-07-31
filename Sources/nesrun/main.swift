import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import NESCore
import NESAnalysis
import ZeldaGame

// Minimal hand-rolled CLI; no external dependencies while the core is in flux.

func usage() -> Never {
    print("""
    nesrun — decompilation harness for the loz project

    USAGE:
      nesrun info    <rom.nes>
      nesrun analyze <rom.nes>
      nesrun disasm  <rom.nes> --bank <n> [--out <file.asm>]
      nesrun run     <rom.nes> [--frames <n>] [--out <frame.ppm>]
      nesrun play    <rom.nes> [options]

    COMMANDS:
      info     Parse the iNES header and print cartridge geometry.
      analyze  Recursive-descent trace from the interrupt vectors; reports
               code/data split and the routine inventory.
      disasm   Emit an annotated listing for one 16KB PRG bank.
      run      Boot the ROM headlessly for N frames and dump the framebuffer.
      play     Drive the game with a scripted input sequence. Designed to be
               run by an agent: no window, PNG output, resumable snapshots.

    PLAY OPTIONS:
      --input <script>     Input sequence, e.g. "wait:60,start:4,up+a:12".
                           Buttons: up down left right a b start select wait.
                           Combine with '+', separate segments with ','.
      --out <file.png>     Write the final frame as a PNG.
      --scale <n>          Screenshot scale factor (default 3).
      --filmstrip <dir>    Also write a PNG every --every frames.
      --every <n>          Filmstrip interval in frames (default 30).
      --load-state <file>  Resume from a snapshot instead of booting.
      --save-state <file>  Write a snapshot when the script finishes.
      --watch <addrs>      Comma-separated hex RAM addresses to report,
                           e.g. --watch 00EB,0070.
      --trace              Record executed code and report new coverage.
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

case "hash":
    // Pins a GameDefinition to an exact dump.
    let data = try! Data(contentsOf: URL(fileURLWithPath: romPath))
    print(ROMHash.hex(of: [UInt8](data)))

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

case "play":
    let nes = try! NES(cartridge: cartridge)
    let scale = Int(flag("--scale", in: args) ?? "3") ?? 3

    if let statePath = flag("--load-state", in: args) {
        let data = try! Data(contentsOf: URL(fileURLWithPath: statePath))
        let state = try! JSONDecoder().decode(SaveState.self, from: data)
        try! nes.restoreState(state)
        print("Resumed from \(statePath) at frame \(nes.ppu.frame)")
    }

    // Trace coverage is accumulated in a reference box so the instruction
    // observer can mutate it without capture-semantics surprises.
    let tracer = CoverageTracer(lastBank: cartridge.prgBankCount16K - 1)
    if args.contains("--trace") {
        nes.onInstruction = { [tracer] bank, pc in tracer.record(bank: bank, pc: pc) }
    }

    runInputScript(nes, script: flag("--input", in: args),
                   filmstrip: flag("--filmstrip", in: args),
                   every: Int(flag("--every", in: args) ?? "30") ?? 30,
                   scale: scale)

    print(String(format: "Stopped at frame %d  PC $%04X  bank %d",
                 nes.ppu.frame, nes.cpu.pc, nes.mapper.currentPRGBank))

    if let watch = flag("--watch", in: args) {
        let values = watch.split(separator: ",").map { token -> String in
            let address = UInt16(token.trimmingCharacters(in: .whitespaces), radix: 16) ?? 0
            return String(format: "$%04X=%02X", address, nes.cpuRead(address))
        }
        print("Watch: " + values.joined(separator: "  "))
    }

    if args.contains("--trace") {
        let analyzer = ROMAnalyzer(cartridge: cartridge)
        let statically = analyzer.analyze()
        let seen = tracer.executed
        let novel = seen.subtracting(statically.codeBytes)
        print("""
        Trace coverage:
          executed bytes:       \(seen.count)
          not found statically: \(novel.count)   <- discovered by playing
        """)
    }

    if let outPath = flag("--out", in: args) {
        writePNG(nes.framebuffer, to: outPath, scale: scale)
        print("Wrote \(outPath)")
    }

    if let statePath = flag("--save-state", in: args) {
        let state = nes.captureState()
        let data = try! JSONEncoder().encode(state)
        try! data.write(to: URL(fileURLWithPath: statePath))
        print("Saved state to \(statePath)")
    }

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

/// Accumulates executed PRG offsets, folded the same way the static analyzer
/// folds them so the two coverage sets can be compared directly.
final class CoverageTracer {
    private(set) var executed = Set<Int>()
    private let lastBank: Int

    init(lastBank: Int) { self.lastBank = lastBank }

    func record(bank: Int, pc: UInt16) {
        switch pc {
        case 0x8000...0xBFFF: executed.insert(bank * 0x4000 + Int(pc - 0x8000))
        case 0xC000...0xFFFF: executed.insert(lastBank * 0x4000 + Int(pc - 0xC000))
        default: break   // RAM-resident code, not a ROM offset
        }
    }
}

/// Parses and runs an input script such as "wait:60,start:4,up+a:12".
func runInputScript(
    _ nes: NES,
    script: String?,
    filmstrip: String?,
    every: Int,
    scale: Int
) {
    var segments: [(buttons: NESButton, frames: Int)] = []

    for segment in (script ?? "wait:60").split(separator: ",") {
        let parts = segment.split(separator: ":")
        guard parts.count == 2, let frames = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else {
            FileHandle.standardError.write(
                "warning: skipping malformed segment '\(segment)'\n".data(using: .utf8)!)
            continue
        }
        var buttons: NESButton = []
        for name in parts[0].split(separator: "+") {
            switch name.trimmingCharacters(in: .whitespaces).lowercased() {
            case "up": buttons.insert(.up)
            case "down": buttons.insert(.down)
            case "left": buttons.insert(.left)
            case "right": buttons.insert(.right)
            case "a": buttons.insert(.a)
            case "b": buttons.insert(.b)
            case "start": buttons.insert(.start)
            case "select": buttons.insert(.select)
            case "wait", "none", "": break
            default:
                FileHandle.standardError.write(
                    "warning: unknown button '\(name)'\n".data(using: .utf8)!)
            }
        }
        segments.append((buttons, frames))
    }

    if let filmstrip {
        try? FileManager.default.createDirectory(
            atPath: filmstrip, withIntermediateDirectories: true)
    }

    var frameIndex = 0
    for segment in segments {
        nes.controller1.releaseAll()
        nes.controller1.press(segment.buttons)
        for _ in 0..<segment.frames {
            nes.stepFrame()
            frameIndex += 1
            if let filmstrip, frameIndex % every == 0 {
                let path = "\(filmstrip)/frame_\(String(format: "%05d", frameIndex)).png"
                writePNG(nes.framebuffer, to: path, scale: scale)
            }
        }
    }
    nes.controller1.releaseAll()
}

/// Builds a CGImage from the PPU framebuffer. The buffer is already R,G,B,A in
/// memory order, so no per-pixel conversion is needed.
func makeCGImage(_ framebuffer: [UInt32]) -> CGImage? {
    framebuffer.withUnsafeBytes { raw -> CGImage? in
        guard let provider = CGDataProvider(data: Data(raw) as CFData) else { return nil }
        return CGImage(
            width: 256, height: 240,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Writes a nearest-neighbour scaled PNG, so screenshots stay legible without
/// blurring the pixel art.
func writePNG(_ framebuffer: [UInt32], to path: String, scale: Int = 3) {
    guard let base = makeCGImage(framebuffer) else { return }
    let width = 256 * scale
    let height = 240 * scale

    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return }

    context.interpolationQuality = .none
    context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let scaled = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            UTType.png.identifier as CFString, 1, nil)
    else { return }

    CGImageDestinationAddImage(destination, scaled, nil)
    CGImageDestinationFinalize(destination)
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
