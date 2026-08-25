import CSlopDeskFFI
import Foundation

/// One thing that happened to a pane's output stream.
public enum PaneOutputEvent: Sendable {
    /// Bytes superd read off the master, with the absolute offset of the first one.
    case bytes(offset: UInt64, Data)
    /// What the shell said out of band in the chunk that follows THIS event.
    ///
    /// Always immediately before its ``bytes`` — superd writes the two frames under one hold of its
    /// wire lock, and sends this one only when a chunk actually contained something, so a receiver
    /// can never wait to find out whether one is coming. The pairing is the caller's to make, and
    /// ``PaneOutputStream`` makes it.
    case sniffed([SniffedEvent])
    /// What the command-block tap found in the chunk that follows THIS event.
    ///
    /// Same placement and the same guarantee as ``sniffed(_:)``: immediately before its ``bytes``,
    /// written under one hold of superd's wire lock, and sent only when a chunk actually produced a
    /// change. ``PaneOutputStream`` makes the pairing.
    case blocks([BlockEvent])
    /// The master is finished — the child closed its tty, which in practice means it exited.
    ///
    /// Synthesised from the pane's `exited` notification rather than from a frame of its own,
    /// because superd guarantees the drain happens first: see the read loop.
    case ended
}

/// hostd's end of the supervisor socket.
///
/// Synchronous request/reply on the caller's thread, plus a background read loop for the
/// unsolicited `exited` notifications and every pane's output. Synchronous because every caller is
/// already on a path that used to call `openpty` + `fork` inline and blocked for exactly as long;
/// making it async would change the shape of `spawnFreshShell` for no gain.
///
/// ## What this file is, now that the message set left it
/// The connection, and nothing else: the socket, the reply-waiter table, the serial write queue and
/// the reader thread. Each is about a connection `slopdesk-ffi` cannot see. What a request LOOKS
/// like and what a reply MEANS crossed into `slopdesk_superwire::protocol` — see
/// ``SupervisorEncoder`` and ``SupervisorReplyReader`` — because that half was spelled twice, once
/// here and once in superd, and a disagreement between them passed both suites and produced a `nil`.
///
/// ## Absent superd is fatal to panes, and says so
/// There is no fallback. hostd cannot fork a shell — nothing in Swift can any more — so a failed
/// ``connect(clientName:)`` means no pane can open, and the caller must say that in as many words
/// rather than degrade quietly. That is the deliberate cost of having exactly one implementation
/// of the spawn path: `make superd-install` is now a prerequisite, not an optimisation.
///
/// ## It also carries the panes' output
/// superd reads every master (`rust/slopdesk-superd/src/pump.rs`); this client `subscribe`s and the
/// read loop demultiplexes the output frames by pane id — see
/// ``subscribe(paneID:fromOffset:onEvent:)``. One thread serves every pane, and the per-pane
/// handler runs ON it, synchronously. That is what makes the backpressure gate real: a handler that
/// takes its time stops the reads, which stops superd's reads, which fills the kernel PTY buffer
/// and pauses the shell. Nothing is buffered on the way and nothing is dropped.
public final class SupervisorClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case notConnected
        /// superd is running a major version this hostd cannot talk to. Carries both sides so the
        /// message can name the fix rather than just the mismatch.
        case incompatible(superdMajor: Int, ourMajor: Int)
        case refused(String)
        /// The verb is not in this superd's vocabulary — it is older than us. Recoverable: the caller
        /// falls back rather than failing (`docs/51` §3 rule 3).
        case unsupported(verb: String, message: String)
        case malformedReply
        /// A reply that should have carried a master fd did not.
        case missingDescriptor
    }

    private let socketPath: String
    private let lock = NSLock()
    private var connection: SupervisorConnection?
    private var nextRequestID: UInt64 = 1
    /// Replies land here, keyed by request id, when the read loop picks them up.
    private var pending: [UInt64: (body: [UInt8], descriptor: Int32?)] = [:]
    /// Ids of requests nobody is waiting for — see ``send(_:)``. Their replies are dropped on
    /// arrival instead of accumulating in `pending` forever.
    private var unawaited: Set<UInt64> = []
    private let replyArrived = NSCondition()
    private var readerThread: Thread?

    /// Every outbound frame is written from HERE, and from nowhere else.
    ///
    /// The read loop delivers a pane's bytes by calling its handler synchronously, and that handler
    /// can come back into this client to write: `PausableQueueGate` crossing its capacity fires
    /// ``setPaused(paneID:paused:)`` from inside the ingest it just performed. That write is a
    /// blocking `write(2)` on the very socket the reader is responsible for draining — so with
    /// superd's pump blocked writing 32 KiB output frames into hostd's full receive buffer, and
    /// hostd's reader blocked writing a pause into superd's full receive buffer, neither side ever
    /// moves again and every terminal in the workspace freezes with no timeout to break it.
    ///
    /// A serial queue fixes it by construction: the reader hands the frame over and goes straight
    /// back to `receive()`, which is what lets superd's writer drain and the whole cycle unwind.
    /// SERIAL, and used by the awaited path too, because the order frames leave in is meaning —
    /// an `unsubscribe` overtaken by a later `subscribe` for the same pane would cancel the live
    /// subscription and leave a pane that renders nothing.
    private let outboundQueue = DispatchQueue(label: "com.slopdesk.supervisor.client.outbound")

    /// The stable socket paths superd told us about at `hello`. hostd MUST advertise these into every
    /// spawned child's environment rather than paths of its own — that is the whole point
    /// (`docs/51` §1).
    public private(set) var hookSocketPath: String?
    public private(set) var controlSocketPath: String?
    public private(set) var superdPID: Int32?
    public private(set) var negotiatedMinor: Int?

    /// The crate version of the superd process on the other end, from ``HelloReply/buildVersion``.
    ///
    /// `nil` when superd predates minor 8 and did not send one — which `SidecarVersionAudit` reads
    /// as `.unknown`, never as "current". A superd that answered is running code that may be older
    /// than the binary an upgrade just wrote to disk; this is the only handle hostd has on which.
    public private(set) var superdBuildVersion: String?

    /// Per-pane output handlers, keyed by `paneID`. Installed by ``subscribe(paneID:fromOffset:onEvent:)``
    /// and removed by ``unsubscribe(paneID:)`` or by the pane's `exited`.
    private var outputHandlers: [String: @Sendable (PaneOutputEvent) -> Void] = [:]

    /// Per-pane exit handlers, keyed by `paneID`.
    ///
    /// hostd cannot `waitpid` a child it did not fork — only superd can, and the `exited`
    /// notification is the whole of hostd's knowledge that a shell is gone. Routing it here rather
    /// than through a table in `HostServer` keeps the lookup next to the read loop that produces it.
    private var exitHandlers: [String: @Sendable (Int32) -> Void] = [:]

    /// Called off the caller's thread when a supervised child exits. Fires for every pane, after
    /// the pane's own handler.
    public var onExit: (@Sendable (ExitedNotice) -> Void)?
    /// Everyone who wants to hear that the connection to superd dropped. The panes are still alive
    /// on superd's side; this means we lost the control channel, not the shells.
    ///
    /// A LIST, reached through ``observeDisconnect(_:)``, rather than one settable property. One
    /// client is shared by every panel service (`HostServiceSupervisor.shared`) as well as by
    /// whatever owns it, and last-writer-wins would silently unhook whichever registered first —
    /// which is how a code-server killed by superd's death went on reporting itself as running.
    private var disconnectObservers: [UUID: @Sendable () -> Void] = [:]
    /// Called with each child connection superd accepted on a listener this client claimed — the
    /// listener kind, and an owned descriptor for the accepted socket.
    ///
    /// **The callee owns the descriptor and must close it.** It arrives on the read-loop thread, so
    /// the handler has to hand it straight to a worker: parking here would stop every pane's output
    /// and every reply, and the peer is a hook binary blocking its agent. With no handler installed
    /// the descriptor is closed rather than leaked, which is also the correct answer — a connection
    /// arriving for a kind nobody wired up has nowhere to go.
    public var onConnection: (@Sendable (ListenerKind, Int32) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    /// Registers `handler`, to be called off the caller's thread when the connection drops.
    ///
    /// Observers outlive a reconnect — the same client object reconnects in place — so a caller
    /// registers once and hears about every drop.
    ///
    /// - Returns: a token for ``removeDisconnectObserver(_:)``.
    @discardableResult
    @preconcurrency
    public func observeDisconnect(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        disconnectObservers[token] = handler
        lock.unlock()
        return token
    }

    public func removeDisconnectObserver(_ token: UUID) {
        lock.lock()
        disconnectObservers.removeValue(forKey: token)
        lock.unlock()
    }

    public init(socketPath: String = SupervisorPaths.controlSocket()) {
        self.socketPath = socketPath
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != nil
    }

    // MARK: Connect

    /// Connects and completes the `hello` handshake. Throws when superd is absent or incompatible.
    public func connect(clientName: String) throws {
        let fd = try SupervisorSocket.connect(to: socketPath)
        let link = SupervisorConnection(fd: fd)
        lock.lock()
        connection = link
        lock.unlock()

        startReader(link)

        let reply = try request(verb: "hello") { id in
            SupervisorEncoder.hello(id: id, client: clientName)
        }
        guard let hello = reply.reader.hello else {
            disconnect()
            throw ClientError.malformedReply
        }
        guard hello.versionMajor == SupervisorEncoder.versionMajor else {
            disconnect()
            throw ClientError.incompatible(
                superdMajor: hello.versionMajor,
                ourMajor: SupervisorEncoder.versionMajor,
            )
        }
        hookSocketPath = hello.hookSocketPath
        controlSocketPath = hello.controlSocketPath
        superdPID = hello.superdPID
        negotiatedMinor = min(hello.versionMinor, SupervisorEncoder.versionMinor)
        superdBuildVersion = hello.buildVersion
        onLog?(
            "supervisor: attached to superd pid \(hello.superdPID) "
                + "(protocol \(hello.versionMajor).\(hello.versionMinor))",
        )
    }

    public func disconnect() {
        lock.lock()
        let link = connection
        connection = nil
        lock.unlock()
        link?.close()
    }

    // MARK: Verbs

    /// Registers the callback for one pane's death. Replaces any previous one.
    ///
    /// Named apart from the ``onExit`` property on purpose: one is per-pane and one is per-client,
    /// and a single overloaded name would let a caller wire the wrong one and never notice.
    ///
    /// Set this BEFORE the `spawn` reply is acted on: a child that exits immediately (a bad
    /// executable, `exit 1`) can be reaped and broadcast before the caller has finished wiring
    /// itself up, and a lost `exited` leaves a dead pane looking alive forever.
    @preconcurrency
    public func observeExit(ofPane paneID: String, _ handler: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        exitHandlers[paneID] = handler
        lock.unlock()
    }

    /// Drops a handler registered by ``observeExit(ofPane:_:)`` for a pane that never came to exist.
    public func forgetExitHandler(ofPane paneID: String) {
        lock.lock()
        exitHandlers.removeValue(forKey: paneID)
        lock.unlock()
    }

    /// Forks a pane shell in superd and returns the record plus the master fd this process now owns.
    public func spawn(_ spawn: SpawnRequest) throws -> (record: PaneRecord, masterFD: Int32) {
        let reply = try request(verb: "spawn") { id in SupervisorEncoder.spawn(id: id, spawn) }
        guard let record = reply.reader.pane else { throw ClientError.malformedReply }
        guard let descriptor = reply.descriptor else { throw ClientError.missingDescriptor }
        return (record, descriptor)
    }

    /// Takes back a pane that survived a restart.
    public func adopt(paneID: String) throws -> (record: PaneRecord, masterFD: Int32) {
        let reply = try request(verb: "adopt") { id in
            SupervisorEncoder.pane(
                UInt32(SLOPDESK_SUPERVISOR_VERB_ADOPT), id: id, paneID: paneID,
            )
        }
        guard let record = reply.reader.pane else { throw ClientError.malformedReply }
        guard let descriptor = reply.descriptor else { throw ClientError.missingDescriptor }
        return (record, descriptor)
    }

    public func list() throws -> [PaneRecord] {
        try request(verb: "list") { id in SupervisorEncoder.list(id: id) }.reader.paneList ?? []
    }

    public func signal(paneID: String, signal number: Int32) throws {
        _ = try request(verb: "signal") { id in
            SupervisorEncoder.paneNumber(
                UInt32(SLOPDESK_SUPERVISOR_VERB_SIGNAL), id: id, paneID: paneID,
                value: UInt64(bitPattern: Int64(number)),
            )
        }
    }

    /// Tells superd the pane's new size.
    ///
    /// Un-awaited and non-throwing, for the same reason as ``setPaused(paneID:paused:)``: hostd has
    /// already applied `TIOCSWINSZ` to its own duplicate of the master — that is the apply the shell
    /// feels — and this is bookkeeping, sent from whichever thread just resolved a size fold.
    /// Waiting here for the reply would mean waiting on the read loop, and a caller that IS the read
    /// loop would wait for ever. An older superd's `unsupported` answer is discarded on the same
    /// grounds (`docs/51` §3 rule 3).
    ///
    /// What it buys, since the size is already applied: superd's record is what `list` reports and
    /// what the NEXT hostd reads when it adopts this pane. Left at the spawn-time default, a 200×50
    /// pane comes back re-wrapped at 80 columns after every restart.
    public func resize(paneID: String, rows: UInt16, cols: UInt16) {
        send { id in SupervisorEncoder.resize(id: id, paneID: paneID, rows: rows, cols: cols) }
    }

    /// Claims the child-facing listeners this hostd will serve.
    ///
    /// Until this succeeds, superd accepts connections on those sockets and closes them at once,
    /// and — more importantly — does not advertise their paths into any spawned child's
    /// environment. Advertising an address is a promise to be listening at it, and this call is
    /// hostd making the promise.
    ///
    /// Send it once per connection, after `hello` and BEFORE the first `spawn`: a pane spawned in
    /// between would be handed hostd's own value for `SLOPDESK_SOCKET_PATH` instead of superd's
    /// stable one, and that snapshot can never be corrected.
    ///
    /// - Throws: ``ClientError/unsupported(verb:message:)`` from a superd older than protocol 1.3,
    ///   which is recoverable — that superd binds nothing, so hostd is free to fall back.
    public func listen(kinds: Set<ListenerKind>) throws {
        _ = try request(verb: "listen") { id in SupervisorEncoder.listen(id: id, kinds: kinds) }
    }

    /// Starts receiving a pane's output.
    ///
    /// The handler is called on the client's read-loop thread, in stream order, with the bytes
    /// superd read off the master. It replaces `PTYReadLoop`'s `onChunk`, and the reason it can is
    /// that superd now does the reading: hostd keeps its duplicate of the master for `write`,
    /// `TIOCSWINSZ` and `tcgetpgrp`, and no longer `read`s it at all.
    ///
    /// Register the handler BEFORE the subscribe goes out — this method does, under the lock — or
    /// the backlog frames that follow the reply immediately would arrive with nowhere to go.
    ///
    /// - Returns: where the stream actually resumed. A ``StreamPosition/lossy`` result means bytes
    ///   were evicted before this client got back; the caller must decide what to do about a hole
    ///   rather than splice across it silently.
    @discardableResult
    @preconcurrency
    public func subscribe(
        paneID: String,
        fromOffset: UInt64 = 0,
        onEvent: @escaping @Sendable (PaneOutputEvent) -> Void,
    ) throws -> StreamPosition {
        lock.lock()
        outputHandlers[paneID] = onEvent
        lock.unlock()
        do {
            let reply = try request(verb: "subscribe") { id in
                SupervisorEncoder.paneNumber(
                    UInt32(SLOPDESK_SUPERVISOR_VERB_SUBSCRIBE), id: id, paneID: paneID,
                    value: fromOffset,
                )
            }
            guard let position = reply.reader.stream else { throw ClientError.malformedReply }
            return position
        } catch {
            lock.lock()
            outputHandlers.removeValue(forKey: paneID)
            lock.unlock()
            throw error
        }
    }

    /// Retires a pane sniffer's title-coalescing anchor.
    ///
    /// superd's sniffer drops a title identical to the one it last emitted. When a detected agent
    /// EXITS, that anchor has to go: the next agent's opening title is very often byte-identical to
    /// the one just retired (`✳ Claude Code`), and deduping it away leaves the pane untitled.
    ///
    /// Best-effort and un-awaited, like ``unsubscribe(paneID:)`` and for both of its reasons: this
    /// is reached FROM the read loop (a detected agent's exit unwinding into the chunk handler), and
    /// waiting there for a reply only that loop can deliver is a deadlock. Losing it costs a stale
    /// pane title rather than a wrong one.
    public func forgetTitleCoalescing(paneID: String) {
        send { id in
            SupervisorEncoder.pane(
                UInt32(SLOPDESK_SUPERVISOR_VERB_FORGET_TITLE), id: id, paneID: paneID,
            )
        }
    }

    /// One finished block's retained output, from superd's ring.
    ///
    /// - Returns: the bytes, or `nil` when this pane has no tap at all. An EMPTY array is the other
    ///   answer and a different one: the block existed and has aged out of the ring, or never was.
    public func blockOutput(paneID: String, index: UInt32) throws -> [UInt8]? {
        let reply = try request(verb: "blockOutput") { id in
            SupervisorEncoder.paneNumber(
                UInt32(SLOPDESK_SUPERVISOR_VERB_BLOCK_OUTPUT), id: id, paneID: paneID,
                value: UInt64(index),
            )
        }
        // The pane having a tap is what makes this non-nil; the BLOCK having survived is what fills
        // it. An evicted index answers `[]` under a present `blocks`, which is a different fact.
        guard let blocks = reply.reader.blocks else { return nil }
        return blocks.output ?? []
    }

    /// Every block superd's tap still knows about this pane, ascending.
    ///
    /// What a client reattaching to a running session is backfilled from: block metadata does not
    /// ride the replayed output stream — only raw bytes do — so without this the Commands panel
    /// comes back empty for a shell that never stopped.
    ///
    /// - Returns: `nil` when the pane has no tap.
    public func blockSnapshot(paneID: String) throws -> [BlockMetadata]? {
        try request(verb: "blockSnapshot") { id in
            SupervisorEncoder.pane(
                UInt32(SLOPDESK_SUPERVISOR_VERB_BLOCK_SNAPSHOT), id: id, paneID: paneID,
            )
        }.reader.blocks?.snapshot
    }

    /// The agent-control read: the last `limit` finished blocks with their bytes, the running
    /// command, and the index the next one will close under.
    ///
    /// Three facts in one round trip because `last-output` and `run --wait` want them together, and
    /// they are only consistent with each other if superd read them under one hold of the tap.
    ///
    /// - Returns: `nil` when the pane has no tap.
    public func blockControl(paneID: String, limit: Int) throws -> BlocksReply? {
        try request(verb: "blockControl") { id in
            SupervisorEncoder.paneNumber(
                UInt32(SLOPDESK_SUPERVISOR_VERB_BLOCK_CONTROL), id: id, paneID: paneID,
                value: UInt64(max(0, limit)),
            )
        }.reader.blocks
    }

    /// Where a session's transcript is on disk, and how much of a live stream it already holds.
    ///
    /// The BYTES are not in the answer. hostd opens the returned path itself, so a multi-megabyte
    /// transcript never crosses this socket to be handed straight to the screen engine.
    ///
    /// - Returns: `nil` when that session has no transcript — which is not the same as an empty
    ///   one, because only "there is nothing here" may start a pane at offset 0.
    public func journalInfo(directory: String, sessionID: String) throws -> JournalReply? {
        try request(verb: "journalInfo") { id in
            SupervisorEncoder.journal(
                UInt32(SLOPDESK_SUPERVISOR_VERB_JOURNAL_INFO), id: id,
                directory: directory, sessionID: sessionID,
            )
        }.reader.journal
    }

    /// Removes a session's transcript — the deliberate end of a pane, and the only thing that
    /// unlinks one on purpose.
    ///
    /// Routed through superd rather than unlinked here because superd may still hold the file open:
    /// on POSIX an unlink under an open writer is not an error, it is a pane journaling the rest of
    /// its life into an inode nobody can ever open again.
    public func journalDelete(directory: String, sessionID: String) {
        send { id in
            SupervisorEncoder.journal(
                UInt32(SLOPDESK_SUPERVISOR_VERB_JOURNAL_DELETE), id: id,
                directory: directory, sessionID: sessionID,
            )
        }
    }

    /// Bounds the orphans: unlinks transcripts past `maxAge` or past the `keepNewest` newest.
    ///
    /// The age and the count are hostd's policy; which files a live pane is still writing is
    /// superd's knowledge, and it is the one thing a sweep must not get wrong.
    public func journalSweep(directory: String, maxAgeSeconds: UInt64, keepNewest: Int) {
        send { id in
            SupervisorEncoder.journal(
                UInt32(SLOPDESK_SUPERVISOR_VERB_JOURNAL_SWEEP), id: id,
                directory: directory, maxAgeSeconds: maxAgeSeconds, keepNewest: keepNewest,
            )
        }
    }

    /// Stops receiving a pane's output. The pane keeps running and superd keeps draining it.
    ///
    /// Best-effort and un-awaited: the local handler is dropped first, so a failure to tell superd
    /// costs some wasted frames rather than output arriving at a torn-down session. Un-awaited also
    /// because teardown can reach here FROM the read loop (an `exited` handler unwinding a
    /// session), and waiting there for a reply only that loop can deliver is a deadlock.
    public func unsubscribe(paneID: String) {
        lock.lock()
        outputHandlers.removeValue(forKey: paneID)
        lock.unlock()
        send { id in
            SupervisorEncoder.pane(
                UInt32(SLOPDESK_SUPERVISOR_VERB_UNSUBSCRIBE), id: id, paneID: paneID,
            )
        }
    }

    /// Stops or resumes superd's reads on a pane — the backpressure gate.
    ///
    /// Un-awaited, and that is a correctness requirement rather than a latency choice. This is
    /// called from ``PausableQueueGate``, which runs inside the output-queue accounting — i.e. from
    /// whatever thread just ingested a chunk. Waiting for a reply would mean waiting for the read
    /// loop, and if the caller IS the read loop the wait can never end.
    ///
    /// Also not `throws`: the caller holds a queue lock and has nothing useful to do with an error.
    /// A pause that fails to land costs a bounded overshoot; a pause that blocks costs the pane.
    public func setPaused(paneID: String, paused: Bool) {
        send { id in
            SupervisorEncoder.paneFlag(
                UInt32(SLOPDESK_SUPERVISOR_VERB_PAUSE), id: id, paneID: paneID, flag: paused,
            )
        }
    }

    /// The pane is closed for good. NEVER call this on hostd shutdown — a hostd that exits must
    /// RELINQUISH its panes, or the restart takes the shells with it.
    public func release(paneID: String, kill: Bool) throws {
        lock.lock()
        exitHandlers.removeValue(forKey: paneID)
        outputHandlers.removeValue(forKey: paneID)
        lock.unlock()
        _ = try request(verb: "release") { id in
            SupervisorEncoder.paneFlag(
                UInt32(SLOPDESK_SUPERVISOR_VERB_RELEASE), id: id, paneID: paneID, flag: kill,
            )
        }
    }

    // MARK: Request plumbing

    /// Sends a request and does not wait for its answer.
    ///
    /// The id is still allocated and still unique — superd answers every request, and rule 3 of the
    /// skew contract depends on that staying true. It is recorded in `unawaited` so the read loop
    /// drops the reply rather than parking it in `pending` for a waiter that will never come; an
    /// un-dropped reply per keystroke-driven pause would be an unbounded map.
    ///
    /// The bytes are built by the caller's closure FROM the allocated id, because the id is part of
    /// what is encoded — there is no half-built request to stamp afterwards.
    private func send(_ encode: (UInt64) -> [UInt8]) {
        lock.lock()
        guard let link = connection else {
            lock.unlock()
            return
        }
        let id = nextRequestID
        nextRequestID += 1
        unawaited.insert(id)
        lock.unlock()

        let encoded = encode(id)
        // An empty encoding is the door's refusal, not an empty frame: sending one would put a body
        // superd cannot parse on a socket whose framing depends on every body being a message.
        guard !encoded.isEmpty else {
            lock.lock()
            unawaited.remove(id)
            lock.unlock()
            return
        }
        // The LINK is resolved here, on the caller's thread, and carried into the queue. Resolving
        // it at execution time would let a frame queued for a connection that has since died go out
        // on its replacement — an `unsubscribe` from a torn-down session cancelling the live
        // subscription its successor just made.
        outboundQueue.async { [weak self] in
            let sent = (try? link.send(body: encoded)) != nil
            // Nothing went out, so nothing will come back — retire the id rather than leave a
            // filter entry that outlives its frame.
            guard !sent, let self else { return }
            lock.lock()
            unawaited.remove(id)
            lock.unlock()
        }
    }

    /// Writes one frame from the outbound queue and waits for it to leave.
    ///
    /// The wait is on the WRITE, not on a reply, and it is what keeps ``request(verb:_:)`` able to
    /// report a broken socket to its caller. Never called from the read loop: an awaited request
    /// there waits for a reply only that loop can deliver, which the callers document.
    private func writeInOrder(_ bytes: [UInt8], on link: SupervisorConnection) throws {
        try outboundQueue.sync { try link.send(body: bytes) }
    }

    /// Sends a request and parks until its reply comes back.
    ///
    /// `verb` is carried only so a failure can name what failed; nothing routes on it, and the wire
    /// spelling is the encoder's.
    private func request(
        verb: String,
        _ encode: (UInt64) -> [UInt8],
    ) throws -> (reader: SupervisorReplyReader, descriptor: Int32?) {
        lock.lock()
        guard let link = connection else {
            lock.unlock()
            throw ClientError.notConnected
        }
        let id = nextRequestID
        nextRequestID += 1
        lock.unlock()

        let encoded = encode(id)
        guard !encoded.isEmpty else { throw ClientError.malformedReply }
        try writeInOrder(encoded, on: link)

        // Wait for the reader thread to route this id back. No timeout: superd answers every verb
        // synchronously and the socket closing wakes the reader, which fails every waiter — so a
        // hang here would mean superd is wedged, and a timeout would only turn a visible hang into a
        // silent fork of a second shell for the same pane.
        replyArrived.lock()
        var arrived: (body: [UInt8], descriptor: Int32?)?
        while arrived == nil {
            if let found = pending.removeValue(forKey: id) {
                arrived = found
                break
            }
            if isClosedLocked() {
                replyArrived.unlock()
                throw ClientError.notConnected
            }
            replyArrived.wait()
        }
        replyArrived.unlock()
        guard let raw = arrived else { throw ClientError.notConnected }

        guard let reader = SupervisorReplyReader(raw.body) else {
            if let descriptor = raw.descriptor { close(descriptor) }
            throw ClientError.malformedReply
        }
        switch reader.status {
        case .ok:
            return (reader, raw.descriptor)
        case .unsupported:
            if let descriptor = raw.descriptor { close(descriptor) }
            throw ClientError.unsupported(verb: verb, message: reader.message ?? "")
        case .error:
            if let descriptor = raw.descriptor { close(descriptor) }
            throw ClientError.refused(reader.message ?? "superd refused \(verb)")
        case .unrecognised:
            // A status a newer superd has and this build does not. Reported as a refusal — the one
            // thing it must NOT be is silence, which is what a throw during decode used to buy:
            // the frame dropped, this waiter never woken, the pane never opened.
            if let descriptor = raw.descriptor { close(descriptor) }
            throw ClientError.refused(
                reader.message
                    ?? "superd answered \(verb) with a status this hostd does not know — "
                    + "it is newer than this build",
            )
        }
    }

    /// Routes one decoded output frame to the pane's handler.
    private func deliverOutput(_ body: [UInt8]) {
        guard let decoded = SupervisorFrame.decodeOutput(body) else {
            onLog?("supervisor: dropped an undecodable output frame (\(body.count) bytes)")
            return
        }
        lock.lock()
        let handler = outputHandlers[decoded.paneID]
        lock.unlock()
        // No handler is ordinary, not an error: `unsubscribe` drops the handler before the verb
        // reaches superd, so the frames already in flight land here.
        handler?(.bytes(offset: decoded.offset, decoded.payload))
    }

    /// Routes one decoded sniff frame to the pane's handler, ahead of the chunk it describes.
    private func deliverSniff(_ body: [UInt8]) {
        guard let decoded = SupervisorFrame.decodeSniff(body) else {
            onLog?("supervisor: dropped an undecodable sniff frame (\(body.count) bytes)")
            return
        }
        guard let events = SupervisorBatch.sniffed(decoded.json) else {
            onLog?("supervisor: dropped a sniff batch for pane \(decoded.paneID) that would not decode")
            return
        }
        lock.lock()
        let handler = outputHandlers[decoded.paneID]
        lock.unlock()
        // No handler is ordinary for the same reason it is on the output path: `unsubscribe` drops
        // it before the verb reaches superd, so the frames already in flight land here.
        handler?(.sniffed(events))
    }

    /// Routes one decoded blocks frame to the pane's handler, ahead of the chunk it describes.
    private func deliverBlocks(_ body: [UInt8]) {
        // The same body shape as a sniff frame, so the same decode — see ``SupervisorFrame``.
        guard let decoded = SupervisorFrame.decodeSniff(body) else {
            onLog?("supervisor: dropped an undecodable blocks frame (\(body.count) bytes)")
            return
        }
        guard let events = SupervisorBatch.blocks(decoded.json) else {
            onLog?("supervisor: dropped a blocks batch for pane \(decoded.paneID) that would not decode")
            return
        }
        lock.lock()
        let handler = outputHandlers[decoded.paneID]
        lock.unlock()
        // No handler is ordinary for the same reason it is on the output path: `unsubscribe` drops
        // it before the verb reaches superd, so the frames already in flight land here.
        handler?(.blocks(events))
    }

    /// Hands one accepted child connection to ``onConnection``, or closes it.
    ///
    /// Every path out of here disposes of the descriptor exactly once. A `connection` event with no
    /// descriptor, or a kind this build cannot name, is a peer we do not understand —
    /// validate-then-drop, the rule every untrusted decode here follows, and a leaked fd per bad
    /// frame is the specific harm.
    private func deliverConnection(_ kind: ListenerKind?, _ descriptor: Int32?) {
        guard let descriptor else {
            onLog?("supervisor: a connection event arrived with no descriptor — ignoring")
            return
        }
        guard let kind else {
            onLog?(
                "supervisor: a connection arrived for a listener kind this build has no name for — "
                    + "closing the descriptor; superd is newer than this hostd",
            )
            close(descriptor)
            return
        }
        guard let handler = onConnection else {
            onLog?("supervisor: nothing serves \(kind) connections here — closing the descriptor")
            close(descriptor)
            return
        }
        handler(kind, descriptor)
    }

    private func isClosedLocked() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection == nil
    }

    private func startReader(_ link: SupervisorConnection) {
        let thread = Thread { [weak self] in
            while true {
                let frame: (tag: UInt8, body: [UInt8], descriptor: Int32?)
                do {
                    frame = try link.receive()
                } catch {
                    break
                }
                guard let self else {
                    if let descriptor = frame.descriptor { close(descriptor) }
                    break
                }
                // Output is not JSON and never carries a descriptor — the tag is the whole
                // discriminator, and decoding it as a reply would be a guaranteed failure on the
                // hottest path this socket has.
                if frame.tag == SupervisorFrame.tagOutput {
                    if let descriptor = frame.descriptor { close(descriptor) }
                    deliverOutput(frame.body)
                    continue
                }
                if frame.tag == SupervisorFrame.tagSniff {
                    if let descriptor = frame.descriptor { close(descriptor) }
                    deliverSniff(frame.body)
                    continue
                }
                if frame.tag == SupervisorFrame.tagBlocks {
                    if let descriptor = frame.descriptor { close(descriptor) }
                    deliverBlocks(frame.body)
                    continue
                }
                // Peek only at the id: a notification is dispatched, anything else is routed to the
                // waiter. A body that will not even decode is dropped rather than trapped —
                // validate-then-drop, same as every other untrusted decode here.
                guard let reply = SupervisorReplyReader(frame.body) else {
                    if let descriptor = frame.descriptor { close(descriptor) }
                    // Loud, because the id went with it: a waiter registered under that id is now
                    // parked on a reply that has already been delivered and thrown away, and this
                    // line is the only trace of why. Statuses no longer land here (they decode to
                    // `.unrecognised`), so anything that does is a shape, not a vocabulary.
                    onLog?("supervisor: dropped an undecodable reply frame (\(frame.body.count) bytes)")
                    continue
                }
                if reply.id == SupervisorEncoder.notificationID {
                    // The one notification that carries a descriptor. Handled before the blanket
                    // close below, which every other event still needs.
                    if reply.event == .connection {
                        deliverConnection(reply.connectionKind, frame.descriptor)
                        continue
                    }
                    if let descriptor = frame.descriptor { close(descriptor) }
                    if reply.event == .exited, let notice = reply.exited {
                        lock.lock()
                        let handler = exitHandlers.removeValue(forKey: notice.paneID)
                        let output = outputHandlers.removeValue(forKey: notice.paneID)
                        lock.unlock()
                        // `.ended` FIRST, and this ordering is the whole of hostd's EOF signal now.
                        // superd drains the pane's pump to EOF before it broadcasts `exited`, and
                        // both travel this one socket in order, so by the time this line runs every
                        // byte the shell ever wrote has already gone through the handler above.
                        // Delivering it here rather than from a second source is what keeps the
                        // exit code behind the final output on the wire.
                        output?(.ended)
                        handler?(notice.code)
                        onExit?(notice)
                    }
                    continue
                }
                lock.lock()
                let ignored = unawaited.remove(reply.id) != nil
                lock.unlock()
                if ignored {
                    if let descriptor = frame.descriptor { close(descriptor) }
                    continue
                }
                replyArrived.lock()
                pending[reply.id] = (body: frame.body, descriptor: frame.descriptor)
                replyArrived.broadcast()
                replyArrived.unlock()
            }

            guard let self else { return }
            // Wake every waiter so nobody blocks forever on a dead socket.
            //
            // `=== link`, never `!= nil`: this thread belongs to ONE connection, and by the time it
            // gets here the client may already have reconnected in place — a superseded reader
            // clearing `connection` would drop the LIVE link on the floor, leaving a client that
            // reports disconnected while its socket is open and its reader is running. It would
            // also fire the disconnect observers for a connection that is fine, which is a service
            // marking itself dead and a panel respawning under a healthy hostd.
            lock.lock()
            let wasAttached = connection === link
            if wasAttached { connection = nil }
            lock.unlock()
            replyArrived.lock()
            replyArrived.broadcast()
            replyArrived.unlock()
            if wasAttached {
                onLog?("supervisor: connection to superd lost — panes stay alive, control is gone")
                lock.lock()
                let observers = Array(disconnectObservers.values)
                lock.unlock()
                // Outside the lock: an observer re-enters this client (a service marks itself dead
                // and the next `ensure` respawns through the same object).
                for observer in observers { observer() }
            }
        }
        thread.name = "com.slopdesk.supervisor.client"
        thread.start()
        readerThread = thread
    }
}
