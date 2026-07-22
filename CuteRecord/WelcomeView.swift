import SwiftUI

struct WelcomeView: View {
    @ObservedObject private var interfaceLanguage = InterfaceLanguageSettings.shared
    let onGetStarted: () -> Void
    @State private var appear = false

    private func t(_ english: String) -> String {
        interfaceLanguage.text(english)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 36)

            // Logo
            CuteRecordLogoView(cornerRadius: 20)
                .frame(width: 80, height: 80)
                .scaleEffect(appear ? 1 : 0.8)
                .opacity(appear ? 1 : 0)

            Spacer().frame(height: 18)

            // App name
            Text("CuteRecord")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 8)

            Spacer().frame(height: 8)

            // Tagline
            Text("专门为口播视频录制打造的提词器")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 6)

            Spacer().frame(height: 28)

            // Feature highlights
            VStack(alignment: .leading, spacing: 12) {
                welcomeFeature(icon: "doc.text", title: "撰写脚本", desc: "支持 Markdown，AI 一键断句优化节奏")
                welcomeFeature(icon: "rectangle.on.rectangle", title: "提词器跟随", desc: "灵动岛、悬浮窗、全屏三种模式随心选")
                welcomeFeature(icon: "record.circle", title: "一键录制", desc: "屏幕 + 摄像头 + 音频一次搞定")
            }
            .padding(.horizontal, 56)
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 12)

            Spacer().frame(height: 32)

            // Get Started button
            Button {
                onGetStarted()
            } label: {
                Text("开始使用")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 200, height: 44)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(appear ? 1 : 0)
            .scaleEffect(appear ? 1 : 0.9)

            Spacer().frame(height: 36)
        }
        .frame(width: 480, height: 460)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) {
                appear = true
            }
        }
    }

    private func welcomeFeature(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Returns a sample script in the current locale — a friendly intro that shows
/// off the teleprompter's features (pace cues, line breaks, bilingual text).
func sampleScript() -> String {
    let lang = InterfaceLanguageSettings.shared.language
    if lang == .simplifiedChinese {
        return """
        # 欢迎使用 CuteRecord  🐱

        你好呀！这是你的第一条口播稿。

        CuteRecord 会帮你｜把长句子拆成适合提词器阅读的短行，
        让你在录制视频时｜读起来更自然、更流畅。

        >> 试试看，点击右上角的「下一步」按钮
        >> 选择录制模式，然后开始你的第一次录制吧！

        -- 小提示：录制前可以先点「AI 断句」
        -- 让 AI 帮你优化脚本的节奏和停顿。

        祝你录制愉快！✨
        """
    } else {
        return """
        # Welcome to CuteRecord  🐱

        Hi there! This is your first script.

        CuteRecord helps you｜break long sentences into teleprompter-friendly lines,
        so you can read naturally｜while recording your video.

        >> Go ahead and click the 「Next」 button
        >> to start your first recording!

        -- Tip: try 「AI Breath Cuts」 before recording
        -- to let AI optimize your script's pacing.

        Happy recording! ✨
        """
    }
}
