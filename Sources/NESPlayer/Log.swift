import Foundation
import os

/// Unified logging for the player shell.
///
/// `print` was the wrong tool for a game that mostly runs on a phone. Its
/// output only exists if something is attached to the process when the line is
/// written, which means the one run that reproduced a bug is exactly the run
/// nobody was watching. Diagnosing a 120 Hz frame-pacing fault on device cost
/// two failed attempts to catch the console at the right moment, and would
/// have cost none if the numbers had simply been in the system log.
///
/// `os.Logger` writes to the unified log instead: persisted by the OS,
/// readable after the fact, cheap enough to leave enabled, and filterable by
/// category. See `docs/ios-app.md` for how to pull it off a device.
///
/// **String interpolation is redacted by default.** The unified log assumes
/// interpolated values may be private and replaces them with `<private>` when
/// read from another process — which silently turns a useful log into a useless
/// one. Nothing logged here is sensitive (frame timings, ROM geometry, error
/// descriptions), so call sites mark values `privacy: .public` deliberately.
enum Log {
    /// One subsystem for the whole player, so `log stream --subsystem` catches
    /// everything regardless of which game is running.
    private static let subsystem = "wtf.evan.loz"

    /// Emulator lifecycle: creation, start, stop, ROM selection.
    static let host = Logger(subsystem: subsystem, category: "host")

    /// Frame pacing. The category that matters when the game runs at the wrong
    /// speed or the picture moves while input does not.
    static let clock = Logger(subsystem: subsystem, category: "clock")

    /// Audio session, engine, and buffer health.
    static let audio = Logger(subsystem: subsystem, category: "audio")

    /// Save states, battery RAM, and auto-resume.
    static let state = Logger(subsystem: subsystem, category: "state")

    /// Anything user-interface shaped that is worth explaining after the fact.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
