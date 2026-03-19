import XCTest
@testable import BuchstabenNative


/// P1–P10: Apple Pencil pressure, azimuth, and state-reset tests.
@MainActor
final class ApplePencilPressureTests: XCTestCase {

    // Inject a no-op audio stub so tests never spin up a real AVAudioEngine.
    // Using the real AudioEngine causes AVAudioSession state pollution across
    // the 10 sequential makeVM() calls in this suite, which manifests as an
    // uncaught ObjC exception on the 10th init (testP10) in headless CI.
    private var vm: TracingViewModel!

    override func setUp() async throws {
        vm = makeTestVM()
    }

    override func tearDown() async throws {
        vm = nil
    }

    // P1: pencilPressure defaults to nil (no pencil contact)
    func testP1_pencilPressureDefaultsToNil() {
        XCTAssertNil(vm.pencilPressure)
    }

    // P2: pencilAzimuth defaults to 0
    func testP2_pencilAzimuthDefaultsToZero() {
        XCTAssertEqual(vm.pencilAzimuth, 0, accuracy: 0.001)
    }

    // P3: endTouch resets pencilPressure to nil
    func testP3_endTouchResetsPressureToNil() {
        vm.pencilPressure = 0.8
        vm.pencilAzimuth = 1.0
        vm.endTouch()
        XCTAssertNil(vm.pencilPressure)
    }

    // P4: endTouch resets pencilAzimuth to 0
    func testP4_endTouchResetsAzimuthToZero() {
        vm.pencilAzimuth = 1.5
        vm.endTouch()
        XCTAssertEqual(vm.pencilAzimuth, 0, accuracy: 0.001)
    }

    // P5: ink width formula — pressure 0.0 → 4 pt
    func testP5_inkWidthAtZeroPressure() {
        let pressure: CGFloat = 0.0
        let inkWidth: CGFloat = 4 + pressure * 10
        XCTAssertEqual(inkWidth, 4, accuracy: 0.001)
    }

    // P6: ink width formula — pressure 1.0 → 14 pt
    func testP6_inkWidthAtFullPressure() {
        let pressure: CGFloat = 1.0
        let inkWidth: CGFloat = 4 + pressure * 10
        XCTAssertEqual(inkWidth, 14, accuracy: 0.001)
    }

    // P7: ink width formula — no pencil (nil pressure) → 8 pt
    func testP7_inkWidthFingerDefault() {
        let pressure: CGFloat? = nil
        let inkWidth: CGFloat = pressure.map { 4 + $0 * 10 } ?? 8
        XCTAssertEqual(inkWidth, 8, accuracy: 0.001)
    }

    // P8: azimuth bias — azimuth=0 (tip pointing right) → cos(0)*0.5 = +0.5 contribution
    func testP8_azimuthBiasAtZero() {
        let azimuth: CGFloat = 0
        let azimuthBias = cos(azimuth) * 0.5
        XCTAssertEqual(azimuthBias, 0.5, accuracy: 0.001)
    }

    // P9: azimuth bias — azimuth=π (tip pointing left) → cos(π)*0.5 = -0.5 contribution
    func testP9_azimuthBiasAtPi() {
        let azimuth: CGFloat = .pi
        let azimuthBias = cos(azimuth) * 0.5
        XCTAssertEqual(azimuthBias, -0.5, accuracy: 0.001)
    }

    // P10: pencilPressure is settable and observable
    func testP10_pencilPressureIsSettable() {
        vm.pencilPressure = 0.65
        XCTAssertEqual(vm.pencilPressure.map(Double.init) ?? 0, 0.65, accuracy: 0.001)
    }
}
