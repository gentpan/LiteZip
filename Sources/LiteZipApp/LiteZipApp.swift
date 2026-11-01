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
        AppModel.shared.preferences.applyDockIcon()
        menuBar = MenuBarController(model: .shared)
        // AppKit adds Writing Tools, AutoFill and similar items when a menu opens, so tidy again then.
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didAddItemNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuChanged(_:)), name: name, object: nil)
        }
        // Menu-bar-first launch: hide and close the primary window the instant SwiftUI
        // creates it, before a frame is composited, so launch shows no window flash.
        if AppModel.shared.preferences.showsMenuBar { suppressLaunchWindow() }
        UpdateController.shared.checkOnLaunchIfNeeded(enabled: AppModel.shared.preferences.checksForUpdates)
    }
    private func suppressLaunchWindow() {
        Task { @MainActor in
            for _ in 0..<1000 {
                // A window that already holds files (opened with LiteZip at launch) stays.
                if !AppModel.shared.files.isEmpty || AppModel.shared.browserURL != nil { return }
                if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                    // Zero opacity kills the launch flash; restore it once the window is
                    // off-screen so the same instance SwiftUI reuses for an on-demand
                    // openWindow is opaque again instead of permanently transparent.
                    window.alphaValue = 0
                    window.orderOut(nil)
                    window.alphaValue = 1
                    window.close()
                    return
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
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
        // ⌘Q closes the windows but keeps the menu bar entry resident; quitting
        // for real stays available from the menu bar popover and the app menu.
        if AppModel.shared.preferences.showsMenuBar,
           let event = NSApp.currentEvent, event.type == .keyDown, event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            for window in NSApp.windows { window.close() }
            return .terminateCancel
        }
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
        // SwiftUI opens this Window at launch even in menu-bar mode, so suppressLaunchWindow
        // hides that first instance; Finder actions and the menu bar reopen it on demand.
        Window("LiteZip", id: "main") { MainView(model: model).environmentObject(model.preferences) }
            .defaultSize(width: 560, height: 460)
            // Links and opened files go to the app delegate only. Otherwise SwiftUI builds this
            // window to receive every litezip:// action (Finder extract, compress, settings);
            // AppModel opens it explicitly where a window is wanted.
            .handlesExternalEvents(matching: [])
            .commands {
                // LiteZip manages its own settings window; see SettingsWindowController.
                CommandGroup(replacing: .appSettings) {
                    Button("设置…") { SettingsWindowController.shared.show() }.keyboardShortcut(",")
                }
                CommandGroup(after: .appInfo) {
                    Button("检查更新…") { UpdateController.shared.check(userInitiated: true) }
                }
                CommandGroup(replacing: .newItem) {
                    Button("选择文件…", action: model.chooseFiles).keyboardShortcut("o")
                }
                // Hiding the toolbar would also hide the format menu.
                CommandGroup(replacing: .toolbar) {}
                // Find, spelling and text substitutions do not apply to LiteZip's fields.
                CommandGroup(replacing: .textEditing) {}
                CommandMenu("压缩包") {
                    Toggle("选项面板", isOn: $preferences.showsInspector).keyboardShortcut("3")
                    Divider()
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
    }
}
