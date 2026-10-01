import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LiteZipCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @State private var targeted = false
    private var levels: [CompressionLevel] { CompressionLevel.allCases.filter { $0 != .store || model.format.supportsStore } }
    private var levelIndex: Binding<Double> {
        Binding(get: { Double(levels.firstIndex(of: model.level) ?? 2) }, set: { model.level = levels[min(levels.count - 1, max(0, Int($0.rounded())))] })
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.mode == .compress {
                        if model.format == .rar {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(preferences.rarURL == nil ? "RAR 压缩需要连接官方引擎" : (preferences.rarVersion.isEmpty ? "已找到本机 RAR 引擎" : preferences.rarVersion + " 已连接"), systemImage: preferences.rarURL == nil ? "puzzlepiece.extension" : "checkmark.circle")
                                    Spacer()
                                    Button(preferences.connectingRAR ? "检查中…" : "连接引擎…", action: model.connectRAREngine).disabled(preferences.connectingRAR)
                                }
                                HStack {
                                    Text("RAR 解压已内置。官方压缩引擎可试用 40 天，之后需购买许可。")
                                    Link("官方下载", destination: URL(string: "https://www.rarlab.com/download.htm")!)
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        compressionSettings
                        VStack(alignment: .leading, spacing: 11) {
                            Toggle("排除 Mac 资源文件", isOn: $model.excludeMacResources)
                                .help(model.format == .dmg ? "排除 .DS_Store、._ AppleDouble 和 __MACOSX。真实资源分叉与扩展属性仍保留；关闭后独立 AppleDouble 文件按系统磁盘映像复制规则处理。" : "排除 .DS_Store、._ 开头的 AppleDouble 文件和 __MACOSX 文件夹。其他隐藏文件仍保留。")
                            Toggle("压缩后验证完整性", isOn: $model.verifyArchive)
                                .help("重新读取生成的压缩包，确认文件数据通过引擎校验。")
                            Toggle("分别压缩每个文件或文件夹", isOn: $model.separateArchives)
                                .help("每个选择的项目生成一个独立压缩包，共用当前设置。")
                        }.toggleStyle(.checkbox).padding(.horizontal, 4)
                    } else { extractionSettings }
                    dropArea
                    if !model.files.isEmpty { selectedFiles }
                    if let message = model.validationMessage, !model.files.isEmpty || !model.password.isEmpty || !model.volumeSize.isEmpty {
                        Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if model.mode == .extract, model.files.count == 1 {
                            Button("预览内容") { model.browserURL = model.files[0] }
                        }
                        Spacer()
                        Button(model.mode == .compress ? (model.separateArchives ? "分别压缩…" : model.format == .dmg ? "制作 DMG…" : "压缩…") : model.diskImagesOnly ? "在 Finder 打开" : "解压…", action: model.chooseDestination)
                            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: [.command])
                            .disabled(model.files.isEmpty || model.validationMessage != nil)
                    }
                    if !model.jobs.isEmpty {
                        Divider()
                        HStack {
                            Text("任务").font(.headline)
                            Text("最多同时处理 2 个任务").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("清除已结束", action: model.clearFinished).buttonStyle(.borderless)
                        }
                        LazyVStack(spacing: 10) { ForEach(model.jobs) { JobRow(job: $0, model: model) } }
                    }
                }.padding(22)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").accessibilityHidden(true)
                Text("所有文件仅在本机处理")
                Spacer()
                Text("LiteZip")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(preferences.appearance.colorScheme)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("操作", selection: $model.mode) { ForEach(AppModel.Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 136)
            }
            ToolbarItem {
                if model.mode == .compress {
                    Picker("压缩格式", selection: $model.format) { ForEach(ArchiveFormat.allCases.filter(\.canCreate)) { Text($0.title).tag($0) } }
                        .pickerStyle(.menu).labelsHidden().frame(width: 108).help("选择压缩格式")
                } else {
                    Button(action: model.chooseFiles) { Label("选择压缩包", systemImage: "plus") }
                }
            }
        }
        .onChange(of: model.format) { _ in model.formatChanged() }
        .sheet(item: Binding(get: { model.browserURL.map(BrowserSelection.init) }, set: { model.browserURL = $0?.url }), onDismiss: {
            if model.chooseDestinationAfterBrowser { model.chooseDestinationAfterBrowser = false; model.chooseDestination() }
        }) { selection in
            ArchiveBrowserView(url: selection.url, model: model)
        }
        .alert("无法完成操作", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }
    private var compressionSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("压缩方式：").foregroundStyle(.secondary)
                    Text(model.format == .tar ? "仅打包" : model.level.title).fontWeight(.medium)
                    Spacer()
                    Image(systemName: "archivebox").foregroundStyle(.tint).accessibilityHidden(true)
                }
                Slider(value: levelIndex, in: 0...Double(levels.count - 1), step: 1)
                    .disabled(model.format == .tar).accessibilityLabel("压缩等级").accessibilityValue(model.level.title)
                HStack {
                    ForEach(levels) { level in
                        Text(level.title).font(.caption).foregroundStyle(model.level == level && model.format != .tar ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: level == levels.first ? .leading : level == levels.last ? .trailing : .center)
                    }
                }
            }.padding(.bottom, 2)
            HStack(spacing: 10) {
                Text("分卷").frame(width: 44, alignment: .leading).foregroundStyle(.secondary)
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
            PasswordInput(label: "密码", placeholder: model.format.supportsPassword ? "可选" : "此格式不支持加密", text: $model.password, visible: $model.showPassword, showsVisibilityButton: true)
                .disabled(!model.format.supportsPassword)
            PasswordInput(label: "重复", placeholder: "再次输入密码", text: $model.passwordConfirmation, visible: $model.showPassword, showsVisibilityButton: false)
                .disabled(!model.format.supportsPassword || model.password.isEmpty)
            if model.format.supportsPassword {
                Label(model.format == .dmg ? "AES-256 磁盘映像加密 · 支持中文密码" : model.format == .zip ? "AES-256 加密 · 密码使用 1–99 个 ASCII 字符" : "AES-256 加密 · 同时加密文件名" + (model.format == .rar ? " · 密码最长 127 字符" : ""), systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if model.format.singleFileOnly {
                Text("每个压缩包包含一个普通文件；多个文件可分别压缩。").font(.caption).foregroundStyle(.secondary)
            }
            if model.format == .dmg {
                Text("保留文件权限、扩展属性与符号链接；完成后可在 Finder 挂载。存储等级生成只读映像。").font(.caption).foregroundStyle(.secondary)
            }
            if !model.volumeSize.isEmpty && model.format.supportsVolumes {
                Text(model.format == .rar ? "分卷保存到 .parts 文件夹，打开 .part1.rar 首卷（编号可能补零）。大小按 1 MB = 1024² 字节计算。" : "分卷保存到 .parts 文件夹。保留整组文件，打开 .001 解压。大小按 1 MB = 1024² 字节计算。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(20).background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.035)))
    }
    private var extractionSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(model.diskImagesOnly ? "磁盘映像" : "解压到独立文件夹", systemImage: model.diskImagesOnly ? "externaldrive" : "folder.badge.plus").font(.headline)
            Text(model.diskImagesOnly ? "可只读预览内容，或在 Finder 挂载以保留应用包与链接。加密映像挂载时由 macOS 询问密码。" : "同名结果自动编号。支持 .001、.z01、.partN.rar 和 .r00 分卷，请保留整组文件。").font(.callout).foregroundStyle(.secondary)
            PasswordInput(label: "密码", placeholder: model.diskImagesOnly ? "预览加密 DMG 时使用" : "加密压缩包可在这里输入密码", text: $model.password, visible: $model.showPassword, showsVisibilityButton: true)
        }.padding(20).background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.035)))
    }
    private var dropArea: some View {
        HStack(spacing: 14) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "square.and.arrow.down").font(.system(size: 26, weight: .light)).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(targeted ? "松开即可添加" : "拖入文件或文件夹").font(.callout.weight(.medium))
                Text("压缩包自动进入解压").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("选择…", action: model.chooseFiles).help("选择文件或文件夹（⌘O）")
        }.padding(18).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            let group = DispatchGroup(), collector = DropCollector()
            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collector.add(url) }
                    else if let url = item as? URL { collector.add(url) }
                }
            }
            group.notify(queue: .main) { model.receive(collector.urls) }
            return true
        }
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
            if model.hasMixedFiles { Text("文件与压缩包混合，可在标题栏选择操作。").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct PasswordInput: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @Binding var visible: Bool
    let showsVisibilityButton: Bool
    var body: some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 44, alignment: .leading).foregroundStyle(.secondary)
            Group {
                if visible { TextField(placeholder, text: $text) }
                else { SecureField(placeholder, text: $text) }
            }.textFieldStyle(.roundedBorder).accessibilityLabel(label == "重复" ? "确认密码" : "密码")
            if showsVisibilityButton {
                Button { visible.toggle() } label: { Image(systemName: visible ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless).help(visible ? "隐藏密码" : "显示密码").accessibilityLabel(visible ? "隐藏密码" : "显示密码")
            } else { Color.clear.frame(width: 18, height: 1).accessibilityHidden(true) }
        }
    }
}

private final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [URL]()
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values }
    func add(_ url: URL) { lock.lock(); values.append(url); lock.unlock() }
}
struct BrowserSelection: Identifiable {
    let url: URL
    var id: URL { url }
}

struct JobRow: View {
    @ObservedObject var job: ArchiveJob
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(job.title, systemImage: job.extracting ? "archivebox" : "archivebox.fill").font(.headline).lineLimit(1)
                Spacer()
                Text(job.state.rawValue).font(.caption).foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                if !job.state.isFinished { Button("取消") { model.cancel(job) } }
                if job.state == .failed || job.state == .cancelled { Button("重试") { model.retry(job) } }
                if let result = job.result { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([result]) } }
            }
            if job.state == .running {
                if let fraction = job.progress.fraction { ProgressView(value: min(1, max(0, fraction))) }
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
        }.padding(16).background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
