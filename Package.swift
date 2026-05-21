// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CloudDeck",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "CloudDeck", targets: ["CloudDeck"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0")
    ],
    targets: [
        .target(
            name: "CloudDeck",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "CloudDeckTests",
            dependencies: [
                "CloudDeck",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
