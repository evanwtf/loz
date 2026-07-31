import Foundation

/// Identifies the running build.
///
/// Exists because "is the phone actually running the build I just installed?"
/// came up repeatedly while chasing a device-only bug, and there was no way to
/// answer it from the device. Guessing wrong is expensive in both directions:
/// a fix dismissed as ineffective when it was never installed, or a stale build
/// blamed on the wrong change.
public enum BuildInfo {
    /// Marketing version, e.g. "1.0".
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
    }

    /// Build number.
    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Debug or Release. Worth surfacing: at `-Onone` the interpreter runs at
    /// roughly a quarter speed and the game looks broken rather than slow, so
    /// "which configuration is this" is a real diagnostic question.
    public static var configuration: String {
        #if DEBUG
            "debug"
        #else
            "release"
        #endif
    }

    /// When the binary was linked, taken from the executable's modification
    /// date. Not a git commit — that would need a build phase in every app
    /// project — but it answers the question that actually gets asked, which is
    /// whether this is the build from a minute ago or from this morning.
    public static var built: Date? {
        guard let url = Bundle.main.executableURL,
              let attributes = try? FileManager.default
              .attributesOfItem(atPath: url.path)
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// Compact one-line form for the diagnostics overlay.
    public static var short: String {
        let stamp = built.map {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            return formatter.string(from: $0)
        } ?? "unknown"
        return "\(version) (\(build)) \(configuration) · \(stamp)"
    }

    /// Fuller form for the log, written once at launch so every captured log
    /// says which build produced it.
    public static var summary: String {
        let stamp = built.map(ISO8601DateFormatter().string(from:)) ?? "unknown"
        return "version \(version) build \(build) \(configuration) linked \(stamp)"
    }
}
