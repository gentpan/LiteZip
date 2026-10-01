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
    @Published var defaultFormat: ArchiveFormat { didSet { UserDefaults.standard.set(defaultFormat.rawValue, forKey: "format") } }
    @Published var level: CompressionLevel { didSet { UserDefaults.standard.set(level.rawValue, forKey: "level") } }
    @Published var revealResult: Bool { didSet { UserDefaults.standard.set(revealResult, forKey: "reveal") } }
    @Published var maximumGB: Int { didSet { UserDefaults.standard.set(maximumGB, forKey: "maximumGB") } }
    @Published var rarPath: String { didSet { UserDefaults.standard.set(rarPath, forKey: "rarPath") } }
    @Published var rarVersion = ""
    @Published var connectingRAR = false
    var rarURL: URL? { RAREngine.locate(configuredPath: rarPath) }
    init() {
        let defaults = UserDefaults.standard
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "跟随系统") ?? .system
        let format = ArchiveFormat(rawValue: defaults.string(forKey: "format") ?? "zip") ?? .zip
        defaultFormat = format.canCreate ? format : .zip
        level = CompressionLevel(rawValue: defaults.object(forKey: "level") as? Int ?? 5) ?? .normal
        revealResult = defaults.object(forKey: "reveal") as? Bool ?? true
        maximumGB = max(1, min(1000, defaults.object(forKey: "maximumGB") as? Int ?? 100))
        rarPath = defaults.string(forKey: "rarPath") ?? ""
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
    @Published var state = JobState.waiting
    @Published var progress = ArchiveProgress()
    @Published var result: URL?
    @Published var error: String?
    init(files: [URL], destination: URL, extracting: Bool, options: CompressionOptions) {
        self.files = files; self.destination = destination; self.extracting = extracting; self.options = options
    }
    var title: String { (extracting ? "解压 " : "压缩 ") + (files.count == 1 ? files[0].lastPathComponent : "\(files.count) 个项目") }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let preferences = AppPreferences()
    @Published var files = [URL]()
    @Published var jobs = [ArchiveJob]()
    @Published var mode = Mode.compress { didSet { if mode != oldValue { clearPassword() } } }
    @Published var format = ArchiveFormat.zip
    @Published var level = CompressionLevel.normal
    @Published var password = ""
    @Published var passwordConfirmation = ""
    @Published var showPassword = false
    @Published var volumeSize = ""
    @Published var excludeMacResources = true
    @Published var verifyArchive = true
    @Published var separateArchives = false
    @Published var errorMessage: String?
    @Published var browserURL: URL?
    var chooseDestinationAfterBrowser = false
    private var running = 0
    private var activePanel: NSSavePanel?
    private let logger = Logger(subsystem: "app.litezip.LiteZip", category: "Tasks")
    enum Mode: String, CaseIterable, Identifiable {
        case compress = "压缩", extract = "解压"
        var id: String { rawValue }
    }
    var hasMixedFiles: Bool {
        let count = files.filter { ArchiveFormat.detect($0) != nil }.count
        return count > 0 && count < files.count
    }
    var validationMessage: String? {
        if mode == .extract {
            return files.contains { ArchiveFormat.detect($0) == nil } ? "解压模式仅支持压缩包，请移除普通文件或切换到压缩。" : nil
        }
        if format == .rar && preferences.rarURL == nil { return ArchiveError.rarEngineMissing.localizedDescription }
        if format == .rar && !separateArchives {
            let names = files.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }
            if Set(names).count != names.count { return "RAR 中的顶层项目不能同名。请勾选分别压缩，或先修改其中一个名称。" }
        }
        if format.supportsPassword && !password.isEmpty {
            if passwordConfirmation != password { return passwordConfirmation.isEmpty ? "请再次输入密码以确认。" : "两次输入的密码不一致。" }
            if password.utf8.count > 4096 || password.contains("\n") || password.contains("\r") || password.contains("\0") { return "密码长度或字符不受支持。" }
            if format == .zip && (!password.unicodeScalars.allSatisfy({ $0.value < 128 }) || password.count > 99) { return ArchiveError.zipPasswordEncoding.localizedDescription }
            if format == .rar && password.utf16.count > 127 { return ArchiveError.rarPasswordLength.localizedDescription }
        }
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
        panel.message = "选择 RARLAB 官方 macOS 软件包内的 rar 文件。引擎留在原位置，请保留该软件包及许可文件。"
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
    func receive(_ urls: [URL]) {
        let valid = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else { return }
        // Selecting a set of volumes represents one archive, not one job per part.
        let normalized = valid.map { ArchiveFormat.firstVolume($0) ?? $0 }
        files = Array(NSOrderedSet(array: normalized)) as? [URL] ?? normalized
        let newMode: Mode = files.allSatisfy({ ArchiveFormat.detect($0) != nil }) ? .extract : .compress
        if mode != newMode { clearPassword() }
        mode = newMode
        NSApp.activate(ignoringOtherApps: true)
    }
    func open(_ urls: [URL]) {
        for url in urls where url.scheme == "litezip" { handleFinder(url) }
        let files = Array(Set(urls.filter(\.isFileURL).map { ArchiveFormat.firstVolume($0) ?? $0 })).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        if files.allSatisfy({ ArchiveFormat.detect($0) != nil }) {
            for file in files {
                enqueue(files: [file], destination: file.deletingLastPathComponent().appendingPathComponent(ArchiveFormat.baseName(file)), extracting: true, options: .init())
            }
        } else { receive(files) }
    }
    private func present(_ panel: NSSavePanel, preferredWindow: NSWindow? = nil, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard activePanel == nil else { return }
        activePanel = panel
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            completion(response)
            self?.activePanel = nil
        }
        // The closing browser sheet can briefly remain the key window. Attach
        // file panels to the main window after its previous sheet has detached.
        Task { @MainActor in
            if let window = preferredWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
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
        panel.message = "选择要压缩的文件，或要解压的压缩包"
        present(panel) { [weak self] response in
            if response == .OK { self?.receive(panel.urls) }
        }
    }
    func chooseDestination() {
        guard !files.isEmpty else { return }
        if let message = validationMessage { errorMessage = message; return }
        if mode == .compress {
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
        } else {
            let inputs = files, secret = password.isEmpty ? nil : password
            let panel = NSOpenPanel()
            panel.title = "选择解压位置"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            panel.prompt = "解压到此处"; panel.directoryURL = files[0].deletingLastPathComponent()
            present(panel) { [weak self] response in
                guard let self, response == .OK, let directory = panel.url else { return }
                for file in inputs {
                    self.enqueue(files: [file], destination: directory.appendingPathComponent(ArchiveFormat.baseName(file)), extracting: true, options: .init(password: secret))
                }
                self.resetSelection()
            }
        }
    }
    func enqueue(files: [URL], destination: URL, extracting: Bool, options: CompressionOptions) {
        jobs.insert(ArchiveJob(files: files, destination: destination, extracting: extracting, options: options), at: 0)
        pump()
    }
    func cancel(_ job: ArchiveJob) {
        guard !job.state.isFinished else { return }
        job.control.cancel()
        if job.state == .waiting { job.state = .cancelled; job.options.password = nil }
    }
    func retry(_ job: ArchiveJob) {
        receive(job.files); mode = job.extracting ? .extract : .compress
        format = job.options.format; level = job.options.level
        excludeMacResources = job.options.excludeMacResources; verifyArchive = job.options.verifyArchive
        volumeSize = job.options.volumeSizeBytes.map { "\(Double($0) / 1_024 / 1_024) MB" } ?? ""
        separateArchives = false
    }
    func clearFinished() { jobs.removeAll { $0.state.isFinished } }
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
                    if preferences.revealResult, let result = job.result { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                    logger.info("Archive operation completed")
                } catch {
                    job.state = (error as? ArchiveError) == .cancelled ? .cancelled : .failed
                    job.error = error.localizedDescription
                    logger.error("Archive operation failed; category: \(String(describing: type(of: error)), privacy: .public)")
                }
                job.options.password = nil
                running -= 1; pump()
            }
        }
    }
    private func handleFinder(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let action = components.host else { return }
        let rawFiles = (components.queryItems ?? []).filter { $0.name == "file" }.compactMap { $0.value }.map { URL(fileURLWithPath: $0) }
        let files = Array(NSOrderedSet(array: rawFiles.map { action == "extract" ? ArchiveFormat.firstVolume($0) ?? $0 : $0 })) as? [URL] ?? rawFiles
        guard !files.isEmpty, files.count <= 1000 else { return }
        switch action {
        case "compress":
            let name = files.count == 1 ? CompressionPlanning.name(for: files[0], format: preferences.defaultFormat) : "Archive." + preferences.defaultFormat.suffix
            let level = preferences.level == .store && !preferences.defaultFormat.supportsStore ? CompressionLevel.normal : preferences.level
            enqueue(files: files, destination: files[0].deletingLastPathComponent().appendingPathComponent(name), extracting: false, options: .init(format: preferences.defaultFormat, level: level))
        case "extract":
            for file in files { enqueue(files: [file], destination: file.deletingLastPathComponent().appendingPathComponent(ArchiveFormat.baseName(file)), extracting: true, options: .init()) }
        default: receive(files)
        }
    }
}
