import Foundation

/// Ricoh 2A03 audio processing unit.
///
/// Clocked once per CPU cycle. Produces mono float samples at a configurable
/// rate for the host's audio engine.
public final class APU {

    // MARK: Channels

    var pulse1 = PulseChannel(isPulse1: true)
    var pulse2 = PulseChannel(isPulse1: false)
    var triangle = TriangleChannel()
    var noise = NoiseChannel()
    var dmc = DMCChannel()

    /// Fetches a byte from the CPU bus for DMC sample playback.
    var readMemory: ((UInt16) -> UInt8)?

    // MARK: Frame counter

    /// False = 4-step (with IRQ), true = 5-step.
    private var fiveStepMode = false
    private var inhibitIRQ = false
    private var frameIRQFlag = false
    private var frameCycle = 0

    /// True while either the frame counter or the DMC is asserting IRQ.
    public var irqAsserted: Bool { frameIRQFlag || dmc.irqFlag }

    // MARK: Output

    /// Host sample rate.
    public let sampleRate: Double
    /// NTSC CPU frequency.
    public static let cpuClock = 1_789_773.0

    private let cyclesPerSample: Double
    private var sampleCounter = 0.0
    private var accumulator = 0.0
    private var accumulatedCycles = 0

    /// Ring buffer of generated samples, drained by the audio engine.
    private var buffer: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private let capacity: Int

    /// True when an even CPU cycle — pulse and noise clock at half rate.
    private var evenCycle = false

    public init(sampleRate: Double = 44100, bufferCapacity: Int = 8192) {
        self.sampleRate = sampleRate
        self.cyclesPerSample = Self.cpuClock / sampleRate
        self.capacity = bufferCapacity
        self.buffer = [Float](repeating: 0, count: bufferCapacity)
    }

    // MARK: Clock

    /// Advances one CPU cycle. Returns cycles the DMC wants to steal.
    @discardableResult
    public func step() -> Int {
        // Triangle and DMC run at the full CPU rate; everything else at half.
        triangle.clockTimer()
        if let readMemory {
            dmc.clockTimer(read: readMemory)
        }

        evenCycle.toggle()
        if evenCycle {
            pulse1.clockTimer()
            pulse2.clockTimer()
            noise.clockTimer()
        }

        clockFrameCounter()
        accumulateSample()

        return dmc.takeStallCycles()
    }

    // MARK: Frame sequencer

    // Step boundaries in CPU cycles (NTSC).
    private static let step1 = 7457
    private static let step2 = 14913
    private static let step3 = 22371
    private static let step4 = 29829
    private static let step5 = 37281

    private func clockFrameCounter() {
        frameCycle += 1

        if fiveStepMode {
            switch frameCycle {
            case Self.step1, Self.step3:
                clockQuarterFrame()
            case Self.step2:
                clockQuarterFrame(); clockHalfFrame()
            case Self.step5:
                clockQuarterFrame(); clockHalfFrame()
                frameCycle = 0
            default:
                break
            }
        } else {
            switch frameCycle {
            case Self.step1, Self.step3:
                clockQuarterFrame()
            case Self.step2:
                clockQuarterFrame(); clockHalfFrame()
            case Self.step4:
                clockQuarterFrame(); clockHalfFrame()
                if !inhibitIRQ { frameIRQFlag = true }
                frameCycle = 0
            default:
                break
            }
        }
    }

    /// Envelopes and the triangle's linear counter.
    private func clockQuarterFrame() {
        pulse1.envelope.clock()
        pulse2.envelope.clock()
        noise.envelope.clock()
        triangle.linear.clock()
    }

    /// Length counters and sweeps.
    private func clockHalfFrame() {
        pulse1.length.clock()
        pulse2.length.clock()
        triangle.length.clock()
        noise.length.clock()
        pulse1.clockSweep()
        pulse2.clockSweep()
    }

    // MARK: Mixing

    /// Non-linear mixer, matching the hardware's documented approximation.
    /// Channels are deliberately *not* summed linearly — the DAC loads each
    /// other, which is why a busy mix sounds compressed rather than clipped.
    private func mix() -> Double {
        let pulseSum = Double(pulse1.output) + Double(pulse2.output)
        let pulseOut = pulseSum == 0 ? 0 : 95.88 / (8128.0 / pulseSum + 100.0)

        let tndSum = Double(triangle.output) / 8227.0
            + Double(noise.output) / 12241.0
            + Double(dmc.output) / 22638.0
        let tndOut = tndSum == 0 ? 0 : 159.79 / (1.0 / tndSum + 100.0)

        return pulseOut + tndOut
    }

    /// Box-filters every CPU cycle between output points rather than
    /// point-sampling, which would alias badly at these ratios.
    private func accumulateSample() {
        accumulator += mix()
        accumulatedCycles += 1
        sampleCounter += 1.0

        guard sampleCounter >= cyclesPerSample else { return }
        sampleCounter -= cyclesPerSample

        let averaged = accumulatedCycles > 0 ? accumulator / Double(accumulatedCycles) : 0
        accumulator = 0
        accumulatedCycles = 0

        // The mixer output is unipolar (0...1) and its resting level depends on
        // which channels are enabled, so a fixed offset cannot centre it — that
        // just converts silence into a loud DC step. A one-pole DC blocker
        // removes whatever the current bias happens to be, and also stops the
        // level jumping when a channel is switched on or off.
        let centred = dcBlock(averaged)
        let smoothed = lowPass(centred)
        push(Float(max(-1.0, min(1.0, smoothed * outputGain))))
    }

    /// Roughly unity for typical NES material while leaving headroom for a
    /// dense mix.
    private let outputGain = 2.4

    private var dcLastInput = 0.0
    private var dcLastOutput = 0.0

    /// One-pole high pass. The coefficient puts the corner near 15 Hz, well
    /// below anything musical.
    private func dcBlock(_ input: Double) -> Double {
        let output = input - dcLastInput + 0.9995 * dcLastOutput
        dcLastInput = input
        dcLastOutput = output
        return output
    }

    private var lowPassState = 0.0

    /// Gentle one-pole low pass, standing in for the console's output filter.
    /// Takes the hardest edges off the square waves without dulling them.
    private func lowPass(_ input: Double) -> Double {
        lowPassState += (input - lowPassState) * 0.55
        return lowPassState
    }

    private func push(_ sample: Float) {
        let next = (writeIndex + 1) % capacity
        // Drop rather than block if the host is not draining; a stalled audio
        // thread must never stall emulation.
        guard next != readIndex else { return }
        buffer[writeIndex] = sample
        writeIndex = next
    }

    /// Number of samples ready to read.
    public var availableSamples: Int {
        (writeIndex - readIndex + capacity) % capacity
    }

    /// Drains up to `count` samples into `destination`, padding with the last
    /// value if the buffer underruns — silence would click.
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) {
        var last: Float = 0
        for i in 0..<count {
            if readIndex != writeIndex {
                last = buffer[readIndex]
                readIndex = (readIndex + 1) % capacity
            }
            destination[i] = last
        }
    }

    /// Drains up to `count` samples as an array.
    public func drain(count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { pointer in
            read(into: pointer.baseAddress!, count: count)
        }
        return out
    }

    // MARK: Registers

    public func writeRegister(_ address: UInt16, _ value: UInt8) {
        switch address {

        // Pulse 1
        case 0x4000:
            pulse1.duty = Int((value >> 6) & 0x03)
            pulse1.length.halt = value & 0x20 != 0
            pulse1.envelope.loop = value & 0x20 != 0
            pulse1.envelope.constantVolume = value & 0x10 != 0
            pulse1.envelope.period = value & 0x0F
        case 0x4001:
            pulse1.sweep.enabled = value & 0x80 != 0
            pulse1.sweep.period = (value >> 4) & 0x07
            pulse1.sweep.negate = value & 0x08 != 0
            pulse1.sweep.shift = value & 0x07
            pulse1.sweep.reload = true
        case 0x4002:
            pulse1.timerPeriod = (pulse1.timerPeriod & 0xFF00) | UInt16(value)
        case 0x4003:
            pulse1.timerPeriod = (pulse1.timerPeriod & 0x00FF) | (UInt16(value & 0x07) << 8)
            pulse1.length.load(index: value >> 3)
            pulse1.envelope.start = true
            pulse1.resetSequencer()

        // Pulse 2
        case 0x4004:
            pulse2.duty = Int((value >> 6) & 0x03)
            pulse2.length.halt = value & 0x20 != 0
            pulse2.envelope.loop = value & 0x20 != 0
            pulse2.envelope.constantVolume = value & 0x10 != 0
            pulse2.envelope.period = value & 0x0F
        case 0x4005:
            pulse2.sweep.enabled = value & 0x80 != 0
            pulse2.sweep.period = (value >> 4) & 0x07
            pulse2.sweep.negate = value & 0x08 != 0
            pulse2.sweep.shift = value & 0x07
            pulse2.sweep.reload = true
        case 0x4006:
            pulse2.timerPeriod = (pulse2.timerPeriod & 0xFF00) | UInt16(value)
        case 0x4007:
            pulse2.timerPeriod = (pulse2.timerPeriod & 0x00FF) | (UInt16(value & 0x07) << 8)
            pulse2.length.load(index: value >> 3)
            pulse2.envelope.start = true
            pulse2.resetSequencer()

        // Triangle
        case 0x4008:
            triangle.linear.control = value & 0x80 != 0
            triangle.length.halt = value & 0x80 != 0
            triangle.linear.reloadValue = value & 0x7F
        case 0x400A:
            triangle.timerPeriod = (triangle.timerPeriod & 0xFF00) | UInt16(value)
        case 0x400B:
            triangle.timerPeriod = (triangle.timerPeriod & 0x00FF) | (UInt16(value & 0x07) << 8)
            triangle.length.load(index: value >> 3)
            triangle.linear.reload = true

        // Noise
        case 0x400C:
            noise.length.halt = value & 0x20 != 0
            noise.envelope.loop = value & 0x20 != 0
            noise.envelope.constantVolume = value & 0x10 != 0
            noise.envelope.period = value & 0x0F
        case 0x400E:
            noise.mode = value & 0x80 != 0
            noise.timerPeriod = NoiseChannel.periods[Int(value & 0x0F)]
        case 0x400F:
            noise.length.load(index: value >> 3)
            noise.envelope.start = true

        // DMC
        case 0x4010:
            dmc.irqEnabled = value & 0x80 != 0
            dmc.loop = value & 0x40 != 0
            dmc.timerPeriod = DMCChannel.rates[Int(value & 0x0F)]
            if !dmc.irqEnabled { dmc.clearIRQ() }
        case 0x4011:
            dmc.outputLevel = value & 0x7F
        case 0x4012:
            dmc.sampleAddress = 0xC000 | (UInt16(value) << 6)
        case 0x4013:
            dmc.sampleLength = (UInt16(value) << 4) | 1

        // Status
        case 0x4015:
            pulse1.length.enabled = value & 0x01 != 0
            pulse2.length.enabled = value & 0x02 != 0
            triangle.length.enabled = value & 0x04 != 0
            noise.length.enabled = value & 0x08 != 0
            if value & 0x10 != 0 {
                if !dmc.isActive { dmc.restart() }
            } else {
                dmc.stop()
            }
            dmc.clearIRQ()

        // Frame counter
        case 0x4017:
            fiveStepMode = value & 0x80 != 0
            inhibitIRQ = value & 0x40 != 0
            if inhibitIRQ { frameIRQFlag = false }
            frameCycle = 0
            // Switching to 5-step mode clocks everything immediately.
            if fiveStepMode {
                clockQuarterFrame()
                clockHalfFrame()
            }

        default:
            break
        }
    }

    /// $4015 read: channel status and IRQ flags. Reading clears the frame IRQ.
    public func readStatus() -> UInt8 {
        var status: UInt8 = 0
        if pulse1.length.isActive   { status |= 0x01 }
        if pulse2.length.isActive   { status |= 0x02 }
        if triangle.length.isActive { status |= 0x04 }
        if noise.length.isActive    { status |= 0x08 }
        if dmc.isActive             { status |= 0x10 }
        if frameIRQFlag             { status |= 0x40 }
        if dmc.irqFlag              { status |= 0x80 }

        frameIRQFlag = false
        return status
    }

    public func reset() {
        pulse1 = PulseChannel(isPulse1: true)
        pulse2 = PulseChannel(isPulse1: false)
        triangle = TriangleChannel()
        noise = NoiseChannel()
        dmc = DMCChannel()
        frameCycle = 0
        frameIRQFlag = false
        writeIndex = 0
        readIndex = 0
        accumulator = 0
        accumulatedCycles = 0
        sampleCounter = 0
        dcLastInput = 0
        dcLastOutput = 0
        lowPassState = 0
    }
}
