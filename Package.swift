// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ResolveEditTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ResolveEditTracker",
            path: "Sources/ResolveEditTracker",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
