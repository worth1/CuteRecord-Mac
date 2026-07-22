//
//  CutePanel.swift
//  CuteRecord
//
//  Unified iOS-cute-style NSPanel wrapper for all dialogs.
//  Shared by permission requests, welcome, update checker, and more.
//

import AppKit
import SwiftUI

/// A reusable NSPanel with the unified iOS cute style:
/// - .ultraThinMaterial background via SwiftUI
/// - 22pt continuous corner radius
/// - Soft shadow
/// - Subtle border
/// - Fade-in/out animation
class CutePanel: NSObject {
    private var panel: NSPanel?

    /// Present a SwiftUI view inside a cute-style floating panel.
    /// - Parameters:
    ///   - view: The SwiftUI content view
    ///   - width: Panel width
    ///   - height: Panel height
    ///   - level: Window level (default: .floating)
    ///   - movable: Whether the panel can be dragged by its background
    func show<Content: View>(
        _ view: Content,
        width: CGFloat,
        height: CGFloat,
        level: NSWindow.Level = .floating,
        movable: Bool = false
    ) {
        dismiss()

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Match the RecordingPreviewBar style
        hostingView.layer?.cornerRadius = 22
        hostingView.layer?.masksToBounds = true

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = movable
        panel.contentView = hostingView
        panel.center()
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        self.panel = panel
    }

    func dismiss(completion: (() -> Void)? = nil) {
        guard let panel = panel else {
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.close()
            completion?()
        })
        self.panel = nil
    }
}

// MARK: - SwiftUI Cute Panel Modifier

/// SwiftUI view modifier that applies the unified cute style background.
/// Use this directly in SwiftUI views displayed inside a CutePanel.
struct CutePanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 24, x: 0, y: 6)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }
}

extension View {
    func cutePanelStyle() -> some View {
        modifier(CutePanelStyle())
    }
}
