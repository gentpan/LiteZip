import AppKit
import SwiftUI

/// LiteZip's own settings window with toolbar tabs. macOS no longer opens a SwiftUI
/// Settings scene from a menu bar popover (it asks for SettingsLink instead), so the
/// popover's gear and the app menu's ⌘, both show this window.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    /// Page identifiers for litezip://settings?tab=…, in tab order.
    private static let pages = ["general", "compress", "extract", "associations", "about"]

    func show(tab: String? = nil) {
        let window = window ?? makeWindow()
        self.window = window
        if let tab, let index = Self.pages.firstIndex(of: tab) { tabs?.selectedTabViewItemIndex = index }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let preferences = AppModel.shared.preferences
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func add<Page: View>(_ title: String, _ symbol: String, _ page: Page) {
            let host = NSHostingController(rootView: page)
            host.sizingOptions = [.preferredContentSize]
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("通用", "gearshape", GeneralSettings(preferences: preferences))
        add("压缩", "doc.zipper", CompressionSettings(preferences: preferences))
        add("解压", "folder", ExtractionSettings(preferences: preferences))
        add("格式关联", "link", AssociationSettings())
        add("关于", "info.circle", AboutSettings(preferences: preferences))
        self.tabs = tabs
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
