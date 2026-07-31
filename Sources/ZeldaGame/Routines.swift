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

        table.register(
            bank: 0, address: 0x9BFF, name: "loadPulse1Registers", cycles: 14,
            body: loadPulse1Registers)

        table.register(
            bank: 0, address: 0x9C1D, name: "loadPulse2Registers", cycles: 14,
            body: loadPulse2Registers)

        table.register(
            bank: 0, address: 0x9EE2, name: "lookupSoundTableEntry", cycles: 19,
            body: lookupSoundTableEntry)

        return table
    }

    // MARK: - loadPulse1Registers  (bank 0, $9BFF)
    //
    //   8C 01 40  STY $4001      ; sweep first
    //   8E 00 40  STX $4000      ; then duty/envelope
    //   60        RTS
    //
    // Neither store touches the flags — STX and STY never do.
    //
    // Note the order: sweep before control. `loadPulse2Registers` below writes
    // its pair the other way round. That asymmetry is real and preserved: the
    // sweep unit reloads off a write to the control register, so swapping the
    // two changes when the sweep divider resets.

    static let loadPulse1Registers: @Sendable (NES) -> Void = { nes in
        nes.cpuWrite(0x4001, nes.cpu.y)
        nes.cpuWrite(0x4000, nes.cpu.x)
    }

    // MARK: - loadPulse2Registers  (bank 0, $9C1D)
    //
    //   8E 04 40  STX $4004      ; duty/envelope first
    //   8C 05 40  STY $4005      ; then sweep
    //   60        RTS

    static let loadPulse2Registers: @Sendable (NES) -> Void = { nes in
        nes.cpuWrite(0x4004, nes.cpu.x)
        nes.cpuWrite(0x4005, nes.cpu.y)
    }

    // MARK: - lookupSoundTableEntry  (bank 0, $9EE2)
    //
    //   29 07     AND #$07       ; keep the low three bits
    //   18        CLC
    //   6D F4 05  ADC $05F4      ; add the current table base
    //   A8        TAY
    //   B9 D1 9F  LDA $9FD1,Y    ; index a table in this bank
    //   60        RTS
    //
    // Returns the indexed byte in A, leaving the computed index in Y. The ADC
    // is a real add-with-carry — CLC first means carry-in is zero, but it still
    // sets C and V on overflow, and a caller may branch on them.

    static let lookupSoundTableEntry: @Sendable (NES) -> Void = { nes in
        let masked = nes.cpu.a & 0x07
        nes.cpu.a = masked
        nes.cpu.setZeroNegative(masked)

        nes.cpu.setCarry(false)
        nes.cpu.addWithCarry(nes.cpuRead(0x05F4))

        nes.cpu.y = nes.cpu.a
        nes.cpu.setZeroNegative(nes.cpu.y)

        let entry = nes.cpuRead(0x9FD1 &+ UInt16(nes.cpu.y))
        nes.cpu.a = entry
        nes.cpu.setZeroNegative(entry)
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
