import Foundation
import NESCore

/// Persists a snapshot of the running machine so the game resumes exactly where
/// it was left, without the player ever choosing to save.
///
/// This is what makes a 1986 game workable on a phone. Sessions are minutes
/// long and get interrupted constantly, and Zelda's own save only records
/// progress at coarse checkpoints — it will not put you back in the middle of a
/// dungeon room. An automatic snapshot does.
///
/// Kept separate from the numbered save-state slots on purpose: those are the
/// player's, and an automatic write must never overwrite one.
enum AutoResume {
    /// How often to snapshot while playing, in emulated frames.
    ///
    /// Backgrounding writes a snapshot anyway, so this only covers cases where
    /// no notification arrives — an out-of-memory kill, a crash, or a force
    /// quit. Twenty seconds bounds the worst-case loss to something a player
    /// would shrug at, while being far too infrequent to matter for wear or
    /// battery.
    static let intervalFrames = 20 * 60

    static func url(for gameName: String) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        else { return nil }

        let directory = base.appendingPathComponent("loz", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(gameName).autoresume")
    }

    /// Encodes and writes off the main actor.
    ///
    /// Capturing state is a cheap array copy, but encoding and file I/O should
    /// not sit in the frame loop. `SaveState` is `Sendable`, so the captured
    /// value crosses over safely.
    static func write(_ state: SaveState, to url: URL) {
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(state)
                try data.write(to: url, options: .atomic)
            } catch {
                // Losing an automatic snapshot must never disturb play.
                print("auto-resume: write failed — \(error)")
            }
        }
    }

    static func read(from url: URL) -> SaveState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SaveState.self, from: data)
    }

    static func clear(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
