import Foundation
import NESCore

/// Finds the RAM addresses an event moved, by comparing snapshots.
///
/// This is the discovery half of the symbol map. Static analysis can say that a
/// routine writes to `$0657`; only running the game can say that `$0657` is the
/// sword. Take a snapshot, do the thing, take another, and the difference is a
/// candidate list.
///
/// The difficulty is that the raw difference is useless. Between two snapshots a
/// few hundred frames apart, hundreds of bytes have moved — the RNG, animation
/// counters, sprite scratch, the frame counter, scroll state. The signal is
/// perhaps two bytes wide and buried in noise that has nothing to do with what
/// was being tested.
///
/// So the interesting mode is not `--before/--after` but `--control`: a second
/// run of comparable length in which the event did *not* happen. Anything that
/// moved in the control moves on its own, and is subtracted. What survives is
/// short enough to read.
enum RamDiff {
    /// One address whose value changed.
    struct Change {
        let address: UInt16
        let before: UInt8
        let after: UInt8
        /// Also changed in the control run, so it moves on its own.
        let noisy: Bool
    }

    /// The two regions worth comparing. Anything else in the address space is
    /// either registers or the cartridge, and neither is state the game owns.
    ///
    /// PRG-RAM is included because Zelda's save files live there, which makes
    /// this the way to find where an inventory item is *persisted* as opposed to
    /// where it is cached for the current session — those are different
    /// addresses and confusing them produces symbols that work until you reload.
    static let ramBase: UInt16 = 0x0000
    static let prgRAMBase: UInt16 = 0x6000

    static func compare(
        before: SaveState,
        after: SaveState,
        control: SaveState?,
        includePRGRAM: Bool
    ) -> [Change] {
        var changes: [Change] = []

        func scan(_ base: UInt16, _ from: [UInt8], _ to: [UInt8], _ noise: [UInt8]?) {
            let count = min(from.count, to.count)
            for offset in 0..<count {
                guard from[offset] != to[offset] else { continue }
                let noisy = noise.map { offset < $0.count && $0[offset] != from[offset] }
                changes.append(Change(
                    address: base + UInt16(offset),
                    before: from[offset],
                    after: to[offset],
                    noisy: noisy ?? false))
            }
        }

        scan(ramBase, before.ram, after.ram, control?.ram)
        if includePRGRAM {
            scan(prgRAMBase, before.prgRAM, after.prgRAM, control?.prgRAM)
        }
        return changes
    }

    static func report(
        _ changes: [Change],
        symbols: SymbolMap,
        hasControl: Bool,
        showNoisy: Bool
    ) -> String {
        let interesting = changes.filter { showNoisy || !$0.noisy }
        var lines: [String] = []

        let suppressed = changes.count - interesting.count
        if hasControl {
            lines.append("\(changes.count) bytes changed, "
                + "\(suppressed) also changed in the control run "
                + "-> \(interesting.count) candidates")
        } else {
            lines.append("\(changes.count) bytes changed "
                + "(no --control given, so this includes everything that "
                + "moves on its own)")
        }
        lines.append("")

        guard !interesting.isEmpty else {
            lines.append("  (nothing survived)")
            return lines.joined(separator: "\n")
        }

        for change in interesting {
            var line = String(
                format: "  $%04X  %02X -> %02X", change.address, change.before, change.after)
            // A byte going 0 -> 1 is what "acquired an item" looks like, and it
            // is worth calling out because it is the shape most searches want.
            if change.before == 0, change.after == 1 { line += "  [0->1]" }
            if change.noisy { line += "  [noisy]" }
            if let name = symbols[change.address] { line += "  \(name)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
