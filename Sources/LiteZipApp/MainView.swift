import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LiteZipCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.openWindow) private var openWindow
    @State private var targeted = false
    private var levels: [CompressionLevel] { CompressionLevel.allCases.filter { $0 != .store || model.format.supportsStore } }
    private var levelIndex: Binding<Double> {
        Binding(get: { Double(levels.firstIndex(of: model.level) ?? 2) }, set: { model.level = levels[min(levels.count - 1, max(0, Int($0.rounded())))] })
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                canvas
                Divider()
                HStack(spacing: 7) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 15, height: 15).accessibilityHidden(true)
                    Text("LiteZip")
                    Spacer()
                    if !model.files.isEmpty { Text(selectionSummary).monospacedDigit() }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .help("所有文件仅在本机处理")
            }
            if preferences.showsInspector {
                Divider()
                inspector
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: preferences.showsInspector ? 780 : 460, minHeight: 400)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .onAppear { model.openMainWindow = { openWindow(id: "main") }; model.visibleMainWindows += 1; configureWindow(); recomputeSelectionSize(model.files) }
        .onChange(of: model.files) { urls in recomputeSelectionSize(urls) }
        .onChange(of: preferences.showsInspector) { shown in if shown { clearAutomaticFocus() } }
        .onDisappear { model.visibleMainWindows = max(0, model.visibleMainWindows - 1) }
        // A flexible space pushes both controls right, onto the canvas's trailing edge;
        // while the panel is open a clear item as wide as the panel keeps them off it.
        // (On macOS .primaryAction means the leading edge.)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
                formatToolbarItem.sharedBackgroundVisibility(.hidden)
                inspectorToolbarItem.sharedBackgroundVisibility(.hidden)
                if preferences.showsInspector { inspectorGapItem.sharedBackgroundVisibility(.hidden) }
            } else {
                ToolbarItem { Spacer() }
                formatToolbarItem
                inspectorToolbarItem
                if preferences.showsInspector { inspectorGapItem }
            }
        }
        .onChange(of: model.format) { _ in model.formatChanged() }
        .sheet(item: Binding(get: { model.browserURL.map(BrowserSelection.init) }, set: { model.browserURL = $0?.url })) { selection in
            ArchiveBrowserView(url: selection.url, model: model)
        }
        .alert("无法完成操作", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    // MARK: - Canvas

    /// The titlebar keeps only the traffic lights and the toolbar controls. The size is
    /// left alone: SwiftUI saves the frame the user drags to and restores it next time.
    private func configureWindow() {
        Task { @MainActor in
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            window.titleVisibility = .hidden
            clearAutomaticFocus()
        }
    }

    /// AppKit gives the panel's first text field (分卷) focus when the window becomes key or
    /// the panel appears, so it looks as if it awaits typing. Clear that until the user
    /// clicks a field; only the panel has text fields, so nothing else loses focus.
    private func clearAutomaticFocus() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  window.firstResponder is NSTextView else { return }
            window.makeFirstResponder(nil)
        }
    }

    @State private var selectionBytes: Int64?
    private var selectionSummary: String {
        let count = "\(model.files.count) 个项目"
        guard let bytes = selectionBytes else { return count }
        return count + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    /// Folder sizes need a full traversal, so the total is summed off the main thread.
    private func recomputeSelectionSize(_ urls: [URL]) {
        guard !urls.isEmpty else { selectionBytes = nil; return }
        Task.detached(priority: .utility) {
            let total = Self.totalBytes(of: urls)
            await MainActor.run { selectionBytes = total }
        }
    }
    /// Kept synchronous and off the main actor: FileManager's enumerator cannot be
    /// iterated from async code, and the traversal may take a while on big folders.
    private nonisolated static func totalBytes(of urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let item as URL in enumerator {
                        if let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                            total += Int64(values.fileSize ?? 0)
                        }
                    }
                }
            } else if let values = try? url.resourceValues(forKeys: [.fileSizeKey]) {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    dropArea
                    if !model.files.isEmpty {
                        selectedFiles
                        summaryBar
                        if let message = model.validationMessage, message != model.passwordValidationMessage,
                           !model.files.isEmpty || !model.password.isEmpty || !model.volumeSize.isEmpty {
                            Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Spacer()
                            Button(model.separateArchives ? "分别压缩" : [.dmg, .iso].contains(model.format) ? "制作 \(model.format.title)" : "压缩", action: model.chooseDestination)
                                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: [.command])
                                .disabled(model.validationMessage != nil)
                        }
                    }
                    if !model.jobs.isEmpty {
                        Divider()
                        HStack {
                            Text("任务").font(.headline)
                            Text("最多同时处理 2 个").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("清除已结束", action: model.clearFinished).buttonStyle(.borderless)
                        }
                        LazyVStack(spacing: 8) { ForEach(model.jobs) { JobRow(job: $0, model: model) } }
                    }
                }
                .padding(22)
                // A short stack sits in the middle of a tall window instead of leaving
                // a large void below; taller content still scrolls from the top.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
            .scrollIndicators(.never)
            // The strip stays narrow for looks; the whole canvas remains a drop target.
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
                collectDroppedURLs(providers) { model.receive($0) }
                return true
            }
        }
    }

    /// States the outcome in one line so the canvas needs no controls of its own.
    private var summaryBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(summaryText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !preferences.showsInspector {
                Button("选项…", action: toggleInspector).buttonStyle(.borderless)
                    .help("压缩等级、密码、分卷等选项（⌘3）")
            }
        }
    }

    private var summaryText: String {
        var parts = [methodText, model.password.isEmpty ? "不加密" : "已加密"]
        if model.format.supportsVolumes { parts.append(model.volumeSize.isEmpty ? "不分卷" : "分卷 " + model.volumeSize) }
        if model.separateArchives { parts.append("每个项目单独压缩") }
        return parts.joined(separator: " · ")
    }

    private var methodText: String {
        switch model.format {
        case .tar: return "仅打包，不压缩"
        case .iso: return "制作映像，不压缩"
        case .snappy: return "固定压缩方式"
        default: return model.format.supportsCompressionLevel ? model.level.title + "压缩" : model.level.title
        }
    }

    private var dropArea: some View {
        let hasFiles = !model.files.isEmpty
        return Group {
            if hasFiles {
                Text(targeted ? "松开即可追加" : "继续拖入可追加项目")
                    .font(.caption).foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: targeted ? "arrow.down.circle.fill" : "square.and.arrow.down")
                            .font(.system(size: 15)).foregroundStyle(.tint).accessibilityHidden(true)
                        Text(targeted ? "松开即可添加" : "拖入文件或文件夹").font(.callout.weight(.medium))
                        Button("选择文件…", action: model.chooseFiles)
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .help("选择文件或文件夹（⌘O）")
                    }
                    Text("选好格式与选项即可压缩；解压请用 Finder 右键或拖到菜单栏图标")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.28), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
    }

    private var selectedFiles: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("已选择 \(model.files.count) 个项目").font(.subheadline.weight(.medium))
                Spacer()
                Button("清空", action: model.resetSelection).buttonStyle(.borderless)
            }
            ForEach(Array(model.files.prefix(3)), id: \.self) { url in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { model.files.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).help("移除 \(url.lastPathComponent)").accessibilityLabel("移除 \(url.lastPathComponent)")
                }.font(.callout)
            }
            if model.files.count > 3 { Text("另有 \(model.files.count - 3) 个项目").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.format == .rar { rarEngine }
                compressionSettings
            }.padding(20)
        }
        // With a mouse attached, macOS keeps a dark legacy scroller beside the panel.
        .scrollIndicators(.never)
        .frame(width: Self.inspectorWidth)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private var rarEngine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(preferences.rarURL == nil ? "RAR 压缩需要官方引擎" : (preferences.rarVersion.isEmpty ? "已找到本机 RAR 引擎" : preferences.rarVersion + " 已连接"), systemImage: preferences.rarURL == nil ? "puzzlepiece.extension" : "checkmark.circle")
                Spacer()
                if preferences.rarURL == nil {
                    Button(preferences.downloadingRAR ? "下载中…" : "下载引擎") { model.downloadRAREngine() }
                        .buttonStyle(.borderedProminent)
                        .disabled(preferences.downloadingRAR || preferences.connectingRAR)
                    Button(preferences.connectingRAR ? "检查中…" : "选择…", action: model.connectRAREngine)
                        .disabled(preferences.downloadingRAR || preferences.connectingRAR)
                        .help("选择本机已安装的 RAR 程序")
                } else {
                    Button(preferences.downloadingRAR ? "检测中…" : "检测更新") { model.checkRAREngineUpdate() }
                        .buttonStyle(.borderless)
                        .disabled(preferences.downloadingRAR || preferences.connectingRAR)
                        .help("查询 rarlab.com 上的最新官方版本，如有更新则下载并替换")
                }
            }
            HStack {
                Text("RAR 解压已内置。官方压缩引擎可试用 40 天，之后需向 RARLAB 购买许可。")
                Link("许可说明", destination: URL(string: "https://www.rarlab.com/license.htm")!)
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var compressionSettings: some View {
        // The format is chosen only in the toolbar menu; the panel holds what is changed
        // occasionally, so it stays short.
        VStack(alignment: .leading, spacing: 22) {
            inspectorSection("压缩方式") {
                VStack(alignment: .leading, spacing: 8) {
                    Slider(value: levelIndex, in: 0...Double(levels.count - 1), step: 1)
                        .disabled(!model.format.supportsCompressionLevel).accessibilityLabel("压缩等级").accessibilityValue(model.level.title)
                    HStack {
                        ForEach(levels) { level in
                            Text(level.title).font(.caption).foregroundStyle(model.level == level && model.format.supportsCompressionLevel ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: level == levels.first ? .leading : level == levels.last ? .trailing : .center)
                        }
                    }
                }
            }
            inspectorSection("分卷") {
                VolumeSizeField(text: $model.volumeSize, supported: model.format.supportsVolumes)
                    .disabled(!model.format.supportsVolumes)
            }
            inspectorSection("密码") {
                VStack(alignment: .leading, spacing: 8) {
                    PasswordInput(placeholder: model.format.supportsPassword ? "不加密" : "此格式不支持加密", accessibilityLabel: "密码", text: $model.password, visible: $model.showPassword, showsVisibilityButton: true)
                        .disabled(!model.format.supportsPassword)
                    PasswordInput(placeholder: "再次输入密码", accessibilityLabel: "确认密码", text: $model.passwordConfirmation, visible: $model.showPassword, showsVisibilityButton: false)
                        .disabled(!model.format.supportsPassword || model.password.isEmpty)
                    passwordError
                }
            }
            inspectorSection("选项") {
                VStack(alignment: .leading, spacing: 11) {
                    Toggle("排除 Mac 资源文件", isOn: $model.excludeMacResources)
                        .help(model.format == .dmg ? "排除 .DS_Store、._ AppleDouble 和 __MACOSX。真实资源分叉与扩展属性仍保留；关闭后独立 AppleDouble 文件按系统磁盘映像复制规则处理。" : "排除 .DS_Store、._ 开头的 AppleDouble 文件和 __MACOSX 文件夹。其他隐藏文件仍保留。")
                    Toggle("压缩后验证完整性", isOn: $model.verifyArchive)
                        .help("重新读取生成的压缩包，确认文件数据通过引擎校验。")
                    Toggle("分别压缩每个项目", isOn: $model.separateArchives)
                        .help("每个选择的项目生成一个独立压缩包，共用当前设置。")
                }.toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 8) {
                if model.format.supportsPassword {
                    Label(model.format == .dmg ? "AES-256 磁盘映像加密 · 支持中文密码" : model.format == .zip ? "AES-256 加密 · 密码使用 1–99 个 ASCII 字符" : "AES-256 加密 · 同时加密文件名" + (model.format == .rar ? " · 密码最长 127 字符" : ""), systemImage: "lock.fill")
                } else if model.format.singleFileOnly {
                    Label("每个压缩包包含一个普通文件；多个文件可分别压缩。", systemImage: "doc")
                }
                if model.format == .dmg {
                    Text("保留文件权限、扩展属性与符号链接；完成后可在 Finder 挂载。存储等级生成只读映像。")
                }
                if model.format == .iso {
                    Text("制作 ISO / Joliet / UDF 光盘映像，不压缩、不加密；支持预览、解压和在 Finder 挂载。")
                }
                if model.format == .aar {
                    Text("Apple 归档：最快使用 LZ4，快速和标准使用 LZFSE，高压缩和极限使用 LZMA；存储仅打包。")
                }
                if !model.volumeSize.isEmpty && model.format.supportsVolumes {
                    Text(model.format == .rar ? "分卷保存到 .parts 文件夹，打开 .part1.rar 首卷（编号可能补零）。大小按 1 MB = 1024² 字节计算。" : "分卷保存到 .parts 文件夹。保留整组文件，打开 .001 解压。大小按 1 MB = 1024² 字节计算。")
                }
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Password problems belong next to the password fields, not at the window bottom.
    private var passwordError: some View {
        Group {
            if let message = model.passwordValidationMessage {
                Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Toolbar

    private func toggleInspector() {
        withAnimation(.easeInOut(duration: 0.18)) { preferences.showsInspector.toggle() }
    }

    static let inspectorWidth: CGFloat = 320

    /// Occupies the toolbar above the open panel so the controls stay over the canvas,
    /// with the same 14 pt trailing margin they keep from the window edge when it is closed.
    private var inspectorGapItem: some ToolbarContent {
        ToolbarItem {
            Color.clear.frame(width: Self.inspectorWidth + 1, height: 1).accessibilityHidden(true)
        }
    }

    private var inspectorToolbarItem: some ToolbarContent {
        ToolbarItem {
            Button(action: toggleInspector) {
                Image(systemName: "slider.horizontal.3")
                    .symbolVariant(preferences.showsInspector ? .fill : .none)
            }
            .help(preferences.showsInspector ? "隐藏选项（⌘3）" : "显示选项：等级、密码、分卷（⌘3）")
            .accessibilityLabel(preferences.showsInspector ? "隐藏选项面板" : "显示选项面板")
        }
    }

    /// The one place the main window picks a format: every creatable format by family,
    /// the same menu as the menu bar popover.
    private var formatToolbarItem: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("压缩格式", selection: $model.format) {
                    ForEach(ArchiveFormat.groupedFormats, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.formats, id: \.self) { format in
                                Text(format.title).tag(format).accessibilityLabel(format.title + "，" + format.menuSummary)
                            }
                        }
                    }
                }.pickerStyle(.inline).labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    FormatBadge(format: model.format, size: 11)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(Capsule())
            }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .modifier(ToolbarSurface())
                .fixedSize()
                .accessibilityLabel("压缩格式：" + model.format.title)
                .help("选择压缩格式。TAR 仅打包；TAR.GZ、TAR.BZ2、TAR.XZ、TAR.ZST 会在打包后压缩。")
        }
    }
}

/// Opaque control surfaces with a hairline edge: no glass, no blurred material.
private struct ToolbarSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
    }
}

/// Resolves file URLs from a drop on the main window or the menu bar popover.
func collectDroppedURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup(), collector = DropCollector()
    for provider in providers {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            defer { group.leave() }
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collector.add(url) }
            else if let url = item as? URL { collector.add(url) }
        }
    }
    group.notify(queue: .main) { completion(collector.urls) }
}

final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [URL]()
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values }
    func add(_ url: URL) { lock.lock(); values.append(url); lock.unlock() }
}
struct BrowserSelection: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Tick-mark progress in the style of usage meters: filled ticks behind the head,
/// one accent tick at the head, dim ticks ahead of it.
/// Progress as tall rounded slats, like a usage meter. Done slats are green in light mode
/// and white in dark mode; the slat being worked on is deep green or purple; the rest are
/// faint. The slat count follows the width, so every slat keeps the same shape in the wide
/// main window and the narrow menu bar popover.
struct SegmentedProgress: View {
    var fraction: Double
    var height: CGFloat = 22
    var slatWidth: CGFloat = 7
    var spacing: CGFloat = 3
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        GeometryReader { proxy in
            let count = max(8, Int((proxy.size.width + spacing) / (slatWidth + spacing)))
            let filled = Int((clamped * Double(count)).rounded(.down))
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: index, filled: filled, finished: clamped >= 1))
                }
            }
            .animation(.easeOut(duration: 0.2), value: filled)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("进度")
        .accessibilityValue("\(Int(clamped * 100))%")
    }
    private func color(for index: Int, filled: Int, finished: Bool) -> Color {
        let dark = scheme == .dark
        if index < filled { return dark ? Color(red: 0.949, green: 0.949, blue: 0.969) : Color(red: 0.204, green: 0.780, blue: 0.349) }
        if index == filled && !finished { return dark ? Color(red: 0.486, green: 0.435, blue: 0.961) : Color(red: 0.082, green: 0.502, blue: 0.239) }
        return dark ? Color.white.opacity(0.12) : Color.black.opacity(0.09)
    }
}

/// One task: format badge, file name, a one-line status, progress while running, and small
/// icon actions (show in Finder, cancel, retry) that the context menu repeats in words.
struct JobRow: View {
    @ObservedObject var job: ArchiveJob
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The badge sits beside the name, so badges of any width need no reserved column;
            // the status line and the progress bar below start at the card edge and align.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let format = job.badgeFormat { FormatBadge(format: format, size: 10) }
                    Text(subject).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                }
                status
                if job.state == .running {
                    if let fraction = job.progress.fraction { SegmentedProgress(fraction: fraction) }
                    else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if let result = job.result { iconButton("magnifyingglass", "在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([result]) } }
                if job.state == .failed || job.state == .cancelled { iconButton("arrow.clockwise", "重试") { model.retry(job) } }
                if !job.state.isFinished { iconButton("xmark.circle.fill", "取消") { model.cancel(job) } }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .contextMenu {
            if let result = job.result { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([result]) } }
            if job.state == .failed || job.state == .cancelled { Button("重试") { model.retry(job) } }
            if !job.state.isFinished { Button("取消") { model.cancel(job) } }
        }
    }

    private var subject: String { job.files.count == 1 ? job.files[0].lastPathComponent : "\(job.files.count) 个项目" }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .completed:
            Label {
                Text((job.extracting ? "解压完成" : "压缩完成") + (job.result.map { " · " + $0.lastPathComponent } ?? ""))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text(job.error ?? "失败").font(.caption).foregroundStyle(.red).lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .cancelled:
            Text(job.error ?? "已取消").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .waiting:
            Text("等待中").font(.caption).foregroundStyle(.secondary)
        case .running:
            Text(runningText).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
    }

    /// "压缩中 · 293.6 MB / 838.9 MB · 77.2 MB/s · 约剩余 7 秒"; a phase message such as
    /// "正在验证完整性…" stands alone while there are no byte counts.
    private var runningText: String {
        let progress = job.progress
        guard progress.totalBytes > 0 else { return progress.currentFile.isEmpty ? (job.extracting ? "解压中" : "压缩中") : progress.currentFile }
        let bytes = { (count: Int64) in ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
        var parts = [job.extracting ? "解压中" : "压缩中", bytes(progress.processedBytes) + " / " + bytes(progress.totalBytes)]
        if progress.bytesPerSecond > 0 { parts.append(bytes(Int64(progress.bytesPerSecond)) + "/s") }
        if let seconds = progress.remainingSeconds {
            parts.append(seconds < 60 ? "约剩余 \(max(1, Int(seconds))) 秒" : "约剩余 \(Int((seconds / 60).rounded(.up))) 分钟")
        }
        return parts.joined(separator: " · ")
    }

    private func iconButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
        .help(title).accessibilityLabel(title)
    }
}
