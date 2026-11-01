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
        .onDisappear { model.visibleMainWindows = max(0, model.visibleMainWindows - 1) }
        .toolbar {
            if #available(macOS 26.0, *) {
                formatToolbarItem.sharedBackgroundVisibility(.hidden)
                inspectorToolbarItem.sharedBackgroundVisibility(.hidden)
            } else {
                formatToolbarItem
                inspectorToolbarItem
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

    /// macOS restores the previous window frame, and an empty window has nothing to fill
    /// a tall frame, so the first empty window of a session is compacted once. The
    /// titlebar keeps only the traffic lights and the toolbar controls.
    private static var compactedEmptyWindow = false
    private func configureWindow() {
        Task { @MainActor in
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            window.titleVisibility = .hidden
            guard !Self.compactedEmptyWindow, model.files.isEmpty, model.jobs.isEmpty,
                  let width = window.contentView?.bounds.width else { return }
            Self.compactedEmptyWindow = true
            window.setContentSize(NSSize(width: min(max(width, 460), 560), height: 340))
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
                            Button(model.separateArchives ? "分别压缩…" : [.dmg, .iso].contains(model.format) ? "制作 \(model.format.title)…" : "压缩…", action: model.chooseDestination)
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
                        LazyVStack(spacing: 10) { ForEach(model.jobs) { JobRow(job: $0, model: model) } }
                    }
                }
                .padding(22)
                // A short stack sits in the middle of a tall window instead of leaving
                // a large void below; taller content still scrolls from the top.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
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
        .frame(width: 320)
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
        VStack(alignment: .leading, spacing: 22) {
            inspectorSection("压缩格式") {
                Picker("压缩格式", selection: $model.format) {
                    ForEach(ArchiveFormat.groupedFormats, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.formats, id: \.self) { format in
                                Label { Text(format.title) } icon: { Image(nsImage: format.fileIcon).resizable().scaledToFit().frame(width: 18, height: 18) }
                                    .tag(format).accessibilityLabel(format.title + "，" + format.menuSummary)
                            }
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
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
                HStack(spacing: 4) {
                    TextField(model.format.supportsVolumes ? "不分卷，例如 100 MB" : "此格式不支持分卷", text: $model.volumeSize).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("分卷大小")
                    Menu {
                        Button("不分卷") { model.volumeSize = "" }
                        Divider()
                        ForEach(["5 MB", "100 MB", "500 MB", "1 GB", "2 GB"], id: \.self) { size in Button(size) { model.volumeSize = size } }
                    } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("分卷预设")
                }.disabled(!model.format.supportsVolumes)
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

    private func formatLabel(_ format: ArchiveFormat) -> some View {
        Label { Text(format.title) } icon: {
            Image(nsImage: format.fileIcon).resizable().scaledToFit().frame(width: 18, height: 18)
        }.tag(format).accessibilityLabel(format.title)
    }

    private var formatToolbarItem: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("压缩格式", selection: $model.format) {
                    ForEach(ArchiveFormat.commonFormats, id: \.self) { format in
                        formatLabel(format)
                    }
                }.pickerStyle(.inline).labelsHidden()
                Divider()
                Button("更多格式…") {
                    withAnimation(.easeInOut(duration: 0.18)) { preferences.showsInspector = true }
                }
                .help("在选项面板中按家族浏览全部格式")
            } label: {
                HStack(spacing: 6) {
                    Image(nsImage: model.format.fileIcon)
                        .resizable().scaledToFit().frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text(model.format.title).font(.callout.weight(.medium))
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

private struct PasswordInput: View {
    let placeholder: String
    let accessibilityLabel: String
    @Binding var text: String
    @Binding var visible: Bool
    let showsVisibilityButton: Bool
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if visible { TextField(placeholder, text: $text) }
                else { SecureField(placeholder, text: $text) }
            }.textFieldStyle(.roundedBorder).accessibilityLabel(accessibilityLabel)
            if showsVisibilityButton {
                // The icon states what the field shows now: open eye = plaintext visible.
                Button { visible.toggle() } label: { Image(systemName: visible ? "eye" : "eye.slash") }
                    .buttonStyle(.borderless).help(visible ? "隐藏密码" : "显示密码").accessibilityLabel(visible ? "隐藏密码" : "显示密码")
            }
        }
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
struct SegmentedProgress: View {
    var fraction: Double
    var height: CGFloat = 14
    var ticks: Int = 36
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        let filled = Int((clamped * Double(ticks)).rounded(.down))
        HStack(spacing: 2) {
            ForEach(0..<ticks, id: \.self) { index in
                Capsule()
                    .fill(color(for: index, filled: filled))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.2), value: filled)
        .accessibilityElement()
        .accessibilityLabel("进度")
        .accessibilityValue("\(Int(clamped * 100))%")
    }
    private func color(for index: Int, filled: Int) -> Color {
        if index == filled { return .accentColor }
        if index < filled { return scheme == .dark ? .white : Color(nsColor: .systemGreen) }
        return .primary.opacity(scheme == .dark ? 0.18 : 0.15)
    }
}

struct JobRow: View {
    @ObservedObject var job: ArchiveJob
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let format = job.badgeFormat {
                    Image(nsImage: format.menuBadge).resizable().scaledToFit().frame(width: 46, height: 15).accessibilityHidden(true)
                }
                Label(job.title, systemImage: job.extracting ? "archivebox" : "archivebox.fill").font(.headline).lineLimit(1)
                Spacer()
                Text(job.state.rawValue).font(.caption).foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                if !job.state.isFinished { Button("取消") { model.cancel(job) } }
                if job.state == .failed || job.state == .cancelled { Button("重试") { model.retry(job) } }
                if let result = job.result { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([result]) } }
            }
            if job.state == .running {
                if let fraction = job.progress.fraction { SegmentedProgress(fraction: fraction) }
                else { ProgressView().controlSize(.small) }
                HStack {
                    Text(job.progress.currentFile.isEmpty ? "正在处理…" : job.progress.currentFile).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if job.progress.totalBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: job.progress.processedBytes, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: job.progress.totalBytes, countStyle: .file)).monospacedDigit()
                    }
                }.font(.caption).foregroundStyle(.secondary)
                if job.progress.bytesPerSecond > 0 {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(job.progress.bytesPerSecond), countStyle: .file) + "/s")
                        if let seconds = job.progress.remainingSeconds { Text("约剩余 \(Int(seconds)) 秒") }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let error = job.error { Text(error).font(.callout).foregroundStyle(job.state == .failed ? Color.red : Color.secondary).textSelection(.enabled) }
            if let result = job.result { Text(result.lastPathComponent).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
