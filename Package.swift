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
            name: "SelectBeaconSDK"
        ),
        .target(
            name: "SelectBeaconAppSupport",
            dependencies: ["SelectBeaconSDK"]
        ),
        .testTarget(
            name: "SelectBeaconSDKTests",
            dependencies: ["SelectBeaconSDK"]
        ),
        .testTarget(
            name: "SelectBeaconAppSupportTests",
            dependencies: ["SelectBeaconAppSupport", "SelectBeaconSDK"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
