import SwiftUI
import LiteZipCore

struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $preferences.appearance) { ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) } }
            }
            Section("压缩") {
                Picker("默认格式", selection: $preferences.defaultFormat) { ForEach(ArchiveFormat.allCases.filter(\.canCreate)) { Text($0.title).tag($0) } }
                Picker("默认压缩等级", selection: $preferences.level) { ForEach(CompressionLevel.allCases.filter { $0 != .store || preferences.defaultFormat.supportsStore }) { Text($0.title).tag($0) } }
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
                    Text(preferences.rarURL == nil ? "尚未连接" : (preferences.rarVersion.isEmpty ? "已找到本机 rar" : preferences.rarVersion))
                    Spacer()
                    Button(preferences.connectingRAR ? "检查中…" : "选择 rar 文件…", action: AppModel.shared.connectRAREngine).disabled(preferences.connectingRAR)
                }
                if let url = preferences.rarURL {
                    Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                if !preferences.rarPath.isEmpty { Button("恢复自动查找") { preferences.rarPath = ""; preferences.rarVersion = ""; AppModel.shared.refreshRAREngine() } }
                Text("仅创建 RAR 需要官方引擎，解压已内置。官方引擎可试用 40 天，之后需要购买许可；LiteZip 不包含引擎或注册密钥。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("官方下载", destination: URL(string: "https://www.rarlab.com/download.htm")!)
                    Link("许可说明", destination: URL(string: "https://www.rarlab.com/license.htm")!)
                }
            }
            Section("Finder 集成") {
                Button("打开扩展设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { NSWorkspace.shared.open(url) }
                }
                Text("在系统设置的扩展中启用 LiteZip Finder，即可使用右键压缩和解压。").font(.caption).foregroundStyle(.secondary)
            }
            Section("关于") {
                Text("LiteZip 0.4.0 · 本地处理 · 无广告 · 无追踪")
                Link("开源代码", destination: URL(string: "https://github.com/gentpan/LiteZip")!)
                Text("内置 7-Zip 26.03（LGPL 与 unRAR 限制），详见应用包内 ThirdPartyNotices。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(width: 520, height: 670).preferredColorScheme(preferences.appearance.colorScheme)
            .onChange(of: preferences.defaultFormat) { format in if preferences.level == .store && !format.supportsStore { preferences.level = .normal } }
    }
}
