import SwiftUI
import UniformTypeIdentifiers
import LiteZipCore

struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject private var updates = UpdateController.shared
    @State private var defaultApps = [String: URL]()
    @State private var associationError: String?
    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $preferences.appearance) { ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("在菜单栏显示 LiteZip", isOn: $preferences.showsMenuBar)
                Toggle("在 Dock 中显示 LiteZip", isOn: $preferences.showsDockIcon).disabled(!preferences.showsMenuBar)
                Text("拖入文件或文件夹即可快捷压缩。启用后关闭主窗口仍会在菜单栏运行；隐藏 Dock 时仅菜单栏常驻，可从菜单栏弹窗打开主窗口。").font(.caption).foregroundStyle(.secondary)
            }
            Section("压缩") {
                Picker("默认格式", selection: $preferences.defaultFormat) { ForEach(ArchiveFormat.allCases.filter(\.offersCreation)) { Text($0.title).tag($0) } }
                Picker("默认压缩等级", selection: $preferences.level) { ForEach(CompressionLevel.allCases.filter { $0 != .store || preferences.defaultFormat.supportsStore }) { Text($0.title).tag($0) } }.disabled(!preferences.defaultFormat.supportsCompressionLevel)
            }
            Section("解压与任务") {
                Toggle("完成后在 Finder 中显示", isOn: $preferences.revealResult)
                Picker("展开大小上限", selection: $preferences.maximumGB) {
                    ForEach([10, 50, 100, 250, 500, 1000], id: \.self) { Text("\($0) GB").tag($0) }
                }
                Text("总是解压到独立文件夹。同名结果自动编号，避免覆盖。密码仅保留在当前任务的内存中。快捷压缩与 Finder 右键操作完成后不自动打开 Finder，结果可在任务记录或系统通知中查看，再按需定位。").font(.caption).foregroundStyle(.secondary)
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
                Text("仅创建 RAR 需要官方引擎，解压已内置。“下载官方引擎”会从 rarlab.com 获取 RARLAB 官方软件包，原样保存到 LiteZip 数据目录；已连接后“检测更新”会先比较版本，仅在官方版本更新时下载替换。RAR 可试用 40 天，之后需向 RARLAB 购买许可；LiteZip 不包含引擎或注册密钥。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("官方下载页", destination: URL(string: "https://www.rarlab.com/download.htm")!)
                    Link("许可说明", destination: URL(string: "https://www.rarlab.com/license.htm")!)
                }
            }
            Section("Finder 集成") {
                Button("打开扩展设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { NSWorkspace.shared.open(url) }
                }
                Text("在系统设置的扩展中启用 LiteZip Finder，即可使用右键压缩和解压。").font(.caption).foregroundStyle(.secondary)
            }
            Section("格式关联") {
                ForEach(FormatAssociation.all) { row in
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
                if let error = associationError { Text(error).font(.caption).foregroundStyle(.red) }
                Text("设置双击对应扩展名文件时默认打开的应用；选择 LiteZip 后压缩包会进入主窗口。更改写入系统 Launch Services 的默认设置，影响所有应用。").font(.caption).foregroundStyle(.secondary)
            }
            Section("更新") {
                Toggle("自动检查更新", isOn: $preferences.checksForUpdates)
                HStack {
                    Text(updates.lastChecked.map { "上次检查：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未检查")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(updates.checking ? "检查中…" : "立即检查") { updates.check(userInitiated: true) }.disabled(updates.checking)
                }
                Text("每天最多查询一次 GitHub 上发布的版本，只读取公开的版本信息，不发送任何个人数据。").font(.caption).foregroundStyle(.secondary)
            }
            Section("关于") {
                Text("LiteZip \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · 本地处理 · 无广告 · 无追踪")
                Link("开源代码", destination: URL(string: "https://github.com/gentpan/LiteZip")!)
                Text("内置 7-Zip 26.05（LGPL 与 unRAR 限制），详见应用包内 ThirdPartyNotices。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(width: 520, height: 670).preferredColorScheme(preferences.appearance.colorScheme)
            .onChange(of: preferences.defaultFormat) { format in if preferences.level == .store && !format.supportsStore { preferences.level = .normal } }
            .onAppear(perform: reloadAssociations)
    }
    /// The managed package keeps its binary one level down; the full path repeats "rar/rar".
    private func rarDisplayPath(_ url: URL) -> String {
        let managed = RAREngine.managedDirectory.path
        return url.path.hasPrefix(managed + "/") ? managed : url.deletingLastPathComponent().path
    }
    private func reloadAssociations() {
        var values = [String: URL]()
        for row in FormatAssociation.all { values[row.extensionName] = NSWorkspace.shared.urlForApplication(toOpen: row.type) }
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

private struct FormatAssociation: Identifiable {
    let extensionName: String
    let type: UTType
    var id: String { extensionName }
    static let all: [FormatAssociation] = ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "zst", "lz", "lz4", "br", "lrz", "aar", "sz", "wim", "cab", "cpio", "lzh", "lzma", "lzo"]
        .compactMap { ext in UTType(filenameExtension: ext).map { FormatAssociation(extensionName: ext, type: $0) } }
}
