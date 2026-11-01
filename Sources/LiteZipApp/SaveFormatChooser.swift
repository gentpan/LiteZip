import AppKit
import LiteZipCore

/// Format popup for the quick compress save panel: every creatable format by family, with
/// the formats that cannot take the current selection disabled.
@MainActor
final class SaveFormatChooser: NSObject {
    let view: NSView
    private(set) var selected: ArchiveFormat
    var onChange: ((_ old: ArchiveFormat, _ new: ArchiveFormat) -> Void)?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(selected: ArchiveFormat, isAvailable: (ArchiveFormat) -> Bool) {
        self.selected = selected
        let label = NSTextField(labelWithString: "格式：")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view = stack
        super.init()

        let menu = NSMenu()
        for (index, group) in ArchiveFormat.groupedFormats.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            if #available(macOS 14.0, *) { menu.addItem(.sectionHeader(title: group.title)) }
            else {
                let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            for format in group.formats {
                let item = NSMenuItem(title: format.title, action: nil, keyEquivalent: "")
                item.representedObject = format.rawValue
                item.isEnabled = isAvailable(format)
                item.toolTip = format.menuSummary
                menu.addItem(item)
            }
        }
        popup.autoenablesItems = false
        popup.menu = menu
        popup.select(menu.items.first { $0.representedObject as? String == selected.rawValue })
        popup.target = self
        popup.action = #selector(changed)
        stack.setFrameSize(stack.fittingSize)
    }

    @objc private func changed() {
        guard let raw = popup.selectedItem?.representedObject as? String,
              let format = ArchiveFormat(rawValue: raw), format != selected else { return }
        let old = selected
        selected = format
        onChange?(old, format)
    }
}
