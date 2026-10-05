import AVFoundation
import Foundation

// Original, preloaded earcons. Playback never waits or gates recording/transcription.
final class SoundCues {
    private let startPlayer: AVAudioPlayer?
    private let finishPlayer: AVAudioPlayer?
    init(resourceDirectory: URL? = Bundle.main.resourceURL) {
        func load(_ name: String) -> AVAudioPlayer? {
            guard let url = resourceDirectory?.appendingPathComponent("Sounds/\(name).wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.volume = 0.55
            player.prepareToPlay()
            return player
        }
        startPlayer = load("record-start")
        finishPlayer = load("record-finish")
    }
    func recordingStarted() {
        stop()
        startPlayer?.currentTime = 0
        startPlayer?.play()
    }
    func recordingFinished() {
        stop()
        finishPlayer?.currentTime = 0
        finishPlayer?.play()
    }
    func stop() {
        startPlayer?.stop()
        finishPlayer?.stop()
    }
}
