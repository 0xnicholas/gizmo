// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "UsageMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "UsageMonitorCore", targets: ["UsageMonitorCore"]),
        .executable(name: "UsageMonitor", targets: ["UsageMonitor"]),
    ],
    targets: [
        .target(name: "UsageMonitorCore"),
        .executableTarget(
            name: "UsageMonitor",
            dependencies: ["UsageMonitorCore"]
        ),
        .testTarget(
            name: "UsageMonitorCoreTests",
            dependencies: ["UsageMonitorCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
