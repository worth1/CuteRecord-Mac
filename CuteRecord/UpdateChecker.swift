//
//  UpdateChecker.swift
//  CuteRecord
//
//

import AppKit

class UpdateChecker {
    static let shared = UpdateChecker()

    private let repoOwner = "worth01"
    private let repoName = "CuteRecord"

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
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
        let alert = NSAlert()
        alert.messageText = uiText("Update Available")
        alert.informativeText = InterfaceLanguageSettings.shared.format("CuteRecord %@ is available. You are currently running %@.", latestVersion, currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: uiText("Download"))
        alert.addButton(withTitle: uiText("Later"))

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: releaseURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = uiText("You're Up to Date")
        alert.informativeText = InterfaceLanguageSettings.shared.format("CuteRecord %@ is the latest version.", currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: uiText("OK"))
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = uiText("Update Check Failed")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: uiText("OK"))
        alert.runModal()
    }
}
