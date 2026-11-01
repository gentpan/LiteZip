import AppKit
import UserNotifications

/// Quick compress and Finder actions run while the user works in another app.
/// Their outcome is reported as a system notification instead of popping windows
/// or pulling Finder to the front.
@MainActor
final class JobNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = JobNotifier()
    private var requestedAuthorization = false
    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reveal = UNNotificationAction(identifier: "reveal", title: "在 Finder 中显示", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "job", actions: [reveal], intentIdentifiers: [])])
    }
    /// Asked for once, when the first background job starts; never at launch.
    func prepare() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    func report(_ job: ArchiveJob) {
        guard job.state == .completed || job.state == .failed else { return }
        // Jobs started in the main window already show their result there.
        guard !job.revealsResult || !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "job"
        if job.state == .completed {
            content.title = job.extracting ? "解压完成" : "压缩完成"
            content.subtitle = job.result?.lastPathComponent ?? job.title
            content.body = job.result?.deletingLastPathComponent().path ?? ""
            if let path = job.result?.path { content.userInfo["result"] = path }
        } else {
            content.title = job.extracting ? "解压失败" : "压缩失败"
            content.subtitle = job.title
            content.body = job.error ?? ""
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == "reveal",
              let path = response.notification.request.content.userInfo["result"] as? String, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { NSApp.isActive ? [] : [.banner, .sound] }
    }
}
