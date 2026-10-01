import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { AppModel.shared.preferences.applyAppearance() }
    func application(_ application: NSApplication, open urls: [URL]) { AppModel.shared.open(urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.shared.jobs.contains { !$0.state.isFinished }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.jobs.contains(where: { !$0.state.isFinished }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "取消正在运行的任务并退出？"
        alert.informativeText = "未完成的文件会在取消后清理。"
        alert.addButton(withTitle: "取消任务并退出"); alert.addButton(withTitle: "继续处理")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        for job in AppModel.shared.jobs { AppModel.shared.cancel(job) }
        Task {
            while AppModel.shared.jobs.contains(where: { $0.state == .running }) { try? await Task.sleep(for: .milliseconds(100)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct LiteZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        WindowGroup("LiteZip") { MainView(model: model).environmentObject(model.preferences).frame(minWidth: 480, minHeight: 600) }
            .defaultSize(width: 560, height: 730)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("选择文件…", action: model.chooseFiles).keyboardShortcut("o")
                }
                CommandMenu("压缩包") {
                    Button("预览内容") { model.browserURL = model.files.first }.disabled(model.files.count != 1 || model.mode != .extract)
                    Button("清除已结束的任务", action: model.clearFinished)
                }
            }
        Settings { SettingsView(preferences: model.preferences) }
    }
}
