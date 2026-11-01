import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import LiteZipCore

// The five pages of the settings window (see SettingsWindowController). Each page takes
// its content height, so nothing is cut off and no scroll bar is needed.

struct GeneralSettings: View {
    @ObservedObject var preferences: AppPreferences
    @StateObject private var login = LoginItem()
    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $preferences.appearance) { ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) } }
            }
            Section("显示位置") {
                Toggle("在菜单栏显示 LiteZip", isOn: $preferences.showsMenuBar)
                Toggle("在 Dock 中显示 LiteZip", isOn: $preferences.showsDockIcon).disabled(!preferences.showsMenuBar)
                Toggle("登录时自动启动", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                if login.needsApproval {
                    HStack {
                        Text("需要在系统设置的“登录项”中允许 LiteZip。").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("打开登录项") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = login.error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("隐藏 Dock 时仅菜单栏常驻，可从菜单栏弹窗打开主窗口；关闭菜单栏图标时会显示 Dock 图标，避免找不到 LiteZip。").font(.caption).foregroundStyle(.secondary)
            }
            Section("Finder 右键菜单") {
                LabeledContent("LiteZip Finder 扩展") {
                    Button("打开扩展设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { NSWorkspace.shared.open(url) }
                    }
                }
                Text("在系统设置的扩展中启用后，即可在 Finder 中右键压缩和解压。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).scrollIndicators(.never).frame(width: 500).fixedSize(horizontal: false, vertical: true)
        .onAppear { login.refresh() }
    }
}

struct CompressionSettings: View {
    @ObservedObject var preferences: AppPreferences
    var body: some View {
        Form {
            Section("默认设置") {
                Picker("默认格式", selection: $preferences.defaultFormat) { ForEach(ArchiveFormat.allCases.filter(\.offersCreation)) { Text($0.title).tag($0) } }
                Picker("默认压缩等级", selection: $preferences.level) { ForEach(CompressionLevel.allCases.filter { $0 != .store || preferences.defaultFormat.supportsStore }) { Text($0.title).tag($0) } }.disabled(!preferences.defaultFormat.supportsCompressionLevel)
                Toggle("排除 Mac 资源文件", isOn: $preferences.defaultExcludeMacResources)
                    .help("排除 .DS_Store、._ 开头的 AppleDouble 文件和 __MACOSX 文件夹。")
                Toggle("压缩后验证完整性", isOn: $preferences.defaultVerifyArchive)
                Text("主窗口和快捷压缩都从这些默认值开始；主窗口选项面板里的修改只影响本次使用。").font(.caption).foregroundStyle(.secondary)
            }
            Section("菜单栏快捷压缩") {
                Picker("保存到", selection: $preferences.menuBarAskDestination) {
                    Text("原文件所在文件夹").tag(false)
                    Text("每次询问").tag(true)
                }
                Text(preferences.menuBarAskDestination ? "每次弹出保存框，可修改文件名、位置和格式。" : "拖入即压缩到原文件旁边，同名结果自动编号，不弹出窗口。").font(.caption).foregroundStyle(.secondary)
            }
            Section("RAR 压缩引擎") {
                HStack {
                    Text(preferences.rarURL == nil ? "尚未连接" : (preferences.rarVersion.isEmpty ? "已找到本机 RAR 引擎" : preferences.rarVersion))
                    Spacer()
                    if preferences.rarURL == nil {
                        Button(preferences.downloadingRAR ? "下载中…" : "下载官方引擎") { AppModel.shared.downloadRAREngine() }
                            .disabled(preferences.downloadingRAR || preferences.connectingRAR)
                    } else {
                        Button(preferences.downloadingRAR ? "检测中…" : "检测更新") { AppModel.shared.checkRAREngineUpdate() }
                            .disabled(preferences.downloadingRAR || preferences.connectingRAR)
                            .help("查询 rarlab.com 上的最新官方版本，如有更新则下载并替换")
                    }
                    Button(preferences.connectingRAR ? "检查中…" : "选择 RAR 程序…", action: AppModel.shared.connectRAREngine)
                        .disabled(preferences.downloadingRAR || preferences.connectingRAR)
                }
                if let url = preferences.rarURL {
                    Text(rarDisplayPath(url)).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                if !preferences.rarPath.isEmpty { Button("恢复自动查找") { preferences.rarPath = ""; preferences.rarVersion = ""; AppModel.shared.refreshRAREngine() } }
                Text("解压 RAR 无需引擎。创建 RAR 需要 RARLAB 官方引擎，可试用 40 天，之后需向 RARLAB 购买许可；LiteZip 不包含引擎或注册密钥。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("官方下载页", destination: URL(string: "https://www.rarlab.com/download.htm")!)
                    Link("许可说明", destination: URL(string: "https://www.rarlab.com/license.htm")!)
                }
            }
        }
        .formStyle(.grouped).scrollIndicators(.never).frame(width: 500).fixedSize(horizontal: false, vertical: true)
        .onChange(of: preferences.defaultFormat) { format in if preferences.level == .store && !format.supportsStore { preferences.level = .normal } }
        .onChange(of: preferences.defaultExcludeMacResources) { AppModel.shared.excludeMacResources = $0 }
        .onChange(of: preferences.defaultVerifyArchive) { AppModel.shared.verifyArchive = $0 }
    }
    /// The managed package keeps its binary one level down; the full path repeats "rar/rar".
    private func rarDisplayPath(_ url: URL) -> String {
        let managed = RAREngine.managedDirectory.path
        return url.path.hasPrefix(managed + "/") ? managed : url.deletingLastPathComponent().path
    }
}

struct ExtractionSettings: View {
    @ObservedObject var preferences: AppPreferences
    var body: some View {
        Form {
            Section("解压") {
                Toggle("完成后在 Finder 中显示", isOn: $preferences.revealResult)
                Picker("展开大小上限", selection: $preferences.maximumGB) {
                    ForEach([10, 50, 100, 250, 500, 1000], id: \.self) { Text("\($0) GB").tag($0) }
                }
                Text("总是解压到独立文件夹，同名结果自动编号，不覆盖已有文件。密码仅保留在当前任务的内存中。快捷压缩与 Finder 右键操作完成后不自动打开 Finder，结果可在任务记录或系统通知中查看。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).scrollIndicators(.never).frame(width: 500).fixedSize(horizontal: false, vertical: true)
    }
}

struct AssociationSettings: View {
    @State private var defaultApps = [String: URL]()
    @State private var associationError: String?
    var body: some View {
        Form {
            Section("双击打开压缩包时使用的应用") {
                ForEach(FormatAssociation.common) { row in associationRow(row) }
                DisclosureGroup("其余 \(FormatAssociation.others.count) 种格式") {
                    ForEach(FormatAssociation.others) { row in associationRow(row) }
                }
                if let error = associationError { Text(error).font(.caption).foregroundStyle(.red) }
                Text("选择 LiteZip 后，双击压缩包会直接解压到旁边的独立文件夹。更改写入系统的默认打开方式，影响所有应用。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).scrollIndicators(.never).frame(width: 500).fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: reloadAssociations)
    }
    private func associationRow(_ row: FormatAssociation) -> some View {
        HStack {
            Text("." + row.extensionName).font(.callout.monospaced()).frame(width: 56, alignment: .leading)
            Text(defaultApps[row.extensionName].map { $0.deletingPathExtension().lastPathComponent } ?? "未关联")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Menu("更改") {
                Button("LiteZip") { setAssociation(row, to: Bundle.main.bundleURL) }
                Button("其他应用…") { chooseApplication(for: row) }
            }.fixedSize()
        }
    }
    private func reloadAssociations() {
        var values = [String: URL]()
        for row in FormatAssociation.common + FormatAssociation.others { values[row.extensionName] = NSWorkspace.shared.urlForApplication(toOpen: row.type) }
        defaultApps = values
    }
    private func setAssociation(_ row: FormatAssociation, to app: URL) {
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: row.type) { error in
            Task { @MainActor in
                if let error { associationError = "无法设置 .\(row.extensionName) 的默认应用：\(error.localizedDescription)" }
                reloadAssociations()
            }
        }
    }
    private func chooseApplication(for row: FormatAssociation) {
        let panel = NSOpenPanel()
        panel.title = "选择打开 .\(row.extensionName) 的应用"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { setAssociation(row, to: url) }
    }
}

/// About the app itself; engine and licence details live on the website and GitHub (the
/// licence texts still ship inside the app bundle).
struct AboutSettings: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject private var updates = UpdateController.shared
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LiteZip").font(.title2.weight(.semibold))
                        Text("版本 \(updates.currentVersion)").foregroundStyle(.secondary)
                        Text("轻巧的 Mac 压缩工具 · 本地处理 · 无广告 · 无追踪").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("更新") {
                if let release = updates.availableRelease {
                    HStack {
                        Text("LiteZip \(release.version) 已发布").foregroundStyle(.green)
                        Spacer()
                        Button("更新") { updates.presentAvailableUpdate() }
                    }
                }
                Toggle("自动检查更新", isOn: $preferences.checksForUpdates)
                HStack {
                    Text(updates.lastChecked.map { "上次检查：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未检查")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(updates.checking ? "检查中…" : "立即检查") { updates.check(userInitiated: true) }.disabled(updates.checking)
                }
            }
            Section {
                Link("官网", destination: URL(string: "https://litezip.app/")!)
                Link("GitHub 开源代码", destination: URL(string: "https://github.com/gentpan/LiteZip")!)
                Link("反馈问题", destination: URL(string: "https://litezip.app/feedback/")!)
            }
        }
        .formStyle(.grouped).scrollIndicators(.never).frame(width: 500).fixedSize(horizontal: false, vertical: true)
    }
}

/// "Open at login" through the system's login items, which also lists LiteZip there.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }
    func refresh() { status = SMAppService.mainApp.status }
    func set(_ on: Bool) {
        error = nil
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { self.error = "无法更改登录启动：\(error.localizedDescription)" }
        refresh()
    }
}

private struct FormatAssociation: Identifiable {
    let extensionName: String
    let type: UTType
    var id: String { extensionName }
    private static func rows(_ extensions: [String]) -> [FormatAssociation] {
        extensions.compactMap { ext in UTType(filenameExtension: ext).map { FormatAssociation(extensionName: ext, type: $0) } }
    }
    /// Shown directly; the rest fold away so the page stays short.
    static let common = rows(["zip", "7z", "rar", "gz"])
    static let others = rows(["tar", "bz2", "xz", "zst", "lz", "lz4", "br", "lrz", "aar", "sz", "wim", "cab", "cpio", "lzh", "lzma", "lzo"])
}
