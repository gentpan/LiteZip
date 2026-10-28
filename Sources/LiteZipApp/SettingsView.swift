import SwiftUI
import LiteZipCore

struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject private var updates = UpdateController.shared
    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $preferences.appearance) { ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("在菜单栏显示 LiteZip", isOn: $preferences.showsMenuBar)
                Text("拖入文件或文件夹即可快捷压缩。启用后关闭主窗口仍会在菜单栏运行。").font(.caption).foregroundStyle(.secondary)
            }
            Section("压缩") {
                Picker("默认格式", selection: $preferences.defaultFormat) { ForEach(ArchiveFormat.allCases.filter(\.canCreate)) { Text($0.title).tag($0) } }
                Picker("默认压缩等级", selection: $preferences.level) { ForEach(CompressionLevel.allCases.filter { $0 != .store || preferences.defaultFormat.supportsStore }) { Text($0.title).tag($0) } }.disabled(!preferences.defaultFormat.supportsCompressionLevel)
            }
            Section("解压与任务") {
                Toggle("完成后在 Finder 中显示", isOn: $preferences.revealResult)
                Picker("展开大小上限", selection: $preferences.maximumGB) {
                    ForEach([10, 50, 100, 250, 500, 1000], id: \.self) { Text("\($0) GB").tag($0) }
                }
                Text("总是解压到独立文件夹。同名结果自动编号，避免覆盖。密码仅保留在当前任务的内存中。").font(.caption).foregroundStyle(.secondary)
            }
            Section("RAR 压缩引擎") {
                HStack {
                    Text(preferences.rarURL == nil ? "尚未连接" : (preferences.rarVersion.isEmpty ? "已找到本机 RAR 引擎" : preferences.rarVersion))
                    Spacer()
                    Button(preferences.downloadingRAR ? "下载中…" : preferences.rarURL == nil ? "下载官方引擎" : "重新下载") { AppModel.shared.downloadRAREngine() }
                        .disabled(preferences.downloadingRAR || preferences.connectingRAR)
                    Button(preferences.connectingRAR ? "检查中…" : "选择 RAR 程序…", action: AppModel.shared.connectRAREngine)
                        .disabled(preferences.downloadingRAR || preferences.connectingRAR)
                }
                if let url = preferences.rarURL {
                    Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                if !preferences.rarPath.isEmpty { Button("恢复自动查找") { preferences.rarPath = ""; preferences.rarVersion = ""; AppModel.shared.refreshRAREngine() } }
                Text("仅创建 RAR 需要官方引擎，解压已内置。“下载官方引擎”会从 rarlab.com 获取 RARLAB 官方软件包，原样保存到 LiteZip 数据目录。RAR 可试用 40 天，之后需向 RARLAB 购买许可；LiteZip 不包含引擎或注册密钥。").font(.caption).foregroundStyle(.secondary)
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
                Text("内置 7-Zip 26.03（LGPL 与 unRAR 限制），详见应用包内 ThirdPartyNotices。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(width: 520, height: 670).preferredColorScheme(preferences.appearance.colorScheme)
            .onChange(of: preferences.defaultFormat) { format in if preferences.level == .store && !format.supportsStore { preferences.level = .normal } }
    }
}
