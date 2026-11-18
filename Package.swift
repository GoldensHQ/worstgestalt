// swift-tools-version: 6.2

import PackageDescription
let package = Package(
    name: "worsegestalt",
    platforms: [
        // Minimum deployment: iOS 26.0 (the app targets iOS 26.x / 27.x).
        .iOS(.v26),
    ],
    products: [
        // An xtool project must contain exactly one library product for the app.
        .library(
            name: "worsegestalt",
            targets: ["WorseGestalt"]
        ),
    ],
    targets: [
        // Pure Swift now: the escape engine (Sources/WorseGestalt/BQCore.swift)
        // and the worse_query exploit port (Sources/WorseGestalt/WorseQuery.swift).
        .target(
            name: "WorseGestalt",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
