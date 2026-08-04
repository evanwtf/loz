import CoreGraphics
import Foundation
import ImageIO
import NESCore
import UniformTypeIdentifiers

/// Numbered save-state slots on disk, each with a thumbnail.
///
/// Distinct from the cartridge battery save, which the game itself writes and
/// which is persisted automatically. These are full machine snapshots, so they
/// capture the exact moment — mid-room, mid-fight — which is what makes a
/// 1986 game bearable on a phone during a commute.
@MainActor
public final class SaveStateStore: ObservableObject {
    public struct Slot: Identifiable, Sendable {
        public let index: Int
        public var savedAt: Date?
        public var thumbnail: CGImage?

        public var id: Int { index }
        public var isEmpty: Bool { savedAt == nil }
    }

    public static let slotCount = 4

    @Published public private(set) var slots: [Slot]

    private let directory: URL?
    private let romHash: String

    public init(gameName: String, romHash: String) {
        self.romHash = romHash

        directory = SaveLocation.directory("loz", "states", gameName)

        slots = (0..<Self.slotCount).map { Slot(index: $0) }
        refresh()
    }

    // MARK: Paths

    private func stateURL(_ index: Int) -> URL? {
        directory?.appendingPathComponent("slot\(index).state")
    }

    private func thumbnailURL(_ index: Int) -> URL? {
        directory?.appendingPathComponent("slot\(index).png")
    }

    // MARK: Loading metadata

    public func refresh() {
        for index in 0..<Self.slotCount {
            guard let url = stateURL(index),
                  let attributes = try? FileManager.default.attributesOfItem(
                      atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date
            else {
                slots[index] = Slot(index: index)
                continue
            }
            slots[index] = Slot(
                index: index,
                savedAt: modified,
                thumbnail: loadThumbnail(index))
        }
    }

    private func loadThumbnail(_ index: Int) -> CGImage? {
        guard let url = thumbnailURL(index),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Save and load

    @discardableResult
    public func save(_ nes: NES, frame: CGImage?, to index: Int) -> Bool {
        guard let url = stateURL(index) else { return false }
        do {
            let state = nes.captureState(romHash: romHash)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
            if let frame { writeThumbnail(frame, to: index) }
            refresh()
            return true
        } catch {
            Log.state.error("save slot \(index, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    public func load(into nes: NES, from index: Int) -> Bool {
        guard let url = stateURL(index),
              let data = try? Data(contentsOf: url)
        else { return false }
        do {
            let state = try JSONDecoder().decode(SaveState.self, from: data)
            // Refuses a snapshot taken from a different ROM, which would
            // otherwise load as convincing-looking nonsense.
            try nes.restoreState(state, romHash: romHash)
            return true
        } catch {
            Log.state.error("load slot \(index, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func delete(_ index: Int) {
        if let url = stateURL(index) { try? FileManager.default.removeItem(at: url) }
        if let url = thumbnailURL(index) { try? FileManager.default.removeItem(at: url) }
        refresh()
    }

    private func writeThumbnail(_ image: CGImage, to index: Int) {
        guard let url = thumbnailURL(index),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
