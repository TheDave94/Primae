// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BuchstabenNative",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "BuchstabenNative", targets: ["BuchstabenNative"])
    ],
    targets: [
        .target(
            name: "BuchstabenNative",
            path: "BuchstabenNative",
            exclude: [
                "App",
                "Core/AudioEngine.swift",
                "Core/CloudSyncService.swift",
                "Core/HapticEngine.swift",
                "Core/LetterSoundLibrary.swift",
                "Core/LocalNotificationScheduler.swift",
                "Core/PBMLoader.swift",
                "Features/Tracing"
            ]
        ),
        .testTarget(
            name: "BuchstabenNativeTests",
            dependencies: ["BuchstabenNative"],
            path: "BuchstabenNativeTests"
        )
    ]
)
