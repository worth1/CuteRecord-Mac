import AVFoundation

/// Simple sound effect player for UI feedback sounds.
enum SoundPlayer {
    private static var players: [String: AVAudioPlayer] = [:]

    static func play(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            print("[SoundPlayer] Resource not found: \(name).mp3")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.6
            player.play()
            players[name] = player // retain reference while playing
        } catch {
            print("[SoundPlayer] Failed to play \(name): \(error.localizedDescription)")
        }
    }
}
