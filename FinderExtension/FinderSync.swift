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
        if urls.allSatisfy({ isArchive($0) }) {
            menu.addItem(.separator())
            add(urls.allSatisfy { $0.pathExtension.lowercased() == "dmg" } ? "在 Finder 打开磁盘映像" : "解压到独立文件夹", action: #selector(extract), to: menu)
        }
        return menu
    }
    private func isArchive(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return false }
        let ext = url.pathExtension.lowercased()
        if ["zip", "zipx", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst", "zstd", "tbz", "tbz2", "txz", "tzst", "dmg"].contains(ext) { return true }
        if ext.count >= 3, let letter = ext.first, let ascii = letter.asciiValue,
           (114...122).contains(ascii), ext.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }),
           let index = Int(ext.dropFirst()), (letter == "z" ? index > 0 : ext.count == 3) { return true }
        let number = url.pathExtension
        return number.count >= 3 && number.allSatisfy({ $0.isASCII && $0.isNumber }) && (Int(number) ?? 0) > 0 && ["zip", "7z"].contains(url.deletingPathExtension().pathExtension.lowercased())
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
