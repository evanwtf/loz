import CoreGraphics
import Foundation
import ImageIO
import NESAnalysis
import NESCore
import UniformTypeIdentifiers
import ZeldaGame

// Minimal hand-rolled CLI; no external dependencies while the core is in flux.

func usage() -> Never {
    // Every command takes the ROM path as its second argument, so the list
    // below is deliberately exhaustive: this help is what CI prints, and it is
    // the first thing an agent reads when it needs a capability it has not
    // used before. A command missing here is a command nobody finds.
    print("""
    nesrun — decompilation harness for the loz project
    
    USAGE:
      nesrun <command> <rom.nes> [options]
    
    INSPECTION:
      info     Parse the iNES header and print cartridge geometry and vectors.
      hash     Print the ROM's SHA-256, for pinning a GameDefinition.
      analyze  Recursive-descent trace from the interrupt vectors; reports the
               code/data split, routine inventory, and per-bank coverage.
      disasm   Emit an annotated listing for one 16KB PRG bank.
               --bank <n>           Which bank to disassemble (required).
               --out <file.asm>     Write to a file instead of stdout.
    
    RUNNING:
      run      Boot the ROM headlessly for N frames and dump the framebuffer.
      play     Drive the game with a scripted input sequence. Designed to be
               run by an agent: no window, PNG output, resumable snapshots.
      probe    Run many candidate input scripts from one snapshot in a single
               process — the fast way to work out a route. A subprocess per
               guess is dominated by process start and ROM load.
               --load-state <file>  Snapshot to branch from (required).
               --inputs <pattern>   Brace-expanded scripts (required), e.g.
                                    "right:{0..12/4},up:100" or "{a,b}:4".
               --goal <ADDR=VAL>    Hex RAM condition marking success.
               --watch <addrs>      Comma-separated hex addresses to report.
               --settle <n>         Frames to run after each script (default 30).
               --save-state <file>  Write the first candidate that hit --goal.
      navigate Pathfind to an overworld screen by searching over $00EB.
               --load-state <file>  Snapshot to start from (required).
               --to <hex screen>    Destination, e.g. --to 37 (required).
               --move-frames <n>    Frames per move (default 170).
               --max-screens <n>    Search limit (default 80).
               --save-state <file>  Write the arrival state.
               --no-tiles           Skip the tile-aware routes and sweep only.
               --verbose            Report each screen as it is explored.
      tiles    Read the room's geometry out of the nametable as a 16x11 walkable
               grid, and route across it. Replaces guessing at a room with
               reading the one the emulator is already drawing.
               --load-state <file>  Snapshot to read.
               --input <script>     Input to run first.
               --settle <n>         Frames before reading (default 30).
               --to-cell <C,R>      Route there; prints the path and a script.
                                    Exits 2 when there is no route.
               --frames-per-cell <n>  Frames per 16px cell in the script (16).
               --raw                Dump the whole 32x30 nametable as hex.
               --census             Report which tiles Link stood on while the
                                    input ran — how the walkable set is built.
               --table <n>          Nametable to read (default: the active one).
    
      clearroom Fight everything in the current room until it is empty, then
               collect what dropped. A closed loop, not a fixed script: enemies
               move, so a replayed script cannot follow them. Counts what is
               left from the enemy slot table at $0350 (OAM undercounts a room
               it has not drawn yet) and aims from OAM.
               --load-state <file>  Snapshot to start from (required).
               --input <script>     Input to run first, e.g. to step in a door.
               --max-frames <n>     Give-up limit (default 3600).
               --save-state <file>  Write the state once the room is clear.
               --out <file.png>     Screenshot the result.
               --verbose            Report every decision the loop makes.
    
    VERIFICATION:
      ramdiff  Compare two snapshots and report which RAM addresses moved.
               How the symbol map gets built: do a thing, diff, read.
               --before <file>      Snapshot from before the event (required).
               --after <file>       Snapshot from after it (required).
               --control <file>     A run of similar length in which the event
                                    did NOT happen. Addresses that moved there
                                    move on their own and are subtracted. The
                                    raw diff is hundreds of bytes of noise;
                                    this is what makes the output readable.
               --show-noisy         Keep the subtracted ones, marked.
               --no-prg-ram         Skip $6000-$7FFF (the save files).
      oam      List the actors the PPU is drawing — Link, enemies, and items —
               with positions. What is on screen, not what the map says.
               --load-state <file>  Snapshot to inspect.
               --input <script>     Input to run first.
               --settle <n>         Frames before reading (default 30).
      mapcheck Correlate the rendered screen against the reference overworld
               map. Turns "does it look right" into a number.
               --load-state <file>  Snapshot to check (required).
               --map <file.png>     Default Reference/overworld-first-quest.png.
               --threshold <0..1>   Pass mark (default 0.55).
               --settle <n>         Frames before sampling (default 90) — too
                                    few captures a mid-scroll composite.
      audio    Render the APU to a WAV with signal statistics.
               --seconds <n>        Duration (default 10).
               --out <file.wav>     Output path (default audio.wav).
               --load-state <file>  Resume from a snapshot instead of booting.
               --input <script>     Input to drive while recording.
      paltrace Log every write that reaches palette memory, so a transfer
               landing at the wrong address is immediately visible.
               --frames <n>         Frames to trace (default 45).
    
    CODEGEN:
      embed    Emit the cartridge image as Swift source so the app needs no
               .nes file at runtime. The output is gitignored.
               --out <file.swift>   Default Sources/ZeldaGame/ZeldaROMData.swift.
               --enum <name>        Generated enum name (default ZeldaROMData).
               --extend <type>      Type to add `embeddedROM` to (default Zelda).
    
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
      --native             Install decompiled Swift routines and report their
                           call counts.
      --trace              Record executed code and report new coverage.
      --trace-in <file>    Merge a previous trace so coverage accumulates.
      --trace-out <file>   Write the merged trace.
    
    See docs/agent-harness.md for input-script syntax and worked examples.
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

/// Reads a snapshot named by a flag. Returns nil when the flag is absent, and
/// exits when it is present but unreadable — a typo'd path should not look the
/// same as an omitted option.
func loadState(_ flagName: String) -> SaveState? {
    guard let path = flag(flagName, in: args) else { return nil }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let state = try? JSONDecoder().decode(SaveState.self, from: data)
    else {
        FileHandle.standardError.write(
            "error: could not read \(flagName) \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return state
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

case "embed":
    // Emits the cartridge image as Swift source so the app needs no .nes file.
    let outPath = flag("--out", in: args) ?? "Sources/ZeldaGame/ZeldaROMData.swift"
    let enumName = flag("--enum", in: args) ?? "ZeldaROMData"
    let romBytes = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: romPath)))

    let source = EmbedROM.generate(
        romData: romBytes, enumName: enumName, gameName: Zelda.title,
        conformingType: flag("--extend", in: args) ?? "Zelda")
    try! source.write(to: URL(fileURLWithPath: outPath), atomically: true, encoding: .utf8)

    print("""
    Embedded \(romBytes.count) bytes as \(enumName)
      sha256: \(ROMHash.hex(of: romBytes))
      wrote:  \(outPath)  (\(source.count / 1024) KB of source)
    """)

case "probe":
    // Many candidate scripts, one process. Working out a route by launching a
    // subprocess per guess is dominated by process start and ROM load.
    guard let statePath = flag("--load-state", in: args),
          let pattern = flag("--inputs", in: args)
    else {
        FileHandle.standardError.write(
            "error: probe needs --load-state and --inputs\n".data(using: .utf8)!)
        exit(1)
    }

    let state = try! JSONDecoder().decode(
        SaveState.self, from: try! Data(contentsOf: URL(fileURLWithPath: statePath)))
    let scripts = Probe.expand(pattern)

    let watch = (flag("--watch", in: args) ?? "")
        .split(separator: ",")
        .compactMap { UInt16($0.trimmingCharacters(in: .whitespaces), radix: 16) }

    var goal: (address: UInt16, value: UInt8)?
    if let spec = flag("--goal", in: args) {
        let parts = spec.split(separator: "=")
        if parts.count == 2,
           let address = UInt16(parts[0], radix: 16),
           let value = UInt8(parts[1], radix: 16)
        {
            goal = (address, value)
        }
    }

    let settle = Int(flag("--settle", in: args) ?? "30") ?? 30
    print("Probing \(scripts.count) candidates...")
    let results = Probe.run(
        cartridge: cartridge, state: state, scripts: scripts,
        watch: watch, goal: goal, settleFrames: settle)
    print(Probe.report(results, goal: goal))

    // Save the first candidate that hit the goal, so a successful probe leaves
    // a state to continue from rather than needing a re-run.
    if let outPath = flag("--save-state", in: args),
       let winner = results.first(where: \.reachedGoal)
    {
        guard let nes = try? NES(cartridge: cartridge) else { break }
        try? nes.restoreState(state)
        runInputScript(nes, script: winner.script, filmstrip: nil, every: 0, scale: 1)
        for _ in 0..<settle { nes.stepFrame() }
        try! JSONEncoder().encode(nes.captureState()).write(to: URL(fileURLWithPath: outPath))
        print("\nSaved winning state (\(winner.script)) to \(outPath)")
    }

case "mapcheck":
    // Structural comparison of rendered overworld screens against the
    // reference map. Turns "does the overworld look right" into a number.
    let mapPath = flag("--map", in: args) ?? "Reference/overworld-first-quest.png"
    let threshold = Double(flag("--threshold", in: args) ?? "0.55") ?? 0.55

    guard let statePath = flag("--load-state", in: args) else {
        FileHandle.standardError.write(
            "error: mapcheck needs --load-state\n".data(using: .utf8)!)
        exit(1)
    }
    let start = try! JSONDecoder().decode(
        SaveState.self, from: try! Data(contentsOf: URL(fileURLWithPath: statePath)))

    let nes = try! NES(cartridge: cartridge)
    try! nes.restoreState(start)
    // Let any in-progress screen transition finish before sampling.
    //
    // This needs to be generous. Zelda scrolls between overworld screens over
    // roughly a second, and `navigate` snapshots on arrival — often mid-scroll.
    // Sampling too early captures a composite of two screens, which scored
    // 0.404 against the map and looked exactly like a rendering bug.
    let settleFrames = Int(flag("--settle", in: args) ?? "90") ?? 90
    for _ in 0..<settleFrames { nes.stepFrame() }

    let screen = nes.cpuRead(Navigator.screenAddress)
    guard let result = MapCheck.score(
        framebuffer: nes.framebuffer, screen: screen, mapPath: mapPath)
    else {
        // The reference map is not in the repository: it is assembled from the
        // game's own graphics and carries Nintendo's copyright notice in the
        // image itself. Say so, rather than leaving a bare "could not read".
        FileHandle.standardError.write("""
        error: could not read \(mapPath), or screen $\(String(format: "%02X", screen)) \
        is out of range.
        
        The reference map is not committed — it is built from ripped game
        graphics. Supply your own and pass it with --map, or drop it at
        Reference/overworld-first-quest.png (gitignored). It must be the
        4352x1408 First Quest overworld; see docs/agent-harness.md for the
        geometry mapcheck expects.
        
        """.data(using: .utf8)!)
        exit(1)
    }

    let verdict = result.correlation >= threshold ? "PASS" : "FAIL"
    print(String(
        format: "screen $%02X (col %d, row %d)  structural correlation %.3f  [%@]",
        screen, result.column, result.row, result.correlation, verdict))
    if result.correlation < threshold { exit(1) }

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
        verbose: args.contains("--verbose"),
        tileAware: !args.contains("--no-tiles"))

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

case "ramdiff":
    // Which addresses an event moved. See RamDiff for why --control is the
    // flag that makes the output readable.
    guard let before = loadState("--before"), let after = loadState("--after") else {
        FileHandle.standardError.write(
            "error: ramdiff needs --before and --after\n".data(using: .utf8)!)
        exit(1)
    }
    let control = loadState("--control")

    let changes = RamDiff.compare(
        before: before, after: after, control: control,
        includePRGRAM: !args.contains("--no-prg-ram"))

    print(RamDiff.report(
        changes, symbols: Zelda.symbols,
        hasControl: control != nil,
        showNoisy: args.contains("--show-noisy")))

case "oam":
    // What is actually on screen, as opposed to what the room layout says.
    let nes = try! NES(cartridge: cartridge)
    if let statePath = flag("--load-state", in: args) {
        let data = try! Data(contentsOf: URL(fileURLWithPath: statePath))
        try! nes.restoreState(try! JSONDecoder().decode(SaveState.self, from: data))
    }
    runInputScript(nes, script: flag("--input", in: args), filmstrip: nil, every: 0, scale: 1)
    for _ in 0..<(Int(flag("--settle", in: args) ?? "30") ?? 30) { nes.stepFrame() }

    print(String(format: "screen $%02X", nes.cpuRead(Navigator.screenAddress)))
    print(Entities.report(
        oam: nes.ppu.oam,
        linkX: Int(nes.cpuRead(0x0070)),
        linkY: Int(nes.cpuRead(0x0084))))

case "tiles":
    let nes = try! NES(cartridge: cartridge)
    if let state = loadState("--load-state") { try! nes.restoreState(state) }

    // The census has to sample *while* the script runs — the whole point is
    // which tiles Link passed over, not where he stopped.
    var census = Tiles.Census()
    if args.contains("--census") {
        for segment in parseInputScript(flag("--input", in: args)) {
            for _ in 0..<segment.frames {
                nes.controller1.releaseAll()
                nes.controller1.press(segment.buttons)
                nes.stepFrame()
                census.sample(nes: nes)
            }
        }
        nes.controller1.releaseAll()
    } else {
        runInputScript(nes, script: flag("--input", in: args), filmstrip: nil, every: 0, scale: 1)
    }
    for _ in 0..<(Int(flag("--settle", in: args) ?? "30") ?? 30) { nes.stepFrame() }

    let table = Int(flag("--table", in: args) ?? "") ?? nes.ppu.activeNametable

    if args.contains("--census") {
        print(census.report)
    } else if args.contains("--raw") {
        print(Tiles.rawDump(nes: nes, table: table))
    } else {
        let grid = Tiles.grid(nes: nes, table: table)
        let start = Tiles.linkCell(nes: nes)
        print(String(
            format: "screen $%02X  link cell (%d,%d)  nametable %d",
            nes.cpuRead(Navigator.screenAddress), start.column, start.row, table))

        // A goal turns the dump into a route. Without one this is just a
        // picture of the room, which is what you want when checking the
        // walkability table itself.
        if let goal = flag("--to-cell", in: args) {
            let parts = goal.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 2 else {
                FileHandle.standardError.write(
                    "error: --to-cell wants COLUMN,ROW\n".data(using: .utf8)!)
                exit(1)
            }
            let target = TileGrid.Cell(column: parts[0], row: parts[1])
            if let path = grid.path(from: start, to: target) {
                print(grid.render(path: path, start: start, goal: target))
                let frames = Int(flag("--frames-per-cell", in: args) ?? "16") ?? 16
                print("script: " + RouteScript.script(for: path, framesPerCell: frames))
            } else {
                print(grid.render(start: start, goal: target))
                print("no route — fall back to a sweep")
                exit(2)
            }
        } else {
            print(grid.render(start: start))
        }
    }

case "clearroom":
    // Closed loop: read OAM, walk at the nearest actor, swing when close.
    guard let statePath = flag("--load-state", in: args) else {
        FileHandle.standardError.write(
            "error: clearroom needs --load-state\n".data(using: .utf8)!)
        exit(1)
    }
    let nes = try! NES(cartridge: cartridge)
    let data = try! Data(contentsOf: URL(fileURLWithPath: statePath))
    try! nes.restoreState(try! JSONDecoder().decode(SaveState.self, from: data))

    if let input = flag("--input", in: args) {
        runInputScript(nes, script: input, filmstrip: nil, every: 0, scale: 1)
        for _ in 0..<60 { nes.stepFrame() }
    }

    let outcome = ClearRoom.run(
        nes: nes,
        maxFrames: Int(flag("--max-frames", in: args) ?? "3600") ?? 3600,
        verbose: args.contains("--verbose"))

    let verdict = outcome.died ? "DIED" : (outcome.cleared ? "CLEARED" : "TIMED OUT")
    print(String(
        format: "%@ in %d frames, %d swings, %d pickups, %d hits taken, %d enemies left  screen $%02X  health $%02X",
        verdict, outcome.frames, outcome.swings, outcome.pickups, outcome.hitsTaken, outcome.remaining,
        nes.cpuRead(Navigator.screenAddress), nes.cpuRead(0x066F)))

    if let outPath = flag("--out", in: args) {
        writePNG(nes.framebuffer, to: outPath, scale: Int(flag("--scale", in: args) ?? "3") ?? 3)
        print("Wrote \(outPath)")
    }
    if let savePath = flag("--save-state", in: args) {
        try! JSONEncoder().encode(nes.captureState())
            .write(to: URL(fileURLWithPath: savePath))
        print("Saved state to \(savePath)")
    }
    if !outcome.cleared { exit(1) }

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
/// Parses the input-script syntax into button/duration segments.
///
/// Split out from `runInputScript` so a caller that needs to do something
/// between frames — the tile census samples what Link is standing on, which is
/// meaningless once the script has finished — drives the same parse rather than
/// growing a second, subtly different one.
func parseInputScript(_ script: String?) -> [(buttons: NESButton, frames: Int)] {
    var segments: [(buttons: NESButton, frames: Int)] = []

    // Strip `#` comments and line breaks so a script can be kept in a file with
    // a header explaining what it does and what proves it worked. Routes are
    // expensive to re-derive by hand; a bare one-line script that nobody can
    // read is how that knowledge gets lost.
    //
    // Lines are joined with a comma, not concatenated, so a script may break
    // across lines without every line needing a trailing comma. Empty segments
    // — from comment-only lines or a trailing comma — are dropped by `split`.
    let cleaned = (script ?? "wait:60")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.prefix(while: { $0 != "#" }) }
        .joined(separator: ",")
        .filter { !$0.isWhitespace }

    for segment in cleaned.split(separator: ",") {
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
    return segments
}

func runInputScript(
    _ nes: NES,
    script: String?,
    filmstrip: String?,
    every: Int,
    scale: Int
) {
    let segments = parseInputScript(script)

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
