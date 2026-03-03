// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BuchstabenNative",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BuchstabenNative", targets: ["BuchstabenNative"])
    ],
    targets: [
        .target(
            name: "BuchstabenNative",
            path: "ios-native/BuchstabenNative"
        ),
        .testTarget(
            name: "BuchstabenNativeTests",
            dependencies: ["BuchstabenNative"],
            path: "ios-native/BuchstabenNativeTests"
        )
    ]
)
