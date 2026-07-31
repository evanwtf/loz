/// Buttons on a standard NES pad, in the order the shift register reports them.
public struct NESButton: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let a      = NESButton(rawValue: 1 << 0)
    public static let b      = NESButton(rawValue: 1 << 1)
    public static let select = NESButton(rawValue: 1 << 2)
    public static let start  = NESButton(rawValue: 1 << 3)
    public static let up     = NESButton(rawValue: 1 << 4)
    public static let down   = NESButton(rawValue: 1 << 5)
    public static let left   = NESButton(rawValue: 1 << 6)
    public static let right  = NESButton(rawValue: 1 << 7)
}

/// A standard controller: a parallel-to-serial shift register.
///
/// Software strobes bit 0 of $4016 high then low to latch the button state,
/// then reads $4016 eight times to clock the bits out one at a time.
public final class Controller {
    /// Live button state, driven by the host's input layer.
    public private(set) var buttons: NESButton = []

    private var latched: UInt8 = 0
    private var strobe = false

    public init() {}

    public func press(_ b: NESButton) { buttons.insert(b) }
    public func release(_ b: NESButton) { buttons.remove(b) }
    public func set(_ b: NESButton, pressed: Bool) {
        if pressed { press(b) } else { release(b) }
    }

    public func releaseAll() { buttons = [] }

    /// CPU write to $4016.
    public func write(_ value: UInt8) {
        strobe = (value & 1) != 0
        if strobe { latched = buttons.rawValue }
    }

    /// CPU read from $4016/$4017. Bit 0 carries the data; the upper bits are
    /// open bus, which on a real NES leaves $40 from the high byte of the
    /// address. Games mask with AND #$01, so this only matters for accuracy.
    public func read() -> UInt8 {
        if strobe {
            // Held high: the register reloads continuously, so every read
            // returns the A button.
            latched = buttons.rawValue
        }
        let bit = latched & 1
        // Shifting in 1s makes reads past the eighth return 1, as hardware does.
        latched = (latched >> 1) | 0x80
        return 0x40 | bit
    }
}
