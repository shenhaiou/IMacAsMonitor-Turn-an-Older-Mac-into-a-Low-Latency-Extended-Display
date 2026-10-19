// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "IMacAsMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "IMacAsMonitor", targets: ["IMacAsMonitor"]),
        .library(name: "MAMCore", targets: ["MAMCore"]),
    ],
    targets: [
        .target(name: "MAMCore"),
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "IMacAsMonitor",
            dependencies: ["MAMCore", "CVirtualDisplay"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Network"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .testTarget(name: "MAMCoreTests", dependencies: ["MAMCore", "CVirtualDisplay"]),
    ],
    swiftLanguageModes: [.v5]
)
