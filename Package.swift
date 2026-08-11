// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SelectBeaconSDK",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "SelectBeaconSDK",
            targets: ["SelectBeaconSDK"]
        ),
        .library(
            name: "SelectBeaconAppSupport",
            targets: ["SelectBeaconAppSupport"]
        ),
    ],
    targets: [
        .target(
            name: "SelectBeaconSDK",
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        .target(
            name: "SelectBeaconAppSupport",
            dependencies: ["SelectBeaconSDK"]
        ),
        // Shared doubles/fixtures for both package test targets (not a product).
        .target(
            name: "SelectBeaconSDKTestSupport",
            dependencies: ["SelectBeaconSDK"],
            path: "Tests/SelectBeaconSDKTestSupport"
        ),
        .testTarget(
            name: "SelectBeaconSDKTests",
            dependencies: ["SelectBeaconSDK", "SelectBeaconSDKTestSupport"]
        ),
        .testTarget(
            name: "SelectBeaconAppSupportTests",
            dependencies: [
                "SelectBeaconAppSupport",
                "SelectBeaconSDK",
                "SelectBeaconSDKTestSupport",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
