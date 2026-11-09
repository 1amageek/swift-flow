// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftFlow",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "SwiftFlow",
            targets: ["SwiftFlow"]
        )
    ],
    targets: [
        .target(
            name: "SwiftFlow",
            exclude: ["DESIGN.md", "Views/DESIGN.md", "EdgePaths/DESIGN.md"]
        ),
        .testTarget(
            name: "SwiftFlowTests",
            dependencies: ["SwiftFlow"]
        )
    ]
)
