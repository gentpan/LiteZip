import Cocoa
import FinderSync
import Darwin
import OSLog

final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir), isDirectory: true) } ?? FileManager.default.homeDirectoryForCurrentUser
        FIFinderSyncController.default().directoryURLs = [home, URL(fileURLWithPath: "/Volumes", isDirectory: true)]
        Logger(subsystem: "app.litezip.LiteZip", category: "Finder").info("Finder extension initialized")
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return nil }
        let menu = NSMenu(title: "LiteZip")
        add("使用 LiteZip 快速压缩", action: #selector(compress), to: menu)
        add("压缩设置…", action: #selector(configure), to: menu)
        if urls.allSatisfy({ ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst"].contains($0.pathExtension.lowercased()) }) {
            menu.addItem(.separator())
            add("解压到独立文件夹", action: #selector(extract), to: menu)
        }
        return menu
    }
    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }
    @objc private func compress() { send("compress") }
    @objc private func configure() { send("configure") }
    @objc private func extract() { send("extract") }
    private func send(_ action: String) {
        guard let files = FIFinderSyncController.default().selectedItemURLs(), !files.isEmpty else { return }
        var url = URLComponents()
        url.scheme = "litezip"; url.host = action
        url.queryItems = files.map { URLQueryItem(name: "file", value: $0.path) }
        guard let target = url.url else { return }
        NSWorkspace.shared.open(target)
    }
}
