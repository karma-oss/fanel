// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FANEL",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0")
    ],
    targets: [
        .executableTarget(
            name: "FANEL",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
