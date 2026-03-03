import XCTest
import CoreGraphics
@testable import BuchstabenNative

final class BuchstabenNativeTests: XCTestCase {
    func testStrokeTrackerProgressionRespectsOrder() {
        let tracker = StrokeTracker()
        let strokes = LetterStrokes(
            letter: "T",
            checkpointRadius: 0.06,
            strokes: [
                .init(id: 1, checkpoints: [.init(x: 0.2, y: 0.2), .init(x: 0.4, y: 0.2)]),
                .init(id: 2, checkpoints: [.init(x: 0.4, y: 0.4), .init(x: 0.6, y: 0.4)])
            ]
        )
        tracker.load(strokes)

        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(tracker.progress[0].nextCheckpoint, 0)
        XCTAssertFalse(tracker.soundEnabled)

        tracker.update(normalizedPoint: CGPoint(x: 0.2, y: 0.2))
        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.2))
        XCTAssertTrue(tracker.progress[0].complete)
        XCTAssertEqual(tracker.currentStrokeIndex, 1)

        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.4))
        tracker.update(normalizedPoint: CGPoint(x: 0.6, y: 0.4))
        XCTAssertTrue(tracker.isComplete)
        XCTAssertEqual(tracker.overallProgress, 1.0)
    }

    func testMapVelocityToSpeedIsMonotonicAndBounded() {
        let sample: [CGFloat] = [0, 60, 120, 240, 500, 900, 1300, 3000]
        let mapped = sample.map(TracingViewModel.mapVelocityToSpeed)

        XCTAssertEqual(mapped.first ?? 0, Float(2.0), accuracy: 0.0001)
        XCTAssertEqual(mapped.last ?? 0, Float(0.5), accuracy: 0.0001)
        mapped.forEach { value in
            XCTAssertGreaterThanOrEqual(value, 0.5)
            XCTAssertLessThanOrEqual(value, 2.0)
        }

        for i in 1..<mapped.count {
            XCTAssertLessThanOrEqual(mapped[i], mapped[i - 1], "Speed should not increase with higher velocity")
        }
    }

    func testLetterRepositoryFallsBackFromInvalidJsonToFolderScan() throws {
        let fs = try TempResourceFS()
        defer { fs.cleanup() }

        try fs.write(relative: "A_strokes.json", content: "{not-json")
        try fs.write(relative: "A/A.pbm", content: "P1\n1 1\n0")
        try fs.write(relative: "A/A1.mp3", content: "dummy")

        let repo = LetterRepository(resources: fs.provider)
        let letters = repo.loadLetters()

        XCTAssertEqual(letters.first?.name, "A")
        XCTAssertEqual(letters.first?.imageName, "A/A.pbm")
        XCTAssertEqual(letters.first?.audioFiles, ["A/A1.mp3"])
    }

    func testLetterRepositoryFallsBackToSampleWhenNoAssetsExist() {
        let provider = MockResourceProvider(urls: [], byRelativePath: [:])
        let repo = LetterRepository(resources: provider)
        let letters = repo.loadLetters()

        XCTAssertEqual(letters.count, 1)
        XCTAssertEqual(letters[0].name, "A")
        XCTAssertEqual(letters[0].audioFiles, ["A.mp3"])
    }

    func testLetterRepositoryPrefersCleanCuratedAudioForAtoM() throws {
        let fs = try TempResourceFS()
        defer { fs.cleanup() }

        try fs.write(relative: "M_strokes.json", content: validJSON(letter: "M"))
        try fs.write(relative: "M/M.pbm", content: "P1\n1 1\n0")
        try fs.write(relative: "M/Möwe.mp3", content: "ok")
        try fs.write(relative: "M/Meer.mp3", content: "ok")
        try fs.write(relative: "M/hmmm.wav", content: "stale")
        try fs.write(relative: "M/ElevenLabs_test.mp3", content: "stale")

        let repo = LetterRepository(resources: fs.provider)
        let letters = repo.loadLetters()
        let m = try XCTUnwrap(letters.first(where: { $0.id.uppercased() == "M" }))

        XCTAssertEqual(m.audioFiles, ["M/Meer.mp3", "M/Möwe.mp3"])
    }

    func testGuideRendererSupportsCouncilLetterSet() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 480)
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            XCTAssertNotNil(LetterGuideRenderer.guidePath(for: letter, in: rect), "Expected guide path for \(letter)")
        }
        XCTAssertNotNil(LetterGuideRenderer.guidePath(for: "Z", in: rect), "Fallback guide should exist for non-curated letters")
    }

    @MainActor
    func testMultiTouchNavigationClearsAndSuppressesSingleTouchBriefly() {
        let vm = TracingViewModel(singleTouchCooldownAfterNavigation: 0.05)
        let size = CGSize(width: 320, height: 480)

        vm.beginTouch(at: CGPoint(x: 20, y: 20), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 28, y: 28), t: 1.03, canvasSize: size)
        XCTAssertGreaterThan(vm.debugActivePathCount, 1)

        vm.beginMultiTouchNavigation()
        XCTAssertTrue(vm.debugIsMultiTouchNavigationActive)
        XCTAssertEqual(vm.debugActivePathCount, 0, "Two-finger nav should immediately clear active stroke")

        vm.endMultiTouchNavigation()
        XCTAssertFalse(vm.debugIsMultiTouchNavigationActive)

        vm.beginTouch(at: CGPoint(x: 30, y: 30), t: CACurrentMediaTime())
        XCTAssertEqual(vm.debugActivePathCount, 0, "Single-touch should be briefly suppressed after multi-touch nav")

        usleep(70_000)
        vm.beginTouch(at: CGPoint(x: 32, y: 32), t: CACurrentMediaTime())
        XCTAssertEqual(vm.debugActivePathCount, 1, "Single-touch should recover after suppression window")
    }

    @MainActor
    func testRepeatedBeginMultiTouchDoesNotLeaveStuckState() {
        let vm = TracingViewModel(singleTouchCooldownAfterNavigation: 0)

        vm.beginMultiTouchNavigation()
        vm.beginMultiTouchNavigation()
        XCTAssertTrue(vm.debugIsMultiTouchNavigationActive)

        vm.endMultiTouchNavigation()
        vm.endMultiTouchNavigation()
        XCTAssertFalse(vm.debugIsMultiTouchNavigationActive)
    }
}


private func validJSON(letter: String) -> String {
    """
    {
      "letter": "\(letter)",
      "checkpointRadius": 0.06,
      "strokes": [
        {
          "id": 1,
          "checkpoints": [
            { "x": 0.2, "y": 0.2 },
            { "x": 0.8, "y": 0.8 }
          ]
        }
      ]
    }
    """
}

private struct MockResourceProvider: LetterResourceProviding {
    let urls: [URL]
    let byRelativePath: [String: URL]

    func allResourceURLs() -> [URL] { urls }
    func resourceURL(for relativePath: String) -> URL? { byRelativePath[relativePath] }
}

private final class TempResourceFS {
    let root: URL
    var provider: MockResourceProvider {
        let urls = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?.map {
            root.appendingPathComponent($0)
        } ?? []

        let map = Dictionary(uniqueKeysWithValues: urls.map { (url) in
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            return (rel, url)
        })

        return MockResourceProvider(urls: urls, byRelativePath: map)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(relative: String, content: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
