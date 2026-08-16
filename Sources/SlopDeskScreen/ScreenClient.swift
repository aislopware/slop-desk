import Darwin
import Foundation
import SlopDeskSupervisor
import SlopDeskTTY

/// hostd's client for `slopdesk-screend` — the VT screen engine.
///
/// ## Why the engine is not in this process
/// Parsing a terminal stream into an attributed grid is the hottest byte path hostd has: a cold
/// reattach composes the whole retained ring, and iOS drops TCP seconds after backgrounding, so
/// every foreground does it again. In Swift the grid is `[[Cell]]` with a `String` per cell, and
/// the ARC traffic plus the nested-array uniqueness check on every printed character measured
/// 17.9 MiB/s against 186 MiB/s for the same corpus in Rust. That is a structural gap, not a
/// tuning one — hence a separate binary over a socket (`CLAUDE.md`: never FFI, so `swift build`
/// stays headless).
///
/// ## Synchronous on purpose
/// Every call site is already a synchronous transform in the middle of a byte pipeline (the replay
/// composer, the detection scan, the `screen` verb). A round trip on an `AF_UNIX` socket is ~11 µs
/// of transport; making these `async` would restructure four call sites to save nothing.
///
/// ## Absent screend degrades, never crashes
/// The daemon holds no durable state — its per-pane models are a cache a repaint refills — so a
/// missing or crashed screend is recoverable by construction. Each verb's caller has a documented
/// PASSTHROUGH answer (replay the raw bytes; skip this detection tick), never a second parser: a
/// Swift fallback implementation is the cross-language mirror this tree forbids.
///
/// `@unchecked Sendable`: every mutable field is under `poolLock` or `startLock`.
public final class ScreenClient: @unchecked Sendable {
    /// The process-wide client, addressed from the environment.
    ///
    /// A single instance so the connection pool is shared: the detection scans of forty panes are
    /// forty callers, and each holding its own socket would be forty threads parked in screend.
    public static let shared = ScreenClient()

    public enum ClientError: Error, Sendable {
        /// Nothing is listening and nothing could be started. The caller falls back.
        case unavailable(reason: String)
        case transport(errno: Int32)
        case rejected(status: ScreenStatus, message: String)
        case malformedReply
    }

    /// Resolved PER CALL, not captured at construction.
    ///
    /// ``shared`` is a `static let`, so whoever touches it first would otherwise freeze the address
    /// for the process — and in a test run that is whichever suite happens to sort first, before
    /// `ScreendFixture` has pointed the environment at the private engine. Reading the environment
    /// each time costs a `getenv` against a round trip, and makes the aiming order irrelevant.
    private let resolveSocketPath: @Sendable () -> String
    private let resolveBinaryPath: @Sendable () -> String?
    private let autostart: Bool

    private let poolLock = NSLock()
    private var idle: [Int32] = []
    /// The address the pooled sockets are connected to. A changed address invalidates them all —
    /// they lead to a different engine, or to nothing.
    private var pooledPath: String?

    private let startLock = NSLock()
    /// Monotonic time of the last spawn attempt. A screend that cannot start (missing binary, a
    /// crash loop) must not be re-forked once per detection tick across every pane.
    private var lastStartAttempt: TimeInterval?

    /// Seconds between spawn attempts.
    private static let startBackoff: TimeInterval = 2.0
    /// How long to wait for a freshly spawned screend to bind.
    private static let startTimeout: TimeInterval = 3.0
    /// Idle connections kept for reuse. Above this the extra sockets are closed rather than pooled
    /// — a burst of parallel composes should not leave hostd holding descriptors for the day.
    private static let poolLimit = 8

    /// A client pinned to one address — the test fixture's private engine, or a gate script's.
    public convenience init(socketPath: String, binaryPath: String?, autostart: Bool = true) {
        self.init(
            resolveSocketPath: { socketPath },
            resolveBinaryPath: { binaryPath },
            autostart: autostart,
        )
    }

    /// The general form: the address is a QUESTION, asked whenever one is needed.
    @preconcurrency
    public init(
        resolveSocketPath: @escaping @Sendable () -> String = { ScreenPaths.requestSocket() },
        resolveBinaryPath: @escaping @Sendable () -> String? = { ScreenPaths.binary() },
        autostart: Bool = true,
    ) {
        self.resolveSocketPath = resolveSocketPath
        self.resolveBinaryPath = resolveBinaryPath
        self.autostart = autostart
    }

    deinit {
        for fd in idle { Darwin.close(fd) }
    }

    // MARK: Verbs

    /// Parses `raw` into a FRESH grid and answers what it shows. Nothing is retained.
    public func snapshot(raw: Data, rows: Int, cols: Int) throws -> ScreenSnapshot {
        try decodeSnapshot(request(verb: .snapshot, rows: rows, cols: cols, raw: raw))
    }

    /// Appends `raw` to `pane`'s resident model and answers what it shows.
    ///
    /// `reset` rebuilds the model first — a resize, a ring overflow, the first scan. A geometry
    /// change resets implicitly on screend's side: a VT model cannot be reflowed, so a model at the
    /// wrong size is not a model that needs adjusting, it is the wrong model.
    public func feed(
        pane: String,
        raw: Data,
        rows: Int,
        cols: Int,
        reset: Bool = false,
    ) throws -> ScreenSnapshot {
        try decodeSnapshot(request(
            verb: .feed,
            flags: reset ? ScreenWire.flagReset : 0,
            rows: rows,
            cols: cols,
            pane: pane,
            raw: raw,
        ))
    }

    /// Folds `raw` into `pane`'s grid, OSC tracker and synchronized-frame parser, and answers what
    /// the screen now SAYS about `agent`.
    ///
    /// One round trip where there used to be four walks of the same chunk: the grid across this
    /// socket, then the OSC tracker, the frame parser and ~20 backtracking regexes in hostd, over a
    /// whole grid shipped back as JSON every ~300 ms per pane. The bytes go one way now and ~150
    /// bytes of verdict come back.
    ///
    /// An EMPTY `agent` folds without running the ladder — the answer is then `unknown` with the
    /// frame fields still filled in. `reset` rebuilds the grid; `rebuildReplay` additionally
    /// restarts the frame parser; `agentChanged` drops the retained OSC evidence first. They are
    /// three separate questions and a caller answers each on its own (``ScreenWire/flagReset``).
    public func detect(
        pane: String,
        agent: String,
        raw: Data,
        rows: Int,
        cols: Int,
        reset: Bool = false,
        rebuildReplay: Bool = false,
        agentChanged: Bool = false,
    ) throws -> ScreenDetection {
        var flags: UInt8 = 0
        if reset { flags |= ScreenWire.flagReset }
        if rebuildReplay { flags |= ScreenWire.flagRebuildReplay }
        if agentChanged { flags |= ScreenWire.flagAgentChanged }
        let payload = try ScreenWire.encodeDetectPayload(agent: agent, raw: raw)
        let reply = try request(verb: .detect, flags: flags, rows: rows, cols: cols, pane: pane, raw: payload)
        guard let verdict = try? JSONDecoder().decode(ScreenDetection.self, from: reply) else {
            throw ClientError.malformedReply
        }
        return verdict
    }

    /// Drops `pane`'s resident model. Best-effort: screend evicts on its own when the table is
    /// full, so a lost `forget` costs memory until then and nothing else.
    public func forget(pane: String) {
        _ = try? request(verb: .forget, pane: pane)
    }

    /// Renders the minimal VT stream that reproduces what `raw` puts on a `rows`×`cols` screen.
    ///
    /// `reassertInputModes` appends the net input-mode state of `raw` after the render — computed
    /// from the RAW bytes, because a render reproduces a SCREEN and input modes are not screen
    /// state: nothing in a rendered grid says `?1002h`.
    public func compose(raw: Data, rows: Int, cols: Int, reassertInputModes: Bool = false) throws -> Data {
        try request(
            verb: .compose,
            flags: reassertInputModes ? ScreenWire.flagReassertInputModes : 0,
            rows: rows,
            cols: cols,
            raw: raw,
        )
    }

    /// Renders `raw` as a plain transcript — scrollback and grid, no modes re-asserted.
    public func transcript(raw: Data, rows: Int, cols: Int) throws -> Data {
        try request(verb: .transcript, rows: rows, cols: cols, raw: raw)
    }

    /// Drops the superseded revisions of every line a progress reporter overprints with `CR`.
    public func collapse(_ raw: Data) throws -> Data {
        try request(verb: .collapse, raw: raw)
    }

    /// Normalises zsh's `PROMPT_SP` mark+fill clusters, and nothing else — for the caller holding
    /// one captured command block, where the rest of the transform would be wrong.
    public func promptEolMarks(_ raw: Data) throws -> Data {
        try request(verb: .promptEolMarks, raw: raw)
    }

    /// Round-trips a `hello`. Used by the gate scripts and the test fixture to wait for a bind.
    @discardableResult
    public func hello() throws -> String {
        let payload = try request(verb: .hello)
        return String(bytes: payload, encoding: .utf8) ?? ""
    }

    // MARK: Transport

    private func decodeSnapshot(_ payload: Data) throws -> ScreenSnapshot {
        guard let snapshot = try? JSONDecoder().decode(ScreenSnapshot.self, from: payload) else {
            throw ClientError.malformedReply
        }
        return snapshot
    }

    /// One request, one reply.
    ///
    /// Retries ONCE on a transport failure with a fresh connection, because the overwhelmingly
    /// likely cause is a pooled socket whose screend was restarted between calls — `make screend`
    /// during a dev loop, or launchd replacing a crashed one. A second failure is reported.
    private func request(
        verb: ScreenVerb,
        flags: UInt8 = 0,
        rows: Int = 0,
        cols: Int = 0,
        pane: String = "",
        raw: Data = Data(),
    ) throws -> Data {
        let frame = try ScreenWire.encodeRequest(
            verb: verb, flags: flags, rows: rows, cols: cols, pane: pane, raw: raw,
        )
        var lastError: Error?
        for attempt in 0..<2 {
            // A pooled socket is only reused on the FIRST attempt: if it just failed, the second
            // attempt must not draw another corpse from the same pool.
            let path = resolveSocketPath()
            let fd = try connection(allowPooled: attempt == 0)
            do {
                let body = try exchange(fd: fd, frame: frame)
                recycle(fd, path: path)
                let (status, payload) = try ScreenWire.decodeReply(body)
                guard status == .ok else {
                    throw ClientError.rejected(
                        status: status,
                        message: String(bytes: payload, encoding: .utf8) ?? "",
                    )
                }
                return payload
            } catch let error as ClientError {
                Darwin.close(fd)
                // A REJECTION is screend answering, not the transport failing — retrying would only
                // ask the same malformed question again.
                if case .rejected = error { throw error }
                lastError = error
            } catch {
                Darwin.close(fd)
                lastError = error
            }
        }
        throw lastError ?? ClientError.malformedReply
    }

    private func exchange(fd: Int32, frame: Data) throws -> Data {
        try writeAll(fd: fd, frame)
        let header = try readExactly(fd: fd, count: 4)
        let declared = header.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
            Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        }
        guard declared >= 1, declared <= ScreenWire.maximumFrameBytes else {
            throw ClientError.malformedReply
        }
        return try readExactly(fd: fd, count: declared)
    }

    /// Same must-report contract as the supervisor's frame writer, and the same loop — a peer that
    /// closed reads as `EPIPE`, which is what this lane's error type spells a lost socket with.
    private func writeAll(fd: Int32, _ data: Data) throws {
        switch FileDescriptorWrite.all(fd: fd, data) {
        case .complete: return
        case .peerClosed: throw ClientError.transport(errno: EPIPE)
        case let .failed(errno, _): throw ClientError.transport(errno: errno)
        }
    }

    /// `read(2)` until the whole frame is in. Same must-report contract as the supervisor's frame
    /// reader, and the same loop — an EOF mid-frame reads as `ECONNRESET`, which is how this lane
    /// spells "screend died holding the answer".
    private func readExactly(fd: Int32, count: Int) throws -> Data {
        let (bytes, outcome) = FileDescriptorRead.exactly(fd: fd, count: count)
        switch outcome {
        case .complete: return Data(bytes)
        case .peerClosed: throw ClientError.transport(errno: ECONNRESET)
        case let .failed(errno, _): throw ClientError.transport(errno: errno)
        }
    }

    // MARK: Connections

    private func connection(allowPooled: Bool) throws -> Int32 {
        let path = resolveSocketPath()
        if allowPooled, let pooled = takePooled(for: path) { return pooled }
        if let fd = try? SupervisorSocket.connect(to: path) { return fd }
        guard autostart else {
            throw ClientError.unavailable(reason: "nothing listening at \(path)")
        }
        try start(at: path)
        do {
            return try SupervisorSocket.connect(to: path)
        } catch {
            throw ClientError.unavailable(reason: "screend did not answer at \(path)")
        }
    }

    private func takePooled(for path: String) -> Int32? {
        poolLock.lock()
        var stale: [Int32] = []
        if pooledPath != path {
            stale = idle
            idle.removeAll()
            pooledPath = path
        }
        let pooled = idle.popLast()
        poolLock.unlock()
        for fd in stale { Darwin.close(fd) }
        return pooled
    }

    private func recycle(_ fd: Int32, path: String) {
        poolLock.lock()
        let keep = idle.count < Self.poolLimit && pooledPath == path
        if keep { idle.append(fd) }
        poolLock.unlock()
        if !keep { Darwin.close(fd) }
    }

    /// Starts a screend and waits for it to bind. Rate-limited; a caller that arrives during the
    /// backoff window fails fast and falls back rather than queueing behind a daemon that is not
    /// coming.
    private func start(at socketPath: String) throws {
        startLock.lock()
        defer { startLock.unlock() }
        // Another thread may have started one while this one waited for the lock.
        if let fd = try? SupervisorSocket.connect(to: socketPath) {
            Darwin.close(fd)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastStartAttempt, now - last < Self.startBackoff {
            throw ClientError.unavailable(reason: "screend start backing off")
        }
        lastStartAttempt = now
        guard let binaryPath = resolveBinaryPath() else {
            throw ClientError.unavailable(reason: "no slopdesk-screend binary (\(ScreenPaths.binaryEnvKey))")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [socketPath]
        // The daemon's log goes to a FILE, never to this process's stdio: a screend that outlives
        // its parent while holding the write end of an inherited pipe is how a test harness hangs
        // reading for an EOF that cannot arrive (`SuperdFixture` documents the same trap at length).
        let log = logURL()
        FileManager.default.createFile(atPath: log.path, contents: nil)
        for channel in 0..<2 {
            let fd = open(log.path, O_WRONLY | O_APPEND)
            guard fd >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            if channel == 0 { process.standardOutput = handle } else { process.standardError = handle }
        }
        do {
            try process.run()
        } catch {
            throw ClientError.unavailable(reason: "cannot start \(binaryPath): \(error)")
        }

        let deadline = Date().addingTimeInterval(Self.startTimeout)
        while Date() < deadline {
            if let fd = try? SupervisorSocket.connect(to: socketPath) {
                Darwin.close(fd)
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw ClientError.unavailable(reason: "screend did not bind \(socketPath) in time")
    }

    private func logURL() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/SlopDesk", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil {
            return directory.appendingPathComponent("screend.log", isDirectory: false)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slopdesk-screend.log")
    }
}
