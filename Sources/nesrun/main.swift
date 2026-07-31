import CoreGraphics
import Foundation
import ImageIO
import NESAnalysis
import NESCore
import UniformTypeIdentifiers
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
    print(String(format: "\n  Confident   (from vectors, fixed bank): %6d bytes",
                 analysis.confidentCodeBytes.count))
    print(String(format: "  Speculative (entry retried per bank):   %6d bytes",
                 analysis.speculativeCodeBytes.count))
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
        let routines = analysis.routines.count { $0.bank == bank }
        let bar = String(repeating: "#", count: Int(bankPct / 4))
        print(String(format: "  bank %d: %5.1f%% code  %3d routines  %@",
                     bank, bankPct, routines, bar))
    }

case "disasm":
    guard let bankArg = flag("--bank", in: args), let bank = Int(bankArg) else { usage() }
    guard bank >= 0, bank < cartridge.prgBankCount16K else {
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

    // Install decompiled Swift routines in place of their 6502 originals.
    if args.contains("--native") {
        nes.nativeRoutines = Zelda.nativeRoutines
        print("Native routines active: \(nes.nativeRoutines.count)")
    }

    if let statePath = flag("--load-state", in: args) {
        let data = try! Data(contentsOf: URL(fileURLWithPath: statePath))
        let state = try! JSONDecoder().decode(SaveState.self, from: data)
        try! nes.restoreState(state)
        print("Resumed from \(statePath) at frame \(nes.ppu.frame)")
    }

    let tracer = ExecutionTracer(cartridge: cartridge)
    let tracing = args.contains("--trace") || flag("--trace-out", in: args) != nil
    if tracing {
        nes.onInstruction = { [tracer] bank, pc in tracer.record(bank: bank, pc: pc) }
    }

    runInputScript(nes, script: flag("--input", in: args),
                   filmstrip: flag("--filmstrip", in: args),
                   every: Int(flag("--every", in: args) ?? "30") ?? 30,
                   scale: scale)

    print(String(format: "Stopped at frame %d  PC $%04X  bank %d",
                 nes.ppu.frame, nes.cpu.pc, nes.mapper.currentPRGBank))

    if !nes.nativeCallCounts.isEmpty {
        print("Native routine calls:")
        for (key, count) in nes.nativeCallCounts.sorted(by: { $0.value > $1.value }) {
            let name = nes.nativeRoutines[key]?.name ?? "?"
            print("  \(key) \(name): \(count)")
        }
    }

    if let watch = flag("--watch", in: args) {
        let values = watch.split(separator: ",").map { token -> String in
            let address = UInt16(token.trimmingCharacters(in: .whitespaces), radix: 16) ?? 0
            return String(format: "$%04X=%02X", address, nes.cpuRead(address))
        }
        print("Watch: " + values.joined(separator: "  "))
    }

    if tracing {
        var trace = tracer.trace(note: flag("--input", in: args) ?? "no input")

        // Merge earlier sessions so coverage accumulates across many short
        // exploration runs rather than restarting each time.
        if let inPath = flag("--trace-in", in: args),
           let previous = try? ExecutionTrace.read(from: URL(fileURLWithPath: inPath))
        {
            let before = trace.executedOffsets.count
            trace.merge(previous)
            print("Merged \(inPath): \(before) -> \(trace.executedOffsets.count) bytes\n")
        }

        let analyzer = ROMAnalyzer(cartridge: cartridge)
        print(trace.report(cartridge: cartridge, static: analyzer.analyze()))

        if let outPath = flag("--trace-out", in: args) {
            try? trace.write(to: URL(fileURLWithPath: outPath))
            print("\nWrote trace to \(outPath)")
        }
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

case "navigate":
    guard let statePath = flag("--load-state", in: args) else {
        FileHandle.standardError.write(
            "error: navigate needs --load-state\n".data(using: .utf8)!)
        exit(1)
    }
    guard let targetText = flag("--to", in: args),
          let target = UInt8(targetText.replacingOccurrences(of: "$", with: ""), radix: 16)
    else {
        FileHandle.standardError.write(
            "error: navigate needs --to <hex screen>, e.g. --to 37\n".data(using: .utf8)!)
        exit(1)
    }

    let frames = Int(flag("--move-frames", in: args) ?? "170") ?? 170
    let maxScreens = Int(flag("--max-screens", in: args) ?? "80") ?? 80
    let start = try! JSONDecoder().decode(
        SaveState.self, from: try! Data(contentsOf: URL(fileURLWithPath: statePath)))

    print("Searching for screen \(Navigator.describe(target))...")
    let found = Navigator.search(
        cartridge: cartridge, from: start, to: target,
        framesPerMove: frames, maxScreens: maxScreens,
        verbose: args.contains("--verbose"))

    guard let found else {
        print("No route found within \(maxScreens) explored screens.")
        exit(1)
    }

    print("\nReached \(Navigator.describe(found.screen)) in \(found.route.count) moves:")
    for (index, step) in found.route.enumerated() {
        print("  \(index + 1). \(step)")
    }
    
    if let outPath = flag("--save-state", in: args) {
        try! JSONEncoder().encode(found.state).write(to: URL(fileURLWithPath: outPath))
        print("\nSaved arrival state to \(outPath)")
    }

case "audio":
    // Renders the APU to a WAV so sound can actually be listened to and
    // measured, rather than assumed to work because it compiles.
    let seconds = Double(flag("--seconds", in: args) ?? "10") ?? 10
    let outPath = flag("--out", in: args) ?? "audio.wav"
    let sampleRate = 44100.0

    let nes = try! NES(cartridge: cartridge, sampleRate: sampleRate)

    if let statePath = flag("--load-state", in: args) {
        let data = try! Data(contentsOf: URL(fileURLWithPath: statePath))
        try! nes.restoreState(try! JSONDecoder().decode(SaveState.self, from: data))
    }

    var script: [(NESButton, Int)] = []
    if let input = flag("--input", in: args) {
        for segment in input.split(separator: ",") {
            let parts = segment.split(separator: ":")
            guard parts.count == 2, let frames = Int(parts[1]) else { continue }
            var buttons: NESButton = []
            for name in parts[0].split(separator: "+") {
                switch name.lowercased() {
                case "a": buttons.insert(.a)
                case "b": buttons.insert(.b)
                case "start": buttons.insert(.start)
                case "select": buttons.insert(.select)
                case "up": buttons.insert(.up)
                case "down": buttons.insert(.down)
                case "left": buttons.insert(.left)
                case "right": buttons.insert(.right)
                default: break
                }
            }
            script.append((buttons, frames))
        }
    }

    let totalFrames = Int(seconds * 60)
    var samples: [Float] = []
    samples.reserveCapacity(Int(seconds * sampleRate) + 4096)

    var scriptIndex = 0
    var framesIntoSegment = 0

    for _ in 0..<totalFrames {
        if scriptIndex < script.count {
            let segment = script[scriptIndex]
            if framesIntoSegment == 0 {
                nes.controller1.releaseAll()
                nes.controller1.press(segment.0)
            }
            framesIntoSegment += 1
            if framesIntoSegment >= segment.1 {
                scriptIndex += 1
                framesIntoSegment = 0
            }
        } else {
            nes.controller1.releaseAll()
        }

        nes.stepFrame()
        // Drain each frame so the ring buffer never overflows.
        let ready = nes.apu.availableSamples
        if ready > 0 { samples.append(contentsOf: nes.apu.drain(count: ready)) }
    }

    writeWAV(samples, sampleRate: Int(sampleRate), to: outPath)

    // Report signal statistics — the cheapest way to confirm this is music
    // rather than silence or a DC offset.
    let peak = samples.map(abs).max() ?? 0
    let rms = (samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(samples.count, 1))).squareRoot()
    let crossings = zip(samples, samples.dropFirst()).count { ($0 < 0) != ($1 < 0) }
    print(String(format: """
                 Rendered %.1fs — %d samples at %.0f Hz
                   peak amplitude:  %.4f
                   RMS:             %.4f
                   zero crossings:  %d  (~%.0f Hz average)
                 """, seconds, samples.count, sampleRate, peak, rms, crossings,
                 Double(crossings) / 2.0 / seconds))
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

/// Writes 16-bit mono PCM as a WAV. Hand-rolled so the CLI stays free of
/// AVFoundation.
func writeWAV(_ samples: [Float], sampleRate: Int, to path: String) {
    var data = Data()

    func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
    func append32(_ value: UInt32) {
        data.append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }
    func append16(_ value: UInt16) {
        data.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    let byteCount = UInt32(samples.count * 2)

    append("RIFF")
    append32(36 + byteCount)
    append("WAVE")
    append("fmt ")
    append32(16)                        // PCM header size
    append16(1)                         // format: PCM
    append16(1)                         // channels: mono
    append32(UInt32(sampleRate))
    append32(UInt32(sampleRate * 2))    // byte rate
    append16(2)                         // block align
    append16(16)                        // bits per sample
    append("data")
    append32(byteCount)

    for sample in samples {
        let clamped = max(-1.0, min(1.0, sample))
        append16(UInt16(bitPattern: Int16(clamped * 32767)))
    }

    try? data.write(to: URL(fileURLWithPath: path))
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
