import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
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
            drop: { [weak self] urls in self?.handle(urls) },
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
            Task { @MainActor [weak self] in self?.handle(urls) }
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

    private func handle(_ urls: [URL]) {
        popover.performClose(nil); state.errorMessage = nil
        model.quickHandle(urls, format: state.format) { [weak self] in self?.showError($0) }
    }

    private func chooseFiles() {
        popover.performClose(nil); state.errorMessage = nil
        model.chooseQuickFiles(format: state.format) { [weak self] in self?.showError($0) }
    }
}

private struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var state: MenuBarState
    @State private var targeted = false
    let chooseFiles: () -> Void
    let drop: ([URL]) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LiteZip").font(.headline)
                    Text("菜单栏快捷压缩").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                usageCapsule
            }
            VStack(spacing: 5) {
                Image(systemName: targeted ? "arrow.down.circle.fill" : "arrow.up.doc")
                    .font(.system(size: 22, weight: .light)).foregroundStyle(.tint).accessibilityHidden(true)
                Text(targeted ? "松开即可压缩" : "拖入文件或文件夹").font(.callout.weight(.medium))
                Text("也可以直接拖到菜单栏图标上").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 78)
            .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.28), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])))
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text("压缩格式").font(.callout)
                    Spacer()
                    formatMenu
                }
                HStack(spacing: 10) {
                    Text("每次选择保存位置").font(.callout)
                    Spacer()
                    Toggle("每次选择保存位置", isOn: $preferences.menuBarAskDestination)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            Text(preferences.menuBarAskDestination ? "松开后选择保存位置；使用默认压缩等级，不加密。" : "拖入即压缩到原目录，同名自动编号；使用默认压缩等级，不加密。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: chooseFiles) {
                Label("选择文件或压缩包…", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            if let message = state.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !model.jobs.isEmpty {
                Divider()
                HStack {
                    Text("任务").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清除已结束", action: model.clearFinished).buttonStyle(.borderless).font(.caption)
                }
                ScrollView {
                    LazyVStack(spacing: 8) { ForEach(model.jobs) { job in MenuBarJobRow(job: job, model: model) } }
                }
                .frame(maxHeight: 180)
            }
            Divider()
            HStack(spacing: 14) {
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("设置")
                .accessibilityLabel("设置")
                Button {
                    close(); NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("退出")
                .accessibilityLabel("退出")
            }
        }
        .padding(16).frame(width: 320)
        // Opaque panel: a translucent popover reads as a grey-to-white gradient over a
        // mixed desktop background.
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            collectDroppedURLs(providers) { urls in
                targeted = false
                drop(urls)
            }
            return true
        }
        .preferredColorScheme(preferences.appearance.colorScheme)
    }

    /// The transient popover's dismissal swallows a Settings window opened in the same
    /// run-loop pass, so raise it on the next turn after the popover is gone.
    private func openSettings() {
        close()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }

    /// Lifetime usage in the header's spare top-right space: bytes saved and compressions.
    private var usageCapsule: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down.doc").font(.system(size: 9, weight: .semibold))
            Text(ByteCountFormatter.string(fromByteCount: preferences.totalBytesSaved, countStyle: .file))
            Text("·")
            Text("\(preferences.compressCount) 次")
        }
        .font(.caption2.weight(.medium)).monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .accessibilityLabel("累计节省 \(ByteCountFormatter.string(fromByteCount: preferences.totalBytesSaved, countStyle: .file))，压缩 \(preferences.compressCount) 次")
    }

    private var formatMenu: some View {
        Menu {
            Picker("压缩格式", selection: $state.format) {
                ForEach(ArchiveFormat.commonFormats, id: \.self) { format in
                    Text(format.title).tag(format).accessibilityLabel(format.title)
                }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Text(state.format.title).font(.callout.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("压缩格式：" + state.format.title)
    }
}

private struct MenuBarJobRow: View {
    @ObservedObject var job: ArchiveJob
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let format = job.badgeFormat {
                    Image(nsImage: format.menuBadge).resizable().scaledToFit().frame(width: 40, height: 13).accessibilityHidden(true)
                }
                Text(job.title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(job.state.rawValue).foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
            }.font(.caption)
            if job.state == .running {
                if let fraction = job.progress.fraction { SegmentedProgress(fraction: fraction, height: 6, ticks: 24) }
                else { ProgressView().controlSize(.small) }
            } else if let error = job.error {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
            }
        }
        .contextMenu {
            if let result = job.result { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([result]) } }
            if !job.state.isFinished { Button("取消") { model.cancel(job) } }
            if job.state == .failed || job.state == .cancelled { Button("重试") { model.retry(job) } }
        }
    }
}
