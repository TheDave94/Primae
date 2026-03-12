// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BuchstabenNative",
    platforms: [
        .iOS(.v18)
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
            path: "BuchstabenNative",
            resources: [
                .copy("Resources/Letters")
            ]
        ),
        .testTarget(
            name: "BuchstabenNativeTests",
            dependencies: ["BuchstabenNative"],
            path: "BuchstabenNativeTests"
        )
    ]
)
