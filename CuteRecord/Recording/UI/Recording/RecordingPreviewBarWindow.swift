import AppKit
import AVFoundation
import SwiftUI

final class RecordingPreviewBarWindow: NSObject {
    private var barWindow: NSWindow?
    private static let windowLevel: NSWindow.Level = .screenSaver + 2

    func show(
        controller: RecordingController,
        recordingMode: Binding<ContentView.RecordingMode>,
        networkCameraIP: Binding<String>,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let visibleFrame = targetVisibleFrame(for: controller.currentRecordingInterfaceFrame)
        let width = visibleFrame.width * 0.40
        let height: CGFloat = 86
        let frame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY + 112,
            width: width,
            height: height
        )

        let window = configuredWindow(frame: frame, movableByBackground: true)

        let rootView = RecordingPreviewBarView(
            controller: controller,
            recordingMode: recordingMode,
            networkCameraIP: networkCameraIP,
            onStart: {
                onStart()
            },
            onCancel: { [weak self] in
                self?.hide()
                onCancel()
            }
        )
        .frame(width: width, height: height)

        let contentView = NSHostingView(rootView: rootView)
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func showStopButton(
        controller: RecordingController,
        onStop: @escaping () -> Void
    ) {
        if barWindow != nil {
            hide()
        }

        let visibleFrame = targetVisibleFrame(for: controller.currentRecordingInterfaceFrame)
        let width: CGFloat = 154
        let height: CGFloat = 62
        let margin: CGFloat = 24
        let frame = NSRect(
            x: visibleFrame.maxX - width - margin,
            y: visibleFrame.minY + margin,
            width: width,
            height: height
        )

        let window = configuredWindow(frame: frame, movableByBackground: false)
        let rootView = RecordingStopBarView(
            controller: controller,
            onStop: { [weak self] in
                self?.hide()
                onStop()
            }
        )
        .frame(width: width, height: height)

        let contentView = NSHostingView(rootView: rootView)
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func showRenderOptions(
        controller: RecordingController,
        onDelete: @escaping () -> Void,
        onRenderAll: @escaping () -> Void,
        onRenderCameraOnly: @escaping () -> Void
    ) {
        if barWindow != nil {
            hide()
        }

        let visibleFrame = targetVisibleFrame(for: controller.currentRecordingInterfaceFrame)
        let width: CGFloat = 372
        let height: CGFloat = 108
        let margin: CGFloat = 24
        let frame = NSRect(
            x: visibleFrame.maxX - width - margin,
            y: visibleFrame.minY + margin,
            width: width,
            height: height
        )

        let window = configuredWindow(frame: frame, movableByBackground: true)
        let rootView = RecordingRenderOptionsView(
            controller: controller,
            onDelete: { [weak self] in
                self?.hide()
                onDelete()
            },
            onRenderAll: { [weak self] in
                self?.hide()
                onRenderAll()
            },
            onRenderCameraOnly: { [weak self] in
                self?.hide()
                onRenderCameraOnly()
            }
        )
        .frame(width: width, height: height)

        let contentView = NSHostingView(rootView: rootView)
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = contentView
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func hide() {
        barWindow?.contentView = nil
        barWindow?.orderOut(nil)
        barWindow?.close()
        barWindow = nil
    }

    func bringToFront() {
        barWindow?.level = Self.windowLevel
        barWindow?.orderFrontRegardless()
    }

    private func configuredWindow(frame: NSRect, movableByBackground: Bool) -> NSWindow {
        if let existingWindow = barWindow {
            existingWindow.setFrame(frame, display: true, animate: true)
            existingWindow.level = Self.windowLevel
            existingWindow.sharingType = .none
            existingWindow.isMovableByWindowBackground = movableByBackground
            return existingWindow
        }

        let window = RecordingPreviewBarPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = Self.windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovableByWindowBackground = movableByBackground
        window.isReleasedWhenClosed = false
        // Do not let the floating controls appear in screen recordings.
        window.sharingType = .none
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.worksWhenModal = true
        barWindow = window
        return window
    }

    private func targetVisibleFrame(for targetFrame: CGRect?) -> NSRect {
        if let targetFrame,
           let screen = NSScreen.screens.max(by: { first, second in
               first.frame.intersection(targetFrame).area < second.frame.intersection(targetFrame).area
           }),
           !screen.frame.intersection(targetFrame).isNull {
            return screen.visibleFrame
        }

        return (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 960, height: 640)
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return max(0, width) * max(0, height)
    }
}

private final class RecordingPreviewBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct RecordingPreviewBarView: View {
    @ObservedObject private var controller: RecordingController
    @ObservedObject private var recordingState: RecordingState
    @ObservedObject private var audioManager: AudioManager
    @ObservedObject private var cameraManager: CameraManager
    @Binding private var recordingMode: ContentView.RecordingMode
    @Binding private var networkCameraIP: String
    @State private var countdownValue: Int = 0
    @State private var isStartHovered: Bool = false

    let onStart: () -> Void
    let onCancel: () -> Void

    init(
        controller: RecordingController,
        recordingMode: Binding<ContentView.RecordingMode>,
        networkCameraIP: Binding<String>,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.controller = controller
        self.recordingState = controller.recordingState
        self.audioManager = controller.audioManager
        self.cameraManager = controller.cameraManager
        self._recordingMode = recordingMode
        self._networkCameraIP = networkCameraIP
        self.onStart = onStart
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain).help("关闭预览")

            Menu {
                ForEach(ContentView.RecordingMode.allCases) { mode in
                    Button { recordingMode = mode } label: {
                        if recordingMode == mode { Label(mode.localizedLabel, systemImage: "checkmark") }
                        else { Text(mode.localizedLabel) }
                    }
                }
            } label: {
                Text(recordingMode.localizedLabel).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .frame(height: 34).padding(.horizontal, 10)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton).fixedSize().help("选择录制模式")

            if recordingMode == .phone {
                HStack(spacing: 4) {
                    Image(systemName: controller.networkCamera.isConnected ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                        .font(.system(size: 11)).foregroundStyle(controller.networkCamera.isConnected ? .green : .secondary)
                    TextField(controller.networkCamera.isConnected ? "已连接" : "IP", text: $networkCameraIP)
                        .font(.system(size: 11, weight: .medium, design: .monospaced)).textFieldStyle(.plain).frame(width: 105)
                        .onSubmit { controller.connectToNetworkCamera(ip: networkCameraIP) }
                    if !networkCameraIP.isEmpty && !controller.networkCamera.isConnected {
                        Button("连接") { controller.connectToNetworkCamera(ip: networkCameraIP) }
                            .font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal, 6).frame(height: 34)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }

            micMenu.help("选择麦克风设备")
            cameraMenu.help("选择摄像头设备")

            Spacer()

            Button(action: { startWithCountdown() }) {
                ZStack {
                    if countdownValue > 0 {
                        Circle().fill(Color.red).frame(width: 46, height: 46).shadow(color: .red.opacity(0.4), radius: 12)
                        Text("\(countdownValue)").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.white)
                    } else if isStartHovered || controller.isRecording {
                        Circle().fill(Color.white).frame(width: 46, height: 46).shadow(color: .white.opacity(0.2), radius: 6, y: 1)
                        catPawMarks
                    } else {
                        Circle().fill(NotchSettings.shared.accentColor.color).frame(width: 46, height: 46).shadow(color: NotchSettings.shared.accentColor.color.opacity(0.3), radius: 8)
                        Text("录制").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(controller.isStarting || controller.isRecording || controller.isStopping)
            .opacity(controller.isStarting || controller.isRecording || controller.isStopping ? 0.55 : 1)
            .onHover { isStartHovered = $0 }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .foregroundStyle(.primary)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
        .onAppear {
            if recordingMode != .phone {
                controller.refreshDevicesAndPermissions()
                controller.beginPreview()
            }
        }
        .onChange(of: recordingMode) { _, newMode in
            if newMode == .phone {
                controller.cameraManager.stopCapture(); controller.cameraManager.pushExternalFrame(nil); controller.hideCameraPreview()
            } else { controller.refreshDevicesAndPermissions(); controller.beginPreview() }
        }
        .onChange(of: cameraManager.selectedCameraID) { _, _ in controller.restartCameraPreview() }
    }

    private var micMenu: some View {
        Menu {
            if recordingMode == .phone { Text("iPhone 麦克风") }
            else {
                ForEach(audioManager.availableMicrophones) { d in
                    Button { audioManager.selectedMicrophone = d } label: {
                        if audioManager.selectedMicrophone == d { Label(d.name, systemImage: "checkmark") }
                        else { Text(d.name) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(NotchSettings.shared.accentColor.color.opacity(0.85)))
                Text(recordingMode == .phone ? "iPhone 麦克风" : audioManager.selectedMicrophone.name)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .frame(height: 34).padding(.horizontal, 10)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var cameraMenu: some View {
        Menu {
            if recordingMode == .phone {
                Button {
                    cameraManager.selectedCameraID = "iphone_front"
                    controller.networkCamera.sendCommand("f"); controller.networkCameraPosition = .front; controller.hideCameraPreview()
                } label: { Label("iPhone 前置摄像头", systemImage: cameraManager.selectedCameraID == "iphone_front" ? "checkmark" : "") }
                Button {
                    cameraManager.selectedCameraID = "iphone_back"
                    controller.networkCamera.sendCommand("b"); controller.networkCameraPosition = .back; controller.showCameraPreview()
                } label: { Label("iPhone 后置摄像头", systemImage: cameraManager.selectedCameraID == "iphone_back" ? "checkmark" : "") }
            } else if cameraManager.availableCameras.isEmpty { Text("无可用摄像头") }
            else {
                ForEach(cameraManager.availableCameras) { c in
                    Button { cameraManager.selectedCameraID = c.id } label: {
                        if cameraManager.selectedCameraID == c.id { Label(c.name, systemImage: "checkmark") }
                        else { Text(c.name) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(NotchSettings.shared.accentColor.color.opacity(0.85)))
                Text(currentCameraName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .frame(height: 34).padding(.horizontal, 10)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var currentCameraName: String {
        if recordingMode == .phone { return cameraManager.selectedCameraID == "iphone_front" ? "前置摄像头" : "后置摄像头" }
        return cameraManager.availableCameras.first(where: { $0.id == cameraManager.selectedCameraID })?.name ?? "选择摄像头"
    }

    private func startWithCountdown() {
        guard countdownValue == 0 else { return }
        recordingState.microphoneEnabled = true; recordingState.cameraOverlayEnabled = true
        countdownValue = 3
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if countdownValue > 1 { countdownValue -= 1 }
            else { t.invalidate(); countdownValue = 0; onStart() }
        }
    }

    private var catPawMarks: some View {
        let toes: [(CGFloat, CGFloat)] = [(-13, -3), (-5, -9), (5, -9), (13, -3)]
        return ZStack {
            Capsule().fill(Color(red: 0.96, green: 0.70, blue: 0.76)).frame(width: 20, height: 16).offset(y: 9)
            ForEach(Array(toes.enumerated()), id: \.0) { i, toe in
                Capsule().fill(Color(red: 0.96, green: 0.70, blue: 0.76)).frame(width: 7, height: 10)
                    .rotationEffect(.degrees(i == 0 ? -20 : i == 3 ? 20 : 0)).offset(x: toe.0, y: toe.1)
            }
        }
    }
}

private struct RecordingStopBarView: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageSettings.shared
    @ObservedObject private var controller: RecordingController
    @ObservedObject private var recordingState: RecordingState
    let onStop: () -> Void

    init(
        controller: RecordingController,
        onStop: @escaping () -> Void
    ) {
        self.controller = controller
        self.recordingState = controller.recordingState
        self.onStop = onStop
    }

    private func t(_ english: String) -> String {
        interfaceLanguage.text(english)
    }

    var body: some View {
        HStack(spacing: 0) {
            StopWindowDragHandle()
                .frame(width: 18, height: 46)
                .padding(.leading, 7)
                .padding(.trailing, 3)

            Button(action: onStop) {
                ZStack {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.red)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                    if controller.isStopping {
                        Circle()
                            .fill(Color.black.opacity(0.24))
                            .frame(width: 44, height: 44)
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                }
                .frame(width: 48, height: 46)
            }
            .buttonStyle(.plain)
            .disabled(controller.isStopping)
            .opacity(controller.isStopping ? 0.75 : 1)
            .help(t("Stop recording"))
            .accessibilityLabel(t("Stop recording"))

            Text(timeString(from: recordingState.recordingDuration))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.74))
                .lineLimit(1)
                .frame(width: 50, alignment: .leading)
                .padding(.leading, 6)
                .padding(.trailing, 6)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
    }

    private func timeString(from duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct RecordingRenderOptionsView: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageSettings.shared
    @ObservedObject private var controller: RecordingController
    let onDelete: () -> Void
    let onRenderAll: () -> Void
    let onRenderCameraOnly: () -> Void

    init(
        controller: RecordingController,
        onDelete: @escaping () -> Void,
        onRenderAll: @escaping () -> Void,
        onRenderCameraOnly: @escaping () -> Void
    ) {
        self.controller = controller
        self.onDelete = onDelete
        self.onRenderAll = onRenderAll
        self.onRenderCameraOnly = onRenderCameraOnly
    }

    private func t(_ english: String) -> String {
        interfaceLanguage.text(english)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Choose Output"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.86))

            HStack(spacing: 8) {
                Button(role: .destructive, action: onDelete) {
                    Label(t("Delete"), systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .help(t("Delete this recording"))
                .accessibilityLabel(t("Delete recording"))

                Button(action: onRenderCameraOnly) {
                    VStack(spacing: 1) {
                        Label(t("Camera Only"), systemImage: "person.crop.rectangle")
                            .lineLimit(1)
                        Text(t("Transparent"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!controller.canRenderPendingCameraOnly || controller.isExporting)
                .help(t("Render camera only with transparent background"))
                .accessibilityLabel(t("Render camera only with transparent background"))

                Button(action: onRenderAll) {
                    Label(t("Render All"), systemImage: "film.stack")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isExporting)
                .help(t("Render full recording"))
                .accessibilityLabel(t("Render full recording"))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
    }
}

private struct StopWindowDragHandle: View {
    var body: some View {
        WindowDragHandleRepresentable()
            .overlay {
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(Color.primary.opacity(0.34))
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .contentShape(Rectangle())
            .help(uiText("Drag"))
    }
}

private struct WindowDragHandleRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        StopWindowDragHandleView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class StopWindowDragHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
