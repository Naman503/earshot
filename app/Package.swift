// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Earshot",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic (text cleanup and chunking, tap recognition, OCR layout, settings models), unit-tested.
        .target(name: "EarshotCore"),
        // The menu-bar app. scripts/bundle.sh wraps the binary into Earshot.app.
        .executableTarget(name: "Earshot", dependencies: ["EarshotCore"]),
        .testTarget(name: "EarshotCoreTests", dependencies: ["EarshotCore"]),
    ],
    swiftLanguageModes: [.v5]
)
