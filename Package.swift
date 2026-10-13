// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pet",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Pet",
            path: "Sources/Pet"
        )
    ]
)
