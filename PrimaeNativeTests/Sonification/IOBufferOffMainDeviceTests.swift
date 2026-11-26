// IOBufferOffMainDeviceTests.swift
// PrimaeNativeTests — SDK27 (2026-11-25, TESTWARN relay)
//
// `SoundEnvelope.applyPreferredIOBuffer` calls `setPreferredIOBufferDuration`,
// which has no asynchronous form; on the main thread while the session is
// active it is a runtime "Hang Risk" (TESTWARN's device runs, pre-SDK27 code:
// `makeHostEngine` → `applyPreferredIOBuffer`). It runs at the launch (before
// the first start) and on EVERY route change, when the session is active. This
// pins both off the main thread on the real host engine and the real live
// voice, on an active session, through the two seams
// (`makeHostEngine(applyIOBuffer:)`, `production(ioBufferWork:)`), and the
// order: the launch buffer before the first start, the route-change buffer
// after it.
//
// Device only: the simulator cannot run AVAudioEngine. XCTest (runtime skip).

import XCTest
import AVFoundation
@testable import PrimaeNative

/// Where each IO-buffer call ran, from `@Sendable` closures.
private nonisolated final class IOBufferCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(site: String, onMain: Bool)] = []
    func add(_ site: String) { let m = Thread.isMainThread; lock.withLock { items.append((site, m)) } }
    var all: [(site: String, onMain: Bool)] { lock.withLock { items } }
}

final class IOBufferOffMainDeviceTests: XCTestCase {

    @MainActor func testIOBufferIsAppliedOffMainAtLaunchAndOnARouteChangeWithAnActiveSession() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("device only: AVAudioEngine cannot run on the simulator")
        #else
        let calls = IOBufferCalls()
        let host = SoundEnvelope.makeHostEngine(applyIOBuffer: {
            calls.add("launch"); SoundEnvelope.applyPreferredIOBuffer()
        })
        let voice = LiveSonificationAudio.production(host: host, fadeOutSeconds: SoundEnvelope.fadeOutSeconds,
                                                     ioBufferWork: { calls.add("route"); SoundEnvelope.applyPreferredIOBuffer() })
        await host.startGate.settle()
        let output = try XCTUnwrap(Mirror(reflecting: voice).descendant("output") as? SourceNodeOutput)
        XCTAssertTrue(output.isRunning, "the engine did not start, so the session is not active")
        XCTAssertGreaterThanOrEqual(host.startGate.startCount, 1)
        XCTAssertEqual(calls.all.map(\.site), ["launch"], "the launch buffer must be set before the first start")

        // The case the 10-suite run never reached: a route change while the session is active.
        voice.handleRouteChange(reasonRawValue: AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue)
        await host.startGate.settle()

        let all = calls.all
        print("SDK27 IOBUF calls=\(all.map { "\($0.site):main=\($0.onMain)" }) "
              + "effective=\(AVAudioSession.sharedInstance().ioBufferDuration * 1000) ms")
        XCTAssertEqual(all.map(\.site), ["launch", "route"])
        XCTAssertEqual(all.filter(\.onMain).map(\.site), [],
                       "setPreferredIOBufferDuration ran on the main thread: a runtime Hang Risk while the session is active")
        voice.stop()
        #endif
    }
}
