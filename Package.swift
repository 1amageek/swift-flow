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
            name: "SwiftFlow"
        ),
        // Debug-only preview scaffolding. Not exported as a product, so
        // library consumers never compile it; opt in during development
        // by building this target directly (Xcode Package editor or
        // `swift build --target SwiftFlowPreviews`).
        .target(
            name: "SwiftFlowPreviews",
            dependencies: ["SwiftFlow"]
        ),
        .testTarget(
            name: "SwiftFlowTests",
            dependencies: ["SwiftFlow"]
        )
    ]
)
