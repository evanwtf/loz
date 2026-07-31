import SwiftUI
import NESPlayer
import ZeldaGame

/// One app, one game. Everything real lives in NESPlayer and ZeldaGame; this
/// target exists only to give the game an identity, an icon, and a bundled ROM.
@main
struct ZeldaApp: App {
    var body: some Scene {
        WindowGroup {
            GameLauncher(game: Zelda.self)
        }
    }
}
