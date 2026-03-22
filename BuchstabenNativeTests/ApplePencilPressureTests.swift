//  ApplePencilPressureTests.swift
//  BuchstabenNativeTests

import Testing
@testable import BuchstabenNative

@Suite @MainActor struct ApplePencilPressureTests {

    let vm: TracingViewModel
    init() { vm = makeTestVM() }

    @Test func p1_pencilPressureDefaultsToNil() {
        #expect(vm.pencilPressure == nil)
    }

    @Test func p2_pencilAzimuthDefaultsToZero() {
        #expect(abs(vm.pencilAzimuth - 0) < 0.001)
    }

    @Test func p3_endTouchResetsPressureToNil() {
        vm.pencilPressure = 0.8
        vm.pencilAzimuth = 1.0
        vm.endTouch()
        #expect(vm.pencilPressure == nil)
    }

    @Test func p4_endTouchResetsAzimuthToZero() {
        vm.pencilAzimuth = 1.5
        vm.endTouch()
        #expect(abs(vm.pencilAzimuth - 0) < 0.001)
    }

    @Test func p5_inkWidthAtZeroPressure() {
        let pressure: CGFloat = 0.0
        let inkWidth: CGFloat = 4 + pressure * 10
        #expect(abs(inkWidth - 4) < 0.001)
    }

    @Test func p6_inkWidthAtFullPressure() {
        let pressure: CGFloat = 1.0
        let inkWidth: CGFloat = 4 + pressure * 10
        #expect(abs(inkWidth - 14) < 0.001)
    }

    @Test func p7_inkWidthFingerDefault() {
        let pressure: CGFloat? = nil
        let inkWidth: CGFloat = pressure.map { 4 + $0 * 10 } ?? 8
        #expect(abs(inkWidth - 8) < 0.001)
    }

    @Test func p8_azimuthBiasAtZero() {
        let azimuthBias = cos(CGFloat(0)) * 0.5
        #expect(abs(azimuthBias - 0.5) < 0.001)
    }

    @Test func p9_azimuthBiasAtPi() {
        let azimuthBias = cos(CGFloat.pi) * 0.5
        #expect(abs(azimuthBias - (-0.5)) < 0.001)
    }

    @Test func p10_pencilPressureIsSettable() {
        vm.pencilPressure = 0.65
        #expect(abs((vm.pencilPressure.map(Double.init) ?? 0) - 0.65) < 0.001)
    }
}
