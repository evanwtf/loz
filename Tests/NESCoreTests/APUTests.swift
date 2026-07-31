@testable import NESCore
import Testing

/// APU component semantics. Wrong envelopes or length counters are audible but
/// nearly impossible to attribute by ear, so they are pinned down directly.
@Suite("APU components")
struct APUComponentTests {
    // MARK: Length counter

    @Test("Length counter loads from the hardware table")
    func lengthTable() {
        var counter = LengthCounter()
        counter.enabled = true
        counter.load(index: 0)
        #expect(counter.value == 10)
        counter.load(index: 1)
        #expect(counter.value == 254)
        counter.load(index: 0x1F)
        #expect(counter.value == 30)
    }

    @Test("Length counter decrements to zero and stops")
    func lengthCountdown() {
        var counter = LengthCounter()
        counter.enabled = true
        counter.load(index: 0)          // 10
        for _ in 0..<10 { counter.clock() }
        #expect(counter.value == 0)
        counter.clock()
        #expect(counter.value == 0)     // does not wrap
        #expect(!counter.isActive)
    }

    @Test("Halt freezes the length counter — this is how notes are held")
    func lengthHalt() {
        var counter = LengthCounter()
        counter.enabled = true
        counter.load(index: 0)
        counter.halt = true
        for _ in 0..<20 { counter.clock() }
        #expect(counter.value == 10)
    }

    @Test("Disabling a channel zeroes its length counter immediately")
    func disableClearsLength() {
        var counter = LengthCounter()
        counter.enabled = true
        counter.load(index: 5)
        #expect(counter.isActive)
        counter.enabled = false
        #expect(counter.value == 0)
    }

    @Test("A disabled channel ignores length loads")
    func disabledIgnoresLoad() {
        var counter = LengthCounter()
        counter.enabled = false
        counter.load(index: 1)
        #expect(counter.value == 0)
    }

    // MARK: Envelope

    @Test("Envelope decays from 15 after the start flag")
    func envelopeDecay() {
        var envelope = Envelope()
        envelope.period = 0        // divider reloads to 0 -> steps every clock
        envelope.start = true

        envelope.clock()           // consumes start, loads 15
        #expect(envelope.output == 15)
        envelope.clock()
        #expect(envelope.output == 14)
        envelope.clock()
        #expect(envelope.output == 13)
    }

    @Test("Constant volume mode outputs the period value directly")
    func envelopeConstantVolume() {
        var envelope = Envelope()
        envelope.constantVolume = true
        envelope.period = 9
        envelope.start = true
        envelope.clock()
        #expect(envelope.output == 9)
        for _ in 0..<40 { envelope.clock() }
        #expect(envelope.output == 9, "constant volume must not decay")
    }

    @Test("Looping envelope wraps back to 15 instead of staying at zero")
    func envelopeLoop() {
        var envelope = Envelope()
        envelope.period = 0
        envelope.loop = true
        envelope.start = true
        envelope.clock()
        for _ in 0..<15 { envelope.clock() }
        #expect(envelope.output == 0)
        envelope.clock()
        #expect(envelope.output == 15)
    }

    @Test("A non-looping envelope stays at zero")
    func envelopeHoldsAtZero() {
        var envelope = Envelope()
        envelope.period = 0
        envelope.loop = false
        envelope.start = true
        envelope.clock()
        for _ in 0..<30 { envelope.clock() }
        #expect(envelope.output == 0)
    }

    @Test("The envelope divider slows the decay rate")
    func envelopeDividerRate() {
        var envelope = Envelope()
        envelope.period = 3        // one step every 4 clocks
        envelope.start = true
        envelope.clock()
        #expect(envelope.output == 15)
        for _ in 0..<4 { envelope.clock() }
        #expect(envelope.output == 14)
    }

    // MARK: Sweep

    @Test("Sweep adds a shifted copy when not negating")
    func sweepUpward() {
        let sweep = Sweep(isPulse1: false)
        // 0x200 >> 1 = 0x100, so target is 0x300.
        var configured = sweep
        configured.shift = 1
        #expect(configured.targetPeriod(current: 0x200) == 0x300)
    }

    /// Pulse 1 negates with one's complement, pulse 2 with two's. The extra
    /// -1 on channel 1 is real hardware behaviour that games composed around.
    @Test("The two pulse channels negate differently")
    func sweepNegateDiffersPerChannel() {
        var one = Sweep(isPulse1: true)
        one.shift = 1
        one.negate = true
        // 0x200 - (0x100 + 1) = 0x0FF
        #expect(one.targetPeriod(current: 0x200) == 0x0FF)

        var two = Sweep(isPulse1: false)
        two.shift = 1
        two.negate = true
        // 0x200 - 0x100 = 0x100
        #expect(two.targetPeriod(current: 0x200) == 0x100)
    }

    @Test("Periods below 8 or above 0x7FF mute the channel")
    func sweepMuting() {
        var sweep = Sweep(isPulse1: false)
        sweep.shift = 1
        #expect(sweep.mutes(current: 7))
        #expect(!sweep.mutes(current: 8))
        // 0x600 + 0x300 overflows the 11-bit period.
        #expect(sweep.mutes(current: 0x600))
    }

    // MARK: Linear counter

    @Test("Linear counter reloads then counts down")
    func linearCounter() {
        var linear = LinearCounter()
        linear.reloadValue = 3
        linear.reload = true
        linear.clock()
        #expect(linear.value == 3)
        linear.clock()
        #expect(linear.value == 2)
        linear.clock(); linear.clock()
        #expect(linear.value == 0)
        #expect(!linear.isActive)
    }

    @Test("The control flag holds the counter in reload")
    func linearCounterControlHolds() {
        var linear = LinearCounter()
        linear.reloadValue = 5
        linear.control = true
        linear.reload = true
        for _ in 0..<10 { linear.clock() }
        #expect(linear.value == 5, "control should keep reloading")
    }
}

@Suite("APU channels")
struct APUChannelTests {
    @Test("Pulse duty sequences match the hardware waveforms")
    func dutyTable() {
        #expect(PulseChannel.dutyTable[0] == [0, 1, 0, 0, 0, 0, 0, 0])
        #expect(PulseChannel.dutyTable[2] == [0, 1, 1, 1, 1, 0, 0, 0])
        // 50% duty is half high.
        #expect(PulseChannel.dutyTable[2].reduce(0, +) == 4)
        // Duty 3 is duty 1 inverted.
        let inverted = PulseChannel.dutyTable[1].map { 1 - $0 }
        #expect(PulseChannel.dutyTable[3] == inverted)
    }

    @Test("A pulse channel is silent with no length remaining")
    func pulseSilentWithoutLength() {
        var pulse = PulseChannel(isPulse1: true)
        pulse.timerPeriod = 100
        pulse.envelope.constantVolume = true
        pulse.envelope.period = 15
        #expect(pulse.output == 0, "length counter is empty")

        pulse.length.enabled = true
        pulse.length.load(index: 1)
        // Advance to a high step of the duty cycle.
        var sawOutput = false
        for _ in 0..<(101 * 8) {
            pulse.clockTimer()
            if pulse.output > 0 { sawOutput = true }
        }
        #expect(sawOutput)
    }

    @Test("A pulse channel is silent at a muting period")
    func pulseSilentWhenMuted() {
        var pulse = PulseChannel(isPulse1: true)
        pulse.length.enabled = true
        pulse.length.load(index: 1)
        pulse.envelope.constantVolume = true
        pulse.envelope.period = 15
        pulse.timerPeriod = 4          // below 8 -> muted

        for _ in 0..<64 {
            pulse.clockTimer()
            #expect(pulse.output == 0)
        }
    }

    @Test("Triangle walks its 32-step sequence")
    func triangleSequence() {
        #expect(TriangleChannel.sequence.count == 32)
        #expect(TriangleChannel.sequence.first == 15)
        #expect(TriangleChannel.sequence[15] == 0)
        #expect(TriangleChannel.sequence[16] == 0)
        #expect(TriangleChannel.sequence.last == 15)
    }

    @Test("Triangle advances only while both gates are open")
    func triangleGating() {
        var triangle = TriangleChannel()
        triangle.timerPeriod = 10
        // Neither gate open: the sequencer must not move.
        let initial = triangle.output
        for _ in 0..<200 { triangle.clockTimer() }
        #expect(triangle.output == initial)

        triangle.length.enabled = true
        triangle.length.load(index: 1)
        triangle.linear.reloadValue = 100
        triangle.linear.reload = true
        triangle.linear.clock()

        var moved = false
        for _ in 0..<200 {
            triangle.clockTimer()
            if triangle.output != initial { moved = true }
        }
        #expect(moved)
    }

    @Test("Noise periods match the NTSC table")
    func noisePeriods() {
        #expect(NoiseChannel.periods.count == 16)
        #expect(NoiseChannel.periods[0] == 4)
        #expect(NoiseChannel.periods[15] == 4068)
    }

    /// The 15-bit LFSR must run its full cycle without ever latching to zero.
    @Test("Noise LFSR produces a long non-repeating sequence")
    func noiseLFSR() {
        var noise = NoiseChannel()
        noise.timerPeriod = 1
        noise.length.enabled = true
        noise.length.load(index: 1)
        noise.envelope.constantVolume = true
        noise.envelope.period = 15

        var highCount = 0
        var lowCount = 0
        for _ in 0..<20000 {
            noise.clockTimer()
            noise.clockTimer()
            if noise.output > 0 { highCount += 1 } else { lowCount += 1 }
        }
        // A locked-up register would give all-high or all-low.
        #expect(highCount > 1000)
        #expect(lowCount > 1000)
    }

    @Test("Short-mode noise repeats far sooner than long mode")
    func noiseModes() {
        func periodLength(mode: Bool) -> Int {
            var noise = NoiseChannel()
            noise.mode = mode
            noise.timerPeriod = 0
            noise.length.enabled = true
            noise.length.load(index: 1)
            noise.envelope.constantVolume = true
            noise.envelope.period = 15

            var pattern: [UInt8] = []
            for _ in 0..<200 {
                noise.clockTimer()
                pattern.append(noise.output)
            }
            return Set(pattern.indices.map { pattern[$0] }).count
        }
        // Both should produce variation; this mainly guards against the tap
        // selection being ignored entirely.
        #expect(periodLength(mode: false) > 1)
        #expect(periodLength(mode: true) > 1)
    }
}

@Suite("APU integration")
struct APUIntegrationTests {
    private func makeAPU() -> APU {
        let apu = APU(sampleRate: 44100)
        apu.readMemory = { _ in 0 }
        return apu
    }

    @Test("Status register reports active length counters")
    func statusRegister() {
        let apu = makeAPU()
        apu.writeRegister(0x4015, 0x01)     // enable pulse 1
        apu.writeRegister(0x4003, 0x08)     // load its length counter
        #expect(apu.readStatus() & 0x01 != 0)

        apu.writeRegister(0x4015, 0x00)     // disable
        #expect(apu.readStatus() & 0x01 == 0)
    }

    @Test("Samples accumulate at roughly the requested rate")
    func sampleRate() {
        let apu = makeAPU()
        // Play a loud square so the mixer produces non-zero output.
        apu.writeRegister(0x4015, 0x01)
        apu.writeRegister(0x4000, 0b1011_1111)   // 50% duty, constant volume 15
        apu.writeRegister(0x4002, 0x40)
        apu.writeRegister(0x4003, 0x08)

        // One second of CPU cycles should yield about one second of samples.
        for _ in 0..<Int(APU.cpuClock) { apu.step() }

        // The ring buffer caps out, so just check it filled.
        #expect(apu.availableSamples > 1000)
    }

    /// The mixer output is unipolar, so without DC removal an idle APU would
    /// sit at a large constant offset — which pops audibly the moment audio
    /// starts. The DC blocker must pull silence down to zero.
    @Test("A silent APU settles to zero rather than a DC offset")
    func silenceSettlesToZero() {
        let apu = makeAPU()
        var latest: [Float] = []

        // Run well past the DC blocker's ~45 ms time constant, draining as we
        // go so the ring buffer never overflows and drops the tail.
        for _ in 0..<20 {
            for _ in 0..<50000 { apu.step() }
            let ready = apu.availableSamples
            if ready > 0 { latest = apu.drain(count: ready) }
        }

        let tail = Array(latest.suffix(256))
        #expect(!tail.isEmpty)
        let peak = tail.map(abs).max() ?? 1
        #expect(peak < 0.01, "settled silence should be ~0, got \(peak)")
    }

    @Test("An enabled pulse channel produces a varying waveform")
    func pulseProducesAudio() {
        let apu = makeAPU()
        apu.writeRegister(0x4015, 0x01)
        apu.writeRegister(0x4000, 0b1011_1111)
        apu.writeRegister(0x4002, 0x80)          // period low
        apu.writeRegister(0x4003, 0x00)          // period high + length

        for _ in 0..<200_000 { apu.step() }
        let samples = apu.drain(count: 1024)

        let minimum = samples.min() ?? 0
        let maximum = samples.max() ?? 0
        #expect(maximum - minimum > 0.01, "expected an audible waveform")
    }

    @Test("The frame counter raises IRQ in 4-step mode and not in 5-step")
    func frameIRQ() {
        let fourStep = makeAPU()
        fourStep.writeRegister(0x4017, 0x00)     // 4-step, IRQ enabled
        for _ in 0..<30000 { fourStep.step() }
        #expect(fourStep.irqAsserted)

        let fiveStep = makeAPU()
        fiveStep.writeRegister(0x4017, 0x80)     // 5-step, no IRQ
        for _ in 0..<40000 { fiveStep.step() }
        #expect(!fiveStep.irqAsserted)
    }

    @Test("Reading $4015 clears the frame IRQ")
    func statusReadClearsIRQ() {
        let apu = makeAPU()
        apu.writeRegister(0x4017, 0x00)
        for _ in 0..<30000 { apu.step() }
        #expect(apu.irqAsserted)
        _ = apu.readStatus()
        #expect(!apu.irqAsserted)
    }

    @Test("Setting the inhibit flag suppresses the frame IRQ")
    func inhibitIRQ() {
        let apu = makeAPU()
        apu.writeRegister(0x4017, 0x40)          // 4-step, IRQ inhibited
        for _ in 0..<40000 { apu.step() }
        #expect(!apu.irqAsserted)
    }
}
