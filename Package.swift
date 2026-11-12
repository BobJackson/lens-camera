// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lens",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Lens", targets: ["Lens"])
    ],
    targets: [
        .executableTarget(
            name: "Lens",
            path: "Sources/Lens",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreImage"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
