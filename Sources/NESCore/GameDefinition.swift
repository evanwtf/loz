import Foundation

/// Everything an app target needs to present exactly one game.
///
/// The app shell is game-agnostic: it takes a `GameDefinition`, embeds that
/// game's ROM as a bundle resource, and launches straight into it. There is no
/// ROM picker and no library UI — one app is one game. Adding another title
/// means writing another conformance, not another emulator.
public protocol GameDefinition {

    /// Display name, used for the app title and window.
    static var title: String { get }

    /// Name of the ROM resource inside the app bundle, without extension.
    static var romResourceName: String { get }

    /// SHA-256 of the expected ROM, lowercase hex. Guards against a wrong or
    /// corrupt dump silently producing garbage — and, once routines are
    /// decompiled, against them being applied to a ROM they were not derived
    /// from, which would be far harder to diagnose.
    static var expectedROMHash: String { get }

    /// Mapper the game is known to use. Checked at load so an unexpected
    /// cartridge fails loudly rather than mysteriously.
    static var expectedMapper: Int { get }

    /// Native reimplementations that replace interpreted 6502 as decompilation
    /// progresses. Empty means "run the whole game interpreted".
    static var nativeRoutines: RoutineTable { get }

    /// Named RAM locations, for debugging overlays and decompiled code.
    static var symbols: SymbolMap { get }
}

extension GameDefinition {
    public static var nativeRoutines: RoutineTable { RoutineTable() }
    public static var symbols: SymbolMap { SymbolMap() }
}

/// Named locations in the CPU address space, recovered by reverse engineering.
public struct SymbolMap: Sendable {
    private var names: [UInt16: String] = [:]

    public init() {}

    public init(_ entries: [UInt16: String]) {
        names = entries
    }

    public subscript(address: UInt16) -> String? {
        get { names[address] }
        set { names[address] = newValue }
    }

    public var count: Int { names.count }

    /// Formats an address as its symbol when known, else as raw hex.
    public func describe(_ address: UInt16) -> String {
        names[address] ?? String(format: "$%04X", address)
    }
}

// MARK: - ROM validation

public enum ROMValidationError: Error, CustomStringConvertible {
    case hashMismatch(expected: String, actual: String)
    case mapperMismatch(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .hashMismatch(let expected, let actual):
            return "ROM hash mismatch.\n  expected \(expected)\n  actual   \(actual)"
        case .mapperMismatch(let expected, let actual):
            return "ROM uses mapper \(actual), but this game expects mapper \(expected)."
        }
    }
}

extension GameDefinition {
    /// Verifies a ROM is the exact image this game's decompiled routines and
    /// symbol map were derived from.
    public static func validate(romData: [UInt8], cartridge: Cartridge) throws {
        guard cartridge.mapperNumber == expectedMapper else {
            throw ROMValidationError.mapperMismatch(
                expected: expectedMapper, actual: cartridge.mapperNumber)
        }
        let actual = ROMHash.hex(of: romData)
        guard actual == expectedROMHash.lowercased() else {
            throw ROMValidationError.hashMismatch(expected: expectedROMHash, actual: actual)
        }
    }
}
