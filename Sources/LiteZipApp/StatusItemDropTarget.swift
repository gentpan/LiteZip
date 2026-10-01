import AppKit

/// A transparent destination over the native status button. The button still
/// draws its system highlight and handles clicks and Command-drag positioning.
@MainActor
final class StatusItemDropTarget: NSView {
    weak var statusButton: NSStatusBarButton?
    var onDrop: (([URL]) -> Void)?
    private var acceptedSequence: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { statusButton?.mouseDown(with: event) }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, urls.count <= 1000,
              urls.allSatisfy({ $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }) else { return [] }
        return Array(NSOrderedSet(array: urls)) as? [URL] ?? urls
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = !Self.fileURLs(from: sender.draggingPasteboard).isEmpty && sender.draggingSourceOperationMask.contains(.copy)
        acceptedSequence = accepted ? sender.draggingSequenceNumber : nil
        statusButton?.highlight(accepted)
        return accepted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = acceptedSequence == sender.draggingSequenceNumber && sender.draggingSourceOperationMask.contains(.copy)
        statusButton?.highlight(accepted)
        return accepted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { acceptedSequence = nil; statusButton?.highlight(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !Self.fileURLs(from: sender.draggingPasteboard).isEmpty && sender.draggingSourceOperationMask.contains(.copy) && onDrop != nil
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusButton?.highlight(false)
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty, sender.draggingSourceOperationMask.contains(.copy), let onDrop else { return false }
        onDrop(urls)
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { acceptedSequence = nil; statusButton?.highlight(false) }
}
