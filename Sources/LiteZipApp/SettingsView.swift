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
                Picker("默认压缩等级", selection: $preferences.level) { ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) } }
            }
            Section("解压与任务") {
                Toggle("完成后在 Finder 中显示", isOn: $preferences.revealResult)
                Picker("展开大小上限", selection: $preferences.maximumGB) {
                    ForEach([10, 50, 100, 250, 500, 1000], id: \.self) { Text("\($0) GB").tag($0) }
                }
                Text("总是解压到独立文件夹。同名结果自动编号，避免覆盖。密码仅保留在当前任务的内存中。").font(.caption).foregroundStyle(.secondary)
            }
            Section("Finder 集成") {
                Button("打开扩展设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { NSWorkspace.shared.open(url) }
                }
                Text("在系统设置的扩展中启用 LiteZip Finder，即可使用右键压缩和解压。").font(.caption).foregroundStyle(.secondary)
            }
            Section("关于") {
                Text("LiteZip 0.1.0 · 本地处理 · 无广告 · 无追踪")
                Link("开源代码", destination: URL(string: "https://github.com/gentpan/LiteZip")!)
                Text("内置 7-Zip 26.03（LGPL 与 unRAR 限制），详见应用包内 ThirdPartyNotices。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(width: 480, height: 540).preferredColorScheme(preferences.appearance.colorScheme)
    }
}
