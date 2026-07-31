import NESCore

/// Routines converted from 6502 to native Swift.
///
/// Each one is registered in `Zelda.nativeRoutines` and is verified against the
/// interpreter by `RoutineEquivalenceTests` before being trusted. The flags a
/// routine leaves behind are part of its contract — callers branch on them — so
/// they are reproduced explicitly rather than left to chance.
public enum ZeldaRoutines {

    /// Builds the table of everything converted so far.
    public static func table() -> RoutineTable {
        var table = RoutineTable()

        table.register(
            bank: 0, address: 0x9D42, name: "resetAudio", cycles: 20,
            body: resetAudio)

        table.register(
            bank: 0, address: 0xBF98, name: "writeMapperRegister", cycles: 30,
            body: writeMapperRegister)

        return table
    }

    // MARK: - resetAudio  (bank 0, $9D42)
    //
    //   A9 00     LDA #$00
    //   8D 09 06  STA $0609      ; clear the sound-request flag
    //   8D 15 40  STA $4015      ; silence every channel
    //   A9 0F     LDA #$0F
    //   8D 15 40  STA $4015      ; re-enable pulse 1/2, triangle, noise
    //   60        RTS
    //
    // The two $4015 writes must happen in this order and both must happen:
    // writing 0 clears the length counters, and only then does re-enabling
    // leave the channels genuinely silent rather than mid-note. Collapsing it
    // to a single write to $4015 would look equivalent and sound wrong.

    static let resetAudio: @Sendable (NES) -> Void = { nes in
        nes.cpu.a = 0x00
        nes.cpu.setZeroNegative(0x00)

        nes.cpuWrite(0x0609, 0x00)
        nes.cpuWrite(0x4015, 0x00)

        nes.cpu.a = 0x0F
        nes.cpu.setZeroNegative(0x0F)

        nes.cpuWrite(0x4015, 0x0F)
    }

    // MARK: - writeMapperRegister  (bank 0, $BF98)
    //
    //   8D 00 80  STA $8000
    //   4A        LSR A
    //   ... repeated, five stores and four shifts ...
    //   60        RTS
    //
    // This is the MMC1 serial write protocol. The mapper latches one bit per
    // write — the low bit of the value — so a register is programmed by storing
    // the value five times, shifting right between stores to present bits 0
    // through 4 in turn.
    //
    // Note the address is always $8000 here; which of MMC1's four registers is
    // written is decided by the address of the *fifth* store, so this helper
    // only ever targets the control register.

    static let writeMapperRegister: @Sendable (NES) -> Void = { nes in
        var value = nes.cpu.a

        nes.cpuWrite(0x8000, value)

        for _ in 0..<4 {
            // LSR: carry takes bit 0, the result shifts right, N is always
            // cleared because bit 7 becomes 0.
            nes.cpu.setCarry(value & 0x01 != 0)
            value >>= 1
            nes.cpu.setZeroNegative(value)

            nes.cpuWrite(0x8000, value)
        }

        nes.cpu.a = value
    }
}
