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

    /// The git commit this was built from, e.g. `6b2c68a` or `6b2c68a+` when
    /// the tree had uncommitted changes.
    ///
    /// Stamped into `Info.plist` by a build phase in each app project, because
    /// nothing in a compiled binary knows this otherwise. That means it is
    /// present in the apps and absent from SwiftPM builds (`zeldamac`, tests),
    /// which have no `Info.plist` — and absent is the honest answer there
    /// rather than a number that might be stale.
    ///
    /// The `+` matters more than the hash on a development build: it is the
    /// difference between "this is exactly that commit" and "this is that
    /// commit plus whatever was in my editor", and only one of those is worth
    /// quoting in a bug report.
    public static var commit: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GitCommit")
            as? String, !value.isEmpty, value != "$(GIT_COMMIT)"
        else { return "—" }
        return value
    }

    /// When the binary was linked, taken from the executable's modification
    /// date. Complements `commit`: the hash says *what* was built and this says
    /// *when*, which together answer "is the device running what I just
    /// installed?" even when the hash has not moved between two builds.
    public static var built: Date? {
        guard let url = Bundle.main.executableURL,
              let attributes = try? FileManager.default
              .attributesOfItem(atPath: url.path)
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// Which build this is, without the timestamp — "1.0 (1) release".
    public static var identity: String {
        "\(version) (\(build)) \(configuration)"
    }

    /// When it was linked, in a form short enough for a narrow overlay column.
    public static var builtStamp: String {
        built.map {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            return formatter.string(from: $0)
        } ?? "unknown"
    }

    /// Compact one-line form.
    public static var short: String {
        "\(identity) · \(commit) · \(builtStamp)"
    }

    /// Fuller form for the log, written once at launch so every captured log
    /// says which build produced it.
    public static var summary: String {
        let stamp = built.map(ISO8601DateFormatter().string(from:)) ?? "unknown"
        return "version \(version) build \(build) \(configuration) "
            + "commit \(commit) linked \(stamp)"
    }
}
