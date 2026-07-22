//
//  SherpaOnnx.swift
//  CuteRecord
//
//  Real sherpa-onnx streaming ASR wrapper (ported from iOS version).
//  Uses on-device transducer model — fully offline, no network required.
//

import Combine
import Foundation
import AVFoundation

// MARK: - Recognizer

final class SherpaOnnxRecognizer: ObservableObject {

    @Published var partialText: String = ""
    @Published var isReady: Bool = false
    @Published var errorMessage: String?

    private var recognizer: OpaquePointer?
    private var stream: OpaquePointer?
    private let queue = DispatchQueue(label: "com.cuterecord.sherpa", qos: .userInitiated)
    private var modelDir: String = ""

    // MARK: - Lifecycle

    /// Load the transducer model and create a streaming recognizer.
    /// Model directory should contain: encoder, decoder, joiner .onnx files + tokens.txt
    func start(modelDir: String) throws {
        guard recognizer == nil else { return }

        self.modelDir = modelDir
        let encoder = modelDir + "/encoder-epoch-99-avg-1.int8.onnx"
        let decoder = modelDir + "/decoder-epoch-99-avg-1.onnx"
        let joiner  = modelDir + "/joiner-epoch-99-avg-1.int8.onnx"
        let tokens  = modelDir + "/tokens.txt"

        // Verify files exist
        for (name, path) in [("encoder", encoder), ("decoder", decoder),
                             ("joiner", joiner), ("tokens", tokens)] {
            guard FileManager.default.fileExists(atPath: path) else {
                throw SherpaOnnxError.modelNotFound("\(name) not found at \(path)")
            }
        }

        var config = SherpaOnnxOnlineRecognizerConfig()

        // Feature config
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80

        // Allocate C strings that must outlive config usage
        guard let enc = strdup(encoder),
              let dec = strdup(decoder),
              let joi = strdup(joiner),
              let tok = strdup(tokens),
              let prov = strdup("cpu"),
              let unit = strdup("cjkchar"),
              let method = strdup("greedy_search")
        else {
            throw SherpaOnnxError.initializationFailed("Memory allocation failed for model config")
        }

        // Transducer model config
        config.model_config.transducer.encoder = UnsafePointer(enc)
        config.model_config.transducer.decoder = UnsafePointer(dec)
        config.model_config.transducer.joiner  = UnsafePointer(joi)
        config.model_config.tokens  = UnsafePointer(tok)
        config.model_config.provider = UnsafePointer(prov)
        config.model_config.num_threads = 1
        config.model_config.modeling_unit = UnsafePointer(unit)

        // Decoding
        config.decoding_method = UnsafePointer(method)
        config.enable_endpoint = 0  // We manage endpoints ourselves

        guard let rec = SherpaOnnxCreateOnlineRecognizer(&config) else {
            free(enc); free(dec); free(joi); free(tok); free(prov); free(unit); free(method)
            throw SherpaOnnxError.initializationFailed("Failed to create recognizer")
        }
        self.recognizer = rec

        // Free C strings (recognizer copies them internally)
        free(enc); free(dec); free(joi); free(tok); free(prov); free(unit); free(method)

        // Create initial stream
        self.stream = SherpaOnnxCreateOnlineStream(rec)

        DispatchQueue.main.async {
            self.isReady = true
            self.errorMessage = nil
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if let s = self.stream {
                SherpaOnnxDestroyOnlineStream(s)
                self.stream = nil
            }
            if let r = self.recognizer {
                SherpaOnnxDestroyOnlineRecognizer(r)
                self.recognizer = nil
            }
            DispatchQueue.main.async {
                self.isReady = false
                self.partialText = ""
            }
        }
    }

    /// Reset stream state (e.g. when switching pages).
    /// Does NOT recreate the recognizer — just the stream.
    func reset() {
        queue.async { [weak self] in
            guard let self, let rec = self.recognizer else { return }
            if let oldStream = self.stream {
                SherpaOnnxDestroyOnlineStream(oldStream)
            }
            self.stream = SherpaOnnxCreateOnlineStream(rec)
            DispatchQueue.main.async { self.partialText = "" }
        }
    }

    // MARK: - Audio Input

    /// Feed raw Float32 PCM samples to the streaming recognizer.
    func acceptWaveform(samples: [Float], sampleRate: Int32) {
        queue.async { [weak self] in
            guard let self, let rec = self.recognizer, let stm = self.stream else { return }

            samples.withUnsafeBufferPointer { buf in
                SherpaOnnxOnlineStreamAcceptWaveform(stm, sampleRate, buf.baseAddress, Int32(buf.count))
            }

            // Decode while frames are ready
            while SherpaOnnxIsOnlineStreamReady(rec, stm) == 1 {
                SherpaOnnxDecodeOnlineStream(rec, stm)
            }

            // Get latest partial result
            let result = SherpaOnnxGetOnlineStreamResult(rec, stm)
            if let text = result?.pointee.text {
                let recognized = String(cString: text)
                if !recognized.isEmpty {
                    DispatchQueue.main.async { self.partialText = recognized }
                }
            }
            SherpaOnnxDestroyOnlineRecognizerResult(result)
        }
    }

    // MARK: - Convenience

    /// Extract Float32 PCM samples from a CMSampleBuffer and feed to the recognizer.
    func feedAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuf = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return }

        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuf, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLen,
                                          dataPointerOut: &dataPtr) == noErr,
              let ptr = dataPtr, totalLen > 0
        else { return }

        let sampleRate = Int32(asbd.mSampleRate)
        let numFrames = totalLen / Int(asbd.mBytesPerFrame)
        let numChannels = Int(asbd.mChannelsPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitDepth = asbd.mBitsPerChannel
        let bytesPerSample = Int(bitDepth) / 8

        guard numFrames > 0 else { return }

        var floatSamples = [Float](repeating: 0, count: numFrames)

        for frame in 0..<numFrames {
            let frameOffset = frame * Int(asbd.mBytesPerFrame)
            let raw = UnsafeRawPointer(ptr).advanced(by: frameOffset)
            var value: Float = 0

            if isFloat, bitDepth == 32 {
                value = raw.assumingMemoryBound(to: Float.self).pointee
            } else if bitDepth == 16 {
                value = Float(raw.assumingMemoryBound(to: Int16.self).pointee) / 32768.0
            } else if bitDepth == 32 {
                value = Float(raw.assumingMemoryBound(to: Int32.self).pointee) / 2147483648.0
            }

            if numChannels > 1 {
                for ch in 1..<min(numChannels, 2) {
                    let chRaw = UnsafeRawPointer(ptr).advanced(by: frameOffset + ch * bytesPerSample)
                    if isFloat, bitDepth == 32 {
                        value += chRaw.assumingMemoryBound(to: Float.self).pointee
                    } else if bitDepth == 16 {
                        value += Float(chRaw.assumingMemoryBound(to: Int16.self).pointee) / 32768.0
                    }
                }
                value /= Float(min(numChannels, 2))
            }

            floatSamples[frame] = value * 3.0  // Boost gain for typical mic levels
        }

        acceptWaveform(samples: floatSamples, sampleRate: sampleRate)
    }
}

// MARK: - Error

enum SherpaOnnxError: LocalizedError {
    case modelNotFound(String)
    case initializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let msg): return "Model not found: \(msg)"
        case .initializationFailed(let msg): return "Init failed: \(msg)"
        }
    }
}
