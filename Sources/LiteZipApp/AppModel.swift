import SwiftUI
import AppKit
import LiteZipCore
import OSLog

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "跟随系统", light = "浅色", dark = "深色"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }
    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    /// With neither a Dock icon nor a menu bar entry the app would be unreachable,
    /// so hiding the Dock only applies while the menu bar entry is on.
    func applyDockIcon() {
        let policy: NSApplication.ActivationPolicy = showsDockIcon || !showsMenuBar ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Info.plist marks LiteZip as an agent (LSUIElement) so a normal launch never flashes a
        // Dock icon. An app promoted to .regular is not frontmost by itself, so bring it forward.
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
    @Published var defaultFormat: ArchiveFormat { didSet { UserDefaults.standard.set(defaultFormat.rawValue, forKey: "format") } }
    @Published var showsMenuBar: Bool { didSet { UserDefaults.standard.set(showsMenuBar, forKey: "showsMenuBar"); applyDockIcon() } }
    @Published var showsDockIcon: Bool { didSet { UserDefaults.standard.set(showsDockIcon, forKey: "showsDockIcon"); applyDockIcon() } }
    @Published var menuBarAskDestination: Bool { didSet { UserDefaults.standard.set(menuBarAskDestination, forKey: "menuBarAskDestination") } }
    /// Starting values for the main window's option checkboxes; the panel changes only the session.
    @Published var defaultExcludeMacResources: Bool { didSet { UserDefaults.standard.set(defaultExcludeMacResources, forKey: "excludeMacResources") } }
    @Published var defaultVerifyArchive: Bool { didSet { UserDefaults.standard.set(defaultVerifyArchive, forKey: "verifyArchive") } }
    /// Folded by default so the main window opens on the drop area and tasks alone.
    @Published var showsInspector: Bool { didSet { UserDefaults.standard.set(showsInspector, forKey: "showsInspector") } }
    @Published var level: CompressionLevel { didSet { UserDefaults.standard.set(level.rawValue, forKey: "level") } }
    @Published var revealResult: Bool { didSet { UserDefaults.standard.set(revealResult, forKey: "reveal") } }
    @Published var maximumGB: Int { didSet { UserDefaults.standard.set(maximumGB, forKey: "maximumGB") } }
    @Published var rarPath: String { didSet { UserDefaults.standard.set(rarPath, forKey: "rarPath") } }
    @Published var checksForUpdates: Bool { didSet { UserDefaults.standard.set(checksForUpdates, forKey: "checksForUpdates") } }
    /// Lifetime usage shown in the menu-bar header capsule.
    @Published var totalBytesSaved: Int64 { didSet { UserDefaults.standard.set(totalBytesSaved, forKey: "bytesSaved") } }
    @Published var compressCount: Int { didSet { UserDefaults.standard.set(compressCount, forKey: "compressCount") } }
    @Published var rarVersion = ""
    @Published var connectingRAR = false
    @Published var downloadingRAR = false
    var rarURL: URL? { RAREngine.locate(configuredPath: rarPath) }
    init() {
        let defaults = UserDefaults.standard
        showsMenuBar = defaults.object(forKey: "showsMenuBar") as? Bool ?? true
        // Menu-bar-first: no Dock icon unless the user asks for one, so LiteZip launch
        // lands in the status item rather than a desktop window.
        showsDockIcon = defaults.object(forKey: "showsDockIcon") as? Bool ?? false
        menuBarAskDestination = defaults.bool(forKey: "menuBarAskDestination")
        defaultExcludeMacResources = defaults.object(forKey: "excludeMacResources") as? Bool ?? true
        defaultVerifyArchive = defaults.object(forKey: "verifyArchive") as? Bool ?? true
        showsInspector = defaults.object(forKey: "showsInspector") as? Bool ?? false
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "跟随系统") ?? .system
        let format = ArchiveFormat(rawValue: defaults.string(forKey: "format") ?? "zip") ?? .zip
        defaultFormat = format.offersCreation ? format : .zip
        level = CompressionLevel(rawValue: defaults.object(forKey: "level") as? Int ?? 5) ?? .normal
        revealResult = defaults.object(forKey: "reveal") as? Bool ?? true
        maximumGB = max(1, min(1000, defaults.object(forKey: "maximumGB") as? Int ?? 100))
        rarPath = defaults.string(forKey: "rarPath") ?? ""
        checksForUpdates = defaults.object(forKey: "checksForUpdates") as? Bool ?? true
        totalBytesSaved = Int64(defaults.integer(forKey: "bytesSaved"))
        compressCount = defaults.integer(forKey: "compressCount")
    }
}

enum JobState: String {
    case waiting = "等待中", running = "处理中", completed = "已完成", failed = "失败", cancelled = "已取消"
    var isFinished: Bool { [.completed, .failed, .cancelled].contains(self) }
}

@MainActor
final class ArchiveJob: ObservableObject, Identifiable {
    let id = UUID()
    let files: [URL]
    let destination: URL
    let extracting: Bool
    var options: CompressionOptions
    let control = OperationControl()
    /// Quick compress and Finder actions report through notifications and task rows
    /// instead of pulling a Finder window to the front for every result.
    var revealsResult = true
    @Published var state = JobState.waiting
    @Published var progress = ArchiveProgress()
    @Published var result: URL?
    @Published var error: String?
    init(files: [URL], destination: URL, extracting: Bool, options: CompressionOptions) {
        self.files = files; self.destination = destination; self.extracting = extracting; self.options = options
    }
    var title: String { (extracting ? "解压 " : "压缩 ") + (files.count == 1 ? files[0].lastPathComponent : "\(files.count) 个项目") }
    /// The format this job actually uses, so task rows never show a generic icon.
    var badgeFormat: ArchiveFormat? { extracting ? ArchiveFormat.detect(files[0]) : options.format }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let preferences = AppPreferences()
    @Published var files = [URL]()
    @Published var jobs = [ArchiveJob]()
    @Published var format = ArchiveFormat.zip
    @Published var level = CompressionLevel.normal
    @Published var password = ""
    @Published var passwordConfirmation = ""
    @Published var showPassword = false
    @Published var volumeSize = ""
    @Published var excludeMacResources = UserDefaults.standard.object(forKey: "excludeMacResources") as? Bool ?? true
    @Published var verifyArchive = UserDefaults.standard.object(forKey: "verifyArchive") as? Bool ?? true
    @Published var separateArchives = false
    @Published var errorMessage: String?
    /// Preview browser target; the main window presents it as a sheet.
    @Published var browserURL: URL?
    /// Captured from MainView so Finder actions can raise the on-demand main window.
    var openMainWindow: (() -> Void)?
    /// Lets the menu bar popover follow a format picked in the quick compress save panel.
    var onQuickFormatChange: ((ArchiveFormat) -> Void)?
    /// Counted by MainView so Finder actions do not open a second main window.
    var visibleMainWindows = 0
    /// Last application the user was in before LiteZip got activated by a URL open.
    private(set) var lastExternalApplication: NSRunningApplication?
    private var running = 0
    private var activePanel: NSSavePanel?
    private let logger = Logger(subsystem: "app.litezip.LiteZip", category: "Tasks")
    /// Password problems are shown next to the password fields instead of the window bottom.
    var passwordValidationMessage: String? {
        guard format.supportsPassword, !password.isEmpty else { return nil }
        if passwordConfirmation != password { return passwordConfirmation.isEmpty ? "请再次输入密码以确认。" : "两次输入的密码不一致。" }
        if password.utf8.count > 4096 || password.contains("\n") || password.contains("\r") || password.contains("\0") { return "密码长度或字符不受支持。" }
        if format == .zip && (!password.unicodeScalars.allSatisfy({ $0.value < 128 }) || password.count > 99) { return ArchiveError.zipPasswordEncoding.localizedDescription }
        if format == .rar && password.utf16.count > 127 { return ArchiveError.rarPasswordLength.localizedDescription }
        return nil
    }
    var validationMessage: String? {
        if format == .rar && preferences.rarURL == nil { return ArchiveError.rarEngineMissing.localizedDescription }
        if [.rar, .dmg, .iso, .aar].contains(format) && !separateArchives {
            let names = files.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }
            if Set(names).count != names.count { return "\(format.title) 中的顶层项目不能同名。请勾选分别压缩，或先修改其中一个名称。" }
        }
        if let message = passwordValidationMessage { return message }
        if format.supportsVolumes { do { _ = try VolumeSize.parse(volumeSize) } catch { return error.localizedDescription } }
        if format.singleFileOnly && !files.isEmpty {
            if !separateArchives && files.count > 1 { return "此格式每个压缩包只能包含一个文件，请勾选分别压缩，或选择 ZIP／7Z。" }
            if files.contains(where: { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true }) { return "此格式只能压缩普通文件。文件夹请使用 ZIP、7Z 或 TAR.GZ。" }
        }
        return nil
    }
    func resetSelection() { files = []; clearPassword() }
    func clearPassword() { password = ""; passwordConfirmation = ""; showPassword = false }
    func formatChanged() {
        if !format.supportsPassword { clearPassword() }
        if !format.supportsVolumes { volumeSize = "" }
        if level == .store && !format.supportsStore { level = .normal }
    }
    private func selectedOptions() throws -> CompressionOptions {
        .init(format: format, level: level, password: format.supportsPassword && !password.isEmpty ? password : nil,
              excludeMacResources: excludeMacResources, verifyArchive: verifyArchive,
              volumeSizeBytes: format.supportsVolumes ? try VolumeSize.parse(volumeSize) : nil)
    }
    var engineURL: URL {
        Bundle.main.url(forResource: "7zz", withExtension: nil, subdirectory: "Engine") ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Engine/7zz")
    }
    var service: ArchiveService {
        ArchiveService(engineURL: engineURL, rarURL: preferences.rarURL, maximumExtractedBytes: Int64(preferences.maximumGB) * 1_024 * 1_024 * 1_024)
    }
    init() {
        format = preferences.defaultFormat; level = preferences.level; formatChanged()
        Task.detached(priority: .utility) { ArchiveService.cleanupAbandonedTemporaryFiles() }
        refreshRAREngine()
        NotificationCenter.default.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor [weak self] in self?.lastExternalApplication = app }
        }
    }
    func refreshRAREngine() {
        guard let url = preferences.rarURL else { preferences.rarVersion = ""; return }
        Task {
            let version = try? await RAREngine.version(at: url)
            if preferences.rarURL == url { preferences.rarVersion = version ?? "" }
        }
    }
    func connectRAREngine() {
        let panel = NSOpenPanel()
        panel.title = "连接官方 RAR 引擎"; panel.prompt = "连接"
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "选择 RARLAB 官方 macOS 软件包内名为 rar 的程序。引擎留在原位置，请保留该软件包及许可文件。"
        present(panel, preferredWindow: NSApp.keyWindow) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            preferences.connectingRAR = true
            Task {
                defer { preferences.connectingRAR = false }
                do {
                    let version = try await RAREngine.version(at: url)
                    preferences.rarPath = url.path; preferences.rarVersion = version
                } catch { errorMessage = ArchiveError.invalidRAREngine.localizedDescription }
            }
        }
    }
    /// Fetches the official package from rarlab.com after the user agrees to RARLAB's trial terms.
    func downloadRAREngine(title: String = "下载 RAR 官方引擎？", confirmation: String = "下载", then next: (() -> Void)? = nil) {
        guard !preferences.downloadingRAR else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "LiteZip 将从 rarlab.com 下载 RARLAB 官方 macOS 软件包（约 1 MB），原样保存到 LiteZip 数据目录并自动连接。\n\nRAR 是共享软件，可免费试用 40 天，之后需向 RARLAB 购买许可。RAR 解压无需此引擎。"
        alert.addButton(withTitle: confirmation); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "许可说明")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertThirdButtonReturn: NSWorkspace.shared.open(URL(string: "https://www.rarlab.com/license.htm")!); return
        default: return
        }
        preferences.downloadingRAR = true
        Task {
            defer { preferences.downloadingRAR = false }
            do {
                let engine = try await RARInstaller.downloadAndInstall()
                // Automatic search checks LiteZip's own copy first.
                preferences.rarPath = ""; preferences.rarVersion = engine.version
                logger.info("Official RAR engine installed")
                next?()
            } catch {
                logger.error("RAR engine download failed")
                let failure = NSAlert()
                failure.messageText = "未能下载 RAR 引擎"
                failure.informativeText = error.localizedDescription
                failure.addButton(withTitle: "好"); failure.addButton(withTitle: "打开官方下载页")
                if failure.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(URL(string: "https://www.rarlab.com/download.htm")!) }
            }
        }
    }
    /// An installed engine is checked for updates rather than offered as a fresh download.
    func checkRAREngineUpdate() {
        guard !preferences.downloadingRAR, preferences.rarURL != nil else { return }
        let alert = NSAlert()
        alert.messageText = "检测 RAR 引擎更新？"
        alert.informativeText = "LiteZip 将查询 rarlab.com 上的最新官方版本，与已连接的\(preferences.rarVersion.isEmpty ? "引擎" : " " + preferences.rarVersion)比较；如有更新则下载并替换，许可文件一并保留。RAR 解压无需此引擎。"
        alert.addButton(withTitle: "检测更新"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "许可说明")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertThirdButtonReturn: NSWorkspace.shared.open(URL(string: "https://www.rarlab.com/license.htm")!); return
        default: return
        }
        preferences.downloadingRAR = true
        Task {
            defer { preferences.downloadingRAR = false }
            do {
                let latest = try await RARInstaller.latestVersionNumber()
                if let latest, let current = Self.rarVersionNumber(preferences.rarVersion), latest <= current {
                    let info = NSAlert()
                    info.messageText = "RAR 引擎已是最新"
                    info.informativeText = "已连接的 \(preferences.rarVersion) 与 rarlab.com 上的最新官方版本一致。"
                    info.addButton(withTitle: "好")
                    info.runModal()
                    return
                }
                let engine = try await RARInstaller.downloadAndInstall()
                preferences.rarPath = ""; preferences.rarVersion = engine.version
                logger.info("Official RAR engine updated")
            } catch {
                logger.error("RAR engine update check failed")
                let failure = NSAlert()
                failure.messageText = "未能检测 RAR 引擎更新"
                failure.informativeText = error.localizedDescription
                failure.addButton(withTitle: "好"); failure.addButton(withTitle: "打开官方下载页")
                if failure.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(URL(string: "https://www.rarlab.com/download.htm")!) }
            }
        }
    }
    /// "RAR 7.13" → 713, the same digits used in rarmacos-arm-713.tar.gz.
    static func rarVersionNumber(_ version: String) -> Int? {
        Int(version.split(separator: " ").last?.replacingOccurrences(of: ".", with: "") ?? "")
    }
    /// Loads files into the compress window. Extraction never comes through here; it is
    /// a direct action via extractNow, so there is no mode to switch.
    func receive(_ urls: [URL]) {
        let valid = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else { return }
        files = Array(NSOrderedSet(array: valid)) as? [URL] ?? valid
        // SwiftUI no longer builds the window for opened files, so show it here.
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
    /// The single extraction path: right-click, drops, double-click, retry and the
    /// preview browser all enqueue here. Encrypted archives prompt only when the engine
    /// actually reports a missing password.
    func extractNow(_ urls: [URL], password: String? = nil, reveal: Bool = true) {
        for url in urls {
            let target = ArchiveFormat.firstVolume(url) ?? url
            if ArchiveFormat.detect(target) == .dmg { openDiskImage(target); continue }
            let destination = target.deletingLastPathComponent().appendingPathComponent(ArchiveFormat.baseName(target))
            enqueue(files: [target], destination: destination, extracting: true, options: .init(password: password), reveal: reveal)
        }
    }
    func open(_ urls: [URL]) {
        for url in urls where url.scheme == "litezip" { handleFinder(url) }
        let files = Array(Set(urls.filter(\.isFileURL).map { ArchiveFormat.firstVolume($0) ?? $0 })).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        if files.allSatisfy({ ArchiveFormat.detect($0) != nil }) { extractNow(files) }
        else { receive(files) }
    }
    func openDiskImage(_ url: URL) {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.DiskImageMounter") else {
            errorMessage = "未找到 macOS 磁盘映像挂载工具。"; return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { _, error in
            if let error { Task { @MainActor in self.errorMessage = error.localizedDescription } }
        }
    }
    private func present(_ panel: NSSavePanel, preferredWindow: NSWindow? = nil, standalone: Bool = false, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard activePanel == nil else { return }
        activePanel = panel
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            completion(response)
            if self?.activePanel === panel { self?.activePanel = nil }
        }
        // The closing browser sheet can briefly remain the key window. Attach
        // file panels to the main window after its previous sheet has detached.
        Task { @MainActor in
            if !standalone, let window = preferredWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                for _ in 0..<50 where window.attachedSheet != nil { try? await Task.sleep(for: .milliseconds(100)) }
                guard window.isVisible, window.attachedSheet == nil else {
                    activePanel = nil; errorMessage = "请先关闭当前对话框，再选择保存位置。"; return
                }
                panel.beginSheetModal(for: window, completionHandler: handler)
            } else { panel.begin(completionHandler: handler) }
        }
    }
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.message = "选择要压缩的文件或文件夹，或要解压的压缩包"
        present(panel) { [weak self] response in
            if response == .OK { self?.receive(panel.urls) }
        }
    }
    /// Menu bar input compresses plain files and extracts archives, so a dropped or
    /// chosen selection always does the sensible thing without any mode switch.
    func quickHandle(_ urls: [URL], format: ArchiveFormat, reportError: @escaping (String) -> Void) {
        let valid = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else { reportError("请拖入本地文件或文件夹。"); return }
        let normalized = Array(NSOrderedSet(array: valid.map { ArchiveFormat.firstVolume($0) ?? $0 })) as? [URL] ?? valid
        if normalized.allSatisfy({ ArchiveFormat.detect($0) != nil }) { extractNow(normalized, reveal: false); return }
        quickCompress(normalized, format: format, reportError: reportError)
    }
    func chooseQuickFiles(format: ArchiveFormat, reportError: @escaping (String) -> Void) {
        guard activePanel == nil else { reportError("请先完成或关闭当前文件对话框。"); return }
        let panel = NSOpenPanel()
        panel.title = "LiteZip"; panel.prompt = "下一步"
        panel.allowsMultipleSelection = true; panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.message = "选择要压缩的文件或文件夹，或要解压的压缩包"
        NSApp.activate(ignoringOtherApps: true)
        present(panel, standalone: true) { [weak self] response in
            guard let self, response == .OK else { return }
            // Clear the open-panel guard before presenting a following save panel.
            self.activePanel = nil
            self.quickHandle(panel.urls, format: format, reportError: reportError)
        }
    }
    func quickCompress(_ urls: [URL], format: ArchiveFormat, reportError: @escaping (String) -> Void) {
        guard activePanel == nil else { reportError("请先完成或关闭当前文件对话框。"); return }
        let inputs = Array(NSOrderedSet(array: urls)) as? [URL] ?? urls
        guard !inputs.isEmpty, inputs.count <= 1000,
              inputs.allSatisfy({ $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }) else {
            reportError("请拖入本地文件或文件夹，一次最多选择 1000 项。"); return
        }
        if let problem = quickCompressProblem(inputs, format: format) { reportError(problem); return }
        let proposedName = { (format: ArchiveFormat) in
            inputs.count == 1 ? CompressionPlanning.name(for: inputs[0], format: format) : "Archive." + format.suffix
        }
        if !preferences.menuBarAskDestination {
            enqueue(files: inputs, destination: inputs[0].deletingLastPathComponent().appendingPathComponent(proposedName(format)), extracting: false, options: quickOptions(format), reveal: false)
            return
        }
        let panel = NSSavePanel()
        panel.prompt = "压缩"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = proposedName(format)
        panel.directoryURL = inputs[0].deletingLastPathComponent()
        let describe = { [weak panel, weak self] (format: ArchiveFormat) in
            guard let panel, let self else { return }
            panel.title = "快捷压缩 · \(format.title)"
            panel.message = "\(inputs.count) 个项目 · \(self.quickOptions(format).level.title)压缩 · 不加密。需要密码或分卷请使用主窗口。"
        }
        describe(format)
        // The format can still change here; an untouched name follows it, an edited one
        // only swaps its extension.
        let chooser = SaveFormatChooser(selected: format) { [weak self] in self?.quickCompressProblem(inputs, format: $0) == nil }
        chooser.onChange = { [weak panel] old, new in
            guard let panel else { return }
            var name = panel.nameFieldStringValue
            if name == proposedName(old) { name = proposedName(new) }
            else {
                if name.lowercased().hasSuffix("." + old.suffix) { name.removeLast(old.suffix.count + 1) }
                name += "." + new.suffix
            }
            panel.nameFieldStringValue = name
            describe(new)
        }
        panel.accessoryView = chooser.view
        NSApp.activate(ignoringOtherApps: true)
        present(panel, standalone: true) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let format = chooser.selected
            if let problem = self.quickCompressProblem(inputs, format: format) { reportError(problem); return }
            self.onQuickFormatChange?(format)
            let destination = url.lastPathComponent.lowercased().hasSuffix("." + format.suffix) ? url : url.appendingPathExtension(format.suffix)
            self.enqueue(files: inputs, destination: destination, extracting: false, options: self.quickOptions(format), reveal: false)
        }
    }

    /// Why `format` cannot take `inputs` in a quick compress, or nil when it can. The
    /// save panel uses the same rules to disable formats in its format menu.
    private func quickCompressProblem(_ inputs: [URL], format: ArchiveFormat) -> String? {
        guard format.canCreate else { return "此格式仅支持解压。" }
        if format.singleFileOnly && (inputs.count != 1 || (try? inputs[0].resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true) {
            return "\(format.title) 只能压缩单个普通文件。文件夹或多个文件请选择 ZIP、7Z 或 TAR.GZ。"
        }
        if format == .rar && preferences.rarURL == nil { return ArchiveError.rarEngineMissing.localizedDescription }
        if [.rar, .dmg, .iso, .aar].contains(format) {
            let names = inputs.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }
            guard Set(names).count == names.count else { return "\(format.title) 中的顶层项目不能同名，请修改名称后重试。" }
        }
        return nil
    }

    private func quickOptions(_ format: ArchiveFormat) -> CompressionOptions {
        let level = preferences.level == .store && !format.supportsStore ? CompressionLevel.normal : preferences.level
        return CompressionOptions(format: format, level: level, excludeMacResources: excludeMacResources, verifyArchive: verifyArchive)
    }
    /// Compress-only: choose a destination and enqueue. Extraction has no destination
    /// dialog of its own — it goes straight to the archive's folder via extractNow.
    func chooseDestination() {
        guard !files.isEmpty else { return }
        if let message = validationMessage { errorMessage = message; return }
        let inputs = files
        let options: CompressionOptions
        do { options = try selectedOptions() } catch { errorMessage = error.localizedDescription; return }
        if separateArchives {
            let panel = NSOpenPanel()
            panel.title = "选择压缩包保存位置"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            panel.prompt = "保存到此处"; panel.directoryURL = inputs[0].deletingLastPathComponent()
            panel.message = "每个文件或文件夹生成一个独立压缩包，同名结果会自动编号。"
            present(panel) { [weak self] response in
                guard let self, response == .OK, let directory = panel.url else { return }
                do {
                    for plan in try CompressionPlanning.separate(files: inputs, directory: directory, format: options.format) {
                        self.enqueue(files: plan.files, destination: plan.destination, extracting: false, options: options)
                    }
                    self.resetSelection()
                } catch { self.errorMessage = error.localizedDescription }
            }
            return
        }
        let panel = NSSavePanel()
        panel.title = "保存压缩包"; panel.canCreateDirectories = true
        panel.nameFieldStringValue = inputs.count == 1 ? CompressionPlanning.name(for: inputs[0], format: options.format) : "Archive." + options.format.suffix
        panel.directoryURL = inputs[0].deletingLastPathComponent()
        if options.volumeSizeBytes != nil { panel.message = options.format == .rar ? "整组分卷保存到同名 .parts 文件夹。保留所有分卷，打开 .part1.rar 首卷解压（编号可能补零）。" : "整组分卷保存到同名 .parts 文件夹。解压时将所有分卷放在一起，打开 .001 文件。" }
        present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let destination = url.lastPathComponent.lowercased().hasSuffix("." + options.format.suffix) ? url : url.appendingPathExtension(options.format.suffix)
            self.enqueue(files: inputs, destination: destination, extracting: false, options: options)
            self.resetSelection()
        }
    }
    func enqueue(files: [URL], destination: URL, extracting: Bool, options: CompressionOptions, reveal: Bool = true) {
        let job = ArchiveJob(files: files, destination: destination, extracting: extracting, options: options)
        job.revealsResult = reveal
        if !reveal { JobNotifier.shared.prepare() }
        jobs.insert(job, at: 0)
        pump()
    }
    func cancel(_ job: ArchiveJob) {
        guard !job.state.isFinished else { return }
        job.control.cancel()
        if job.state == .waiting { job.state = .cancelled; job.options.password = nil }
    }
    func retry(_ job: ArchiveJob) {
        if job.extracting {
            // Extraction stays a direct action; re-run it without opening any UI.
            extractNow(job.files, password: job.options.password, reveal: job.revealsResult)
            return
        }
        receive(job.files)
        format = job.options.format; level = job.options.level
        excludeMacResources = job.options.excludeMacResources; verifyArchive = job.options.verifyArchive
        volumeSize = job.options.volumeSizeBytes.map { "\(Double($0) / 1_024 / 1_024) MB" } ?? ""
        separateArchives = false
    }
    func clearFinished() { jobs.removeAll { $0.state.isFinished } }
    /// progress.totalBytes is the input total the engine reported; the archive's own
    /// size is the output, so their difference is the space this compression saved.
    private func recordCompression(inputBytes: Int64, result: URL?) {
        preferences.compressCount += 1
        guard let result, let outputBytes = try? result.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
        let saved = inputBytes - Int64(outputBytes)
        if saved > 0 { preferences.totalBytesSaved += saved }
    }
    private func pump() {
        while running < 2, let job = jobs.reversed().first(where: { $0.state == .waiting }) {
            job.state = .running; running += 1
            let service = self.service
            Task {
                do {
                    let update: @Sendable (ArchiveProgress) -> Void = { value in
                        Task { @MainActor in if job.state == .running { job.progress = value } }
                    }
                    if job.extracting {
                        job.result = try await service.extract(archive: job.files[0], destination: job.destination, password: job.options.password, control: job.control, progress: update)
                    } else {
                        job.result = try await service.compress(files: job.files, destination: job.destination, options: job.options, control: job.control, progress: update)
                    }
                    job.state = .completed
                    if !job.extracting { recordCompression(inputBytes: job.progress.totalBytes, result: job.result) }
                    if job.revealsResult && preferences.revealResult, let result = job.result { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                    logger.info("Archive operation completed")
                    JobNotifier.shared.report(job)
                    job.options.password = nil
                } catch {
                    // Extraction asks for a password only when an archive needs one;
                    // a supplied password re-queues the job instead of failing it.
                    if job.extracting, (error as? ArchiveError) == .wrongPassword, let secret = requestPassword(for: job) {
                        job.options.password = secret
                        job.state = .waiting
                    } else {
                        job.state = (error as? ArchiveError) == .cancelled ? .cancelled : .failed
                        job.error = error.localizedDescription
                        logger.error("Archive operation failed; category: \(String(describing: type(of: error)), privacy: .public)")
                        JobNotifier.shared.report(job)
                        job.options.password = nil
                    }
                }
                running -= 1; pump()
            }
        }
    }
    /// Password prompt shown at the moment an encrypted archive actually needs one.
    private func requestPassword(for job: ArchiveJob) -> String? {
        let alert = NSAlert()
        alert.messageText = "需要密码"
        alert.informativeText = "「\(job.files[0].lastPathComponent)」是加密压缩包，请输入解压密码。"
        alert.addButton(withTitle: "解压"); alert.addButton(withTitle: "取消")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 300, height: 22))
        field.placeholderString = "解压密码"
        let batch = NSButton(checkboxWithTitle: "同一密码用于其余等待中的压缩包", target: nil, action: nil)
        batch.frame = NSRect(x: 0, y: 2, width: 300, height: 18)
        let hasOthers = jobs.contains { $0 !== job && $0.extracting && $0.state == .waiting && $0.options.password == nil }
        batch.isHidden = !hasOthers
        batch.state = .on
        accessory.addSubview(field); accessory.addSubview(batch)
        alert.accessoryView = accessory
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        if hasOthers, batch.state == .on {
            for other in jobs where other !== job && other.extracting && other.state == .waiting && other.options.password == nil {
                other.options.password = field.stringValue
            }
        }
        return field.stringValue
    }
    private func handleFinder(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let action = components.host else { return }
        // litezip://settings[?tab=general|compress|extract|associations|about] opens the settings window.
        if action == "settings" {
            SettingsWindowController.shared.show(tab: components.queryItems?.first { $0.name == "tab" }?.value)
            return
        }
        let rawFiles = (components.queryItems ?? []).filter { $0.name == "file" }.compactMap { $0.value }.map { URL(fileURLWithPath: $0) }
        let files = Array(NSOrderedSet(array: rawFiles.map { action.hasPrefix("extract") ? ArchiveFormat.firstVolume($0) ?? $0 : $0 })) as? [URL] ?? rawFiles
        guard !files.isEmpty, files.count <= 1000 else { return }
        switch action {
        case "compress":
            let requested = components.queryItems?.first { $0.name == "format" }?.value.flatMap(ArchiveFormat.init(rawValue:))
            compressFromFinder(files, format: requested.flatMap { $0.canCreate ? $0 : nil } ?? preferences.defaultFormat)
        case "extract":
            extractNow(files, reveal: false)
            returnFocusToSender()
        case "extract-to": chooseExtractionFolder(for: files)
        default:
            // "在 LiteZip 中打开…": archives open in the preview browser, other files
            // load into the compress window. The window is on-demand, so raise it here.
            if files.allSatisfy({ ArchiveFormat.detect($0) != nil }) { browserURL = files[0] }
            else { receive(files) }
            openMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private func compressFromFinder(_ files: [URL], format: ArchiveFormat) {
        if format == .rar && preferences.rarURL == nil {
            downloadRAREngine(title: "创建 RAR 需要官方引擎", confirmation: "下载并压缩") { [weak self] in
                guard let self, preferences.rarURL != nil else { return }
                compressFromFinder(files, format: format)
            }
            return
        }
        let name = files.count == 1 ? CompressionPlanning.name(for: files[0], format: format) : "Archive." + format.suffix
        let level = preferences.level == .store && !format.supportsStore ? CompressionLevel.normal : preferences.level
        enqueue(files: files, destination: files[0].deletingLastPathComponent().appendingPathComponent(name), extracting: false, options: .init(format: format, level: level), reveal: false)
        returnFocusToSender()
    }
    /// Opening the litezip:// URL activates LiteZip. Hand focus back to the app the
    /// user was working in, so right-click compression never pops windows forward.
    func returnFocusToSender() {
        guard visibleMainWindows == 0, NSApp.windows.allSatisfy({ !($0.isVisible && $0.canBecomeMain) }),
              let previous = lastExternalApplication,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return }
        previous.activate()
    }
    /// Finder's "解压到…" asks for a folder without changing the main window's selection.
    private func chooseExtractionFolder(for archives: [URL]) {
        for image in archives where ArchiveFormat.detect(image) == .dmg { openDiskImage(image) }
        let inputs = archives.filter { ArchiveFormat.detect($0).map { $0 != .dmg } ?? false }
        guard !inputs.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "选择解压位置"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "解压到此处"; panel.directoryURL = inputs[0].deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        present(panel, standalone: true) { [weak self] response in
            guard let self, response == .OK, let directory = panel.url else { return }
            for file in inputs {
                enqueue(files: [file], destination: directory.appendingPathComponent(ArchiveFormat.baseName(file)), extracting: true, options: .init(), reveal: false)
            }
        }
    }
}
