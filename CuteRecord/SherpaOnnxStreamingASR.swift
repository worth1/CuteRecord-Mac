//
//  SherpaOnnxStreamingASR.swift
//  CuteRecord
//

import AVFoundation
import Foundation
import CoreAudio

class SherpaOnnxStreamingASR {
    private var audioEngine: AVAudioEngine?
    private var tapFired = false

    // Callback properties
    var onTextUpdate: ((String) -> Void)?
    var onNewSegment: (() -> Void)?
    var onLevelUpdate: ((CGFloat) -> Void)?
    var onError: ((String) -> Void)?
    /// Called on a background queue with each audio buffer captured
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    var isReady: Bool { true }

    func start(selectedMicUID: String) {
        stop()

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Select specific mic if requested
        if !selectedMicUID.isEmpty {
            if let deviceID = AudioInputDevice.deviceID(forUID: selectedMicUID) {
                let audioUnit = inputNode.audioUnit!
                var devID = deviceID
                AudioUnitSetProperty(audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
        }

        tapFired = false
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            if !(self?.tapFired ?? true) {
                self?.tapFired = true
            }
            guard let self = self else { return }

            // Forward buffer for speech recognition
            self.onAudioBuffer?(buffer)

            // Compute RMS level
            guard let channelData = buffer.floatChannelData else { return }
            let data = channelData.pointee
            let len = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<len {
                let s = data[i]
                sum += s * s
            }
            let rms = sqrt(sum / Float(len))
            let level = CGFloat(min(1.0, rms * 12.0))

            DispatchQueue.main.async {
                self.onLevelUpdate?(level)
            }
        }

        engine.prepare()
        do {
            try engine.start()

            // Verify tap fires within 2s
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.audioEngine != nil else { return }
                if !self.tapFired {
                    DispatchQueue.main.async {
                        self.onError?("Microphone not delivering audio. Check System Settings → Privacy & Security → Microphone.")
                    }
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.onError?("Audio engine failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    func process(audioBuffer: AVAudioPCMBuffer) -> String? { nil }
    func flush() -> String? { nil }

    func reset() { stop() }
}
