import AppKit
import AVFoundation
import Combine
import CoreMedia
import Foundation

@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    let recordingState = RecordingState()
    let permissionsManager = PermissionsManager()
    let audioManager = AudioManager()

    private let simpleRecorder = SimpleScreenRecorder()
    private let previewController = RecordingPreviewController()
    private let recordingIndicator = RecordingIndicatorWindow()
    private let previewRecordingIndicator = RecordingIndicatorWindow()

    let networkCamera = NetworkCameraReceiver()
    var networkCameraPosition: AVCaptureDevice.Position = .back
    private var circularCameraWindow: CircularCameraWindow?
    private var previewCameraWindow: CircularCameraWindow?
    private var recordingTimer: Timer?
    private var isPreviewActive = false
    private var pendingStopCompletions: [() -> Void] = []

    @Published var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var isRecording = false
    @Published private(set) var isPreviewing = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportStatusText: String?
    @Published private(set) var pendingCapturedRecording: CapturedRecordingOutput?
    @Published private(set) var recordingLibraryChangeID = UUID()
    @Published private(set) var lastOutputURL: URL?
    @Published var lastError: String?
    @Published var showPermissionRequest = false
    var onPreviewClosed: (() -> Void)?

    let cameraManager = CameraManager()

    private func setupNetworkCameraCallbacks() {
        networkCamera.onCommandReceived = { [weak self] cmd in
            if cmd == "S" { self?.stopNetworkRecording() }
        }
    }

    var currentRecordingInterfaceFrame: CGRect? {
        resolvedRecordingTarget()?.interfaceFrame
    }

    var hasPendingCapturedRecording: Bool {
        pendingCapturedRecording != nil
    }

    var canRenderPendingCameraOnly: Bool {
        pendingCapturedRecording != nil
    }

    // MARK: - Preview

    func refreshDevicesAndPermissions() {
        Task {
            await permissionsManager.checkAllPermissions()
            await audioManager.refreshMicrophoneDevices()
            cameraManager.refreshCameraDevices()
            updatePreview()
        }
    }

    func requestPermissions() {
        Task {
            await permissionsManager.requestAllPermissions()
            updatePreview()
        }
    }

    func beginPreview() {
        guard !recordingState.isRecording else { return }
        isPreviewActive = true
        isPreviewing = true
        Task {
            await permissionsManager.checkAllPermissions()
            guard permissionsManager.cameraAuthorized else {
                NSLog("[RecordingController] Camera not authorized")
                return
            }
            // Small delay after permission grant lets system settle (macOS issue)
            if !cameraManager.isCapturing {
                try? await Task.sleep(nanoseconds: 300_000_000)
                do {
                    try await cameraManager.startCapture(enableAudio: false)
                } catch {
                    NSLog("[RecordingController] Camera start failed: \(error)")
                    // Retry once after a delay
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    do { try await cameraManager.startCapture(enableAudio: false) }
                    catch { NSLog("[RecordingController] Camera retry also failed: \(error)"); return }
                }
            }
            updatePreview()
        }
    }

    func showCameraPreview() {
        recordingState.cameraOverlayEnabled = true
        updatePreview()
    }

    func hideCameraPreview() {
        recordingState.cameraOverlayEnabled = false
        circularCameraWindow?.hide()
        circularCameraWindow = nil
    }

    func updatePreview() {
        guard isPreviewActive, !recordingState.isRecording else { return }
        guard let previewRect = previewRecordingRect() else {
            previewRecordingIndicator.hideIndicator()
            updateCameraPreview(recordingRect: nil)
            return
        }
        updateCameraPreview(recordingRect: previewRect)
    }

    func resetCustomCameraOverlayFrame() {
        recordingState.customCameraOverlayFrame = nil
        updatePreview()
    }

    func restartCameraPreview() {
        guard isPreviewActive else { return }
        if !recordingState.isRecording { cameraManager.stopCapture() }
        updatePreview()
    }

    func endPreview() {
        isPreviewActive = false
        isPreviewing = false
        previewRecordingIndicator.hideIndicator()
        previewCameraWindow?.hide()
        previewCameraWindow = nil
        if !recordingState.isRecording { cameraManager.stopCapture() }
    }

    // MARK: - Recording

    func startSimpleRecording() async {
        guard !recordingState.isRecording, !isStarting else { return }
        isStarting = true
        lastError = nil

        // Refresh permissions state before checking (avoids stale cache)
        await permissionsManager.checkAllPermissions()
        print("🔍 录制权限检查: mic=\(permissionsManager.microphoneAuthorized) cam=\(permissionsManager.cameraAuthorized)")
        if recordingState.microphoneEnabled && !permissionsManager.microphoneAuthorized {
            print("❌ 麦克风未授权，弹出权限窗口")
            isStarting = false; showPermissionRequest = true; return
        }
        if recordingState.cameraOverlayEnabled && !permissionsManager.cameraAuthorized {
            print("❌ 摄像头未授权，弹出权限窗口")
            isStarting = false; showPermissionRequest = true; return
        }

        recordingState.startRecording()
        isRecording = true
        startRecordingTimer()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let outputURL = recordingState.outputDirectory
            .appendingPathComponent("Camera_\(formatter.string(from: Date())).mov")

        var portraitCrop: (width: Int, height: Int, cropX: Int)?
        for _ in 0..<30 {
            guard let frame = cameraManager.getCurrentFrame() else { continue }
            let rw = CVPixelBufferGetWidth(frame)
            let rh = CVPixelBufferGetHeight(frame)
            if rw < rh {
                let cropH = rh / 2 * 2
                let cropW = Int(CGFloat(cropH) * CGFloat(cropH) / CGFloat(rw) / 2) * 2
                let cropX = (rw - cropW) / 2
                portraitCrop = (cropW, cropH, cropX)
            }
            break
        }

        let writerWidth = portraitCrop?.width ?? Int(cameraManager.currentResolution.width)
        let writerHeight = portraitCrop?.height ?? Int(cameraManager.currentResolution.height)

        do {
            try await simpleRecorder.startRecording(
                outputURL: outputURL, width: writerWidth, height: writerHeight
            )
        } catch {
            recordingState.stopRecording(); isRecording = false
            stopRecordingTimer(); lastError = error.localizedDescription
            isStarting = false; return
        }

        // Wire up camera → SimpleScreenRecorder frame feeding
        cameraManager.setRecordingFrameHandler { [weak self] frame in
            guard let self, self.simpleRecorder.isRecording else { return }
            self.simpleRecorder.appendVideoFrame(pixelBuffer: frame.pixelBuffer, timestamp: frame.timestamp)
        }
        cameraManager.audioRecordingHandler = { [weak self] sampleBuffer in
            guard let self, self.simpleRecorder.isRecording else { return }
            self.simpleRecorder.appendAudioSampleBuffer(sampleBuffer)
        }

        // Restart camera with audio for recording (preview was started without audio)
        if cameraManager.isCapturing {
            do { try await cameraManager.startCapture(enableAudio: true) }
            catch { print("⚠️ 录制音频启动失败: \(error)") }
        }

        showRecordingOverlays()
        isStarting = false
    }

    func startNetworkRecording() async {
        guard !recordingState.isRecording, !isStarting else { return }
        isStarting = true; lastError = nil

        // Push teleprompter text to iPhone before starting recording
        let service = CuteRecordService.shared
        let idx = service.currentPageIndex
        let currentText = (idx < service.pages.count ? service.pages[idx] : service.pages.first) ?? ""
        networkCamera.sendCommand("A:" + currentText)

        // Brief delay for iPhone to process the script
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Send scroll speed
        let speed = String(format: "%.1f", NotchSettings.shared.scrollSpeed)
        networkCamera.sendCommand("s:" + speed)

        // Start recording on iPhone
        recordingState.startRecording()
        isRecording = true
        startRecordingTimer()
        networkCamera.sendCommand("R")
        isStarting = false
    }

    func stopNetworkRecording() {
        networkCamera.sendCommand("S")
        networkCamera.disconnect()
        recordingState.stopRecording()
        isRecording = false
        stopRecordingTimer()
    }

    func connectToNetworkCamera(ip: String) {
        setupNetworkCameraCallbacks()
        networkCamera.connect(to: ip)
    }

    func stopSimpleRecordingAndGetOutput() async -> URL? {
        do {
            if let outputURL = try await simpleRecorder.stopRecording() {
                pendingCapturedRecording = CapturedRecordingOutput(discovering: outputURL)
                recordingState.stopRecording()
                isRecording = false
                stopRecordingTimer()
                circularCameraWindow?.hide(); circularCameraWindow = nil
                previewCameraWindow?.hide(); previewCameraWindow = nil
                return outputURL
            }
        } catch {
            lastError = error.localizedDescription
        }
        recordingState.stopRecording()
        isRecording = false
        stopRecordingTimer()
        circularCameraWindow?.hide(); circularCameraWindow = nil
        previewCameraWindow?.hide(); previewCameraWindow = nil
        return nil
    }

    func stopRecording(completion: (() -> Void)? = nil) {
        if let completion { pendingStopCompletions.append(completion) }
        guard !isStopping else { return }
        guard recordingState.isRecording else { runPendingStopCompletions(); return }
        isStopping = true
        stopRecordingTimer()
        recordingIndicator.hideIndicator()
        // Disconnect frame feeding
        cameraManager.setRecordingFrameHandler(nil)
        cameraManager.audioRecordingHandler = nil
        // Close all camera windows
        circularCameraWindow?.hide(); circularCameraWindow = nil
        previewCameraWindow?.hide(); previewCameraWindow = nil

        Task {
            pendingCapturedRecording = CapturedRecordingOutput(discovering: recordingState.outputURL)
            recordingState.stopRecording()
            isRecording = false
            isStopping = false
            runPendingStopCompletions()
        }
    }

    private func runPendingStopCompletions() {
        let completions = pendingStopCompletions
        pendingStopCompletions.removeAll()
        for c in completions { c() }
    }

    // MARK: - Post-Recording

    func renderPendingCapturedRecording(mode: RecordingRenderMode, exportSettings: RecordingExportSettings = .default) {
        guard let url = pendingCapturedRecording?.outputURL, !isExporting else { return }
        pendingCapturedRecording = nil
        lastOutputURL = url
        recordingLibraryChangeID = UUID()
        SoundPlayer.play("lling")
        revealRecordingInFinder(url)
    }

    func renderPendingCapturedRecording(editDecision: RecordingEditDecision, exportSettings: RecordingExportSettings = .default) {
        renderPendingCapturedRecording(mode: .edited(editDecision), exportSettings: exportSettings)
    }

    func renderCapturedRecording(_ capturedOutput: CapturedRecordingOutput, editDecision: RecordingEditDecision, exportSettings: RecordingExportSettings = .default) {
        lastOutputURL = capturedOutput.outputURL
        recordingLibraryChangeID = UUID()
        SoundPlayer.play("lling")
        revealRecordingInFinder(capturedOutput.outputURL)
    }

    func renderCapturedRecording(_ capturedOutput: CapturedRecordingOutput, mode: RecordingRenderMode, exportSettings: RecordingExportSettings = .default) {
        lastOutputURL = capturedOutput.outputURL
        recordingLibraryChangeID = UUID()
        SoundPlayer.play("lling")
        revealRecordingInFinder(capturedOutput.outputURL)
    }

    func deletePendingCapturedRecording() {
        guard let output = pendingCapturedRecording else { return }
        pendingCapturedRecording = nil
        deleteCapturedRecording(output)
    }

    func deleteCapturedRecording(_ output: CapturedRecordingOutput) {
        try? FileManager.default.removeItem(at: output.outputURL)
        lastOutputURL = nil
        exportStatusText = nil
        recordingLibraryChangeID = UUID()
    }

    // MARK: - Internal

    private func startRecordingTimer() {
        let start = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.recordingState.recordingDuration = Date().timeIntervalSince(start)
        }
    }
    private func stopRecordingTimer() { recordingTimer?.invalidate(); recordingTimer = nil }

    private func showRecordingOverlays() {
        // Hide preview overlay before showing recording overlay (only one at a time)
        previewCameraWindow?.hide()
        previewCameraWindow = nil
        guard recordingState.cameraOverlayEnabled else { return }
        if circularCameraWindow == nil { circularCameraWindow = CircularCameraWindow(cameraManager: cameraManager) }
        circularCameraWindow?.show(
            at: recordingState.cameraOverlayPosition, size: recordingState.cameraOverlaySize,
            shape: recordingState.cameraOverlayShape, recordingRect: previewRecordingRect(),
            customFrame: recordingState.customCameraOverlayFrame
        ) { [weak self] frame in self?.recordingState.customCameraOverlayFrame = frame }
    }

    private func resolvedRecordingTarget() -> ResolvedRecordingTarget? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let display = RecordingDisplayGeometry(
            id: CGDirectDisplayID(screen.displayID ?? 0),
            frame: screen.frame, name: screen.localizedName
        )
        return .display(display)
    }

    private func previewRecordingRect() -> CGRect? {
        guard let target = resolvedRecordingTarget() else { return nil }
        let visibleFrame = target.interfaceFrame
        let aspectRatio: CGFloat = 16.0 / 9.0
        var width = visibleFrame.width * 0.62
        var height = width / aspectRatio
        if height > visibleFrame.height * 0.82 { height = visibleFrame.height * 0.82; width = height * aspectRatio }
        let x = visibleFrame.midX - width / 2
        let y = visibleFrame.midY - height / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func updateCameraPreview(recordingRect: CGRect?) {
        guard let rect = recordingRect else {
            previewCameraWindow?.hide(); previewCameraWindow = nil; return
        }
        if previewCameraWindow == nil { previewCameraWindow = CircularCameraWindow(cameraManager: cameraManager) }
        previewCameraWindow?.show(at: recordingState.cameraOverlayPosition, size: recordingState.cameraOverlaySize,
                                  shape: recordingState.cameraOverlayShape, recordingRect: rect,
                                  customFrame: recordingState.customCameraOverlayFrame) { [weak self] frame in
            self?.recordingState.customCameraOverlayFrame = frame
        }
    }

    private func revealRecordingInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func closePreview() { endPreview() }
}
