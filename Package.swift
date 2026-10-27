// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Aura",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Aura",
            path: "Sources/Aura",
            // The .jxa/.applescript files are standalone manual-test
            // scripts (run directly with osascript); the app itself
            // runs the embedded script strings, so these are not
            // build inputs.
            exclude: ["now-playing.jxa", "now-playing-artwork.jxa", "chrome-tabs.applescript"]
        )
    ]
)
