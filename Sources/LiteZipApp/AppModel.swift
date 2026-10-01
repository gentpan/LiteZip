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
    init() {
        let defaults = UserDefaults.standard
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "跟随系统") ?? .system
        let format = ArchiveFormat(rawValue: defaults.string(forKey: "format") ?? "zip") ?? .zip
        defaultFormat = format.canCreate ? format : .zip
        level = CompressionLevel(rawValue: defaults.integer(forKey: "level")) ?? .normal
        revealResult = defaults.object(forKey: "reveal") as? Bool ?? true
        maximumGB = max(1, min(1000, defaults.object(forKey: "maximumGB") as? Int ?? 100))
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
    @Published var mode = Mode.compress
    @Published var format = ArchiveFormat.zip
    @Published var level = CompressionLevel.normal
    @Published var password = ""
    @Published var errorMessage: String?
    @Published var browserURL: URL?
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
    var engineURL: URL {
        Bundle.main.url(forResource: "7zz", withExtension: nil, subdirectory: "Engine") ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Engine/7zz")
    }
    var service: ArchiveService {
        ArchiveService(engineURL: engineURL, maximumExtractedBytes: Int64(preferences.maximumGB) * 1_024 * 1_024 * 1_024)
    }
    init() {
        format = preferences.defaultFormat; level = preferences.level
        Task.detached(priority: .utility) { ArchiveService.cleanupAbandonedTemporaryFiles() }
    }
    func receive(_ urls: [URL]) {
        let valid = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else { return }
        files = Array(NSOrderedSet(array: valid)) as? [URL] ?? valid
        password = ""
        if files.allSatisfy({ ArchiveFormat.detect($0) != nil }) { mode = .extract }
        else { mode = .compress }
        NSApp.activate(ignoringOtherApps: true)
    }
    func open(_ urls: [URL]) {
        for url in urls where url.scheme == "litezip" { handleFinder(url) }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if files.allSatisfy({ ArchiveFormat.detect($0) != nil }) {
            for file in files {
                enqueue(files: [file], destination: file.deletingLastPathComponent().appendingPathComponent(ArchiveFormat.baseName(file)), extracting: true, options: .init())
            }
        } else { receive(files) }
    }
    private func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard activePanel == nil else { return }
        activePanel = panel
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            completion(response)
            self?.activePanel = nil
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { panel.begin(completionHandler: handler) }
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
        if mode == .compress {
            let panel = NSSavePanel()
            panel.title = "保存压缩包"; panel.canCreateDirectories = true
            let name = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "Archive"
            panel.nameFieldStringValue = name + "." + format.suffix
            panel.directoryURL = files[0].deletingLastPathComponent()
            present(panel) { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                self.enqueue(files: self.files, destination: url, extracting: false, options: .init(format: self.format, level: self.level, password: self.password.isEmpty ? nil : self.password))
                self.password = ""; self.files = []
            }
        } else {
            let panel = NSOpenPanel()
            panel.title = "选择解压位置"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            panel.prompt = "解压到此处"; panel.directoryURL = files[0].deletingLastPathComponent()
            present(panel) { [weak self] response in
                guard let self, response == .OK, let directory = panel.url else { return }
                for file in self.files {
                    self.enqueue(files: [file], destination: directory.appendingPathComponent(ArchiveFormat.baseName(file)), extracting: true, options: .init(password: self.password.isEmpty ? nil : self.password))
                }
                self.password = ""; self.files = []
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
        let files = (components.queryItems ?? []).filter { $0.name == "file" }.compactMap { $0.value }.map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty, files.count <= 1000 else { return }
        switch action {
        case "compress":
            let name = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "Archive"
            enqueue(files: files, destination: files[0].deletingLastPathComponent().appendingPathComponent(name + "." + preferences.defaultFormat.suffix), extracting: false, options: .init(format: preferences.defaultFormat, level: preferences.level))
        case "extract":
            for file in files { enqueue(files: [file], destination: file.deletingLastPathComponent().appendingPathComponent(ArchiveFormat.baseName(file)), extracting: true, options: .init()) }
        default: receive(files)
        }
    }
}
