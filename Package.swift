// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FeatureBerrySDK",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "FeatureBerrySDK", targets: ["FeatureBerrySDK"])
    ],
    targets: [
        .target(
            name: "FeatureBerrySDK",
            resources: [.process("Resources")]),
        .testTarget(name: "FeatureBerrySDKTests", dependencies: ["FeatureBerrySDK"])
    ]
)
