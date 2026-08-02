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
            bank: 0, address: 0x9D42, name: "resetAudio", cycles: 22,
            body: resetAudio)

        table.register(
            bank: 0, address: 0xBF98, name: "writeMapperControl", cycles: 34,
            body: writeMapperControl)

        table.register(
            bank: 0, address: 0xBFAC, name: "writeMapperPRGBank", cycles: 34,
            body: writeMapperPRGBank)

        table.register(
            bank: 0, address: 0x9BFF, name: "loadPulse1Registers", cycles: 14,
            body: loadPulse1Registers)

        table.register(
            bank: 0, address: 0x9C1D, name: "loadPulse2Registers", cycles: 14,
            body: loadPulse2Registers)

        table.register(
            bank: 0, address: 0x9EE2, name: "lookupSoundTableEntry", cycles: 20,
            body: lookupSoundTableEntry)

        table.register(
            bank: 0, address: 0x9EDC, name: "lookupRotatedSoundTableEntry", cycles: 32,
            body: lookupRotatedSoundTableEntry)

        table.register(
            bank: 0, address: 0x9F72, name: "loadNoiseDefaults", cycles: 16,
            body: loadNoiseDefaults)

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

    // MARK: - lookupRotatedSoundTableEntry  (bank 0, $9EDC)
    //
    //   AA        TAX            ; keep the original
    //   6A        ROR A          ; seed carry from bit 0
    //   8A        TXA            ; restore it, carry survives
    //   2A        ROL A          ; rotate left three times *through* carry
    //   2A        ROL A
    //   2A        ROL A
    //   ... then falls straight into lookupSoundTableEntry at $9EE2 ...
    //
    // The `ROR`/`TXA` pair is not a shift of the value: it is there purely to
    // load carry with bit 0 and then throw the shifted result away, so that the
    // three `ROL`s rotate rather than shift. Treating any of the four as a
    // plain shift loses a bit per step and yields a table index that is wrong
    // in a way that still looks like a plausible sound.
    //
    // Note this routine *falls through* into `$9EE2` rather than calling it,
    // so the native version has to reproduce that tail as well. Both addresses
    // are registered: the dispatcher keys on PC, so entering at either works.

    static let lookupRotatedSoundTableEntry: @Sendable (NES) -> Void = { nes in
        nes.cpu.x = nes.cpu.a
        nes.cpu.setZeroNegative(nes.cpu.x)

        // ROR A: the result is discarded by the TXA that follows, but the carry
        // it leaves behind is the whole reason the instruction is here.
        _ = nes.cpu.rotateRight(nes.cpu.a)

        nes.cpu.a = nes.cpu.x
        nes.cpu.setZeroNegative(nes.cpu.a)

        for _ in 0..<3 {
            nes.cpu.a = nes.cpu.rotateLeft(nes.cpu.a)
        }

        // Falls through into $9EE2.
        lookupSoundTableEntry(nes)
    }

    // MARK: - loadNoiseDefaults  (bank 0, $9F72)
    //
    //   AD 19 06  LDA $0619      ; read, then immediately discarded
    //   A9 20     LDA #$20
    //   A2 82     LDX #$82
    //   A0 7F     LDY #$7F
    //   60        RTS
    //
    // Returns three constants in A, X and Y. The leading load is dead — its
    // value and its flags are both overwritten by the `LDA #$20` on the next
    // instruction — but it is reproduced anyway rather than optimised away.
    // `$0619` is plain RAM here so the read has no side effect, but "this load
    // looks pointless" is exactly the reasoning that turns a hardware register
    // read into a silent behaviour change, and the rule is cheaper to keep than
    // to make exceptions to.

    static let loadNoiseDefaults: @Sendable (NES) -> Void = { nes in
        _ = nes.cpuRead(0x0619)

        nes.cpu.a = 0x20
        nes.cpu.x = 0x82
        nes.cpu.y = 0x7F
        // Every load sets Z and N; the last one is what a caller sees.
        nes.cpu.setZeroNegative(0x7F)
    }

    // MARK: - writeMapperControl  (bank 0, $BF98)
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
    // Which of MMC1's four registers is written is decided by the address, and
    // this one always stores to $8000 — the control register.

    static let writeMapperControl: @Sendable (NES) -> Void = { nes in
        nes.cpu.a = serialWrite(nes, to: 0x8000, value: nes.cpu.a)
    }

    // MARK: - writeMapperPRGBank  (bank 0, $BFAC)
    //
    //   8D 00 E0  STA $E000
    //   4A        LSR A
    //   ... repeated, five stores and four shifts ...
    //   60        RTS
    //
    // The same serial protocol as `writeMapperControl`, aimed at $E000 instead:
    // on MMC1 the register is selected by which quarter of $8000-$FFFF the
    // store lands in, and $E000 is the PRG bank register. So this is the
    // routine that switches banks — which makes it the one whose side effect is
    // least forgiving, since getting it wrong changes what code runs next.

    static let writeMapperPRGBank: @Sendable (NES) -> Void = { nes in
        nes.cpu.a = serialWrite(nes, to: 0xE000, value: nes.cpu.a)
    }

    /// MMC1's serial write: five stores of the same value, shifted right
    /// between each, so the mapper latches bits 0 through 4 in turn.
    ///
    /// Shared because the two callers differ only in the address, and a copy
    /// would be a place for the two to drift apart.
    private static func serialWrite(_ nes: NES, to address: UInt16, value: UInt8) -> UInt8 {
        var value = value
        nes.cpuWrite(address, value)

        for _ in 0..<4 {
            value = nes.cpu.shiftRight(value)
            nes.cpuWrite(address, value)
        }
        return value
    }
}
