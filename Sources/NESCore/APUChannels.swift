// The five sound channels of the 2A03.

// MARK: - Pulse

/// Square wave with four duty cycles, a volume envelope, and a pitch sweep.
struct PulseChannel {
    /// Duty cycle waveforms. The fourth is the second inverted, which is why it
    /// sounds identical to 25% duty but phase-shifted.
    static let dutyTable: [[UInt8]] = [
        [0, 1, 0, 0, 0, 0, 0, 0],   // 12.5%
        [0, 1, 1, 0, 0, 0, 0, 0],   // 25%
        [0, 1, 1, 1, 1, 0, 0, 0],   // 50%
        [1, 0, 0, 1, 1, 1, 1, 1],   // 25% negated
    ]

    var duty = 0
    var timerPeriod: UInt16 = 0
    var envelope = Envelope()
    var sweep: Sweep
    var length = LengthCounter()

    private var timer: UInt16 = 0
    private var sequencePosition = 0

    init(isPulse1: Bool) {
        sweep = Sweep(isPulse1: isPulse1)
    }

    /// Clocked every APU cycle (every second CPU cycle).
    mutating func clockTimer() {
        if timer == 0 {
            timer = timerPeriod
            sequencePosition = (sequencePosition + 1) % 8
        } else {
            timer -= 1
        }
    }

    mutating func clockSweep() {
        if let updated = sweep.clock(current: timerPeriod) {
            timerPeriod = updated
        }
    }

    var output: UInt8 {
        guard length.isActive,
              !sweep.mutes(current: timerPeriod),
              Self.dutyTable[duty][sequencePosition] != 0
        else { return 0 }
        return envelope.output
    }

    mutating func resetSequencer() {
        sequencePosition = 0
    }
}

// MARK: - Triangle

/// A stepped triangle wave. No volume control — it is either running or not,
/// which is why NES bass lines have such a characteristic flat dynamic.
struct TriangleChannel {
    /// 32 steps down from 15 and back up.
    static let sequence: [UInt8] = [
        15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    ]

    var timerPeriod: UInt16 = 0
    var linear = LinearCounter()
    var length = LengthCounter()

    private var timer: UInt16 = 0
    private var sequencePosition = 0

    /// Clocked every CPU cycle — twice as often as the pulse channels, which is
    /// why the triangle reaches an octave lower for the same period value.
    mutating func clockTimer() {
        if timer == 0 {
            timer = timerPeriod
            // The sequencer only advances while both gates are open. It does
            // not reset, so a re-triggered note resumes mid-waveform.
            if linear.isActive, length.isActive {
                sequencePosition = (sequencePosition + 1) % 32
            }
        } else {
            timer -= 1
        }
    }

    var output: UInt8 {
        // At very short periods the output would be an ultrasonic buzz that
        // mostly manifests as a DC pop. Real hardware does this too, but
        // silencing it is kinder to speakers and inaudible otherwise.
        guard timerPeriod >= 2 else { return 7 }
        return Self.sequence[sequencePosition]
    }
}

// MARK: - Noise

/// Pseudo-random noise from a 15-bit linear feedback shift register.
struct NoiseChannel {
    /// Timer periods selected by the 4-bit period index (NTSC).
    static let periods: [UInt16] = [
        4, 8, 16, 32, 64, 96, 128, 160,
        202, 254, 380, 508, 762, 1016, 2034, 4068,
    ]

    /// False taps bit 1 (long, hiss-like); true taps bit 6 (short, metallic).
    var mode = false
    var timerPeriod: UInt16 = 4
    var envelope = Envelope()
    var length = LengthCounter()

    /// Must never be zero or the register locks up; hardware powers on at 1.
    private var shiftRegister: UInt16 = 1
    private var timer: UInt16 = 0

    mutating func clockTimer() {
        if timer == 0 {
            timer = timerPeriod
            let tap: UInt16 = mode ? 6 : 1
            let feedback = (shiftRegister & 1) ^ ((shiftRegister >> tap) & 1)
            shiftRegister = (shiftRegister >> 1) | (feedback << 14)
        } else {
            timer -= 1
        }
    }

    var output: UInt8 {
        // Bit 0 set means silence — the register is inverted relative to what
        // you might expect.
        guard length.isActive, shiftRegister & 1 == 0 else { return 0 }
        return envelope.output
    }
}

// MARK: - DMC

/// Delta modulation channel: plays 1-bit delta-encoded samples from ROM.
///
/// Unique among the channels in that it reads memory itself, stalling the CPU
/// while it does. Zelda uses it sparingly, but games that lean on it (and the
/// stalls it causes) are a classic source of timing bugs.
struct DMCChannel {
    /// Timer periods by rate index (NTSC), in CPU cycles.
    static let rates: [UInt16] = [
        428, 380, 340, 320, 286, 254, 226, 214,
        190, 160, 142, 128, 106, 84, 72, 54,
    ]

    var irqEnabled = false
    var loop = false
    var timerPeriod: UInt16 = 428
    var outputLevel: UInt8 = 0
    var sampleAddress: UInt16 = 0xC000
    var sampleLength: UInt16 = 1

    private(set) var bytesRemaining: UInt16 = 0
    private(set) var irqFlag = false
    /// CPU cycles the channel wants to steal for a sample fetch.
    private(set) var stallCycles = 0

    private var currentAddress: UInt16 = 0xC000
    private var timer: UInt16 = 0
    private var shiftRegister: UInt8 = 0
    private var bitsRemaining = 0
    private var sampleBuffer: UInt8?
    private var silence = true

    var isActive: Bool { bytesRemaining > 0 }

    mutating func restart() {
        currentAddress = sampleAddress
        bytesRemaining = sampleLength
    }

    mutating func stop() {
        bytesRemaining = 0
    }

    mutating func clearIRQ() {
        irqFlag = false
    }

    mutating func takeStallCycles() -> Int {
        defer { stallCycles = 0 }
        return stallCycles
    }

    /// Clocked every CPU cycle. `read` fetches from the CPU bus.
    mutating func clockTimer(read: (UInt16) -> UInt8) {
        fillSampleBuffer(read: read)

        if timer == 0 {
            timer = timerPeriod
            clockOutput()
        } else {
            timer -= 1
        }
    }

    private mutating func fillSampleBuffer(read: (UInt16) -> UInt8) {
        guard sampleBuffer == nil, bytesRemaining > 0 else { return }

        sampleBuffer = read(currentAddress)
        // The sample region wraps to $8000 rather than overflowing.
        currentAddress = currentAddress == 0xFFFF ? 0x8000 : currentAddress &+ 1
        bytesRemaining -= 1
        stallCycles += 4

        if bytesRemaining == 0 {
            if loop {
                restart()
            } else if irqEnabled {
                irqFlag = true
            }
        }
    }

    private mutating func clockOutput() {
        if bitsRemaining == 0 {
            bitsRemaining = 8
            if let buffered = sampleBuffer {
                silence = false
                shiftRegister = buffered
                sampleBuffer = nil
            } else {
                silence = true
            }
        }

        if !silence {
            // Each bit nudges the level by two, clamped to 0...127.
            if shiftRegister & 1 != 0 {
                if outputLevel <= 125 { outputLevel += 2 }
            } else {
                if outputLevel >= 2 { outputLevel -= 2 }
            }
        }
        shiftRegister >>= 1
        bitsRemaining -= 1
    }

    var output: UInt8 { outputLevel }
}
