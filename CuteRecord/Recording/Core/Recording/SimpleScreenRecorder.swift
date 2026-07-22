import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Combine

/// 录制器：接收外部音视频帧写入文件
/// 不自己创建 AVCaptureSession，由调用方通过 append 方法传入帧
class SimpleScreenRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0

    private let writeQueue = DispatchQueue(label: "com.cuterecord.simple.writer", qos: .userInteractive)

    // 以下属性仅在 writeQueue 上访问
    private var videoWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var videoFrameCount = 0
    private var audioSampleCount = 0
    private var firstVideoTimestamp: CMTime?
    private var firstAudioTimestamp: CMTime?
    private var isWriting = false

    // 主线程定时器
    private var durationTimer: Timer?
    private var durationStartTime: Date?

    // MARK: - 开始录制（准备好 writer，等待外部帧）

    func startRecording(outputURL: URL, width: Int, height: Int) async throws {
        let started = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            writeQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                guard !self.isWriting else {
                    continuation.resume(returning: false)
                    return
                }

                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try? FileManager.default.removeItem(at: outputURL)
                }

                do {
                    let (writer, videoInput, adaptor) = try Self.makeVideoWriter(
                        outputURL: outputURL,
                        width: width,
                        height: height
                    )
                    let audioInput = Self.makeAudioWriter(writer: writer)

                    guard writer.startWriting() else {
                        throw NSError(domain: "SimpleScreenRecorder", code: -7, userInfo: [NSLocalizedDescriptionKey: "无法启动视频写入"])
                    }
                    writer.startSession(atSourceTime: .zero)

                    self.videoWriter = writer
                    self.videoWriterInput = videoInput
                    self.pixelBufferAdaptor = adaptor
                    self.audioWriterInput = audioInput
                    self.outputURL = outputURL
                    self.videoFrameCount = 0
                    self.audioSampleCount = 0
                    self.firstVideoTimestamp = nil
                    self.firstAudioTimestamp = nil
                    self.isWriting = true

                    print("✅ 录制器已就绪: \(outputURL.lastPathComponent)")
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        guard started else {
            throw NSError(domain: "SimpleScreenRecorder", code: -9, userInfo: [NSLocalizedDescriptionKey: "录制已在进行中"])
        }

        isRecording = true
        durationStartTime = Date()
        startDurationTimer()
    }

    // MARK: - 写入视频帧（从外部 CameraManager 调用）

    func appendVideoFrame(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        writeQueue.async { [weak self] in
            guard let self, self.isWriting,
                  let adaptor = self.pixelBufferAdaptor,
                  let writerInput = self.videoWriterInput else {
                print("⚠️ SimpleScreenRecorder: guard failed - isWriting=\(self?.isWriting ?? false), adaptor=\(self?.pixelBufferAdaptor != nil), input=\(self?.videoWriterInput != nil)")
                return
            }
            guard writerInput.isReadyForMoreMediaData else {
                print("⚠️ SimpleScreenRecorder: writerInput not ready")
                return
            }

            if self.firstVideoTimestamp == nil {
                self.firstVideoTimestamp = timestamp
            }
            let relativeTime = CMTimeSubtract(timestamp, self.firstVideoTimestamp!)

            if adaptor.append(pixelBuffer, withPresentationTime: relativeTime) {
                self.videoFrameCount += 1
                if self.videoFrameCount == 1 {
                    print("📹 第一帧视频已写入")
                } else if self.videoFrameCount % 150 == 0 {
                    print("📹 已写入 \(self.videoFrameCount) 帧视频")
                }
            }
        }
    }

    // MARK: - 写入音频样本（从外部 CameraManager 调用）

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        writeQueue.async { [weak self] in
            guard let self, self.isWriting,
                  let writerInput = self.audioWriterInput,
                  writerInput.isReadyForMoreMediaData else { return }

            let originalTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if self.firstAudioTimestamp == nil {
                self.firstAudioTimestamp = originalTimestamp
            }
            let relativeTime = CMTimeSubtract(originalTimestamp, self.firstAudioTimestamp!)

            var timingInfo = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: relativeTime,
                decodeTimeStamp: CMTime.invalid
            )

            var newSampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleBufferOut: &newSampleBuffer
            )

            if status == noErr, let buffer = newSampleBuffer {
                if writerInput.append(buffer) {
                    self.audioSampleCount += 1
                }
            }
        }
    }

    // MARK: - 停止录制

    func stopRecording() async throws -> URL? {
        guard isRecording else { return nil }

        durationTimer?.invalidate()
        durationTimer = nil
        durationStartTime = nil
        isRecording = false
        recordingDuration = 0

        return try await withCheckedThrowingContinuation { continuation in
            writeQueue.async { [weak self] in
                guard let self, self.isWriting else {
                    continuation.resume(returning: nil)
                    return
                }

                print("⏹ 停止录制...")
                self.isWriting = false

                let writer = self.videoWriter
                let finalURL = self.outputURL
                let frameCount = self.videoFrameCount
                let sampleCount = self.audioSampleCount

                self.videoWriterInput?.markAsFinished()
                self.audioWriterInput?.markAsFinished()

                self.videoWriter = nil
                self.videoWriterInput = nil
                self.audioWriterInput = nil
                self.pixelBufferAdaptor = nil
                self.outputURL = nil
                self.firstVideoTimestamp = nil
                self.firstAudioTimestamp = nil
                self.videoFrameCount = 0
                self.audioSampleCount = 0

                writer?.finishWriting {
                    print("✅ 录制完成: \(finalURL?.lastPathComponent ?? ""), 视频帧: \(frameCount), 音频样本: \(sampleCount)")
                    continuation.resume(returning: finalURL)
                }
            }
        }
    }

    // MARK: - 时长定时器（主线程）

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let startTime = self.durationStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(startTime)
        }
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

    // MARK: - 工厂方法

    private static func makeVideoWriter(outputURL: URL, width: Int, height: Int) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        writer.add(videoInput)
        return (writer, videoInput, adaptor)
    }

    private static func makeAudioWriter(writer: AVAssetWriter) -> AVAssetWriterInput? {
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(audioInput) else { return nil }
        writer.add(audioInput)
        return audioInput
    }
}
