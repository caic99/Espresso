// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Espresso",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Espresso", path: "Sources/Espresso")
    ]
)
