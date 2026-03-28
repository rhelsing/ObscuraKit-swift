// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ObscuraKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "ObscuraKit",
            targets: ["ObscuraKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(path: "vendored/libsignal/swift"),
    ],
    targets: [
        .target(
            name: "ObscuraKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "LibSignalClient", package: "swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "ScratchpadTests",
            dependencies: ["ObscuraKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "ScenarioTests",
            dependencies: ["ObscuraKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
