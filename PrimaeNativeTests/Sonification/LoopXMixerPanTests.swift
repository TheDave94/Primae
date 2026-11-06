// LoopXMixerPanTests.swift
// PrimaeNativeTests — lane LOOPX (2026-11-03): how the main mixer applies a
// change of a mono source node's `pan` (AVAudioMixing), the r17 voice's pan
// path. Measured, not assumed: an AVAudioEngine in offline manual rendering
// (the same AVAudioMixerNode implementation as the live graph), a mono source
// node emitting a constant 0.5, the main mixer at 44.1 kHz stereo, pan
// changed BETWEEN render calls as a touch-thread write lands. A constant input
// makes each output sample the gain itself, so the law (gain vs pan) and the
// transition (a step at a buffer edge, or a ramp, and how long) are read
// directly. Device instrument: prints "LOOPX-PAN" lines; asserts only that the
// render ran.

import XCTest
import AVFoundation

final class LoopXMixerPanTests: XCTestCase {

    func testMainMixerPanTransition() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("device instrument (David: no simulator)")
        #else
        let sr = 44_100.0, frames: AVAudioFrameCount = 256
        let engine = AVAudioEngine()
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: frames)
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1))
        let node = AVAudioSourceNode(format: mono) { _, _, n, abl in
            let p = abl.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(n) { p[i] = 0.5 }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: mono)
        try engine.start()
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: frames))
        var left: [Float] = [], right: [Float] = []
        // Pan schedule (buffer index -> pan): settle, the A stroke-2 start jump
        // (-0.88 -> +0.17 in canvas terms), full swings, small writing steps.
        let schedule: [Int: Float] = [0: 0, 20: -0.88, 40: 0.17, 60: -1, 80: 1, 100: 0.3, 101: 0.31, 102: 0.32]
        for k in 0..<130 {
            if let p = schedule[k] { node.pan = p }
            let status = try engine.renderOffline(frames, to: buf)
            XCTAssertEqual(status, .success)
            for i in 0..<Int(frames) {
                left.append(buf.floatChannelData![0][i]); right.append(buf.floatChannelData![1][i])
            }
        }
        engine.stop()
        let f = Int(frames)
        for k in schedule.keys.sorted() where k > 0 {
            let a = k * f
            // samples to settle within 1e-4 of the buffer's last value
            let lEnd = left[a + f - 1], rEnd = right[a + f - 1]
            var settle = 0
            for i in 0..<f where abs(left[a + i] - lEnd) > 1e-4 || abs(right[a + i] - rEnd) > 1e-4 { settle = i + 1 }
            let step = max(abs(left[a] - left[a - 1]), abs(right[a] - right[a - 1]))
            print(String(format: "LOOPX-PAN buffer %d pan %.2f: before L %.4f R %.4f | first L %.4f R %.4f | settled L %.4f R %.4f after %d samples | first-sample step %.4f (input 0.5)",
                         k, schedule[k]!, left[a - 1], right[a - 1], left[a], right[a], lEnd, rEnd, settle, step))
            print("LOOPX-PAN   first 8 L: \((0..<8).map { String(format: "%.4f", left[a + $0]) }.joined(separator: " "))")
        }
        // Law: settled gain / 0.5 vs pan, against constant power cos/sin((p+1) pi/4).
        for k in schedule.keys.sorted() {
            let p = Double(schedule[k]!), a = k * f + f - 1
            let cp = (cos((p + 1) * .pi / 4), sin((p + 1) * .pi / 4))
            print(String(format: "LOOPX-PAN law pan %.2f: gains L %.4f R %.4f | constant-power %.4f %.4f | linear %.4f %.4f",
                         p, Double(left[a]) / 0.5, Double(right[a]) / 0.5, cp.0, cp.1, (1 - p) / 2, (1 + p) / 2))
        }
        XCTAssertEqual(left.count, 130 * f)
        #endif
    }
}
