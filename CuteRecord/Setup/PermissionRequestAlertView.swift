//
//  PermissionRequestAlertView.swift
//  CuteRecord
//

import SwiftUI
import AVFoundation
import AppKit

// MARK: - 权限请求浮窗

class PermissionRequestWindow: NSObject {
    private var panel: NSPanel?
    private var hostingView: NSView?

    func show(
        permissionsManager: PermissionsManager,
        onRequestFileAccess: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()

        let alertView = PermissionRequestAlertView(
            permissionsManager: permissionsManager,
            onRequestFileAccess: onRequestFileAccess,
            onComplete: { [weak self] in
                self?.dismiss()
                onComplete()
            },
            onCancel: { [weak self] in
                self?.dismiss()
                onCancel()
            }
        )

        let hostingView = NSHostingView(rootView: alertView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        self.hostingView = hostingView

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        panel.center()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        self.panel = panel
    }

    func dismiss() {
        guard let panel = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.close()
        })
        self.panel = nil
        hostingView = nil
    }
}

struct PermissionRequestAlertView: View {
    @ObservedObject var permissionsManager: PermissionsManager
    let onRequestFileAccess: () -> Void
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var isRequesting = false
    @State private var currentRequestingPermission: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Text(uiText("Permission Required for Recording"))
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.top, 24)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 8) {
                Text(uiText("The following permissions are needed for video recording:"))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                PermissionRow(icon: "rectangle.on.rectangle", text: uiText("Screen Recording: Capture screen content"))
                PermissionRow(icon: "mic.fill", text: uiText("Microphone: Record audio"))
                PermissionRow(icon: "camera.fill", text: uiText("Camera: Record video"))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 20)

            if isRequesting {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(InterfaceLanguageSettings.shared.format(
                        uiText("Requesting %@ permission…"), currentRequestingPermission))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 12)
            }

            Divider()

            HStack(spacing: 0) {
                Button {
                    onCancel()
                } label: {
                    Text(uiText("Cancel"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .disabled(isRequesting)
                .keyboardShortcut(.cancelAction)

                Divider()

                Button {
                    requestAllPermissions()
                } label: {
                    Text(uiText("Continue"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .disabled(isRequesting)
                .keyboardShortcut(.defaultAction)
            }
            .frame(height: 44)
        }
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 20, x: 0, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func requestAllPermissions() {
        isRequesting = true

        Task {
            currentRequestingPermission = uiText("File Access")
            await MainActor.run {
                onRequestFileAccess()
            }
            try? await Task.sleep(nanoseconds: 500_000_000)

            currentRequestingPermission = uiText("Microphone")
            await permissionsManager.requestMicrophonePermission()

            currentRequestingPermission = uiText("Camera")
            await permissionsManager.requestCameraPermission()

            isRequesting = false
            onComplete()
        }
    }
}

// MARK: - Permission Row

private struct PermissionRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundColor(.secondary)
            Text(text)
                .font(.callout)
                .foregroundColor(.primary)
        }
    }
}