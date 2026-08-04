import Foundation

/// A brief message telling the player their quest was written down.
///
/// Zelda writes battery RAM at exactly the moments a player already thinks of
/// as saving — choosing Save, dying and continuing, registering a name — so a
/// notice at that moment lands on an event they were expecting rather than
/// interrupting one they were not.
public struct SaveNotice: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Written here and pushed to iCloud.
        case savedToCloud
        /// Written here, but iCloud could not be reached. Worth saying out
        /// loud: it is the difference between "my other device will have this"
        /// and "it won't", and the player can act on it.
        case savedLocally
    }

    public let id = UUID()
    public let kind: Kind

    public init(kind: Kind) { self.kind = kind }

    public var message: String {
        switch kind {
        case .savedToCloud: "Game saved to iCloud"
        case .savedLocally: "Game saved on this device only"
        }
    }

    public var symbol: String {
        switch kind {
        case .savedToCloud: "checkmark.icloud"
        case .savedLocally: "icloud.slash"
        }
    }

    /// Whether this reports something the player might want to fix.
    public var isWarning: Bool { kind == .savedLocally }
}

/// Carries save notices to the UI.
///
/// On its own object rather than as an `@Published` on `EmulatorHost`, for the
/// same reason `frames` and `diagnostics` are: anything observing an
/// `ObservableObject` is invalidated by *any* of its published properties, so
/// putting this on the host would rebuild every control — and every gesture
/// attached to one — the moment a save happened.
@MainActor
public final class SaveNoticeStream: ObservableObject {
    @Published public private(set) var latest: SaveNotice?

    public init() {}

    func post(_ kind: SaveNotice.Kind) {
        latest = SaveNotice(kind: kind)
    }

    /// Clears a specific notice, so a toast that has timed out cannot dismiss
    /// a newer one that replaced it while it was on screen.
    public func clear(_ notice: SaveNotice) {
        if latest?.id == notice.id { latest = nil }
    }
}
