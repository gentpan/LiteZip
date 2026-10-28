import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var menuBar: MenuBarController?
    func applicationWillFinishLaunching(_ notification: Notification) {
        // LiteZip has one main window. Window tabs only add unused View and Window menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.preferences.applyAppearance()
        menuBar = MenuBarController(model: .shared)
        // AppKit adds Writing Tools, AutoFill and similar items when a menu opens, so tidy again then.
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didAddItemNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuChanged(_:)), name: name, object: nil)
        }
        UpdateController.shared.checkOnLaunchIfNeeded(enabled: AppModel.shared.preferences.checksForUpdates)
    }
    @objc private func menuChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, let main = NSApp.mainMenu else { return }
        var root = menu
        while let parent = root.supermenu { root = parent }
        if root === main { Self.hideExtraSeparators(in: menu) }
    }
    /// Emptied SwiftUI command groups leave their separators behind. Hide doubled,
    /// leading and trailing ones rather than removing items SwiftUI still manages.
    static func hideExtraSeparators(in menu: NSMenu) {
        var afterSeparator = true
        var trailing: NSMenuItem?
        for item in menu.items {
            if let submenu = item.submenu { hideExtraSeparators(in: submenu) }
            if item.isSeparatorItem {
                item.isHidden = afterSeparator
                if !item.isHidden { afterSeparator = true; trailing = item }
            } else if !item.isHidden {
                afterSeparator = false; trailing = nil
            }
        }
        trailing?.isHidden = true
    }
    func application(_ application: NSApplication, open urls: [URL]) { AppModel.shared.open(urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.shared.preferences.showsMenuBar && !AppModel.shared.jobs.contains { !$0.state.isFinished }
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
    @ObservedObject private var preferences = AppModel.shared.preferences
    var body: some Scene {
        WindowGroup("LiteZip", id: "main") { MainView(model: model).environmentObject(model.preferences).frame(minWidth: 480, minHeight: 600) }
            .defaultSize(width: 560, height: 730)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("检查更新…") { UpdateController.shared.check(userInitiated: true) }
                }
                CommandGroup(replacing: .newItem) {
                    Button("选择文件…", action: model.chooseFiles).keyboardShortcut("o")
                }
                // Hiding the toolbar would also hide the compress/extract switch and format menu.
                CommandGroup(replacing: .toolbar) {}
                // Find, spelling and text substitutions do not apply to LiteZip's fields.
                CommandGroup(replacing: .textEditing) {}
                CommandMenu("压缩包") {
                    ForEach(AppModel.Mode.allCases) { mode in
                        Toggle(mode.rawValue, isOn: Binding(get: { model.mode == mode }, set: { _ in model.mode = mode }))
                            .keyboardShortcut(mode == .compress ? "1" : "2")
                    }
                    Divider()
                    Button("预览内容") { model.browserURL = model.files.first }.disabled(model.files.count != 1 || model.mode != .extract)
                    Button("清除已结束的任务", action: model.clearFinished)
                    if preferences.showsMenuBar {
                        Divider()
                        Button("菜单栏快捷压缩") { delegate.menuBar?.togglePopover() }
                    }
                }
                CommandGroup(replacing: .help) {
                    Button("LiteZip 官网") { NSWorkspace.shared.open(URL(string: "https://litezip.app/")!) }
                    Button("更新记录") { NSWorkspace.shared.open(URL(string: "https://litezip.app/changelog/")!) }
                    Button("反馈问题…") { NSWorkspace.shared.open(URL(string: "https://litezip.app/feedback/")!) }
                }
            }
        Settings { SettingsView(preferences: model.preferences) }
    }
}
