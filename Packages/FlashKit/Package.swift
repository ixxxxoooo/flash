// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlashKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FlashKit", targets: ["FlashKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "FlashKit",
            dependencies: [
                "Yams",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FlashKitTests",
            dependencies: ["FlashKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
