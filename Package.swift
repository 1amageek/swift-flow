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
        .testTarget(
            name: "SwiftFlowTests",
            dependencies: ["SwiftFlow"]
        )
    ]
)
