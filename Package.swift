// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BuchstabenNative",
    platforms: [
        .iOS(.v17)
    ],
    targets: [
        .target(
            name: "BuchstabenNative",
            path: "BuchstabenNative"
        ),
        .testTarget(
            name: "BuchstabenNativeTests",
            dependencies: ["BuchstabenNative"],
            path: "BuchstabenNativeTests"
        )
    ]
)
