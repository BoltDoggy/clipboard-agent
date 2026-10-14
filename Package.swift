// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipboardAgent",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClipboardAgent",
            path: "Sources/ClipboardAgent"
        )
    ]
)
