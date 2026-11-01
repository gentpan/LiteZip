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
    /// Turns the ring while no unfinished job has reported a size yet.
    private var spinner: Timer?
    private var spinPhase = 0.0

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
        model.onQuickFormatChange = { [weak self] format in self?.state.format = format }
        // Progress arrives many times a second; the ring only needs a few redraws.
        model.$jobs.map { jobs in
            Publishers.MergeMany(jobs.map { job in
                job.$state.map { _ in () }.merge(with: job.$progress.map { _ in () }).eraseToAnyPublisher()
            })
        }.switchToLatest()
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateStatus() }
            }.store(in: &subscriptions)
    }

    private func setVisible(_ visible: Bool) {
        if !visible {
            popover.performClose(nil)
            setSpinning(false)
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }
        button.target = self; button.action = #selector(togglePopover)
        button.image = StatusItemIcon.logo
        button.imageScaling = .scaleNone
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

    /// Idle: the logo. Busy: a ring with the average progress of all unfinished jobs
    /// (waiting ones count as zero) and, for more than one job, their number.
    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let active = model.jobs.filter { !$0.state.isFinished }
        guard !active.isEmpty else {
            setSpinning(false)
            button.image = StatusItemIcon.logo
            button.toolTip = "LiteZip · 拖入文件或文件夹以压缩"
            return
        }
        let fractions = active.map { $0.state == .running ? $0.progress.fraction : 0 }
        let known = fractions.contains { $0 != nil }
        let overall = known ? fractions.reduce(0) { $0 + ($1 ?? 0) } / Double(active.count) : nil
        setSpinning(overall == nil)
        button.image = StatusItemIcon.ring(fraction: overall, phase: spinPhase, count: active.count)
        let percent = overall.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
        button.toolTip = "LiteZip · \(active.count) 个任务正在处理" + percent
    }

    private func setSpinning(_ spinning: Bool) {
        guard spinning != (spinner != nil) else { return }
        spinner?.invalidate()
        spinner = nil
        guard spinning else { return }
        spinner = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                spinPhase = (spinPhase + 1.0 / 14).truncatingRemainder(dividingBy: 1)
                updateStatus()
            }
        }
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
    @ObservedObject private var updates = UpdateController.shared
    @State private var targeted = false
    @State private var hoveringDrop = false
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
                .lineLimit(1)
                Spacer(minLength: 6)
                VersionCapsule(version: updates.currentVersion, available: updates.availableRelease?.version,
                               checking: updates.checking, action: versionTapped)
            }
            // One target for both ways in: drop onto it, or click it to choose files, folders
            // or archives. The whole popover still accepts drops.
            Button(action: chooseFiles) {
                VStack(spacing: 5) {
                    Image(systemName: targeted ? "arrow.down.circle.fill" : "arrow.up.doc")
                        .font(.system(size: 22, weight: .light)).foregroundStyle(.tint).accessibilityHidden(true)
                    Text(targeted ? "松开即可压缩" : "拖入或点击选择文件、文件夹").font(.callout.weight(.medium))
                    Text("选择压缩包即解压；也可以直接拖到菜单栏图标上").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).frame(height: 78)
                .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.10) : hoveringDrop ? Color.accentColor.opacity(0.05) : Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted || hoveringDrop ? Color.accentColor : Color.secondary.opacity(0.28), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .onHover { hoveringDrop = $0 }
            .help("点击选择文件、文件夹或压缩包")
            .accessibilityLabel("选择文件、文件夹或压缩包")
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text("压缩格式").font(.callout)
                    Spacer()
                    formatMenu
                }
            }
            Text((preferences.menuBarAskDestination ? "松开后选择保存位置" : "拖入即压缩到原文件旁边，同名自动编号") + "；使用默认压缩等级，不加密。可在设置中更改。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                .scrollIndicators(.never)
                .frame(maxHeight: 180)
            }
            Divider()
            HStack(spacing: 14) {
                UsageBadges(bytesSaved: preferences.totalBytesSaved, count: preferences.compressCount)
                Spacer(minLength: 0)
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

    /// Green capsule: offer the known release. Otherwise: check now. Like Settings below,
    /// the alert waits for the transient popover to close first.
    private func versionTapped() {
        close()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if UpdateController.shared.availableRelease != nil { UpdateController.shared.presentAvailableUpdate() }
            else { UpdateController.shared.check(userInitiated: true) }
        }
    }

    /// The transient popover's dismissal swallows a Settings window opened in the same
    /// run-loop pass, so raise it on the next turn after the popover is gone.
    private func openSettings() {
        close()
        DispatchQueue.main.async { SettingsWindowController.shared.show() }
    }

    private var formatMenu: some View {
        // The popover has no options panel to open, so its menu lists every creatable format.
        Menu {
            Picker("压缩格式", selection: $state.format) {
                ForEach(ArchiveFormat.groupedFormats, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.formats, id: \.self) { format in
                            Text(format.title).tag(format).accessibilityLabel(format.title + "，" + format.menuSummary)
                        }
                    }
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
                    FormatBadge(format: format, size: 8.5)
                }
                Text(job.title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(job.state.rawValue).foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
            }.font(.caption)
            if job.state == .running {
                if let fraction = job.progress.fraction { SegmentedProgress(fraction: fraction, height: 15) }
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
