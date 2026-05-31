// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AndroidConnect",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AndroidConnect",
            path: "Sources/AndroidConnect"
        )
    ]
)
