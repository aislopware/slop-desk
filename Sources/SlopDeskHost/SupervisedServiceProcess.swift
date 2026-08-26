import CSlopDeskFFI
import Foundation
import SlopDeskSupervisor

/// A panel backend — `code-server`, `baguette serve` — held by `slopdesk-superd` instead of by
/// hostd, so a hostd rebuild no longer costs the user a multi-second workbench reboot.
///
/// ## Why these moved too
/// `docs/51` §8 listed the panel backends as a non-goal, on the grounds that they are HTTP servers
/// addressed by port rather than by fd and could be re-found from a small state file. That reasoning
/// was about *how* to re-find them and skipped the part that actually hurt: `HostServer.stop()`
/// terminated them. Every host edit therefore killed the embedded editor and the simulator server
/// along with everything else, and the panel spent the next several seconds booting Node again.
/// A pane already had the answer to this, and it was one call away.
///
/// ## Held on a PTY, deliberately
/// superd's one spawn primitive is `openpty` + `fork` + `execve`, and it stays that way. Both
/// services were checked on a real terminal before this was written: neither colourises, neither
/// changes its announce line, and the only difference in the stream is `\r\n` — which
/// ``LineAssembler`` strips. Teaching superd a second, pipe-flavoured spawn would mean a second
/// pre-exec window next to the one that is disassembly-pinned (`fork_window_contract`), to buy a
/// carriage return.
///
/// ## Spawn-or-adopt, by a STABLE pane id
/// The id is `service:<name>` — not a UUID, and not derived from anything about this hostd, for
/// exactly the reason in `docs/51` §1. A starting hostd tries ``adopt`` first: a hit means the
/// service ran straight through the restart, and the port is re-learned by replaying the ring from
/// offset 0, which still holds the announce line. So there is no state file, no port handshake, and
/// nothing to go stale — the child's own words are the record.
///
/// A non-UUID pane id also keeps these out of `HostServer.adoptSurvivingPanes()`, which parses one
/// and leaves anything else running untouched.
///
/// Hang-safety: this creates a real process. Unit tests drive their manager through the injected
/// ``CodeServerManager/Spawner`` seam and never reach here.
final class SupervisedServiceProcess: HostServiceProcessHandle, @unchecked Sendable {
    /// `service:code-server`, `service:baguette`. Stable across every hostd this machine ever runs.
    static func paneID(for service: String) -> String { "service:\(service)" }

    private let paneID: String
    private let supervisor: SupervisorClient
    private let lock = NSLock()
    private var ended = false
    /// Held so the subscription outlives this initialiser; released by ``terminate()``.
    private var stream: PaneOutputStream?
    /// Unregistered at the end of this handle's life, so a released service stops being told about
    /// connections it no longer has anything to do with.
    private var disconnectToken: UUID?
    /// Whether the adopt replay started past the beginning of the service's output — i.e. whether
    /// the announce line, and with it the port, is unrecoverable. Always false on the spawn path.
    ///
    /// `var` only because it is settled at the end of `init`, after the stream it is read from
    /// exists; nothing writes it afterwards.
    private var replayMissedTheStart = false

    /// Whether this handle adopted a service that survived a hostd restart, rather than spawning
    /// one. Reported to the log, and asserted on by `SupervisedServiceProcessTests`.
    let adopted: Bool

    /// Takes over the named service if superd still holds it, else starts it.
    ///
    /// - Throws: when superd is unreachable, or when the spawn itself fails (a missing or broken
    ///   binary) — the caller reports the panel `unavailable`, which is the same answer it gave
    ///   when this was a `Foundation.Process`.
    static func spawnOrAdopt(
        service: String,
        binary: String,
        arguments: [String],
        environment: [String: String],
        supervisor: SupervisorClient,
        onLogLine: @escaping @Sendable (String) -> Void,
        onLog: (@Sendable (String) -> Void)? = nil,
    ) throws -> SupervisedServiceProcess {
        let paneID = paneID(for: service)
        if let survivor = adoptSurvivor(
            service: service, paneID: paneID, supervisor: supervisor,
            onLogLine: onLogLine, onLog: onLog,
        ) {
            return survivor
        }
        let masterFD = try supervisor.spawn(
            SpawnRequest(
                paneID: paneID,
                // superd only records this, and a service has no scrollback journal to
                // re-associate. Its own id is the most truthful thing to say.
                sessionID: paneID,
                executable: binary,
                arguments: arguments,
                environment: environment,
                // A service reads no input and redraws nothing, so the size is arbitrary. It is
                // not zero because a zero winsize makes some libraries think the terminal is
                // gone.
                rows: 24,
                cols: 200,
            ),
        ).masterFD
        // hostd wants nothing from this fd: no keystrokes, no resizes, no foreground probe. superd
        // holds the original, so closing the duplicate immediately is not a hangup — it is the same
        // act `relinquish()` performs at the end of a pane's hostd-side life.
        close(masterFD)
        return SupervisedServiceProcess(
            paneID: paneID, supervisor: supervisor, adopted: false, onLogLine: onLogLine,
            onLog: onLog,
        )
    }

    /// Takes back the service superd is still holding, or `nil` — including when it is holding one
    /// this hostd cannot USE.
    ///
    /// The port is re-learned by replaying the ring from offset 0, because the announce line is the
    /// first thing the service ever said. A service that has since written more than the ring holds
    /// (`ring::DEFAULT_CAPACITY_BYTES` — hours of an editor's chatter) no longer has that line in
    /// there, and an adopt would leave the manager with a live handle and no port: `isRunning` says
    /// true, so it never respawns, and the panel reports `starting` for the rest of the daemon's
    /// life with nothing in the log to say why.
    ///
    /// So a lossy resume is treated as a failed adoption. The service is ended and the caller
    /// spawns a fresh one — a few seconds of Node boot, in the rare case, rather than a panel that
    /// never comes back.
    private static func adoptSurvivor(
        service: String,
        paneID: String,
        supervisor: SupervisorClient,
        onLogLine: @escaping @Sendable (String) -> Void,
        onLog: (@Sendable (String) -> Void)?,
    ) -> SupervisedServiceProcess? {
        guard let masterFD = try? supervisor.adopt(paneID: paneID).masterFD else { return nil }
        close(masterFD)
        let handle = SupervisedServiceProcess(
            paneID: paneID, supervisor: supervisor, adopted: true, onLogLine: onLogLine,
            onLog: onLog,
        )
        guard !handle.replayMissedTheStart else {
            onLog?(
                "service \(service): survived under superd, but its output ring no longer reaches "
                    + "the announce line, so the port cannot be re-learned — restarting it rather "
                    + "than adopting one hostd can never address",
            )
            handle.terminate()
            return nil
        }
        onLog?("service \(service): still running under superd — adopted, not restarted")
        return handle
    }

    private init(
        paneID: String,
        supervisor: SupervisorClient,
        adopted: Bool,
        onLogLine: @escaping @Sendable (String) -> Void,
        onLog: (@Sendable (String) -> Void)?,
    ) {
        self.paneID = paneID
        self.supervisor = supervisor
        self.adopted = adopted

        // From offset 0, always. On the adopt path that is what re-learns the port: the announce
        // line is the first thing the service ever said and superd's ring still has it.
        let assembler = LineAssembler()
        let stream = PaneOutputStream(
            supervisor: supervisor,
            paneID: paneID,
            // A service pane's history is its log lines; the stream offset is the disk journal's
            // concern and there is no journal here.
            // A service pane is neither sniffed nor tapped — it was spawned without
            // `shellIntegration` and without `blocks`, so superd never reads it for either and both
            // batches are always empty. A daemon's stdout is not an OSC stream.
            onChunk: { chunk, _, _, _ in
                for line in assembler.append(chunk) { onLogLine(line) }
            },
            onEOF: { [weak self] in self?.markEnded() },
        )
        // Wired, because this stream's warnings are the only account of a re-learn that went wrong.
        stream.onLog = onLog
        self.stream = stream
        stream.start()
        replayMissedTheStart = stream.resumedLossily
        // superd holds the ONLY master fd for this service, so superd dying kills the child — and
        // hostd would otherwise never hear about it: the `exited` notice travels the connection
        // that just died. Marking the handle ended makes the next `ensure` re-run
        // ``spawnOrAdopt``, which adopts the survivor if superd is merely unreachable and spawns a
        // fresh one if it really restarted. An OBSERVER rather than `onDisconnect`, because this
        // client is shared by every panel service.
        disconnectToken = supervisor.observeDisconnect { [weak self] in self?.markEnded() }
    }

    // MARK: - HostServiceProcessHandle

    /// `false` once the child's stream has ended, which is the next `ensure`'s cue to respawn.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !ended
    }

    /// Ends the service for good — the counterpart to letting it go, and the distinction `docs/51`
    /// §5.5 draws for panes, drawn identically here. Only a deliberate stop may call it.
    func terminate() {
        lock.lock()
        let live = !ended
        ended = true
        let subscription = stream
        stream = nil
        let token = disconnectToken
        disconnectToken = nil
        lock.unlock()
        if let token { supervisor.removeDisconnectObserver(token) }
        subscription?.stop()
        guard live else { return }
        try? supervisor.release(paneID: paneID, kill: true)
    }

    /// Lets the service GO: hostd stops listening, superd keeps the child.
    ///
    /// What `HostServer.stop()` calls, and the whole reason this type exists. Nothing is signalled
    /// and superd is told nothing — the next hostd finds the service in `list` and adopts it.
    func relinquish() {
        lock.lock()
        let subscription = stream
        stream = nil
        let token = disconnectToken
        disconnectToken = nil
        lock.unlock()
        if let token { supervisor.removeDisconnectObserver(token) }
        subscription?.stop()
    }

    private func markEnded() {
        lock.lock()
        ended = true
        lock.unlock()
    }
}

/// Accumulates stream chunks and yields complete lines, as `slopdesk_sidecars::line_assembler`
/// does it.
///
/// The rule — one trailing `\r` off and no more, an over-cap residue dropped rather than truncated
/// or split, an undecodable line skipped — is that module's, with what each edge costs written down
/// beside it. What is left here is the OWNERSHIP: the handle's lifetime, and the lock that keeps two
/// calls on it from overlapping.
///
/// ## Why a handle rather than the pure crossing everything else here uses
/// This type IS the memory. It holds the residue of a line that has not finished arriving, across as
/// many reads as that takes, and passing that residue over and back per chunk would copy it twice on
/// every wake of a daemon whose whole job is to be quiet.
///
/// ## The lock is not decoration any more
/// The handle's mutator takes `&mut` on the far side, so two overlapping calls are aliasing UB
/// rather than a lost line. The stream callback that drives this is not the only thread in the
/// process.
final class LineAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: OpaquePointer

    init() {
        // Rust returns null only if the allocation failed, and it aborts on allocation failure
        // before it could — so this is unreachable rather than unhandled.
        guard let handle = slopdesk_line_assembler_new() else {
            preconditionFailure("slopdesk_line_assembler_new returned null")
        }
        self.handle = handle
    }

    /// Balances the one `new`. Nothing else frees it, and by definition nothing can call in
    /// afterwards — the object that held the only reference is gone.
    deinit { slopdesk_line_assembler_free(handle) }

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let count = chunk.withUnsafeBytes { raw in
            slopdesk_line_assembler_append(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        // One crossing per line. Each has to land in its own `String` for the sink regardless, so
        // flattening them would add a whole extra copy of an adopt's replayed ring to save
        // crossings the count already saved.
        return (0..<count).map { index in
            let needed = slopdesk_line_assembler_line(handle, index, nil, 0)
            guard needed > 0 else { return "" } // an empty line is still a line
            var room = [UInt8](repeating: 0, count: needed)
            let written = room.withUnsafeMutableBufferPointer { out in
                slopdesk_line_assembler_line(handle, index, out.baseAddress, out.count)
            }
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: room.prefix(min(written, needed)), as: UTF8.self)
        }
    }
}
