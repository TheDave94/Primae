// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BuchstabenNative",
    platforms: [
        .iOS(.v17)
    ],
    // ADD THIS NEW PRODUCTS SECTION:
    products: [
        .library(
            name: "BuchstabenNative",
            targets: ["BuchstabenNative"]
        )
    ],
    // LEAVE THE REST AS IT WAS:
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
