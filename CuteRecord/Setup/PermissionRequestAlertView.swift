//
//  PermissionRequestAlertView.swift
//  CuteRecord
//

import SwiftUI
import AVFoundation
import AppKit

// MARK: - 权限请求浮窗

class PermissionRequestWindow: NSObject {
    private let cutePanel = CutePanel()

    func show(
        permissionsManager: PermissionsManager,
        onRequestFileAccess: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        cutePanel.show(
            PermissionRequestAlertView(
                permissionsManager: permissionsManager,
                onRequestFileAccess: onRequestFileAccess,
                onComplete: { [weak self] in
                    self?.cutePanel.dismiss { onComplete() }
                },
                onCancel: { [weak self] in
                    self?.cutePanel.dismiss { onCancel() }
                }
            )
            .cutePanelStyle(),
            width: 360, height: 310,
            movable: true
        )
    }

    func dismiss() {
        cutePanel.dismiss()
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
            Text("获得权限以进行视频录制")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.top, 24)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("需要以下权限：")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                PermissionRow(icon: "folder", text: "文件保存：将录制文件保存在本地")
                PermissionRow(icon: "mic.fill", text: "麦克风：录制声音")
                PermissionRow(icon: "camera.fill", text: "摄像头：录制画面")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)

            if isRequesting {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("正在请求「\(currentRequestingPermission)」权限…")
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
                    Text("取消")
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
                    Text("继续")
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
        .frame(width: 360)
        .onAppear {
            // Auto-dismiss if camera + mic already granted (file access is a folder picker, not a system permission)
            if permissionsManager.cameraAuthorized && permissionsManager.microphoneAuthorized {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onComplete() }
            }
        }
    }

    private func requestAllPermissions() {
        isRequesting = true

        Task {
            currentRequestingPermission = "文件保存"
            await MainActor.run { onRequestFileAccess() }
            try? await Task.sleep(nanoseconds: 500_000_000)

            currentRequestingPermission = "麦克风"
            await permissionsManager.requestMicrophonePermission()

            currentRequestingPermission = "摄像头"
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
