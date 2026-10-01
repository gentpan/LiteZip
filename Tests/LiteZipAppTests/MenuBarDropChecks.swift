import AppKit

@MainActor
private final class DragSession: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@main
struct MenuBarDropChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiteZip-menu-bar-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("中文 文件夹 #1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("existing.zip")
        try Data("Keep source untouched".utf8).write(to: file)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        func write(_ urls: [URL]) {
            board.clearContents()
            precondition(board.writeObjects(urls.map { $0 as NSURL }))
        }
        let target = StatusItemDropTarget(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let drag = DragSession(board)
        var received: [URL] = []
        target.onDrop = { received = $0 }
        write([folder, file, folder])
        precondition(target.draggingEntered(drag) == .copy)
        precondition(target.draggingUpdated(drag) == .copy)
        precondition(target.prepareForDragOperation(drag))
        precondition(target.performDragOperation(drag))
        precondition(received == [folder, file], "Folders, archives and duplicate inputs must be passed correctly")
        let preservedSource = try Data(contentsOf: file)
        precondition(preservedSource == Data("Keep source untouched".utf8))
        received = []
        drag.draggingSourceOperationMask = .move
        precondition(target.draggingEntered(drag).isEmpty)
        precondition(!target.prepareForDragOperation(drag))
        precondition(!target.performDragOperation(drag))
        precondition(received.isEmpty, "A drag must never move the source files")
        target.draggingExited(drag)
        precondition(target.draggingUpdated(drag).isEmpty)
        drag.draggingSourceOperationMask = .copy
        write([URL(string: "https://example.com/archive.zip")!])
        precondition(target.draggingEntered(drag).isEmpty)
        precondition(!target.performDragOperation(drag))
        write([folder, directory.appendingPathComponent("vanished-file")])
        precondition(target.draggingEntered(drag).isEmpty)
        precondition(!target.performDragOperation(drag))
        write(Array(repeating: file, count: 1001))
        precondition(target.draggingEntered(drag).isEmpty)
        precondition(!target.performDragOperation(drag))
        board.clearContents()
        precondition(!target.performDragOperation(drag))
        print("PASS: folder/file drop, Unicode names, deduplication, copy-only, remote/missing/empty inputs, item limit, untouched sources")
    }
}
