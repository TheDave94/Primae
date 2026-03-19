// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BuchstabenNative",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "BuchstabenNative", targets: ["BuchstabenNative"]),
    ],
    targets: [
        .target(
            name: "BuchstabenNative",
            path: "BuchstabenNative",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "BuchstabenNativeTests",
            dependencies: ["BuchstabenNative"],
            path: "BuchstabenNativeTests"
        )
    ]
)
