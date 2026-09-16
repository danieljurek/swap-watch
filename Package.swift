// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwapWatch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SwapWatch", targets: ["SwapWatch"])],
    targets: [
        .target(name: "SwapCore"),
        .executableTarget(name: "SwapWatch", dependencies: ["SwapCore"]),
        .testTarget(name: "SwapCoreTests", dependencies: ["SwapCore"]),
        .testTarget(name: "SwapWatchTests", dependencies: ["SwapWatch"])
    ]
)
