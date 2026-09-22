// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EditorTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EditorTracker",
            path: "Sources/EditorTracker",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
