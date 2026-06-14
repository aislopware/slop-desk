import AislopdeskProtocol
import Foundation

/// A non-rendering ``TerminalSurface`` that simply accumulates the bytes fed to it.
///
/// It performs **no VT parsing** — it is a faithful byte sink, which is exactly what
/// the headless `aislopdesk-client` CLI and the test suite need to verify the byte
/// pipeline end to end without libghostty or a GUI. The real terminal emulation is
/// the libghostty-backed `GhosttySurface` in the GUI app target (WF-5).
///
/// Thread-safety: all mutable state is guarded by an internal lock, so it is safe to
/// `feed` from a background receive loop while reading ``output`` elsewhere. Hence
/// `@unchecked Sendable`.
public final class HeadlessTerminalSurface: TerminalSurface, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var cols: UInt16 = 80
    private var rows: UInt16 = 24
    private var onWriteStorage: ((Data) -> Void)?

    public init() {}

    // MARK: TerminalSurface

    public func feed(_ bytes: Data) {
        lock.lock()
        buffer.append(bytes)
        lock.unlock()
    }

    public func setSize(cols: UInt16, rows: UInt16) {
        lock.lock()
        self.cols = cols
        self.rows = rows
        lock.unlock()
    }

    public func handleInput(_ bytes: Data) {
        // A headless surface does no key encoding; it forwards input bytes verbatim
        // to the write callback so the client can wrap them as `input`.
        let callback = withLock { onWriteStorage }
        callback?(bytes)
    }

    public var onWrite: ((Data) -> Void)? {
        get { withLock { onWriteStorage } }
        set { withLock { onWriteStorage = newValue } }
    }

    // MARK: Inspection (tests / headless CLI)

    /// All bytes fed so far.
    public var output: Data {
        withLock { buffer }
    }

    /// The output decoded as UTF-8 (empty when the bytes are not valid UTF-8), for convenience in
    /// tests / CLI display.
    public var text: String {
        String(bytes: output, encoding: .utf8) ?? ""
    }

    /// Current grid size.
    public var size: (cols: UInt16, rows: UInt16) {
        withLock { (cols, rows) }
    }

    /// Clears the accumulated buffer (does not reset size).
    public func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
