// swift-tools-version: 5.9
// Vendored from github.com/Jakubantalik/Libraries.dev at b7f44b8744f4e09ff088d824719636a513110e2a
// (packages/voice-glow/ports/ios/VoiceGlowKit). The test target is left out with its tests, and
// `VoiceGlowOptions.bandColors` is added to match the web `bandColors` prop.
import PackageDescription

let package = Package(
    name: "VoiceGlowKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VoiceGlowKit", targets: ["VoiceGlowKit"])
    ],
    targets: [
        .target(
            name: "VoiceGlowKit",
            // Compiled into the bundle's default.metallib by Xcode's build system.
            resources: [.process("VoiceGlowShaders.metal")]
        )
    ]
)
