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
            name: "pressure-haptics-demo",
            targets: ["PressureHapticsDemo"]
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
            name: "PressureHapticsDemo",
            dependencies: ["PressureHapticsCore", "PressureHapticsTrackpad"]
        ),
        .testTarget(
            name: "PressureHapticsTrackpadTests",
            dependencies: ["PressureHapticsCore", "PressureHapticsTrackpad"]
        ),
        .testTarget(
            name: "PressureHapticsKitComprehensiveTests",
            dependencies: ["PressureHapticsCore", "PressureHapticsTrackpad"],
            path: "test"
        ),
    ]
)
