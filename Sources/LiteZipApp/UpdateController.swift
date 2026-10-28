import AppKit
import LiteZipCore

/// Compares the running version with LiteZip's GitHub releases and links to the download page.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()
    @Published private(set) var checking = false
    @Published private(set) var lastChecked = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Automatic checks run at most once a day and stay silent unless a new version exists.
    func checkOnLaunchIfNeeded(enabled: Bool) {
        guard enabled else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 24 * 60 * 60 { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            let releases: [UpdateCheck.Release]
            do { releases = try await UpdateCheck.fetchReleases() } catch {
                if userInitiated { inform("无法检查更新", "暂时无法连接 GitHub，请检查网络后重试。") }
                return
            }
            let now = Date()
            lastChecked = now
            UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
            guard let release = UpdateCheck.newestRelease(in: releases, newerThan: currentVersion) else {
                if userInitiated { inform("LiteZip 已是最新版本", "当前版本 \(currentVersion)。") }
                return
            }
            if !userInitiated && UserDefaults.standard.string(forKey: "skippedUpdateVersion") == release.version { return }
            offer(release, userInitiated: userInitiated)
        }
    }

    private func offer(_ release: UpdateCheck.Release, userInitiated: Bool) {
        let alert = NSAlert()
        alert.messageText = "LiteZip \(release.version) 已发布"
        alert.informativeText = "当前版本 \(currentVersion)。" + (release.notesSummary.map { "\n\n" + $0 } ?? "")
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")
        if !userInitiated { alert.addButton(withTitle: "跳过此版本") }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(release.htmlURL)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.version, forKey: "skippedUpdateVersion")
        default: break
        }
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
