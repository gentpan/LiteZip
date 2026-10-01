import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LiteZipCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("文件，轻装出发。").font(.system(size: 28, weight: .semibold))
                            Text("压缩与解压，简单又安心。").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "archivebox.fill").font(.system(size: 32)).foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    dropArea
                    if !model.files.isEmpty { selection }
                    if !model.jobs.isEmpty {
                        HStack {
                            Text("任务").font(.headline)
                            Text("最多同时处理 2 个任务").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("清除已结束", action: model.clearFinished).buttonStyle(.borderless)
                        }
                        LazyVStack(spacing: 12) { ForEach(model.jobs) { JobRow(job: $0, model: model) } }
                    }
                }.padding(28)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").accessibilityHidden(true)
                Text("所有文件仅在本机处理").font(.caption)
                Spacer()
                Text("ZIP · 7Z · RAR · TAR · GZ · XZ · ZSTD").font(.caption2)
            }.foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(preferences.appearance.colorScheme)
        .toolbar {
            ToolbarItem { Button(action: model.chooseFiles) { Label("选择文件", systemImage: "plus") }.help("选择文件或文件夹（⌘O）") }
        }
        .sheet(item: Binding(get: { model.browserURL.map(BrowserSelection.init) }, set: { model.browserURL = $0?.url })) { selection in
            ArchiveBrowserView(url: selection.url, model: model)
        }
        .alert("无法完成操作", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }
    private var dropArea: some View {
        VStack(spacing: 14) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "square.and.arrow.down")
                .font(.system(size: 40, weight: .light)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(targeted ? "松开即可添加" : "把文件拖到这里").font(.title3.weight(.medium))
            Text("文件与文件夹自动进入压缩，压缩包自动进入解压").font(.callout).foregroundStyle(.secondary)
            Button("或选择文件…", action: model.chooseFiles).controlSize(.large)
        }
        .frame(maxWidth: .infinity).padding(.vertical, model.files.isEmpty ? 44 : 24)
        .background(RoundedRectangle(cornerRadius: 16).fill(targeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
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
    private var selection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("已选择 \(model.files.count) 个项目").font(.headline)
                Spacer()
                Button("清空") { model.files = []; model.password = "" }.buttonStyle(.borderless)
            }
            VStack(spacing: 8) {
                ForEach(Array(model.files.prefix(5)), id: \.self) { url in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ArchiveFormat.detect(url)?.title ?? (url.hasDirectoryPath ? "文件夹" : "文件")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.files.count > 5 { Text("另有 \(model.files.count - 5) 个项目").font(.caption).foregroundStyle(.secondary) }
            }
            if model.hasMixedFiles {
                Label("文件与压缩包混合，请选择要执行的操作。", systemImage: "info.circle").font(.callout)
            }
            Picker("操作", selection: $model.mode) { ForEach(AppModel.Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if model.mode == .compress {
                HStack(spacing: 24) {
                    Picker("格式", selection: $model.format) { ForEach(ArchiveFormat.allCases.filter(\.canCreate)) { Text($0.title).tag($0) } }
                    Picker("压缩等级", selection: $model.level) { ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) } }.disabled(model.format == .tar)
                }
                if model.format.singleFileOnly { Text("此格式仅压缩一个文件。多个项目可使用 ZIP、7Z 或 TAR.GZ。").font(.caption).foregroundStyle(.secondary) }
            }
            if model.mode == .extract || model.format.supportsPassword {
                SecureField("密码（可选）", text: $model.password).textFieldStyle(.roundedBorder)
                    .help("密码仅用于当前任务，不保存。ZIP 密码使用 AES-256，仅支持最多 99 个 ASCII 字符；中文密码请选择 7Z。")
            }
            HStack {
                if model.mode == .extract, model.files.count == 1 {
                    Button("预览内容") { model.browserURL = model.files[0] }
                }
                Spacer()
                Button(model.mode == .compress ? "压缩…" : "解压…", action: model.chooseDestination)
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.mode == .extract && model.files.contains { ArchiveFormat.detect($0) == nil })
            }
        }.padding(20).background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
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
