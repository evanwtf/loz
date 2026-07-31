// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "loz",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "NESCore", targets: ["NESCore"]),
    ],
    targets: [
        // Platform-agnostic emulator. No Foundation-heavy or UI dependencies so it
        // drops cleanly into the iOS, tvOS, and macOS app targets alike.
        .target(
            name: "NESCore",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release))
            ]
        ),
        // macOS-only harness: boots a ROM headlessly and dumps frames to disk.
        // This is the fast debug loop while the PPU is being brought up.
        .executableTarget(name: "nesrun", dependencies: ["NESCore"]),
        .testTarget(name: "NESCoreTests", dependencies: ["NESCore"]),
    ]
)
