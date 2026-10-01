import SwiftUI
import LiteZipCore

struct ArchiveBrowserView: View {
    let url: URL
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries = [ArchiveEntry]()
    @State private var search = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @State private var control = OperationControl()
    var filtered: [ArchiveEntry] { search.isEmpty ? entries : entries.filter { $0.path.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(url.lastPathComponent, systemImage: "archivebox").font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.escape, modifiers: [])
            }
            HStack {
                SecureField("密码（如果需要）", text: $password).textFieldStyle(.roundedBorder)
                Button("读取目录") { load(test: false) }.disabled(busy)
                Button("校验完整性") { load(test: true) }.disabled(busy)
            }
            TextField("搜索文件名", text: $search).textFieldStyle(.roundedBorder)
            if busy { HStack { ProgressView().controlSize(.small); Text("正在读取…"); Spacer(); Button("取消") { control.cancel() } } }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            Table(filtered) {
                TableColumn("文件") { entry in Label(entry.path, systemImage: entry.isSymbolicLink ? "link" : entry.isDirectory ? "folder" : "doc").lineLimit(1).help(entry.path) }
                TableColumn("大小") { entry in Text(entry.isDirectory || entry.isSymbolicLink ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).monospacedDigit() }.width(100)
                TableColumn("加密") { entry in Text(entry.encrypted ? "是" : "—") }.width(45)
            }
            HStack {
                Text("\(entries.count) 个项目 · \(ByteCountFormatter.string(fromByteCount: entries.reduce(0) { $0 + $1.size }, countStyle: .file))").foregroundStyle(.secondary)
                Spacer()
                Button(ArchiveFormat.detect(url) == .dmg ? "在 Finder 打开" : "解压…") {
                    if ArchiveFormat.detect(url) == .dmg { model.openDiskImage(url); dismiss(); return }
                    model.receive([url]); model.mode = .extract; model.password = password
                    model.chooseDestinationAfterBrowser = true; dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 720, height: 520)
        .onAppear { password = model.password; load(test: false) }
        .onDisappear { control.cancel(); password = "" }
    }
    private func load(test: Bool) {
        guard !busy else { return }
        busy = true; message = nil; control = OperationControl()
        let service = model.service, operation = control, secret = password.isEmpty ? nil : password
        Task {
            do {
                if test { try await service.test(archive: url, password: secret, control: operation); message = "校验通过，未发现数据损坏。" }
                else { entries = try await service.list(archive: url, password: secret, control: operation) }
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}
