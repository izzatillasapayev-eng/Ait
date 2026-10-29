// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Ait",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Ait",
            path: "Sources/Ait",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
