// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "DXFViewer",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure-logic library: parser, entity model, render model. No SwiftUI / AppKit.
        // Linked by both the UI executable and the test runner.
        .target(
            name: "DXFViewerCore",
            path: "Sources/DXFViewerCore"
        ),
        .executableTarget(
            name: "DXFViewer",
            dependencies: [
                "DXFViewerCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DXFViewer"
        ),
        // Self-contained test runner — uses precondition() instead of XCTest so it
        // builds on Command Line Tools only. `swift run DXFTests` → exit 0 green / 1 red.
        .executableTarget(
            name: "DXFTests",
            dependencies: ["DXFViewerCore"],
            path: "Tests/DXFViewerTests",
            resources: [.copy("Fixtures")]
        ),
        // Headless render CLI: takes a DXF, produces a PNG. Used as a debugging
        // toolkit — render the same scene the SwiftUI Canvas would, then inspect
        // the bitmap to see what the app actually drew.
        // Usage: swift run DXFRender <input.dxf> <output.png> [--width N] [--height N] [-v]
        .executableTarget(
            name: "DXFRender",
            dependencies: ["DXFViewerCore"],
            path: "Sources/DXFRender"
        )
    ]
)
