// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DictationCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DictationCore", targets: ["DictationCore"]),
    ],
    targets: [
        .target(
            name: "DictationCore",
            path: "Sources/DictationCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"],
            path: "Tests/DictationCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
