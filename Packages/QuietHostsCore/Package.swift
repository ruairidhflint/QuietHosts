// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuietHostsCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuietHostsCore", targets: ["QuietHostsCore"]),
    ],
    targets: [
        .target(name: "QuietHostsCore"),
        .executableTarget(name: "qh-bench", dependencies: ["QuietHostsCore"]),
        .testTarget(name: "QuietHostsCoreTests", dependencies: ["QuietHostsCore"]),
    ]
)
