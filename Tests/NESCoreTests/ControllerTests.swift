import Testing
@testable import NESCore

/// The standard NES controller is a parallel-to-serial shift register: strobe
/// high samples the buttons continuously, strobe low latches them, and each
/// read shifts one bit out in a fixed order.
@Suite("Controller")
struct ControllerTests {

    @Test("Buttons shift out in hardware order, one per read")
    func shiftOrder() {
        let c = Controller()
        c.press([.a, .select, .down])

        c.write(1)      // strobe high: sample
        c.write(0)      // strobe low: latch

        // Order is A, B, Select, Start, Up, Down, Left, Right.
        let expected: [UInt8] = [1, 0, 1, 0, 0, 1, 0, 0]
        let actual = (0..<8).map { _ in c.read() & 1 }
        #expect(actual == expected)
    }

    @Test("While strobe is high, every read returns the A button")
    func strobeHighRepeatsA() {
        let c = Controller()
        c.press([.a])
        c.write(1)      // hold strobe high
        #expect(c.read() & 1 == 1)
        #expect(c.read() & 1 == 1)
        #expect(c.read() & 1 == 1)

        c.release([.a])
        #expect(c.read() & 1 == 0)
    }

    @Test("Reads past the eighth return 1")
    func readsPastEndReturnOne() {
        let c = Controller()
        c.press([])
        c.write(1)
        c.write(0)
        for _ in 0..<8 { _ = c.read() }
        #expect(c.read() & 1 == 1)
        #expect(c.read() & 1 == 1)
    }

    @Test("Latched state is immune to button changes until the next strobe")
    func latchIsStable() {
        let c = Controller()
        c.press([.a])
        c.write(1)
        c.write(0)                  // latch with A held

        c.release([.a])             // let go mid-read
        #expect(c.read() & 1 == 1)  // still reports the latched press

        c.write(1)                  // re-strobe
        c.write(0)
        #expect(c.read() & 1 == 0)  // now reflects reality
    }

    @Test("Button set round-trips through press and release")
    func pressRelease() {
        let c = Controller()
        c.press([.up, .right])
        c.release([.up])
        c.write(1); c.write(0)
        let bits = (0..<8).map { _ in c.read() & 1 }
        #expect(bits[4] == 0)   // up released
        #expect(bits[7] == 1)   // right still held
    }
}
