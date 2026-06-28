<p align="center">
  <img src="CuteRecord/Assets.xcassets/CuteRecordLogo.imageset/logo.png" alt="CuteRecord Logo" width="128">
</p>

<h1 align="center">🐱 CuteRecord</h1>

<p align="center">
  <strong>The recording workspace for scripted screen videos — teleprompter meets screen recorder.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/language-Swift-orange" alt="Language">
  <img src="https://img.shields.io/badge/license-Apache%202.0-green" alt="License">
</p>

---

## ✨ What is CuteRecord?

CuteRecord is a **macOS recording studio** that combines a professional teleprompter with full screen/audio/camera recording. Write your script, polish it with AI, then read it from a beautiful teleprompter while CuteRecord captures everything — your screen, your voice, your face.

Unlike using a separate prompter app + OBS + camera tools, CuteRecord is **one unified workspace** where every piece talks to every other piece.

---

## 🎯 Why CuteRecord?

| Problem | CuteRecord's Solution |
|---|---|
| Reading a script while recording is awkward | **Notch-integrated teleprompter** that lives right below your camera |
| Speech recognition loses your place | **Real-time word tracking** highlights each word as you say it |
| Scripts feel robotic | **AI Breath Cuts** — AI adds natural pacing markers to your script |
| Need a prompter on another device | **Browser Server** — any phone/tablet becomes a prompter over WiFi |
| Someone else needs to feed you lines | **Director Mode** — remote script control from a browser in real time |

---

## 🚀 Features

### 📝 Script Editor
- Full Markdown editor with syntax highlighting
- **Drag & drop PPTX** — automatically extracts presenter notes into script pages
- Page-based document organization for multi-scene recordings
- Dictation mode — speak your script instead of typing

### 🎭 Multi-Mode Teleprompter

| Mode | Description |
|---|---|
| **Notch** | Dynamic Island-style overlay expanding from the MacBook notch |
| **Floating** | Draggable, always-on-top window with glass blur effect |
| **Fullscreen** | Dedicated prompter display for external monitors |
| **Follow Cursor** | Compact panel that tracks your mouse |
| **Browser** | Open a URL on any device — no app install needed |

### 🗣️ Smart Speech Tracking
- **Word Tracking** — highlights each word in real time as you speak (uses on-device ASR)
- **Classic** — smooth auto-scroll at configurable words-per-second
- **Voice-Activated** — pauses the prompter when you're silent, scrolls when you speak
- **Bilingual ASR** — built-in SherpaOnnx Paraformer model for Chinese-English speech recognition, all on-device, no internet required

### 🎬 Professional Recording
- Screen capture — full screen, selected area, or specific window
- System audio + microphone capture
- **Circular camera overlay** — draggable, resizable picture-in-picture
- Recording preview with countdown
- Post-recording editor with export configuration

### 🤖 AI Script Enhancement
- Send your script to an AI to add natural breath breaks and pacing cues
- **30+ AI providers** supported (302.AI, DeepSeek, OpenAI-compatible, and more)
- Custom API endpoint support
- API keys stored securely in Keychain
- Two output modes: **Marked** (with `>>` and `--` pace cues) or **Clean** (newlines only)

### 🎬 Director Mode
- Two-way remote control system over WebSocket
- A director/producer edits your script from their browser in **real time**
- Authenticated with a secure random token
- See the speaker's progress live

### 🎨 Customization
- 4 font families (Sans, Serif, Mono, **Dyslexia-friendly OpenDyslexic**)
- 4 font sizes + 6 color presets
- Pace cue colors (`>>` fast blue, `--` slow amber)
- Audience face backdrop (cat eyes or custom image) for eye-contact simulation
- Mirror axis support for hardware prompter rigs
- Hide from screen share — keep your prompter private

### 🌐 Bilingual
- Full UI in **English** and **Simplified Chinese**
- ASR model is bilingual (Chinese-English)

---

## 🛠 Tech Stack

| Layer | Technology |
|---|---|
| UI | SwiftUI + AppKit interop |
| Speech Recognition | Apple SFSpeechRecognizer + SherpaOnnx (local bilingual ASR) |
| Recording | CGDisplayStream, AVAudioEngine, AVCaptureSession |
| Networking | Network.framework (TCP + WebSocket) |
| AI Integration | OpenAI-compatible API with multi-provider catalog |
| Storage | File-based vault with FSEvent monitoring |
| Concurrency | Swift async/await, Combine |

---

## 📦 Installation

### Requirements
- **macOS 13 (Ventura)** or later
- Xcode 15+ to build from source

### Build from Source
```bash
git clone https://github.com/worth01/CuteRecord.git
cd CuteRecord
open CuteRecord.xcodeproj
```

> **Note:** The SherpaOnnx model files and dylibs in `Vendor/` are placeholders. You may need to download the actual binaries from the [SherpaOnnx](https://github.com/k2-fsa/sherpa-onnx) project for full ASR functionality.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘B` | Toggle sidebar |
| `⌘⌥N` | New page |
| `⌘⌥S` | Start/stop recording |
| `⌘⌥P` | Open teleprompter |
| `⌘⌥D` | Start dictation |

---

## 📁 Project Structure

```text
CuteRecord/                         App source
├── AI/                             AI script composer & provider catalog
├── Recording/                      Screen/audio/camera recording pipeline
│   ├── Core/                       Audio, camera, permissions, recording engine
│   ├── Models/                     State, edit decisions, takes
│   └── UI/                         Camera overlay, recording indicator, editor
├── Setup/                          Permission request flow
├── Storage/                        Vault project persistence & repair
├── Teleprompter/                   Cue tokenizer & speech tracking matcher
└── Fonts/                          Bundled OpenDyslexic typeface
Tests/RecordingCoreTests/           Recording core tests
Vendor/                             SherpaOnnx xcframework, dylibs & ASR models
```

---

## 📄 License

CuteRecord is released under the [Apache License 2.0](LICENSE).

---

## 👨‍💻 Author

**worth01**

---

## 🙏 Acknowledgements

CuteRecord evolved from [CueRecord](https://github.com/nolanlai/cuterecord) by **Nolan Lai**. Thank you for the incredible foundation.

---

<p align="center">
  <sub>Made with ❤️ for creators, presenters, and tutorial makers.</sub>
</p>
