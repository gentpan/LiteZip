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
    /// Common formats, in menu order. Raw values match LiteZipCore's ArchiveFormat.
    private static let formats: [(title: String, id: String)] = [("ZIP", "zip"), ("7Z", "sevenZip"), ("TAR.GZ", "tarGzip"), ("RAR", "rar")]

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return nil }
        let menu = NSMenu(title: "LiteZip")
        if urls.allSatisfy({ isArchive($0) }) {
            let imagesOnly = urls.allSatisfy { $0.pathExtension.lowercased() == "dmg" }
            add(imagesOnly ? "在 Finder 打开磁盘映像" : "解压到独立文件夹", action: #selector(extract), to: menu)
            if !imagesOnly { add("解压到…", action: #selector(extractTo), to: menu) }
            // Archives can still be packed again, one level down to keep the menu short.
            let compress = NSMenuItem(title: "压缩为", action: nil, keyEquivalent: "")
            compress.submenu = NSMenu(title: "压缩为")
            addCompressionItems(to: compress.submenu!, prefix: "")
            menu.addItem(compress)
        } else {
            addCompressionItems(to: menu, prefix: "压缩为 ")
        }
        menu.addItem(.separator())
        add("在 LiteZip 中打开…", action: #selector(openInApp), to: menu)
        return menu
    }
    private func addCompressionItems(to menu: NSMenu, prefix: String) {
        for (index, format) in Self.formats.enumerated() {
            let item = NSMenuItem(title: prefix + format.title, action: #selector(compress(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            menu.addItem(item)
        }
    }
    private func isArchive(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return false }
        let ext = url.pathExtension.lowercased()
        if ["zip", "zipx", "7z", "rar", "tar", "gz", "gzip", "tgz", "bz2", "bzip2", "xz", "zst", "zstd", "tbz", "tbz2", "txz", "tzst", "lz", "lzip", "lz4", "br", "brotli", "lrz", "lrzip", "aar", "sz", "snappy", "wim", "dmg", "iso"].contains(ext) { return true }
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
    @objc private func compress(_ sender: NSMenuItem) {
        guard Self.formats.indices.contains(sender.tag) else { return }
        send("compress", format: Self.formats[sender.tag].id)
    }
    /// Opens the selection in the main window, where passwords and volumes can be set.
    @objc private func openInApp() { send("open") }
    @objc private func extract() { send("extract") }
    @objc private func extractTo() { send("extract-to") }
    private func send(_ action: String, format: String? = nil) {
        guard let files = FIFinderSyncController.default().selectedItemURLs(), !files.isEmpty else { return }
        var url = URLComponents()
        url.scheme = "litezip"; url.host = action
        url.queryItems = (format.map { [URLQueryItem(name: "format", value: $0)] } ?? []) + files.map { URLQueryItem(name: "file", value: $0.path) }
        guard let target = url.url else { return }
        NSWorkspace.shared.open(target)
    }
}
