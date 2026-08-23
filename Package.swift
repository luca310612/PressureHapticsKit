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
        .library(name: "SandboxPressureKit", targets: ["SandboxPressureKit"]),
        .executable(
            name: "pressure-haptics-core-tests",
            targets: ["PressureHapticsCoreTestRunner"]
        ),
        .executable(
            name: "pressure-haptics-trackpad-tests",
            targets: ["PressureHapticsTrackpadTestRunner"]
        ),
        .executable(
            name: "sandbox-pressure-tests",
            targets: ["SandboxPressureKitTestRunner"]
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
            name: "SandboxPressureKit",
            dependencies: ["PressureHapticsCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
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
        .executableTarget(
            name: "SandboxPressureKitTestRunner",
            dependencies: ["PressureHapticsCore", "SandboxPressureKit"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "PressureHapticsTrackpadTests",
            dependencies: ["PressureHapticsCore", "PressureHapticsTrackpad"]
        ),
    ]
)
