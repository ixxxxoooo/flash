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
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.5.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "FlashKit",
            dependencies: [
                "Yams",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
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
