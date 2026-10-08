// swift-tools-version: 5.9
// Vendored from github.com/Jakubantalik/Libraries.dev at b7f44b8744f4e09ff088d824719636a513110e2a
// (packages/thinking-orbs/ports/ios/ThinkingOrbsKit). The test target is left out with its tests.
import PackageDescription

let package = Package(
    name: "ThinkingOrbsKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ThinkingOrbsKit", targets: ["ThinkingOrbsKit"])
    ],
    targets: [
        .target(name: "ThinkingOrbsKit")
    ]
)
