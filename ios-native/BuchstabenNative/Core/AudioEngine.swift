import AVFoundation
import Foundation

final class AudioEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var currentFile: AVAudioFile?

    private(set) var isPlaying = false

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)

        do {
            try engine.start()
        } catch {
            print("AudioEngine start error: \(error)")
        }
    }

    func loadAudioFile(named fileName: String) {
        guard let url = resourceURL(for: fileName) else {
            print("Missing audio file: \(fileName)")
            return
        }
        do {
            currentFile = try AVAudioFile(forReading: url)
            restart()
        } catch {
            print("Audio load error: \(error)")
        }
    }

    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        // Map speed (0.5...2.0) to native timePitch.rate (32...200)
        let clampedSpeed = max(0.5, min(2.0, speed))
        timePitch.rate = clampedSpeed * 100.0

        // Pan on playerNode mixer output [-1, 1]
        player.pan = max(-1.0, min(1.0, horizontalBias))
    }

    func play() {
        guard !isPlaying else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        player.play()
        isPlaying = true
    }

    func stop() {
        player.pause()
        isPlaying = false
    }

    func restart() {
        guard let file = currentFile else { return }
        player.stop()
        player.scheduleFile(file, at: nil, completionHandler: nil)
        player.play()
        isPlaying = true
    }
}

private extension AudioEngine {
    func resourceURL(for fileName: String) -> URL? {
        if let direct = Bundle.main.url(forResource: fileName, withExtension: nil) {
            return direct
        }

        let ns = fileName as NSString
        let resource = ns.lastPathComponent
        let subdir = ns.deletingLastPathComponent
        if !subdir.isEmpty,
           let nested = Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: subdir) {
            return nested
        }

        return nil
    }
}
