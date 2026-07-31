// Shared building blocks of the 2A03 sound channels.
//
// Each is a small state machine clocked by the frame counter. They are
// separated out because pulse, triangle, and noise share them in different
// combinations, and because they are individually testable — which matters,
// since a wrong envelope or length counter is audible but very hard to
// attribute by ear.

/// Gates a channel off after a programmed duration.
///
/// Loaded from a lookup table indexed by the top 5 bits of the length register,
/// then decremented on half-frames. `halt` freezes it, which is how games hold
/// a note indefinitely.
struct LengthCounter {
    /// Values the 5-bit length index maps to. Not a formula — this is a literal
    /// ROM table inside the chip.
    static let table: [UInt8] = [
        10, 254, 20,  2, 40,  4, 80,  6, 160,  8, 60, 10, 14, 12, 26, 14,
        12,  16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30,
    ]

    var value: UInt8 = 0
    var halt = false
    var enabled = false {
        didSet { if !enabled { value = 0 } }
    }

    var isActive: Bool { value > 0 }

    mutating func load(index: UInt8) {
        guard enabled else { return }
        value = Self.table[Int(index & 0x1F)]
    }

    mutating func clock() {
        if !halt, value > 0 { value -= 1 }
    }
}

/// Volume envelope: either a constant level or a decay from 15 to 0.
struct Envelope {
    var start = false
    /// Doubles as the length-counter halt flag in hardware.
    var loop = false
    var constantVolume = false
    /// Both the divider period and, in constant mode, the volume itself.
    var period: UInt8 = 0

    private var divider: UInt8 = 0
    private var decayLevel: UInt8 = 0

    var output: UInt8 {
        constantVolume ? period : decayLevel
    }

    mutating func clock() {
        if start {
            start = false
            decayLevel = 15
            divider = period
        } else if divider > 0 {
            divider -= 1
        } else {
            divider = period
            if decayLevel > 0 {
                decayLevel -= 1
            } else if loop {
                decayLevel = 15
            }
        }
    }
}

/// Pitch sweep on the pulse channels.
///
/// The two pulse channels differ in one detail: channel 1 uses one's complement
/// when negating, channel 2 uses two's complement. That off-by-one is why a
/// downward sweep on pulse 1 lands a semitone differently, and games were
/// written around it.
struct Sweep {
    var enabled = false
    var period: UInt8 = 0
    var negate = false
    var shift: UInt8 = 0
    var reload = false
    /// True for pulse channel 1, which negates with one's complement.
    let isPulse1: Bool

    private var divider: UInt8 = 0

    init(isPulse1: Bool) {
        self.isPulse1 = isPulse1
    }

    /// The period the sweep unit would produce next.
    func targetPeriod(current: UInt16) -> UInt16 {
        let change = current >> UInt16(shift)
        if negate {
            // Pulse 1 subtracts an extra one; pulse 2 does not.
            let delta = isPulse1 ? change &+ 1 : change
            return current >= delta ? current &- delta : 0
        }
        return current &+ change
    }

    /// A channel is silenced when its period is out of range, whether or not
    /// the sweep is enabled.
    func mutes(current: UInt16) -> Bool {
        current < 8 || targetPeriod(current: current) > 0x07FF
    }

    /// Clocked on half-frames. Returns the new timer period, if it changed.
    mutating func clock(current: UInt16) -> UInt16? {
        var newPeriod: UInt16?

        if divider == 0 && enabled && shift > 0 && !mutes(current: current) {
            newPeriod = targetPeriod(current: current)
        }

        if divider == 0 || reload {
            divider = period
            reload = false
        } else {
            divider -= 1
        }
        return newPeriod
    }
}

/// Linear counter — the triangle channel's extra gate, giving finer duration
/// control than the length counter alone.
struct LinearCounter {
    var reloadValue: UInt8 = 0
    var control = false
    var reload = false

    private(set) var value: UInt8 = 0

    var isActive: Bool { value > 0 }

    mutating func clock() {
        if reload {
            value = reloadValue
        } else if value > 0 {
            value -= 1
        }
        // The control flag doubles as "halt", holding the reload state.
        if !control { reload = false }
    }
}
