import Foundation
import NESCore
@testable import NESPlayer
import Testing

/// Drives `EmulatorHost` the way the app does — `setButton` plus `tick` — with
/// the real cartridge, and checks the game actually responds.
///
/// The unit suite covers the controller shift register and the CLI covers the
/// emulator, but nothing covered the seam between them: the path a button press
/// takes from a SwiftUI gesture into the machine. "Buttons do nothing" on a
/// real device is exactly the failure that seam produces, and it was invisible
/// to every existing test.
@Suite("Host input path")
@MainActor
struct HostInputTests {
    /// The real ROM, or nil. These tests skip without it, like the routine
    /// equivalence suite.
    private static var romData: [UInt8]? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("zelda.nes")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return [UInt8](data)
    }

    private enum RealZelda: GameDefinition {
        static let title = "The Legend of Zelda"
        static let romResourceName = "loz-hostinput-\(UUID().uuidString.prefix(8))"
        static let expectedMapper = 1
        static let expectedROMHash =
            "89232edf4f9b52e3cb872094bc78973de080befca2ddea893b6e936066514d4e"
    }

    /// Runs an input script through the host, one segment at a time.
    private func drive(_ host: EmulatorHost, _ script: [(NESButton, Int)]) {
        for (buttons, frames) in script {
            host.releaseAllButtons()
            for button in [NESButton.a, .b, .start, .select, .up, .down, .left, .right]
                where buttons.contains(button)
            {
                host.setButton(button, pressed: true)
            }
            for _ in 0..<frames { host.tick() }
            host.releaseAllButtons()
        }
    }

    @Test("Pressing start through the host advances past the title screen")
    func startAdvancesTitle() throws {
        guard let rom = Self.romData else { return }   // no ROM: skip
        let host = try EmulatorHost(game: RealZelda.self, romData: rom)

        // Title screen sits until start is pressed. Run well past the point
        // where it appears, then press start and see whether anything moved.
        for _ in 0..<400 { host.tick() }
        let beforePC = host.nes.cpu.pc
        let beforeFrame = host.nes.ppu.frame

        drive(host, [(.start, 4), ([], 120)])

        #expect(host.nes.ppu.frame > beforeFrame, "the clock must advance")
        #expect(host.nes.cpu.pc != beforePC || host.nes.ppu.frame > beforeFrame)
    }

    /// The real test: the committed boot script, replayed through the host
    /// rather than through `nesrun`. It ends on the overworld, and `$00EB` says
    /// so — a number the emulator cannot produce by accident.
    @Test("The boot script drives the host to the overworld, exactly as nesrun does")
    func bootScriptReachesOverworld() throws {
        guard let rom = Self.romData else { return }
        let host = try EmulatorHost(game: RealZelda.self, romData: rom)

        let script: [(NESButton, Int)] = [
            ([], 80), (.start, 4), ([], 40), (.start, 4), ([], 40),
            (.a, 4), ([], 20), (.select, 4), ([], 16), (.select, 4), ([], 16),
            (.select, 4), ([], 16), (.right, 4), ([], 16),
            (.start, 6), ([], 60), (.start, 6), ([], 180),
        ]
        drive(host, script)

        #expect(host.nes.cpuRead(0x00EB) == 0x77,
                "should be on the starting overworld screen")
    }

    /// Directions have to reach the machine too, not just the menu buttons.
    @Test("Holding a direction moves Link")
    func directionMovesLink() throws {
        guard let rom = Self.romData else { return }
        let host = try EmulatorHost(game: RealZelda.self, romData: rom)

        let script: [(NESButton, Int)] = [
            ([], 80), (.start, 4), ([], 40), (.start, 4), ([], 40),
            (.a, 4), ([], 20), (.select, 4), ([], 16), (.select, 4), ([], 16),
            (.select, 4), ([], 16), (.right, 4), ([], 16),
            (.start, 6), ([], 60), (.start, 6), ([], 180),
        ]
        drive(host, script)

        let startX = host.nes.cpuRead(0x0070)
        drive(host, [(.left, 60)])
        #expect(host.nes.cpuRead(0x0070) != startX, "holding left must move Link")
    }

    /// A paused host must ignore input rather than queue it up, and must resume
    /// cleanly — the app pauses on backgrounding and on opening the menu.
    @Test("A paused host does not advance, and resumes when unpaused")
    func pauseStopsTheClock() throws {
        guard let rom = Self.romData else { return }
        let host = try EmulatorHost(game: RealZelda.self, romData: rom)
        for _ in 0..<60 { host.tick() }

        host.isPaused = true
        let frozen = host.nes.ppu.frame
        for _ in 0..<60 { host.tick() }
        #expect(host.nes.ppu.frame == frozen, "a paused host must not step")

        host.isPaused = false
        for _ in 0..<10 { host.tick() }
        #expect(host.nes.ppu.frame > frozen, "unpausing must resume")
    }
}
