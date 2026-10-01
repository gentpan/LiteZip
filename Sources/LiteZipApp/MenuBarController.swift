import AppKit
import SwiftUI
import Combine
import LiteZipCore

@MainActor
final class MenuBarState: ObservableObject {
    @Published var format: ArchiveFormat
    @Published var errorMessage: String?
    init(format: ArchiveFormat) { self.format = format }
}

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let state: MenuBarState
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        state = MenuBarState(format: model.preferences.defaultFormat)
        super.init()
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: MenuBarView(
            model: model, preferences: model.preferences, state: state,
            chooseFiles: { [weak self] in self?.chooseFiles() },
            close: { [weak self] in self?.popover.performClose(nil) }))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize
        model.preferences.$showsMenuBar.sink { [weak self] visible in self?.setVisible(visible) }.store(in: &subscriptions)
        model.$jobs.map { jobs in
            Publishers.MergeMany(jobs.map { $0.$state.map { _ in () }.eraseToAnyPublisher() })
        }.switchToLatest().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatus() }
        }.store(in: &subscriptions)
    }

    private func setVisible(_ visible: Bool) {
        if !visible {
            popover.performClose(nil)
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }
        button.target = self; button.action = #selector(togglePopover)
        button.image = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: "LiteZip 快捷压缩")
        button.image?.isTemplate = true
        button.setAccessibilityLabel("LiteZip 快捷压缩")
        let target = StatusItemDropTarget(frame: button.bounds)
        target.autoresizingMask = [.width, .height]
        target.statusButton = button
        target.onDrop = { [weak self] urls in
            // Return from the drag session before activating a save panel.
            Task { @MainActor [weak self] in self?.compress(urls) }
        }
        button.addSubview(target)
        updateStatus()
    }

    private func updateStatus() {
        let count = model.jobs.filter { !$0.state.isFinished }.count
        statusItem?.button?.toolTip = count > 0 ? "LiteZip · \(count) 个任务正在处理" : "LiteZip · 拖入文件或文件夹以压缩"
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showError(_ message: String) {
        state.errorMessage = message
        if !popover.isShown { togglePopover() }
    }

    private func compress(_ urls: [URL]) {
        popover.performClose(nil); state.errorMessage = nil
        model.quickCompress(urls, format: state.format) { [weak self] in self?.showError($0) }
    }

    private func chooseFiles() {
        popover.performClose(nil); state.errorMessage = nil
        model.chooseQuickCompressionFiles(format: state.format) { [weak self] in self?.showError($0) }
    }
}

private struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var state: MenuBarState
    @Environment(\.openWindow) private var openWindow
    let chooseFiles: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LiteZip").font(.headline)
                    Text("菜单栏快捷压缩").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Label("拖入文件或文件夹到菜单栏图标", systemImage: "arrow.up.doc")
                .font(.callout)
            Picker("压缩格式", selection: $state.format) {
                ForEach(ArchiveFormat.allCases.filter(\.canCreate)) { format in
                    Label { Text(format.title + " · " + format.menuSummary) } icon: { Image(nsImage: format.menuBadge) }
                        .tag(format).accessibilityLabel(format.title + "，" + format.menuSummary)
                }
            }
            Toggle("每次选择保存位置", isOn: $preferences.menuBarAskDestination).toggleStyle(.checkbox)
            Text(preferences.menuBarAskDestination ? "使用默认压缩等级，不加密；松开后选择保存位置。" : "拖入即压缩到原目录，同名自动编号。使用默认压缩等级，不加密。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: chooseFiles) { Label("选择文件并压缩…", systemImage: "plus") }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            if let message = state.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !model.jobs.isEmpty {
                Divider()
                Text("最近任务").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(model.jobs.prefix(3))) { job in MenuBarJobRow(job: job, model: model) }
            }
            Divider()
            HStack {
                Button("打开主窗口") {
                    if let open = model.openMainWindow { open() } else { openWindow(id: "main") }
                    NSApp.activate(ignoringOtherApps: true); close()
                }
                Spacer()
                Button("退出") { close(); NSApp.terminate(nil) }
            }.buttonStyle(.borderless)
        }
        .padding(18).frame(width: 320)
        .preferredColorScheme(preferences.appearance.colorScheme)
    }
}

private struct MenuBarJobRow: View {
    @ObservedObject var job: ArchiveJob
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(job.title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(job.state.rawValue).foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
            }.font(.caption)
            if job.state == .running {
                if let fraction = job.progress.fraction { ProgressView(value: min(1, max(0, fraction))) }
                else { ProgressView().controlSize(.small) }
            }
            if let error = job.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
            HStack {
                if let result = job.result {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                }
                if !job.state.isFinished { Button("取消") { model.cancel(job) } }
            }.font(.caption).buttonStyle(.borderless)
        }
    }
}
