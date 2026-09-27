// swift-tools-version:5.9
// ZeonVNC terminal view: a thin Objective-C friendly wrapper around
// SwiftTerm (MIT licensed xterm emulator, vendored in Vendor/SwiftTerm).
import PackageDescription

let package = Package(
    name: "ZVTerminalKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZVTerminalKit", type: .dynamic, targets: ["ZVTerminalKit"]),
    ],
    targets: [
        .target(name: "SwiftTerm",
                path: "Vendor/SwiftTerm/SwiftTerm",
                exclude: ["iOS", "Mac/README.md"]),
        .target(name: "ZVTerminalKit",
                dependencies: ["SwiftTerm"]),
    ]
)
