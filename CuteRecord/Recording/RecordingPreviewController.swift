import SwiftUI
import AVKit
import Combine

@MainActor
class RecordingPreviewController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var isShowing = false
    @Published var videoURL: URL?
    
    private var window: NSWindow?
    private var player: AVPlayer?
    private var playerView: AVPlayerView?
    var onClose: (() -> Void)?
    
    func show(videoURL: URL) {
        self.videoURL = videoURL
        
        let player = AVPlayer(url: videoURL)
        self.player = player
        
        if window == nil {
            createWindow()
        }
        
        playerView?.player = player
        window?.makeKeyAndOrderFront(nil)
        isShowing = true
        // 不自动播放，停在第一帧，用户手动点击播放
        player.seek(to: .zero)
        player.pause()
    }
    
    func hide() {
        window?.orderOut(nil)
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerView?.player = nil
        videoURL = nil
        isShowing = false
    }
    
    func windowWillClose(_ notification: Notification) {
        hide()
        onClose?()
    }
    
    private func createWindow() {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        self.playerView = playerView
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "录制预览"
        window.center()
        window.contentView = playerView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        
        self.window = window
    }
}

