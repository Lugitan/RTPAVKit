// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RTPAVKit",
    platforms: [
        .iOS(.v13),
        .macOS(SupportedPlatform.MacOSVersion.v10_15),
        .watchOS(SupportedPlatform.WatchOSVersion.v6),
    ],
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "RTPAVKit",
            targets: ["RTPAVKit"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(
            url: "https://github.com/Lugitan/SwiftRTP.git",
            .branch("master")
        ),
        .package(
            url: "https://github.com/Lugitan/BinaryKit.git",
            .branch("master")
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "RTPAVKit",
            dependencies: ["SwiftRTP", "BinaryKit"]),
        .testTarget(
            name: "RTPAVKitTests",
            dependencies: ["SwiftRTP", "RTPAVKit"]),
    ]
)
