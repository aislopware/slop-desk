import CSlopDeskFFI
import Foundation
import SlopDeskSupervisor
import SlopDeskTransport
import SlopDeskVideoProtocol

/// hostd's half of disk scrollback: the POLICY, and what a restored transcript is rendered into.
///
/// ## The file is superd's
/// `ScrollbackJournal.swift` used to live here and write `<uuid>.scrollback` from the chunks this
/// process received over superd's socket. It does not any more (`docs/DECISIONS.md`, stage 27):
/// superd owns the PTY read, so it numbers the stream, and the daemon that numbers a stream is the
/// one that should be persisting it. What went with the file is the entire class of problem that
/// came from one process journaling another's stream — the `.resume` sidecar, its pane-life stamp,
/// the re-claim on the flush cadence for a hostd that was killed, and the rule about which of two
/// non-atomic writes was allowed to be stale. `journalInfo` answers that number now, from memory,
/// in the process that owns it.
///
/// ## What is left here is every decision
/// Where journals are filed, how big one may get, whether a pane has one at all, when one is
/// deleted, how long an orphan lives — and, decisively, what the bytes MEAN. superd hands back a
/// path and a geometry; turning that into a preamble a fresh shell can be given is this type's job,
/// because it is the same rendering question the reattach path already answers
/// (``TerminalReplaySnapshot``) and it belongs next to its sibling rather than inside a custodian.
///
/// ## Two ways to render, and the sidecar decides
/// With the prior life's PTY size available, the raw bytes are rendered ONCE into a plain
/// transcript — O(final state) to paint, mode-free by construction. Without it (an older journal,
/// a pane that never resized past a failed sidecar write, the snapshot composer switched off) the
/// distilled byte history is used instead, with a mode-sanitizing suffix appended: the prior life
/// may have ended inside an alt-screen TUI with mouse reporting on and the cursor hidden, and
/// replaying that verbatim into a FRESH terminal wedges the pane before its first prompt.
public struct ScrollbackTranscripts: Sendable {
    /// Where superd files journals. hostd's choice; superd creates it and names the files inside.
    public let directory: String

    /// Per-file byte cap, handed to superd at spawn.
    public let byteCap: Int

    /// Applied to the raw bytes at RESTORE time, never at write time — so a change to the pass
    /// chain retroactively benefits every journal already on disk. Injected for testability.
    private let distiller: (@Sendable (Data) -> Data)?

    /// The state-transfer composer, `(raw, rows, cols) → transcript`
    /// (``TerminalReplaySnapshot/composeTranscript``). `nil` (env-disabled, or tests) keeps the
    /// distiller path.
    private let snapshotComposer: (@Sendable (Data, Int, Int) -> Data)?

    /// Terminal-mode sanitize suffix appended to a distilled restore. Order matters: leave the alt
    /// screen FIRST, so the resets that follow land on the main screen. The default path is already
    /// mode-free — the input-mode strip runs inside the replay transform — so this is the backstop
    /// for the raw/env-disabled path.
    ///
    /// Built by `slopdesk-sanitize`'s `inputmode` from the SAME array the strip pass reads, rather
    /// than spelled here. All fourteen tracked modes used to be written out in this file, with
    /// nothing connecting the two lists: a mode added to the pass would have been silently missing
    /// from the backstop that exists to catch what the pass did not run on.
    public static let sanitizeSuffix: Data = {
        let needed = slopdesk_input_mode_reset(nil, 0)
        guard needed > 0 else { return Data() }
        var room = [UInt8](repeating: 0, count: needed)
        let written = room.withUnsafeMutableBufferPointer { out in
            slopdesk_input_mode_reset(out.baseAddress, out.count)
        }
        guard written == needed else { return Data() }
        return Data(room)
    }()

    /// How old an orphan may get before a sweep unlinks it, and how many of the newest survive that
    /// cut regardless. Both are policy, so both cross the socket on every sweep rather than being
    /// read from an environment superd would have to be restarted to see.
    public static let sweepMaxAgeSeconds: UInt64 = 14 * 24 * 3600
    public static let sweepKeepNewest = 256

    @preconcurrency
    public init(
        directory: String,
        byteCap: Int,
        distiller: (@Sendable (Data) -> Data)? = nil,
        snapshotComposer: (@Sendable (Data, Int, Int) -> Data)? = nil,
    ) {
        self.directory = directory
        self.byteCap = max(0, byteCap)
        self.distiller = distiller
        self.snapshotComposer = snapshotComposer
    }

    // MARK: Environment factory (hostd wiring)

    /// Builds the production policy, or `nil` when disk persistence is off.
    ///
    /// Gates (both default-ON, the `!= "0"` idiom):
    /// - `SLOPDESK_SCROLLBACK_PERSIST` — the master scrollback gate (also controls the in-memory
    ///   ring in ``MuxChannelSession/makeReplayBuffer``).
    /// - `SLOPDESK_SCROLLBACK_DISK` — disk-specific kill switch, so the journal can be turned off
    ///   without losing the warm-resume ring.
    ///
    /// Cap: `SLOPDESK_SCROLLBACK_BYTES` (the same env the ring reads). Distill:
    /// `SLOPDESK_SCROLLBACK_DISTILL`. Location: `<Application Support>/SlopDesk/scrollback/`,
    /// overridable with `SLOPDESK_SCROLLBACK_DIR` — or wholesale by
    /// ``SlopDeskAppSupport/directoryEnvKey``, which moves the container this sits inside.
    ///
    /// One of the two is REQUIRED of any daemon an automation run starts, and `HOME` is neither: a
    /// sweep unlinks everything past the newest 256 in whatever directory it resolves.
    public static func makeFromEnvironment(
        environment env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
    ) -> Self? {
        guard env["SLOPDESK_SCROLLBACK_PERSIST"] != "0", env["SLOPDESK_SCROLLBACK_DISK"] != "0" else {
            return nil
        }
        let directory: String
        if let override = env["SLOPDESK_SCROLLBACK_DIR"], !override.isEmpty {
            directory = override
        } else {
            guard let base = SlopDeskAppSupport.directory(environment: env, fileManager: fileManager)
            else { return nil }
            directory = base.appendingPathComponent("scrollback", isDirectory: true).path
        }
        let cap: Int =
            if let raw = env["SLOPDESK_SCROLLBACK_BYTES"], let parsed = Int(raw), parsed >= 0 {
                parsed
            } else {
                ReplayBuffer.defaultScrollbackBytes
            }
        guard cap > 0 else { return nil }
        // The same distill + strip chain as the in-memory ring's cold replay, but with NO
        // input-mode re-assert: a journal restore fronts a FRESH shell, so the prior life's TUI
        // modes must stay off (and ``sanitizeSuffix`` enforces the same for the raw path).
        // The composer rides the same gate as the reattach snapshot replay — one switch governs
        // state transfer on every replay path.
        var snapshotComposer: (@Sendable (Data, Int, Int) -> Data)?
        if env["SLOPDESK_SCROLLBACK_SNAPSHOT"] != "0" {
            snapshotComposer = { raw, rows, cols in
                TerminalReplaySnapshot.composeTranscript(raw: raw, rows: rows, cols: cols)
            }
        }
        return Self(
            directory: directory,
            byteCap: cap,
            distiller: ScrollbackReplayTransform.make(environment: env),
            snapshotComposer: snapshotComposer,
        )
    }

    // MARK: What superd is told

    /// The `spawn` payload that asks superd to journal a pane. Only a real client-owned session
    /// gets one: a panel backend has no transcript anybody would ever restore.
    public func spawnRequest(sessionID: String) -> JournalSpawnRequest? {
        guard !sessionID.isEmpty else { return nil }
        return JournalSpawnRequest(directory: directory, capBytes: byteCap)
    }

    // MARK: Restore

    /// One restored transcript: the preamble bytes plus HOW they were produced (the caller's log
    /// line — the reattach path's "snapshot|raw replay in N ms" sibling).
    public struct Restored {
        public let bytes: Data
        /// TRUE when the bytes are a rendered state-transfer transcript; FALSE for the distilled
        /// byte history.
        public let snapshotComposed: Bool
    }

    /// What superd knows about a session's transcript: how much is on disk, at what geometry, and
    /// how much of a LIVE pane's stream it already holds.
    ///
    /// `nil` when there is no transcript there — which is not the same as an empty one, because
    /// only "there is nothing here" may start a pane's stream at offset 0.
    public func info(sessionID: UUID, supervisor: SupervisorClient) -> JournalReply? {
        try? supervisor.journalInfo(directory: directory, sessionID: sessionID.uuidString)
    }

    /// The preamble `spawnFreshShell` hands a new session, rendered from what superd has on disk.
    ///
    /// `nil` when there is no journal, when it cannot be read, or when nothing survives the
    /// transform — all three mean "nothing to restore", and the caller starts the pane clean.
    public func restored(sessionID: UUID, supervisor: SupervisorClient) -> Restored? {
        guard let info = info(sessionID: sessionID, supervisor: supervisor), info.bytes > 0,
              let raw = try? Data(contentsOf: URL(fileURLWithPath: info.path)), !raw.isEmpty
        else { return nil }
        if let snapshotComposer, info.rows > 0, info.cols > 0 {
            let transcript = snapshotComposer(raw, Int(info.rows), Int(info.cols))
            guard !transcript.isEmpty else { return nil }
            return Restored(bytes: transcript, snapshotComposed: true)
        }
        var restored = distiller.map { $0(raw) } ?? raw
        restored.append(Self.sanitizeSuffix)
        return Restored(bytes: restored, snapshotComposed: false)
    }

    // MARK: End of life

    /// Removes a session's transcript — the deliberate end of a pane only. Every other end (a link
    /// drop, a TTL eviction, a daemon stop) KEEPS the file: that is the feature.
    public func delete(sessionID: UUID, supervisor: SupervisorClient) {
        supervisor.journalDelete(directory: directory, sessionID: sessionID.uuidString)
    }

    /// Bounds the orphans. hostd sets the age and the count; superd knows which files a live pane is
    /// still writing, which is the one thing a sweep must not get wrong.
    public func sweep(supervisor: SupervisorClient) {
        supervisor.journalSweep(
            directory: directory,
            maxAgeSeconds: Self.sweepMaxAgeSeconds,
            keepNewest: Self.sweepKeepNewest,
        )
    }
}
