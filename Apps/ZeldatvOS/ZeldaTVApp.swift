import NESPlayer
import SwiftUI
import ZeldaGame

/// Apple TV build. Identical to the iOS app apart from input: there is no
/// touchscreen, so a game controller is required and the shell says so when
/// none is attached.
@main
struct ZeldaTVApp: App {
    var body: some Scene {
        WindowGroup {
            GameLauncher(game: Zelda.self)
        }
    }
}
