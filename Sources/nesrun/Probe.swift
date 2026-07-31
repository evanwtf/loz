import Foundation
import NESCore

/// Runs many candidate input scripts from one save state in a single process.
///
/// Working out a route by launching a subprocess per guess is brutally slow —
/// process start and ROM load dominate, and each answer costs a round trip.
/// Batching turns a dozen guesses into one command and one report, which is the
/// difference between exploring a screen in minutes and in seconds.
enum Probe {
    struct Result {
        let script: String
        let screen: UInt8
        let x: UInt8
        let y: UInt8
        let watched: [(UInt16, UInt8)]
        let reachedGoal: Bool
    }

    /// Expands brace patterns so a sweep is one argument rather than a dozen.
    ///
    ///     "right:{0,4,8},up:100"  ->  ["right:0,up:100", "right:4,up:100", ...]
    ///     "right:{0..12/4}"       ->  ["right:0", "right:4", "right:8", "right:12"]
    static func expand(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{"),
              let close = pattern[open...].firstIndex(of: "}")
        else { return [pattern] }

        let prefix = String(pattern[pattern.startIndex..<open])
        let suffix = String(pattern[pattern.index(after: close)...])
        let body = String(pattern[pattern.index(after: open)..<close])

        var values: [String] = []
        if body.contains("..") {
            // "a..b" or "a..b/step"
            let stepParts = body.split(separator: "/")
            let range = stepParts[0].components(separatedBy: "..")
            let step = stepParts.count > 1 ? Int(stepParts[1]) ?? 1 : 1
            if range.count == 2, let from = Int(range[0]), let to = Int(range[1]), step > 0 {
                values = stride(from: from, through: to, by: step).map(String.init)
            }
        } else {
            values = body.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }

        // Recurse so multiple brace groups all expand.
        return values.flatMap { expand(prefix + $0 + suffix) }
    }

    static func run(
        cartridge: Cartridge,
        state: SaveState,
        scripts: [String],
        watch: [UInt16],
        goal: (address: UInt16, value: UInt8)?,
        settleFrames: Int
    ) -> [Result] {
        var results: [Result] = []

        for script in scripts {
            // A fresh machine per candidate: restoring alone can leave audio and
            // interrupt state from the previous run, and a probe has to be a
            // clean experiment.
            guard let nes = try? NES(cartridge: cartridge) else { continue }
            try? nes.restoreState(state)

            runInputScript(nes, script: script, filmstrip: nil, every: 0, scale: 1)
            for _ in 0..<settleFrames { nes.stepFrame() }

            let screen = nes.cpuRead(Navigator.screenAddress)
            let watched = watch.map { ($0, nes.cpuRead($0)) }
            let reached = goal.map { nes.cpuRead($0.address) == $0.value } ?? false

            results.append(Result(
                script: script,
                screen: screen,
                x: nes.cpuRead(0x0070),
                y: nes.cpuRead(0x0084),
                watched: watched,
                reachedGoal: reached))
        }
        return results
    }

    static func report(_ results: [Result], goal: (address: UInt16, value: UInt8)?) -> String {
        let width = results.map(\.script.count).max() ?? 10
        var lines: [String] = []

        for result in results {
            let padded = result.script.padding(
                toLength: min(width, 52), withPad: " ", startingAt: 0)
            var line = String(
                format: "  %@  screen $%02X  x=$%02X y=$%02X",
                padded, result.screen, result.x, result.y)
            for (address, value) in result.watched {
                line += String(format: "  $%04X=%02X", address, value)
            }
            if goal != nil, result.reachedGoal { line += "   <== GOAL" }
            lines.append(line)
        }

        if let goal, !results.contains(where: \.reachedGoal) {
            lines.append(String(
                format: "  (no candidate reached $%04X = %02X)", goal.address, goal.value))
        }
        return lines.joined(separator: "\n")
    }
}
