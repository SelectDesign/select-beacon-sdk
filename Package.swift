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
    ],
    targets: [
        .target(
            name: "SelectBeaconSDK",
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "SelectBeaconSDKTests",
            dependencies: ["SelectBeaconSDK"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
