import Foundation
import Darwin

/// One control per operation. Cancelling also terminates a blocked engine process.
public final class OperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    public init() {}
    public func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw ArchiveError.cancelled }
    }
    public func cancel() {
        lock.lock(); cancelled = true; let active = process; lock.unlock()
        Self.stop(active)
    }
    func start(_ active: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw ArchiveError.cancelled }
        // Starting while holding the lock closes the cancel-before-run race.
        try active.run(); process = active
    }
    func clear(_ active: Process) {
        lock.lock(); defer { lock.unlock() }
        if process === active { process = nil }
    }
    static func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

private final class ErrorBuffer: @unchecked Sendable {
    var data = Data()
}

struct ProcessRunner: Sendable {
    let executable: URL
    func run(_ arguments: [String], directory: URL? = nil, password: String? = nil, standardInput: Data? = nil, environment: [String: String] = [:],
             control: OperationControl, limit: Int = 32 * 1_024 * 1_024,
             output: ((Data) throws -> Void)? = nil) throws -> Data {
        try control.check()
        guard password == nil || standardInput == nil else { throw ArchiveError.invalidInput }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ArchiveError.engineMissing }
        if let password, password.utf8.count > 4096 || password.contains("\n") || password.contains("\r") || password.contains("\0") { throw ArchiveError.invalidInput }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin"].merging(environment) { _, value in value }
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = stdin
        let errorBuffer = ErrorBuffer(), done = DispatchGroup()
        try control.start(process)
        done.enter()
        defer { control.clear(process); try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close() }
        Thread.detachNewThread {
            defer { done.leave() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while let chunk = try? Self.nextChunk(from: stderr.fileHandleForReading, buffer: &buffer) {
                if errorBuffer.data.count < 65_536 { errorBuffer.data.append(chunk.prefix(65_536 - errorBuffer.data.count)) }
            }
        }
        do {
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            if let input = standardInput ?? password.map({ Data(($0 + "\n" + $0 + "\n").utf8) }) {
                do { try stdin.fileHandleForWriting.write(contentsOf: input) }
                catch {
                    let ns = error as NSError
                    let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
                    if ns.code != EPIPE && underlying?.code != Int(EPIPE) { throw error }
                }
            }
            try stdin.fileHandleForWriting.close()
            var captured = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while let chunk = try Self.nextChunk(from: stdout.fileHandleForReading, buffer: &buffer) {
                try control.check()
                if let output { try output(chunk) }
                else {
                    guard captured.count <= limit - chunk.count else { throw ArchiveError.tooLarge }
                    captured.append(chunk)
                }
            }
            process.waitUntilExit(); done.wait()
            try control.check()
            guard process.terminationStatus == 0 else {
                let detail = (String(data: errorBuffer.data, encoding: .utf8) ?? "") + (String(data: captured, encoding: .utf8) ?? "")
                throw Self.mapError(detail)
            }
            return captured
        } catch {
            OperationControl.stop(process)
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit(); done.wait()
            try control.check()
            throw error
        }
    }
    // Foundation's read(upToCount:) may wait to fill a pipe buffer. POSIX read
    // returns available bytes immediately, so small progress updates reach the UI.
    private static func nextChunk(from handle: FileHandle, buffer: inout [UInt8]) throws -> Data? {
        let capacity = buffer.count
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, capacity) }
            if count > 0 { return Data(buffer.prefix(count)) }
            if count == 0 { return nil }
            if errno != EINTR { throw ArchiveError.invalidArchive }
        }
    }
    static func mapError(_ detail: String) -> ArchiveError {
        let text = detail.lowercased()
        if text.contains("password") || text.contains("encrypted") || text.contains("authentication error") || text.contains("认证错误") || text.contains("認證錯誤") { return .wrongPassword }
        if text.contains("no space") { return .diskFull }
        if text.contains("permission") || text.contains("access is denied") { return .permissionDenied }
        if text.contains("volume") { return .missingVolume }
        if text.contains("crc") || text.contains("checksum") || text.contains("data error") || text.contains("unexpected end") { return .corruptedArchive }
        if text.contains("unsupported") { return .unsupportedFormat }
        return .invalidArchive
    }
}
