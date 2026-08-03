import Foundation
import NESCore
@testable import NESPlayer
import Testing

/// A host nobody started must not reach the speaker.
///
/// This suite exists because the opposite was true for a long time and nothing
/// caught it. `isMuted` is `@Published`, so assigning it in `init` goes through
/// the property wrapper's setter and its `didSet` *does* fire during
/// initialisation — unlike a plain stored property, where it would not. The
/// observer started the audio engine on any unmuted assignment, so merely
/// constructing an `EmulatorHost` opened the audio device.
///
/// The visible consequence: every `swift test` run played Zelda out loud, from
/// eleven hosts built across the suite, and so did `zeldamac --selftest`. Tests
/// drive `tick()` directly and never call `start()`, so nothing in the code
/// looked like it was asking for audio.
@Suite("Silent when headless")
@MainActor
struct SilentByDefaultTests {
    private func host() throws -> EmulatorHost {
        try EmulatorHost(game: SilentTestGame.self, romData: TestGame.romImage)
    }

    @Test("Constructing a host does not open the audio device")
    func constructionIsSilent() throws {
        let host = try host()
        #expect(host.isAudioRunning == false)
    }

    @Test("Ticking a host that was never started stays silent")
    func tickingIsSilent() throws {
        let host = try host()
        for _ in 0..<10 { host.tick() }
        #expect(host.isAudioRunning == false)
    }

    /// Unmuting is not on its own a request to make noise — it says what should
    /// happen *when running*, and this host is not.
    @Test("Toggling mute on a stopped host does not open the device")
    func mutingAStoppedHostIsSilent() throws {
        let host = try host()
        host.isMuted = true
        #expect(host.isAudioRunning == false)
        host.isMuted = false
        #expect(host.isAudioRunning == false)
    }

    /// The other direction still has to work: a started host that is muted must
    /// not be holding the device open either.
    @Test("A started host honours mute")
    func startedHostHonoursMute() throws {
        let host = try host()
        host.isMuted = true
        host.start()
        #expect(host.isAudioRunning == false)
        host.stop()
        #expect(host.isAudioRunning == false)
    }
}
