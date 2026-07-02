//
//  SpeechRecognizer.swift
//  CuteRecord
//
//

import AppKit
import Foundation
import AVFoundation
import CoreAudio
import Combine
import Speech

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func allInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard let uid = stringProperty(deviceID: deviceID, address: &uidAddress) else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard let name = stringProperty(deviceID: deviceID, address: &nameAddress) else { continue }

            result.append(AudioInputDevice(id: deviceID, uid: uid, name: name))
        }
        return result
    }

    private static func stringProperty(deviceID: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> String? {
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return nil
        }

        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr,
              let stringValue = value?.takeRetainedValue()
        else {
            return nil
        }

        return stringValue as String
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allInputDevices().first(where: { $0.uid == uid })?.id
    }
}

// @Observable
class SpeechRecognizer: ObservableObject {
    @Published var recognizedCharCount: Int = 0
    @Published var isListening: Bool = false
    @Published var error: String?
    @Published var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    @Published var lastSpokenText: String = ""
    @Published var shouldDismiss: Bool = false
    @Published var shouldAdvancePage: Bool = false

    /// True when recent audio levels indicate the user is actively speaking.
    /// Uses hysteresis: once speaking, requires level to drop further before
    /// deciding the user has stopped. Prevents rapid on/off oscillation.
    private var _speaking: Bool = false
    var isSpeaking: Bool {
        let recent = audioLevels.suffix(10)
        guard !recent.isEmpty else { return false }
        let avg = recent.reduce(0, +) / CGFloat(recent.count)
        if _speaking {
            _speaking = avg > 0.04  // lower threshold to stop
        } else {
            _speaking = avg > 0.08  // higher threshold to start
        }
        return _speaking
    }

    private let asr = SherpaOnnxStreamingASR()
    private var sourceText: String = ""
    private var normalizedSource: String = ""
    private var matchStartOffset: Int = 0  // char offset to start matching from
    private var sessionGeneration: Int = 0
    /// Sliding window of recent match positions for confidence gating.
    /// Larger jumps still need agreement, but short or anchored partial hits
    /// should move immediately so streaming ASR feels responsive.
    private var recentMatchPositions: [Int] = []
    private var matchCallbackCount: Int = 0
    /// Tracks consecutive callbacks with no forward progress to detect stuck state
    private var consecutiveNoProgressCount: Int = 0

    // Tokenization cache to avoid re-splitting source text every callback
    private var cachedRemainingSource: String = ""
    private var cachedSourceWords: [String] = []
    private var cachedSourceTokens: [(normalized: String, endOffset: Int, isAnnotation: Bool)] = []

    // Apple SFSpeechRecognizer for speech-to-text (used when SherpaOnnx models not available)
    private let speechRecognizer: SFSpeechRecognizer? = {
        SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()
    }()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private struct RecoveryAnchorResult {
        let endOffset: Int
        let score: Int
        let matchedWordCount: Int
        let matchedSignalCount: Int
        let exactMatchCount: Int
        let sourceStart: Int
        let spokenStart: Int
        let isPhraseMatch: Bool

        static let none = RecoveryAnchorResult(
            endOffset: 0,
            score: Int.min,
            matchedWordCount: 0,
            matchedSignalCount: 0,
            exactMatchCount: 0,
            sourceStart: 0,
            spokenStart: 0,
            isPhraseMatch: false
        )

        var isUsable: Bool {
            endOffset > 0
        }

        var isStrongForImmediateCatchUp: Bool {
            guard isUsable else { return false }

            if isPhraseMatch {
                return matchedSignalCount >= 6
            }

            if matchedWordCount >= 3 {
                return true
            }

            guard matchedWordCount >= 2, exactMatchCount >= 2 else {
                return matchedWordCount >= 2 && matchedSignalCount >= 10
            }

            if matchedSignalCount >= 6 {
                return true
            }

            return sourceStart <= 12 && spokenStart <= 4
        }
    }

    /// Update the source text while preserving the current recognized char count.
    /// Used by Director Mode to live-edit unread text without resetting read progress.
    func updateText(_ text: String, preservingCharCount: Int) {
        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        recognizedCharCount = min(preservingCharCount, collapsed.count)
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        matchCallbackCount = 0
        consecutiveNoProgressCount = 0
        cachedRemainingSource = ""
    }

    /// Jump highlight to a specific char offset (e.g. when user taps a word)
    func jumpTo(charOffset: Int) {
        recognizedCharCount = charOffset
        matchStartOffset = charOffset
        recentMatchPositions = []
        matchCallbackCount = 0
        consecutiveNoProgressCount = 0
        cachedRemainingSource = ""
        if isListening {
            restartRecognition()
        }
    }

    func start(with text: String) {
        // Clean up any previous session immediately so pending restarts
        // and stale taps are removed before the async auth callback fires.
        cleanupRecognition()

        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        recognizedCharCount = 0
        matchStartOffset = 0
        recentMatchPositions = []
        matchCallbackCount = 0
        consecutiveNoProgressCount = 0
        cachedRemainingSource = ""
        error = nil
        sessionGeneration += 1

        // Check microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            error = "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow CuteRecord."
            openMicrophoneSettings()
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginRecognition()
                    } else {
                        self?.error = "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow CuteRecord."
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

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        isListening = false
        cleanupRecognition()
    }

    func forceStop() {
        isListening = false
        sourceText = ""
        recentMatchPositions = []
        matchCallbackCount = 0
        consecutiveNoProgressCount = 0
        cachedRemainingSource = ""
        cleanupRecognition()
    }

    func resume() {
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        matchCallbackCount = 0
        consecutiveNoProgressCount = 0
        cachedRemainingSource = ""
        shouldDismiss = false
        beginRecognition()
    }

    private func cleanupRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        asr.stop()
    }

    private var recognitionStartTime: Date = .distantPast
    private var consecutiveRestartCount: Int = 0
    private var usingRecordingAudio: Bool = false

    private func beginRecognition() {
        cleanupRecognition()
        asr.resetRetryCounter()
        recognitionStartTime = Date()
        usingRecordingAudio = false

        let currentGeneration = sessionGeneration

        // Set up audio level and error callbacks from the audio capture layer
        asr.onLevelUpdate = { [weak self] level in
            self?.audioLevels.append(level)
            if (self?.audioLevels.count ?? 0) > 30 {
                self?.audioLevels.removeFirst()
            }
        }
        asr.onError = { [weak self] message in
            guard let self, self.sessionGeneration == currentGeneration else { return }
            self.error = message
            self.isListening = false
            // Auto-recover: restart after a short delay unless we've
            // been retrying too many times already
            if self.consecutiveRestartCount < 5 {
                self.consecutiveRestartCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard self.isListening == false else { return }
                    self.restartRecognition()
                }
            }
        }
        asr.onNewSegment = { [weak self] in
            guard let self, self.sessionGeneration == currentGeneration else { return }
            self.matchStartOffset = self.recognizedCharCount
            self.recentMatchPositions = []
            self.matchCallbackCount = 0
            self.consecutiveNoProgressCount = 0
            self.cachedRemainingSource = ""
        }

        // Use Apple SFSpeechRecognizer for speech-to-text.
        // (SherpaOnnx models are placeholders until the user downloads them.)
        if let recognizer = speechRecognizer, recognizer.isAvailable {
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let request = recognitionRequest else { return }
            request.shouldReportPartialResults = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, err in
                guard let self, self.sessionGeneration == currentGeneration else { return }

                if let err = err {
                    let nsErr = err as NSError
                    if nsErr.domain != "kAFAssistantErrorDomain" || nsErr.code != 203 {
                        DispatchQueue.main.async {
                            self.error = err.localizedDescription
                        }
                    }
                    return
                }

                if let result = result, !result.isFinal {
                    let spoken = result.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        self.lastSpokenText = spoken
                        self.matchCharacters(spoken: spoken)
                    }
                }
            }

            // Feed captured audio buffers to the speech recognizer
            asr.onAudioBuffer = { [weak self] buffer in
                guard let self, self.sessionGeneration == currentGeneration else { return }
                self.recognitionRequest?.append(buffer)

                // SFSpeechAudioBufferRecognitionRequest accumulates audio buffers
                // indefinitely. Restart every 15s to keep latency near real-time
                // while retaining enough context for accurate recognition.
                let elapsed = Date().timeIntervalSince(self.recognitionStartTime)
                if elapsed > 5 {
                    DispatchQueue.main.async {
                        self.restartRecognition()
                    }
                }
            }
        } else {
            error = "Speech recognition is not available. Check your network connection and try again."
            isListening = false
        }

        isListening = true
        asr.start(selectedMicUID: NotchSettings.shared.selectedMicUID)
    }

    /// Starts recognition using the recording's AVCaptureSession audio stream
    /// instead of a separate AVAudioEngine. Call this when recording is active.
    func beginRecognitionFromRecordingAudio() {
        cleanupRecognition()
        asr.resetRetryCounter()
        recognitionStartTime = Date()
        usingRecordingAudio = true

        let currentGeneration = sessionGeneration

        // Auto-recover from unexpected stops (e.g. audio stream interruption)
        asr.onError = { [weak self] message in
            guard let self, self.sessionGeneration == currentGeneration else { return }
            self.error = message
            self.isListening = false
            if self.consecutiveRestartCount < 5 {
                self.consecutiveRestartCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard self.isListening == false else { return }
                    self.restartRecognition()
                }
            }
        }

        if let recognizer = speechRecognizer, recognizer.isAvailable {
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let request = recognitionRequest else { return }
            request.shouldReportPartialResults = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, err in
                guard let self, self.sessionGeneration == currentGeneration else { return }
                if let err = err {
                    let nsErr = err as NSError
                    if nsErr.domain != "kAFAssistantErrorDomain" || nsErr.code != 203 {
                        DispatchQueue.main.async {
                            self.error = err.localizedDescription
                        }
                    }
                    return
                }
                if let result = result, !result.isFinal {
                    let spoken = result.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        self.lastSpokenText = spoken
                        self.matchCharacters(spoken: spoken)
                    }
                }
            }
        } else {
            error = "Speech recognition is not available."
            isListening = false
            return
        }

        isListening = true
        // AVAudioEngine NOT started — audio feeds in via feedAudioSampleBuffer()
        // Periodic restart (same as beginRecognition) is handled inside
        // feedAudioSampleBuffer's elapsed-time check.
    }

    /// Feed audio from AVCaptureSession (recording) into the speech recognizer.
    /// Use this during recording instead of running a separate AVAudioEngine.
    func feedAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isListening, let request = recognitionRequest else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return }

        let numFrames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        let numChannels = Int(asbd.mChannelsPerFrame)
        guard numFrames > 0, numChannels > 0 else { return }

        // Use AVAudioCompressedBuffer as a simplified path — create a format
        // and directly access the sample buffer's audio data via the block buffer
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(numChannels),
            interleaved: false
        ) else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(numFrames))
        else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(numFrames)

        // Extract raw audio data from CMSampleBuffer and copy channel-by-channel
        guard let blockBuf = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var dataPtr: UnsafeMutablePointer<Int8>?
        var totalLength: Int = 0
        guard CMBlockBufferGetDataPointer(blockBuf, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPtr) == noErr,
              let ptr = dataPtr, totalLength > 0
        else { return }

        let floatsPerChannel = numFrames
        for ch in 0..<numChannels {
            let offset = ch * floatsPerChannel * MemoryLayout<Float>.size
            guard offset + floatsPerChannel * MemoryLayout<Float>.size <= totalLength,
                  let dst = pcmBuffer.floatChannelData?[ch]
            else { continue }
            memcpy(dst, ptr.advanced(by: offset), floatsPerChannel * MemoryLayout<Float>.size)
        }

        request.append(pcmBuffer)

        // Compute audio level for silence-paused / voice-activated mode
        if let floatData = pcmBuffer.floatChannelData?[0] {
            let len = Int(pcmBuffer.frameLength)
            var sum: Float = 0
            for i in 0..<len { let s = floatData[i]; sum += s * s }
            let count = Swift.max(1, len)
            let rms = sqrt(sum / Float(count))
            let level = CGFloat(min(1.0, rms * 12.0))
            DispatchQueue.main.async {
                self.audioLevels.append(level)
                if self.audioLevels.count > 30 { self.audioLevels.removeFirst() }
            }
        }

        // Periodic restart to keep the recognition buffer small
        let elapsed = Date().timeIntervalSince(recognitionStartTime)
        if elapsed > 5 {
            DispatchQueue.main.async { self.restartRecognition() }
        }
    }

    private func restartRecognition() {
        guard !sourceText.isEmpty else { return }
        isListening = true
        matchStartOffset = recognizedCharCount
        recentMatchPositions = []
        matchCallbackCount = 0
        consecutiveNoProgressCount = 0
        consecutiveRestartCount = 0
        cachedRemainingSource = ""
        if usingRecordingAudio {
            beginRecognitionFromRecordingAudio()
        } else {
            beginRecognition()
        }
    }

    // MARK: - Fuzzy character-level matching

    private func matchCharacters(spoken: String) {
        let spokenSignalCount = Self.normalizedSignal(spoken).count
        guard spokenSignalCount > 0 else { return }

        // Strategy 1: character-level fuzzy match from the start offset
        let charResult = charLevelMatch(spoken: spoken)

        // Strategy 2: word-level match (handles STT word substitutions)
        let wordResult = wordLevelMatch(spoken: spoken)

        // Strategy 3: recovery anchors. If ASR drops a few words but the
        // following phrase is accurate, catch up from the later anchor.
        // Only skip recovery anchors when BOTH matchers agree AND the matched
        // amount is substantial relative to what was spoken. If both agree on
        // a tiny match (e.g. stuck at the same wrong position), we still need
        // recovery anchors to try to jump past the stuck point.
        let minAgreed = min(charResult, wordResult)
        let charWordAgree = charResult > 0 && wordResult > 0
            && abs(charResult - wordResult) <= 30
            && minAgreed >= max(4, spokenSignalCount / 3)

        // When stuck for several callbacks, run full recovery (ignore throttle)
        let isStuck = consecutiveNoProgressCount >= 4
        let recoveryMatch: RecoveryAnchorResult
        let recoveryResult: Int
        if charWordAgree && !isStuck {
            recoveryMatch = .none
            recoveryResult = 0
        } else if isStuck {
            // Full recovery sweep — all 4 strategies, no throttle
            recoveryMatch = [
                immediateThreeWordAnchorMatch(spoken: spoken),
                recoveryAnchorMatch(spoken: spoken),
                windowedAnchorMatch(spoken: spoken),
                normalizedPhraseAnchorMatch(spoken: spoken)
            ].reduce(.none, betterRecoveryAnchor)
            recoveryResult = recoveryMatch.endOffset
        } else {
            recoveryMatch = bestRecoveryAnchorMatch(spoken: spoken)
            recoveryResult = recoveryMatch.endOffset
        }

        let best = selectBestMatch(
            charResult: charResult,
            wordResult: wordResult,
            recoveryResult: recoveryResult,
            spokenSignalCount: spokenSignalCount
        )

        // Stuck detection: no progress despite user speaking.
        // After 3 callbacks with no forward movement, nudge past
        // the stuck word aggressively for fast readers.
        guard best > 0 else {
            consecutiveNoProgressCount += 1
            if consecutiveNoProgressCount >= 3 {
                let nudge = max(15, spokenSignalCount / 3)
                let nudged = min(recognizedCharCount + nudge, sourceText.count)
                if nudged > recognizedCharCount {
                    recognizedCharCount = nudged
                    recentMatchPositions = [nudged]
                    consecutiveNoProgressCount = 0
                    matchStartOffset = nudged
                    cachedRemainingSource = ""
                }
            }
            return
        }

        let newCount = matchStartOffset + best
        guard newCount > recognizedCharCount else {
            consecutiveNoProgressCount += 1
            if consecutiveNoProgressCount >= 3 {
                let nudge = max(15, spokenSignalCount / 3)
                let nudged = min(recognizedCharCount + nudge, sourceText.count)
                if nudged > recognizedCharCount {
                    recognizedCharCount = nudged
                    recentMatchPositions = [nudged]
                    consecutiveNoProgressCount = 0
                    matchStartOffset = nudged
                    cachedRemainingSource = ""
                }
            }
            return
        }

        consecutiveNoProgressCount = 0

        let candidate = min(newCount, sourceText.count)
        let forwardDelta = candidate - recognizedCharCount

        // Confidence gating: require 2-of-3 recent results to agree on
        // large forward movement to avoid single-result false-positive jumps.
        recentMatchPositions.append(candidate)
        if recentMatchPositions.count > 3 {
            recentMatchPositions.removeFirst()
        }

        // First 2 callbacks in a segment pass through immediately.
        // This eliminates startup stutter where every segment's initial
        // partial results are blocked by insufficient history.
        let earlyCallbackBypass = recentMatchPositions.count <= 2

        // Check if at least 2 of the recent positions agree (within tolerance)
        let agreementThreshold = 20 // characters (wider for CJK)
        var confirmed = false
        if recentMatchPositions.count >= 2 {
            var agreeCount = 0
            for pos in recentMatchPositions {
                if abs(pos - candidate) <= agreementThreshold {
                    agreeCount += 1
                }
            }
            confirmed = agreeCount >= 2
        }

        let strategyDisagreesBecauseOneIsMissing = (charResult == 0) != (wordResult == 0)
        let shortStep = forwardDelta <= 45
        let anchoredPartial = strategyDisagreesBecauseOneIsMissing && best >= 2 && forwardDelta <= 90
        let strongSequentialMatch = best >= max(6, min(24, spokenSignalCount / 2)) && forwardDelta <= 180
        let strongRecoveryAnchor = recoveryMatch.isStrongForImmediateCatchUp
            && best >= recoveryResult
            && forwardDelta <= 1200

        let immediateThreeWordAnchor = recoveryMatch.matchedWordCount >= 3
            && best >= recoveryResult

        if immediateThreeWordAnchor {
            let anchorCandidate = min(matchStartOffset + recoveryResult, sourceText.count)
            if anchorCandidate > recognizedCharCount {
                recognizedCharCount = anchorCandidate
                recentMatchPositions = [anchorCandidate]
                return
            }
        }

        if earlyCallbackBypass || confirmed || shortStep || anchoredPartial || strongSequentialMatch || strongRecoveryAnchor {
            recognizedCharCount = candidate
            consecutiveNoProgressCount = 0
        } else {
            consecutiveNoProgressCount += 1
        }
    }

    private func bestRecoveryAnchorMatch(spoken: String) -> RecoveryAnchorResult {
        matchCallbackCount += 1
        // Only run the expensive phrase-level character anchor every 3rd callback.
        // The other 3 strategies handle nearby recovery (immediate 3-word, skip-2,
        // and windowed word anchors) and cover the common case.
        if matchCallbackCount % 3 == 1 {
            return [
                immediateThreeWordAnchorMatch(spoken: spoken),
                recoveryAnchorMatch(spoken: spoken),
                windowedAnchorMatch(spoken: spoken),
                normalizedPhraseAnchorMatch(spoken: spoken)
            ].reduce(.none, betterRecoveryAnchor)
        } else {
            return [
                immediateThreeWordAnchorMatch(spoken: spoken),
                recoveryAnchorMatch(spoken: spoken),
                windowedAnchorMatch(spoken: spoken)
            ].reduce(.none, betterRecoveryAnchor)
        }
    }

    private func betterRecoveryAnchor(_ current: RecoveryAnchorResult, _ next: RecoveryAnchorResult) -> RecoveryAnchorResult {
        guard next.isUsable else { return current }
        guard current.isUsable else { return next }

        if next.score != current.score {
            return next.score > current.score ? next : current
        }

        return next.endOffset > current.endOffset ? next : current
    }

    private func immediateThreeWordAnchorMatch(spoken: String) -> RecoveryAnchorResult {
        let (sourceWords, _) = sourceTokenCache()
        let spokenWords = splitTextIntoWords(spoken.lowercased())
        guard let match = SpeechTrackingMatcher.immediateThreeWordAnchor(sourceWords: sourceWords, spokenWords: spokenWords) else {
            return .none
        }

        return RecoveryAnchorResult(
            endOffset: match.endOffset,
            score: match.score,
            matchedWordCount: match.matchedWordCount,
            matchedSignalCount: match.matchedSignalCount,
            exactMatchCount: match.exactMatchCount,
            sourceStart: match.sourceStart,
            spokenStart: match.spokenStart,
            isPhraseMatch: false
        )
    }

    private func selectBestMatch(charResult: Int, wordResult: Int, recoveryResult: Int, spokenSignalCount: Int) -> Int {
        let anchoredWordResult = max(wordResult, recoveryResult)
        if charResult == 0 { return anchoredWordResult }
        if anchoredWordResult == 0 { return charResult }

        let tolerance = max(20, min(60, spokenSignalCount * 2))
        if abs(charResult - anchoredWordResult) <= tolerance {
            return max(charResult, anchoredWordResult)
        }

        // If word-level matching found substantially more progress, keep it
        // when it has enough spoken evidence or a recovery anchor.
        if anchoredWordResult > charResult {
            let hasRecoveryAnchor = recoveryResult > 0 && anchoredWordResult >= recoveryResult
            if hasRecoveryAnchor || anchoredWordResult >= max(6, spokenSignalCount / 3) {
                return anchoredWordResult
            }
        }

        // Paraformer zh-en often emits Chinese as a continuous phrase while
        // the prompt is displayed as CJK character tokens. If char-level is
        // ahead by more than the word matcher, keep that stronger anchor.
        if charResult > anchoredWordResult && charResult >= 2 {
            return charResult
        }

        return min(charResult, anchoredWordResult)
    }

    private func charLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        // Use Character arrays (not unicodeScalars) so counts match sourceText.count
        let src = Array(remainingSource.lowercased())
        let spk = Array(Self.normalize(spoken))

        var si = 0
        var ri = 0
        var lastGoodOrigIndex = 0

        while si < src.count && ri < spk.count {
            let sc = src[si]
            let rc = spk[ri]

            // Skip non-alphanumeric in source
            if !sc.isLetter && !sc.isNumber {
                si += 1
                continue
            }
            // Skip non-alphanumeric in spoken
            if !rc.isLetter && !rc.isNumber {
                ri += 1
                continue
            }

            if sc == rc {
                si += 1
                ri += 1
                lastGoodOrigIndex = si
            } else {
                // Try to re-sync: look ahead in both strings
                var found = false

                // Skip up to 3 chars in spoken (STT inserted extra chars)
                let maxSkipR = min(3, spk.count - ri - 1)
                if maxSkipR >= 1 {
                    for skipR in 1...maxSkipR {
                        let nextRI = ri + skipR
                        if nextRI < spk.count && spk[nextRI] == sc {
                            ri = nextRI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // Skip up to 3 chars in source (STT missed some chars)
                let maxSkipS = min(3, src.count - si - 1)
                if maxSkipS >= 1 {
                    for skipS in 1...maxSkipS {
                        let nextSI = si + skipS
                        if nextSI < src.count && src[nextSI] == rc {
                            si = nextSI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // No resync found — advance spoken pointer only.
                // Do NOT advance lastGoodOrigIndex; this is a genuine mismatch,
                // not a confirmed match position.
                ri += 1
            }
        }

        return lastGoodOrigIndex
    }

    private static func isAnnotationWord(_ word: String) -> Bool {
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        let stripped = word.filter { $0.isLetter || $0.isNumber }
        return stripped.isEmpty
    }

    private func wordLevelMatch(spoken: String) -> Int {
        let (sourceWords, _) = sourceTokenCache()
        let spokenWords = splitTextIntoWords(spoken.lowercased())

        var si = 0 // source word index
        var ri = 0 // spoken word index
        var matchedCharCount = 0

        while si < sourceWords.count && ri < spokenWords.count {
            // Auto-skip annotation words in source (brackets, emoji)
            if Self.isAnnotationWord(sourceWords[si]) {
                matchedCharCount += sourceWords[si].count
                if si < sourceWords.count - 1 { matchedCharCount += 1 }
                si += 1
                continue
            }

            let srcWord = sourceWords[si].lowercased()
                .filter { $0.isLetter || $0.isNumber }
            let spkWord = spokenWords[ri]
                .filter { $0.isLetter || $0.isNumber }

            if srcWord == spkWord || isFuzzyMatch(srcWord, spkWord) {
                // Count original chars including trailing punctuation
                matchedCharCount += sourceWords[si].count
                si += 1
                ri += 1
                // Add space separator only if there's a following word
                if si < sourceWords.count {
                    matchedCharCount += 1
                }
            } else {
                // Try skipping up to 3 spoken words (STT hallucinated words)
                var foundSpk = false
                let maxSpkSkip = min(3, spokenWords.count - ri - 1)
                for skip in 1...max(1, maxSpkSkip) where skip <= maxSpkSkip {
                    let nextSpk = spokenWords[ri + skip].filter { $0.isLetter || $0.isNumber }
                    if srcWord == nextSpk || isFuzzyMatch(srcWord, nextSpk) {
                        ri += skip
                        foundSpk = true
                        break
                    }
                }
                if foundSpk { continue }

                // Try skipping up to 3 source words (user read fast, STT missed words)
                var foundSrc = false
                let maxSrcSkip = min(3, sourceWords.count - si - 1)
                for skip in 1...max(1, maxSrcSkip) where skip <= maxSrcSkip {
                    let nextSrc = sourceWords[si + skip].lowercased().filter { $0.isLetter || $0.isNumber }
                    if nextSrc == spkWord || isFuzzyMatch(nextSrc, spkWord) {
                        // Add all skipped source words' char counts
                        for s in 0..<skip {
                            matchedCharCount += sourceWords[si + s].count + 1
                        }
                        si += skip
                        foundSrc = true
                        break
                    }
                }
                if foundSrc { continue }

                // Try treating current source word as punctuation-only and skip it
                if srcWord.isEmpty {
                    matchedCharCount += sourceWords[si].count
                    if si < sourceWords.count - 1 { matchedCharCount += 1 }
                    si += 1
                    continue
                }
                // No match, advance spoken
                ri += 1
            }
        }

        // Auto-skip trailing annotation words at end of source
        while si < sourceWords.count && Self.isAnnotationWord(sourceWords[si]) {
            matchedCharCount += sourceWords[si].count
            if si < sourceWords.count - 1 { matchedCharCount += 1 }
            si += 1
        }

        return matchedCharCount
    }

    private func recoveryAnchorMatch(spoken: String) -> RecoveryAnchorResult {
        let (_, sourceTokens) = sourceTokenCache()
        let spokenWords = splitTextIntoWords(spoken.lowercased())
            .map { Self.normalizedToken($0) }
            .filter { !$0.isEmpty }

        guard sourceTokens.count >= 2, spokenWords.count >= 2 else { return .none }

        let maxInitialSourceSkip = min(2, sourceTokens.count - 1)
        let maxInitialSpokenSkip = min(2, spokenWords.count - 1)
        var best: RecoveryAnchorResult = .none

        for sourceStart in 0...maxInitialSourceSkip {
            for spokenStart in 0...maxInitialSpokenSkip {
                var si = sourceStart
                var ri = spokenStart
                var consecutiveHits = 0
                var exactHits = 0
                var matchedSignal = 0
                var lastEndOffset = 0

                while si < sourceTokens.count && ri < spokenWords.count {
                    let src = sourceTokens[si]
                    if src.isAnnotation || src.normalized.isEmpty {
                        lastEndOffset = src.endOffset
                        si += 1
                        continue
                    }

                    let spk = spokenWords[ri]
                    let exact = src.normalized == spk
                    guard exact || isFuzzyMatch(src.normalized, spk) else {
                        break
                    }

                    consecutiveHits += 1
                    exactHits += exact ? 1 : 0
                    matchedSignal += max(src.normalized.count, spk.count)
                    lastEndOffset = src.endOffset
                    si += 1
                    ri += 1

                    if consecutiveHits >= 2 {
                        let candidate = RecoveryAnchorResult(
                            endOffset: lastEndOffset,
                            score: consecutiveHits * 120 + exactHits * 24 + matchedSignal * 4 - sourceStart * 4 - spokenStart,
                            matchedWordCount: consecutiveHits,
                            matchedSignalCount: matchedSignal,
                            exactMatchCount: exactHits,
                            sourceStart: sourceStart,
                            spokenStart: spokenStart,
                            isPhraseMatch: false
                        )
                        best = betterRecoveryAnchor(best, candidate)
                    }
                }
            }
        }

        return best
    }

    private func windowedAnchorMatch(spoken: String) -> RecoveryAnchorResult {
        let (_, sourceTokens) = sourceTokenCache()
        let spokenWords = splitTextIntoWords(spoken.lowercased())
            .map { Self.normalizedToken($0) }
            .filter { !$0.isEmpty }

        guard sourceTokens.count >= 2, spokenWords.count >= 2 else { return .none }

        let maxSourceStart = min(sourceTokens.count - 1, 40)
        let maxSpokenStart = min(spokenWords.count - 1, 6)
        var best: RecoveryAnchorResult = .none

        for sourceStart in 0...maxSourceStart {
            for spokenStart in 0...maxSpokenStart {
                var si = sourceStart
                var ri = spokenStart
                var hits = 0
                var exactHits = 0
                var matchedSignal = 0
                var lastEndOffset = 0

                while si < sourceTokens.count && ri < spokenWords.count {
                    let src = sourceTokens[si]
                    if src.isAnnotation || src.normalized.isEmpty {
                        lastEndOffset = src.endOffset
                        si += 1
                        continue
                    }

                    let spk = spokenWords[ri]
                    let exact = src.normalized == spk
                    guard exact || isFuzzyMatch(src.normalized, spk) else {
                        break
                    }

                    hits += 1
                    exactHits += exact ? 1 : 0
                    matchedSignal += max(src.normalized.count, spk.count)
                    lastEndOffset = src.endOffset
                    si += 1
                    ri += 1
                }

                let enoughForCJK = hits >= 3 || (hits >= 2 && sourceStart <= 8)
                let enoughForWords = hits >= 2 && matchedSignal >= 4
                guard enoughForCJK || enoughForWords else { continue }

                let candidate = RecoveryAnchorResult(
                    endOffset: lastEndOffset,
                    score: hits * 100 + exactHits * 20 + matchedSignal * 4 - sourceStart * 2 - spokenStart,
                    matchedWordCount: hits,
                    matchedSignalCount: matchedSignal,
                    exactMatchCount: exactHits,
                    sourceStart: sourceStart,
                    spokenStart: spokenStart,
                    isPhraseMatch: false
                )
                best = betterRecoveryAnchor(best, candidate)
            }
        }

        return best
    }

    private func normalizedPhraseAnchorMatch(spoken: String) -> RecoveryAnchorResult {
        let spokenChars = Array(Self.normalizedSignal(spoken))
        guard spokenChars.count >= 4 else { return .none }

        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        let sourceChars = Array(remainingSource.lowercased()).enumerated().compactMap { index, char -> (char: Character, endOffset: Int)? in
            guard char.isLetter || char.isNumber else { return nil }
            return (char: char, endOffset: index + 1)
        }
        guard sourceChars.count >= 4 else { return .none }

        let maxSourceStart = min(sourceChars.count - 1, 400)
        let maxSpokenStart = min(spokenChars.count - 1, 40)
        let minRunLength = spokenChars.count >= 12 ? 6 : 4
        var best: RecoveryAnchorResult = .none

        for sourceStart in 0...maxSourceStart {
            for spokenStart in 0...maxSpokenStart {
                var runLength = 0
                while sourceStart + runLength < sourceChars.count,
                      spokenStart + runLength < spokenChars.count,
                      sourceChars[sourceStart + runLength].char == spokenChars[spokenStart + runLength] {
                    runLength += 1
                }

                guard runLength >= minRunLength else { continue }
                let endOffset = sourceChars[sourceStart + runLength - 1].endOffset
                let candidate = RecoveryAnchorResult(
                    endOffset: endOffset,
                    score: runLength * 100 - sourceStart * 2 - spokenStart,
                    matchedWordCount: 0,
                    matchedSignalCount: runLength,
                    exactMatchCount: 0,
                    sourceStart: sourceStart,
                    spokenStart: spokenStart,
                    isPhraseMatch: true
                )
                best = betterRecoveryAnchor(best, candidate)
            }
        }

        return best
    }

    private func buildSourceTokens(from words: [String]) -> [(normalized: String, endOffset: Int, isAnnotation: Bool)] {
        var tokens: [(normalized: String, endOffset: Int, isAnnotation: Bool)] = []
        var offset = 0
        for word in words {
            let endOffset = offset + word.count
            tokens.append((
                normalized: Self.normalizedToken(word),
                endOffset: endOffset,
                isAnnotation: Self.isAnnotationWord(word)
            ))
            offset = endOffset + 1
        }
        return tokens
    }

    /// Returns cached (sourceWords, sourceTokens) for the current matchStartOffset.
    /// Rebuilds the cache only when the offset changes.
    private func sourceTokenCache() -> (words: [String], tokens: [(normalized: String, endOffset: Int, isAnnotation: Bool)]) {
        let remaining = String(sourceText.dropFirst(matchStartOffset))
        if remaining != cachedRemainingSource {
            cachedRemainingSource = remaining
            cachedSourceWords = remaining.split(separator: " ").map { String($0) }
            cachedSourceTokens = buildSourceTokens(from: cachedSourceWords)
        }
        return (cachedSourceWords, cachedSourceTokens)
    }

    private func isFuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        // Exact match
        if a == b { return true }
        let shorter = min(a.count, b.count)
        // Prefix match — only for words with at least 3 chars to avoid
        // false positives like "or" matching "organization"
        if shorter >= 3 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        // Shared prefix >= 60% of shorter word (min 3 chars shared)
        let shared = zip(a, b).prefix(while: { $0 == $1 }).count
        if shorter >= 3 && shared >= max(3, shorter * 3 / 5) { return true }
        // Edit distance tolerance — stricter for very short words
        let dist = editDistance(a, b)
        if shorter <= 2 { return false } // 2-char words must be exact
        if shorter <= 4 { return dist <= 1 }
        if shorter <= 8 { return dist <= 2 }
        return dist <= max(a.count, b.count) / 3
    }

    private func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i-1] == b[j-1] ? prev : min(prev, dp[j], dp[j-1]) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }

    private static func normalizedToken(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func normalizedSignal(_ text: String) -> String {
        normalizedToken(text)
    }
}
