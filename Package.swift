// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "DXFViewer",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "DXFViewer",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DXFViewer"
        )
    ]
)
