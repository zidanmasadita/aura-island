// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Aura",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Aura",
            path: "Sources/Aura"
        )
    ]
)
