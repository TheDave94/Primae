// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BuchstabenNative",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "BuchstabenNative", targets: ["BuchstabenNative"]),
        .library(name: "BuchstabenNativeTests", targets: ["BuchstabenNativeTests"]),
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
                "Core/DifficultyAdaptation.swift",
                "Core/LetterAnimationGuide.swift",
                "Core/Models.swift",
                "Core/StrokeRecognizer.swift",
                "Core/StrokeTracker.swift",
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
