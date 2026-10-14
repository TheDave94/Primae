// DeliveryEnvironment.swift
// PrimaeNative
//
// The live readers behind the delivery record (fix batch D, audit
// 2026-10-13, R-020 / R-018). Each is a SEAM: the view model reads the
// device through a protocol, so a test injects a fixed environment and the
// rows it writes can be asserted exactly. What only hardware can show (a
// real headphone unplug, Guided Access on, another app playing music) is
// read here and nowhere else.
//
// Do Not Disturb / Focus is NOT read: the only API (`INFocusStatusCenter`)
// needs the Communication Notifications capability and a user
// authorisation prompt, neither of which this app has.

import AVFoundation
import Foundation
import MachO
import UIKit

// MARK: - Environment

@MainActor
protocol DeliveryEnvironmentProviding {
    /// The device and audio state now.
    func sample() -> EnvironmentStamp
}

/// Reads the real device. Battery monitoring is switched on at first use —
/// `UIDevice.batteryLevel` reads -1 otherwise.
@MainActor
final class LiveDeliveryEnvironment: DeliveryEnvironmentProviding {
    init() {}

    func sample() -> EnvironmentStamp {
        let session = AVAudioSession.sharedInstance()
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let battery = device.batteryLevel
        return EnvironmentStamp(
            outputRoute: session.currentRoute.outputs.first?.portType.rawValue,
            outputVolume: Double(session.outputVolume),
            outputLatency: session.outputLatency,
            otherAudioPlaying: session.isOtherAudioPlaying,
            secondaryAudioHint: session.secondaryAudioShouldBeSilencedHint,
            guidedAccess: UIAccessibility.isGuidedAccessEnabled,
            idleTimerDisabled: UIApplication.shared.isIdleTimerDisabled,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: Self.name(ProcessInfo.processInfo.thermalState),
            batteryLevel: battery >= 0 ? Double(battery) : nil)
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}

// MARK: - Audio preflight (R-018)

/// The audio session is mixable (`AudioEngine`: `.playback` with
/// `.interruptSpokenAudioAndMixWithOthers`), so another app's audio plays
/// through every arm, the silent arm included. Changing the category is an
/// AudioEngine ruling (D7); this only names the state to the proctor.
enum AudioPreflight {
    static func warning(for stamp: EnvironmentStamp) -> String? {
        guard stamp.otherAudioPlaying == true || stamp.secondaryAudioHint == true else { return nil }
        return "Eine andere App spielt gerade Ton ab (z. B. Musik oder ein Video). Er läuft in jedem Arm mit — auch im stillen Arm — und würde die Bedingungen vermischen. Die andere App vor der Sitzung stoppen (Kontrollzentrum)."
    }
}

// MARK: - Launch sentinel

/// Marks whether the app is running in the foreground, so the NEXT launch
/// can tell an unclean exit from a clean one (R-020 / H1-15: a kill
/// mid-letter left no trace). iOS terminates suspended apps without
/// notice, so "clean" means "the last thing the process did was move to
/// the background"; a launch that finds the marker still saying
/// `running` follows a crash, a watchdog kill or a foreground jetsam.
@MainActor
protocol LaunchSentinelRecording {
    /// The app moved to the background and drained its stores.
    func markCleanSuspend()
    /// The app is in the foreground again.
    func markActive()
}

/// A no-op sentinel, for tests and previews.
@MainActor
struct NullLaunchSentinel: LaunchSentinelRecording {
    func markCleanSuspend() {}
    func markActive() {}
}

@MainActor
final class LaunchSentinel: LaunchSentinelRecording {
    struct Marker: Codable, Equatable {
        var launchId: String
        var state: String
        var updatedAt: Date
    }
    static let running = "running"
    static let suspended = "suspended"

    private let fileURL: URL
    let launchId: UUID
    /// What the previous launch left behind: true when it was still
    /// `running`; false when it suspended cleanly or there was none.
    private(set) var previousRunAbnormal = false

    init(fileURL: URL, launchId: UUID = UUID()) {
        self.fileURL = fileURL
        self.launchId = launchId
    }

    /// Read the previous marker, then claim the file for this launch.
    /// Called once per process (`LaunchSentinel.shared`).
    func beginLaunch(now: Date = Date()) {
        if let data = try? Data(contentsOf: fileURL),
           let previous = try? JSONDecoder().decode(Marker.self, from: data) {
            previousRunAbnormal = previous.state == Self.running
        } else {
            previousRunAbnormal = false
        }
        write(Self.running, now: now)
    }

    func markCleanSuspend() { write(Self.suspended, now: Date()) }
    func markActive() { write(Self.running, now: Date()) }

    /// Synchronous and atomic: a few dozen bytes, and the point is that it
    /// is on disk before the process can die.
    private func write(_ state: String, now: Date) {
        let marker = Marker(launchId: launchId.uuidString, state: state, updatedAt: now)
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            lifecycleLogger.error("Launch sentinel write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The production sentinel, begun at first use — once per process.
    static let shared: LaunchSentinel = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let sentinel = LaunchSentinel(fileURL: support
            .appendingPathComponent("PrimaeNative", isDirectory: true)
            .appendingPathComponent("launch_sentinel.json"))
        sentinel.beginLaunch()
        return sentinel
    }()
}

// MARK: - Build identity

enum BuildIdentity {
    /// The stamp for this process: the shared sentinel's launch plus this
    /// binary's identity. Production only (`TracingDependencies.live`).
    @MainActor
    static func current(sentinel: LaunchSentinel = .shared) -> BuildStamp {
        BuildStamp(launchId: sentinel.launchId.uuidString,
                   previousRunAbnormal: sentinel.previousRunAbnormal,
                   appVersion: appVersion(),
                   buildConfiguration: configuration,
                   buildUUID: imageUUID(),
                   osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                   deviceModel: deviceModel())
    }

    #if DEBUG
    static let configuration = "debug"
    #else
    static let configuration = "release"
    #endif

    static func appVersion(_ bundle: Bundle = .main) -> String? {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// `hw.machine` — the hardware model identifier.
    static func deviceModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The LC_UUID of the Mach-O image that contains this code (`#dsohandle`
    /// — the app executable, or its debug dylib in a Debug build).
    static func imageUUID(header: UnsafeRawPointer = #dsohandle) -> String? {
        let mh = header.assumingMemoryBound(to: mach_header_64.self)
        guard mh.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = header.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<mh.pointee.ncmds {
            let lc = command.assumingMemoryBound(to: load_command.self).pointee
            if lc.cmd == UInt32(LC_UUID) {
                let uuidCommand = command.assumingMemoryBound(to: uuid_command.self).pointee
                return UUID(uuid: uuidCommand.uuid).uuidString
            }
            command = command.advanced(by: Int(lc.cmdsize))
        }
        return nil
    }
}
