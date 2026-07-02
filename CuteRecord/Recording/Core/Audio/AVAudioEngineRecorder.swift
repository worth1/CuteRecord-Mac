import Foundation
import AVFoundation
import os

// MARK: - AVAudioEngine 麦克风录制器
// 注意：不能标记 @MainActor，因为 installTap 回调在音频实时线程运行
// 主 actor 隔离会导致音频线程读到过期的属性值（isRecording / sessionStarted / sessionStartHostTime）
class AVAudioEngineRecorder: NSObject, @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFile: AVAudioFile?
    private var audioWriterInput: AVAssetWriterInput?
    private let lock = OSAllocatedUnfairLock()
    private var _isRecording = false
    private var _sessionStarted = false
    private var _sessionStartHostTime: UInt64 = 0
    /// Cached audio format description — format never changes, avoids per-buffer CoreMedia allocation
    private var cachedFormatDescription: CMAudioFormatDescription?

    var isRecording: Bool {
        get { lock.withLock { _isRecording } }
        set { lock.withLock { _isRecording = newValue } }
    }
    var sessionStarted: Bool {
        get { lock.withLock { _sessionStarted } }
        set { lock.withLock { _sessionStarted = newValue } }
    }
    var sessionStartHostTime: UInt64 {
        get { lock.withLock { _sessionStartHostTime } }
        set { lock.withLock { _sessionStartHostTime = newValue } }
    }

    // 音频缓冲区管理
    private let audioQueue = DispatchQueue(label: "com.screenrecorder.audioengine", qos: .userInteractive)
    private var startTime: CMTime?
    private var audioFormat: AVAudioFormat?
    private var sampleCount: Int64 = 0  // 音频样本计数器
    
    // MARK: - 初始化
    override init() {
        super.init()
        setupAudioEngine()
    }
    
    deinit {
        // 清理将在stopRecording方法中处理
    }
    
    // MARK: - 音频引擎设置
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        inputNode = audioEngine?.inputNode
        
        guard let inputNode = inputNode else {
            print("❌ 无法获取音频输入节点")
            return
        }
        
        // 获取输入格式
        audioFormat = inputNode.outputFormat(forBus: 0)
        print("🎤 AVAudioEngine 初始化完成")
        print("   格式: \(audioFormat?.description ?? "未知")")
    }
    
    // MARK: - 设置音频设备
    nonisolated func setInputDevice(deviceID: AudioDeviceID?) {
        guard let engine = audioEngine else { return }

        // 如果没有指定设备ID，使用默认设备
        guard let deviceID = deviceID else {
            print("🎤 使用默认麦克风设备")
            return
        }

        // 设置指定的音频输入设备
        let audioUnit = engine.inputNode.audioUnit
        var deviceIDVar = deviceID
        let propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioUnitSetProperty(
            audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDVar,
            propertySize
        )

        if status == noErr {
            print("✅ 已设置音频输入设备: \(deviceID)")
        } else {
            print("❌ 设置音频输入设备失败: \(status)")
        }
    }
    
    // MARK: - 开始录制
    nonisolated func startRecording(writerInput: AVAssetWriterInput) throws {
        guard let engine = audioEngine,
              let inputNode = inputNode else {
            throw RecordingError.audioSetupFailed
        }

        self.audioWriterInput = writerInput
        self.isRecording = true
        self.sessionStarted = false  // 等待视频 session 启动
        self.startTime = nil
        self.sampleCount = 0  // 重置样本计数器
        self.sessionStartHostTime = 0  // 重置会话开始时间
        
        // 安装音频tap来捕获音频数据
        let format = inputNode.outputFormat(forBus: 0)
        let queue = self.audioQueue  // 局部引用，避免闭包捕获 actor
        
        // 注意：tap 回调在音频实时线程调用，buffer 只在回调内有效
        // 必须在回调内同步复制数据，不能异步延迟处理
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self = self else { return }
            
            // 在回调内同步创建 CMSampleBuffer（会复制 buffer 数据）
            // 这样即使 buffer 在回调返回后被回收，数据仍然有效
            let isRec = self.isRecording
            let sessionOn = self.sessionStarted
            guard isRec, sessionOn else { return }
            guard let sampleBuffer = self.createSampleBuffer(from: buffer, time: time) else { return }
            
            queue.async { [weak self] in
                guard let self = self else { return }
                let isRec = self.isRecording
                let sessionOn = self.sessionStarted
                guard isRec, sessionOn else { return }
                guard let writerInput = self.audioWriterInput,
                      writerInput.isReadyForMoreMediaData else { return }
                
                if writerInput.append(sampleBuffer) {
                    self.sampleCount += Int64(buffer.frameLength)
                }
            }
        }
        
        // 启动音频引擎
        try engine.start()
        print("✅ AVAudioEngine 开始录制")
    }
    
    // MARK: - 停止录制
    func stopRecording() {
        guard let engine = audioEngine else { return }

        isRecording = false
        sampleCount = 0  // 重置样本计数器
        
        // 移除音频tap
        inputNode?.removeTap(onBus: 0)
        
        // 停止音频引擎
        engine.stop()
        
        print("⏹ AVAudioEngine 停止录制")
    }
    
    // MARK: - 启动会话（与视频 session 对齐时间戳）
    func startSession() {
        sessionStartHostTime = mach_absolute_time()
        sessionStarted = true
        print("🎤 音频会话已启动，时间戳已对齐")
    }
    
    // MARK: - 创建CMSampleBuffer
    // 从 AVAudioPCMBuffer 创建 CMSampleBuffer，使用 AudioBufferList 直接引用原始数据
    // 这样避免了手动复制和数据布局（交错/非交错）不匹配的问题
    private func createSampleBuffer(from audioBuffer: AVAudioPCMBuffer, time: AVAudioTime) -> CMSampleBuffer? {
        let audioFormat = audioBuffer.format
        let frameLength = Int64(audioBuffer.frameLength)
        let sampleRate = audioFormat.sampleRate

        // 使用视频 session 启动时的 host time 作为参考点，确保音画同步
        let hostTimeDiff: UInt64
        if sessionStartHostTime > 0 && time.hostTime >= sessionStartHostTime {
            hostTimeDiff = time.hostTime - sessionStartHostTime
        } else {
            hostTimeDiff = time.hostTime
        }
        let hostTimeFrequency = CVGetHostClockFrequency()
        guard hostTimeFrequency > 0 else {
            return nil
        }
        let seconds = Double(hostTimeDiff) / hostTimeFrequency
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / Double(sampleRate) else {
            return nil
        }

        let presentationTime = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(sampleRate))

        // 创建音频格式描述（缓存复用，避免每次回调都分配 CoreMedia 对象）
        let formatDesc: CMAudioFormatDescription
        if let cached = cachedFormatDescription {
            formatDesc = cached
        } else {
            var formatDescription: CMAudioFormatDescription?
            var asbd = audioFormat.streamDescription.pointee
            let fmtStatus = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
            guard fmtStatus == noErr, let desc = formatDescription else {
                return nil
            }
            cachedFormatDescription = desc
            formatDesc = desc
        }
        
        // 复制音频数据到新分配的内存块，保持原始非交错布局
        // AVAudioEngine 的 inputNode 输出是非交错 Float32 格式
        // 数据布局：[ch0_sample0, ch0_sample1, ..., ch0_sampleN, ch1_sample0, ..., ch1_sampleN]
        let frameCount = Int(audioBuffer.frameLength)
        let channelCount = Int(audioFormat.channelCount)
        let bytesPerChannel = frameCount * MemoryLayout<Float>.size
        let totalBytes = bytesPerChannel * channelCount
        
        guard let copiedData = malloc(totalBytes) else {
            return nil
        }
        
        if let channelData = audioBuffer.floatChannelData {
            // 非交错布局：逐通道复制，每个通道的数据连续排列
            for channel in 0..<channelCount {
                let dst = copiedData.advanced(by: channel * bytesPerChannel)
                memcpy(dst, channelData[channel], bytesPerChannel)
            }
        } else {
            // 如果不是 Float32 格式（极少见），用零填充
            memset(copiedData, 0, totalBytes)
        }
        
        // 创建 CMBlockBuffer（kCFAllocatorDefault 会在释放时 free copiedData）
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: copiedData,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        
        guard blockStatus == noErr, let block = blockBuffer else {
            return nil
        }
        
        // 创建 CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        
        // 构造时间信息，显式设置 duration 让编码器正确处理
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameLength), timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        if sampleStatus != noErr {
            return nil
        }
        
        return sampleBuffer
    }
}

// MARK: - 录制错误扩展
// RecordingError.audioSetupFailed 已在其他地方定义