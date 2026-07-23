import Foundation

/// Where received file bytes land. A seam so the server logic is tested against a fake in-memory sink
/// (hang-safety: no real disk in XCTest) while production writes to ``DiskFileDropSink``.
///
/// One sink instance serves one connection; it is keyed internally by `transferId` so overlapping
/// transfers on the same connection don't collide. All methods throw — a failure surfaces as a
/// `failed` reply + an abort at the server.
public protocol FileDropSink: AnyObject, Sendable {
    /// Create a destination for `transferId` (a temp file). `size` is advisory (pre-allocation hint).
    func open(transferId: UInt32, name: String, size: UInt64) throws
    /// Append `data` to the open destination for `transferId`.
    func write(transferId: UInt32, data: Data) throws
    /// Finalize `transferId`: move the temp file into place under a non-colliding final name.
    func finalize(transferId: UInt32) throws
    /// Discard any partial destination for `transferId` (best-effort delete; never throws).
    func abort(transferId: UInt32)
}

public enum FileDropSinkError: Error, Equatable, Sendable {
    case notOpen
    case ioFailed(String)
}

/// Production sink: streams each transfer to a hidden temp file in the drop directory, then atomically
/// renames it into place under a collision-avoiding final name (`report.pdf` → `report (1).pdf`).
///
/// Streaming to a temp file (not buffering in memory) keeps a multi-GiB upload flat in RAM; the
/// temp-then-rename means a half-received file never appears under its real name, and a dropped
/// connection leaves only a stray dotfile (swept on the next `abort`/deinit).
///
/// `@unchecked Sendable`: the mutable handle table is guarded by an `NSLock` (the server may drive
/// writes off the connection's receive task).
public final class DiskFileDropSink: FileDropSink, @unchecked Sendable {
    private struct Open {
        let handle: FileHandle
        let tempURL: URL
        let finalName: String
    }

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var opens: [UInt32: Open] = [:]

    /// - Parameters:
    ///   - directory: the drop directory (created if absent).
    ///   - fileManager: injectable for tests; production uses `.default`.
    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public func open(transferId: UInt32, name: String, size _: UInt64) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".slopdesk-upload-\(transferId).part")
        // A stale temp from a crashed prior run under the same id must not be appended to.
        try? fileManager.removeItem(at: tempURL)
        guard fileManager.createFile(atPath: tempURL.path, contents: nil) else {
            throw FileDropSinkError.ioFailed("create temp failed")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: tempURL)
        } catch {
            throw FileDropSinkError.ioFailed(String(describing: error))
        }
        lock.lock()
        opens[transferId] = Open(handle: handle, tempURL: tempURL, finalName: name)
        lock.unlock()
    }

    public func write(transferId: UInt32, data: Data) throws {
        lock.lock()
        let open = opens[transferId]
        lock.unlock()
        guard let open else { throw FileDropSinkError.notOpen }
        do {
            try open.handle.write(contentsOf: data)
        } catch {
            throw FileDropSinkError.ioFailed(String(describing: error))
        }
    }

    public func finalize(transferId: UInt32) throws {
        lock.lock()
        let open = opens.removeValue(forKey: transferId)
        lock.unlock()
        guard let open else { throw FileDropSinkError.notOpen }
        try? open.handle.close()
        let finalURL = nonCollidingURL(for: open.finalName)
        do {
            try fileManager.moveItem(at: open.tempURL, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: open.tempURL)
            throw FileDropSinkError.ioFailed(String(describing: error))
        }
    }

    public func abort(transferId: UInt32) {
        lock.lock()
        let open = opens.removeValue(forKey: transferId)
        lock.unlock()
        guard let open else { return }
        try? open.handle.close()
        try? fileManager.removeItem(at: open.tempURL)
    }

    /// A destination URL for `name` that does not already exist: `report.pdf`, then `report (1).pdf`,
    /// `report (2).pdf`, … The name is already a sanitized leaf, so this only appends a counter.
    private func nonCollidingURL(for name: String) -> URL {
        let candidate = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let asURL = URL(fileURLWithPath: name)
        let ext = asURL.pathExtension
        let stem = asURL.deletingPathExtension().lastPathComponent
        var counter = 1
        while true {
            let suffixed = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            let url = directory.appendingPathComponent(suffixed)
            if !fileManager.fileExists(atPath: url.path) { return url }
            counter += 1
        }
    }

    deinit {
        for open in opens.values {
            try? open.handle.close()
            try? fileManager.removeItem(at: open.tempURL)
        }
    }
}
