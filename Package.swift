// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PressureHapticsKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PressureHapticsCore", targets: ["PressureHapticsCore"]),
        .library(
            name: "PressureHapticsTrackpad",
            targets: ["PressureHapticsTrackpad"]
        ),
        .executable(
            name: "pressure-haptics-core-tests",
            targets: ["PressureHapticsCoreTestRunner"]
        ),
        .executable(
            name: "pressure-haptics-trackpad-tests",
            targets: ["PressureHapticsTrackpadTestRunner"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/KrishKrosh/OpenMultitouchSupport.git",
            from: "1.0.12"
        ),
    ],
    targets: [
        .target(name: "PressureHapticsCore"),
        .target(
            name: "PressureHapticsTrackpad",
            dependencies: [
                "PressureHapticsCore",
                .product(
                    name: "OpenMultitouchSupport",
                    package: "OpenMultitouchSupport"
                ),
            ]
        ),
        .executableTarget(
            name: "PressureHapticsCoreTestRunner",
            dependencies: ["PressureHapticsCore"]
        ),
        .executableTarget(
            name: "PressureHapticsTrackpadTestRunner",
            dependencies: ["PressureHapticsCore", "PressureHapticsTrackpad"]
        ),
        .testTarget(
            name: "PressureHapticsTrackpadTests",
            dependencies: ["PressureHapticsCore", "PressureHapticsTrackpad"]
        ),
    ]
)
