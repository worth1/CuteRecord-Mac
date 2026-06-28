//
//  CuteRecordApp.swift
//  CuteRecord
//
//

import SwiftUI

private let supportedCuteRecordFileExtensions: Set<String> = ["md", "cuterecord", "takeone", "cueshot"]

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let openAbout = Notification.Name("openAbout")
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        let launchedByURL: Bool
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchedByURL = event.eventClass == kInternetEventClass
        } else {
            launchedByURL = false
        }
        if launchedByURL {
            CuteRecordService.shared.launchedExternally = true
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSApp.servicesProvider = CuteRecordService.shared  // 注释掉：触发 macOS 扫描 ~/Documents
        // NSUpdateDynamicServices()  // 注释掉：首次调用可能触发 macOS 扫描 ~/Documents

        if CuteRecordService.shared.launchedExternally {
            CuteRecordService.shared.hideMainWindow()
        }

        // Silent update check on launch
        UpdateChecker.shared.checkForUpdates(silent: true)

        // Start browser server if enabled
        CuteRecordService.shared.updateBrowserServer()

        // Start director server if enabled
        CuteRecordService.shared.updateDirectorServer()

        // Set window delegate to intercept close, disable tabs and fullscreen
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.delegate = self
                window.tabbingMode = .disallowed
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.collectionBehavior.insert(.fullScreenNone)
            }
            self.removeUnwantedMenus()
        }
    }

    private func removeUnwantedMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Remove View and Window menus (keep Edit for copy/paste)
        let menusToRemove = ["View", "Window"]
        for title in menusToRemove {
            if let index = mainMenu.items.firstIndex(where: { $0.title == title }) {
                mainMenu.removeItem(at: index)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        CuteRecordService.shared.saveFile()
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if CuteRecordService.shared.launchedExternally {
            CuteRecordService.shared.launchedExternally = false
            NSApp.setActivationPolicy(.regular)
        }
        if !flag {
            // Show existing window instead of letting SwiftUI create a duplicate
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.hasDirectoryPath || supportedCuteRecordFileExtensions.contains(url.pathExtension.lowercased()) {
                CuteRecordService.shared.openFileAtURL(url)
                // Show the main window for file opens
                for window in NSApp.windows where !(window is NSPanel) {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            } else {
                let wasExternal = CuteRecordService.shared.launchedExternally
                CuteRecordService.shared.launchedExternally = true
                if !wasExternal {
                    NSApp.setActivationPolicy(.accessory)
                }
                CuteRecordService.shared.hideMainWindow()
                CuteRecordService.shared.handleURL(url)
            }
        }
    }
}

@main
struct CuteRecordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var interfaceLanguage = InterfaceLanguageSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    if url.hasDirectoryPath || supportedCuteRecordFileExtensions.contains(url.pathExtension.lowercased()) {
                        CuteRecordService.shared.openFileAtURL(url)
                    } else {
                        CuteRecordService.shared.handleURL(url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 740, height: 430)
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(interfaceLanguage.text("About CuteRecord")) {
                    NotificationCenter.default.post(name: .openAbout, object: nil)
                }
                Divider()
                Button(interfaceLanguage.text("Check for Updates…")) {
                    UpdateChecker.shared.checkForUpdates()
                }
            }
            CommandGroup(after: .appSettings) {
                Button(interfaceLanguage.text("Settings…")) {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button(interfaceLanguage.text("Open Folder…")) {
                    CuteRecordService.shared.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) { }
            CommandGroup(replacing: .windowArrangement) { }
            CommandGroup(replacing: .help) {
                Button(interfaceLanguage.text("CuteRecord Help")) {
                    if let url = URL(string: "https://github.com/worth01/CuteRecord") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
