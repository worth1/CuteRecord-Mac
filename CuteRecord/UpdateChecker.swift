//
//  UpdateChecker.swift
//  CuteRecord
//
//

import AppKit
import SwiftUI

class UpdateChecker {
    static let shared = UpdateChecker()
    private let cutePanel = CutePanel()

    private let repoOwner = "worth01"
    private let repoName = "CuteRecord"

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func uiText(_ english: String) -> String {
        InterfaceLanguageSettings.shared.text(english)
    }

    /// Check GitHub for the latest release and prompt the user if an update is available.
    func checkForUpdates(silent: Bool = false) {
        checkReleasesPage(silent: silent, retryWithAPIIfNeeded: true)
    }

    private func checkReleasesPage(silent: Bool, retryWithAPIIfNeeded: Bool) {
        let webURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!
        var request = URLRequest(url: webURL)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            DispatchQueue.main.async {
                // Extract tag from redirect: /releases/tag/vX.Y.Z
                if let httpResponse = response as? HTTPURLResponse,
                   let location = httpResponse.allHeaderFields["Location"] as? String ?? httpResponse.allHeaderFields["location"] as? String,
                   let tagComponent = location.split(separator: "/").last {
                    let tag = String(tagComponent)
                    let latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                    let releaseURL = "https://github.com/\(self.repoOwner)/\(self.repoName)/releases/tag/\(tag)"

                    if self.isVersion(latestVersion, newerThan: self.currentVersion) {
                        self.showUpdateAvailable(latestVersion: latestVersion, releaseURL: releaseURL)
                    } else if !silent {
                        self.showUpToDate()
                    }
                    return
                }

                // Fallback: try GitHub API
                if retryWithAPIIfNeeded {
                    self.checkGitHubAPI(silent: silent)
                } else if !silent {
                    self.showUpToDate()
                }
            }
        }.resume()
    }

    private func checkGitHubAPI(silent: Bool) {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            if !silent { showUpToDate() }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            DispatchQueue.main.async {
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    if !silent {
                        self.showUpToDate()
                    }
                    return
                }

                let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                let htmlURL = json["html_url"] as? String ?? "https://github.com/\(self.repoOwner)/\(self.repoName)/releases"

                if self.isVersion(latestVersion, newerThan: self.currentVersion) {
                    self.showUpdateAvailable(latestVersion: latestVersion, releaseURL: htmlURL)
                } else if !silent {
                    self.showUpToDate()
                }
            }
        }.resume()
    }

    // MARK: - Version comparison

    private func isVersion(_ remote: String, newerThan local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - Alerts

    private func showUpdateAvailable(latestVersion: String, releaseURL: String) {
        cutePanel.show(
            UpdateAlertView(
                title: uiText("Update Available"),
                message: InterfaceLanguageSettings.shared.format("CuteRecord %@ is available. You are currently running %@.", latestVersion, currentVersion),
                primaryButton: uiText("Download"),
                secondaryButton: uiText("Later"),
                onPrimary: {
                    self.cutePanel.dismiss()
                    if let url = URL(string: releaseURL) { NSWorkspace.shared.open(url) }
                },
                onSecondary: { self.cutePanel.dismiss() }
            )
            .cutePanelStyle(),
            width: 380, height: 180
        )
    }

    private func showUpToDate() {
        cutePanel.show(
            UpdateAlertView(
                title: uiText("You're Up to Date"),
                message: InterfaceLanguageSettings.shared.format("CuteRecord %@ is the latest version.", currentVersion),
                primaryButton: uiText("OK"),
                secondaryButton: nil,
                onPrimary: { self.cutePanel.dismiss() },
                onSecondary: {}
            )
            .cutePanelStyle(),
            width: 380, height: 180
        )
    }

    private func showError(_ message: String) {
        cutePanel.show(
            UpdateAlertView(
                title: uiText("Update Check Failed"),
                message: message,
                primaryButton: uiText("OK"),
                secondaryButton: nil,
                onPrimary: { self.cutePanel.dismiss() },
                onSecondary: {}
            )
            .cutePanelStyle(),
            width: 380, height: 180
        )
    }
}

// MARK: - Update Alert View

private struct UpdateAlertView: View {
    let title: String
    let message: String
    let primaryButton: String
    let secondaryButton: String?
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.top, 24)
                .padding(.bottom, 8)

            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)

            Divider()

            HStack(spacing: 0) {
                if let secondary = secondaryButton {
                    Button(action: onSecondary) {
                        Text(secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)

                    Divider()
                }

                Button(action: onPrimary) {
                    Text(primaryButton)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .frame(height: 44)
        }
    }
}
