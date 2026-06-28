//
//  DictationManager.swift
//  CuteRecord
//

import Foundation
import AVFoundation
import AppKit
import Combine
import Speech

// @Observable
class DictationManager: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var audioLevels: [CGFloat] = Array(repeating: 0, count: 40)
    @Published var error: String?

    /// Called on main thread with the latest recognized text for the current segment
    var onTextUpdate: ((String) -> Void)?
    /// Called on main thread when a new recognition segment begins (after silence/restart)
    var onNewSegment: (() -> Void)?

    private let asr = SherpaOnnxStreamingASR()
    private let speechRecognizer: SFSpeechRecognizer? = {
        SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()
    }()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var committedText: String = ""
    private var sessionGeneration: Int = 0

    func start() {
        guard !isRecording else { return }
        cleanup()
        committedText = ""
        sessionGeneration += 1
        error = nil

        // Check SFSpeechRecognizer availability
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            error = "Speech recognition not available on this device."
            return
        }

        // Check microphone permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            error = "Microphone access denied. Open System Settings → Privacy & Security → Microphone."
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginRecognition()
                    } else {
                        self?.error = "Microphone access denied."
                    }
                }
            }
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        beginRecognition()
    }

    func stop() {
        isRecording = false
        cleanup()
    }

    private func cleanup() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        asr.stop()
    }

    private func beginRecognition() {
        cleanup()

        let currentGeneration = sessionGeneration
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            error = "Speech recognition unavailable."
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            error = "Unable to create recognition request."
            return
        }
        request.shouldReportPartialResults = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, err in
            guard let self, self.sessionGeneration == currentGeneration else { return }

            if let err = err {
                DispatchQueue.main.async {
                    // Ignore expected end-of-speech errors
                    let nsErr = err as NSError
                    if nsErr.domain != "kAFAssistantErrorDomain" || nsErr.code != 203 {
                        self.error = err.localizedDescription
                    }
                }
                return
            }

            if let result = result, result.isFinal {
                // Final result — close segment
                self.committedText += result.bestTranscription.formattedString
                print("[Dictation] Final: \(result.bestTranscription.formattedString)")
            } else if let result = result {
                // Partial result
                let spoken = result.bestTranscription.formattedString
                let text = self.committedText + spoken
                print("[Dictation] Partial: \(spoken)")
                DispatchQueue.main.async {
                    self.onTextUpdate?(text)
                }
            }
        }

        asr.onNewSegment = { [weak self] in
            guard let self, self.sessionGeneration == currentGeneration else { return }
            self.onNewSegment?()
        }
        asr.onLevelUpdate = { [weak self] level in
            guard let self, self.sessionGeneration == currentGeneration else { return }
            self.audioLevels.append(level)
            if self.audioLevels.count > 40 {
                self.audioLevels.removeFirst()
            }
        }
        asr.onAudioBuffer = { [weak self] buffer in
            guard let self, self.sessionGeneration == currentGeneration else { return }
            self.recognitionRequest?.append(buffer)
        }
        asr.onError = { [weak self] message in
            guard let self, self.sessionGeneration == currentGeneration else { return }
            self.error = message
            self.isRecording = false
        }

        isRecording = true
        asr.start(selectedMicUID: NotchSettings.shared.selectedMicUID)
    }
}
