// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AreaShare",
    platforms: [.macOS(.v14)],
    targets: [
        // Geometry and settings: no AppKit windows, so it is unit-testable.
        .target(name: "AreaShareCore", path: "Sources/AreaShareCore"),
        .executableTarget(name: "AreaShare", dependencies: ["AreaShareCore"], path: "Sources/AreaShare"),
        .testTarget(name: "AreaShareCoreTests", dependencies: ["AreaShareCore"], path: "Tests/AreaShareCoreTests"),
    ]
)
