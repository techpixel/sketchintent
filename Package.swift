// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SketchIntent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SketchIntentServer", targets: ["SketchIntentServer"])
    ],
    targets: [
        .target(name: "StreamProtocol"),
        .target(
            name: "HIDAcceleration",
            path: "Sources/HIDAcceleration",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "SketchIntentServerCore",
            dependencies: ["StreamProtocol", "HIDAcceleration"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "SketchIntentServer",
            dependencies: ["SketchIntentServerCore"]
        ),
        .testTarget(
            name: "StreamProtocolTests",
            dependencies: ["StreamProtocol"]
        ),
        .testTarget(
            name: "SketchIntentServerTests",
            dependencies: ["SketchIntentServerCore"]
        )
    ]
)
