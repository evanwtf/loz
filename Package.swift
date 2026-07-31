// swift-tools-version: 6.0
import PackageDescription

// One app = one game. The emulation machinery is reusable libraries; each
// title is a small game target plus a thin app target that embeds its ROM.
//
//   NESCore     emulator — ships inside every game app
//   NESAnalysis disassembly and tracing tools — development only, never shipped
//   ZeldaGame   Zelda-specific metadata, symbol map, and decompiled routines
//   nesrun      CLI harness for the decompilation workflow
//
// Adding Super Mario Bros. 3 means a new `SMB3Game` target next to `ZeldaGame`
// plus an MMC3 mapper in NESCore — not a fork of any of this.

let package = Package(
    name: "loz",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "NESCore", targets: ["NESCore"]),
        .library(name: "NESAnalysis", targets: ["NESAnalysis"]),
        .library(name: "ZeldaGame", targets: ["ZeldaGame"]),
    ],
    targets: [
        .target(
            name: "NESCore",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release))
            ]
        ),
        .target(name: "NESAnalysis", dependencies: ["NESCore"]),
        .target(name: "ZeldaGame", dependencies: ["NESCore"]),
        .executableTarget(name: "nesrun", dependencies: ["NESCore", "NESAnalysis", "ZeldaGame"]),
        .testTarget(name: "NESCoreTests", dependencies: ["NESCore"]),
        .testTarget(name: "NESAnalysisTests", dependencies: ["NESAnalysis", "NESCore"]),
    ]
)
