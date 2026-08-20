import CSlopDeskFFI
import Foundation
import SlopDeskArena

/// Everything the host knows about one pane's RUNNING PROCESS, as a value.
///
/// This is the record that answers the question the reported bug came down to: *what is true about
/// this pane right now?* Today the host derives every one of these facts with a stateful parser and
/// then publishes them only as EDGE-TRIGGERED events (types 21/23/26/27/32/33/34/36) — so a client
/// that was not listening at the instant of the edge can never learn the fact and has no way to ask.
/// Collecting them into a value the host retains is what makes the document askable.
///
/// **Liveness only.** The topology half of `pane/*` (`kind`, `title`, `userRenamed`, `videoTarget`,
/// `spawnCwd`) is written by an intent and persisted; those fields are deliberately absent here.
/// This record is derived from a live process and is never persisted — restoring
/// `commandRunning = 1` for a process that no longer exists is exactly the "fake-live" render
/// docs/45 §6.5 exists to prevent.
///
/// **This type is a VOCABULARY, not an implementation.** The projection, the read-back, the merge,
/// the eviction and the reconciler's three-way reap all live in `rust/slopdesk-wire`'s
/// `document::liveness` and are reached through the doors below; every method here is marshalling.
/// The Swift copies of all five were deleted in the same change that opened the doors, on
/// `CLAUDE.md`'s one-implementation rule. What stays is the case list and the field names, for the
/// reason `docs/55` §6 keeps `AgentKind`'s: a `switch` in a view reads them, and marshalling a value
/// type through C to restate its own fields would buy nothing.
///
/// **Absent means default**, and that rule is the crate's. A field is emitted only when it carries a
/// non-default value, with ONE exception: ``liveness`` is always emitted, so the presence of a pane
/// object in the document is never ambiguous. `nil` (never observed) and `""` (retired) stay
/// distinct all the way across the boundary — a zero-length value is first-class here, because an
/// empty type-21 title is already this codebase's agent-title-ownership retirement signal, and
/// ``SlopDeskWsSpan``'s `present` flag is what carries the distinction.
///
/// - Note: this lives in the MODEL target, not the host, deliberately — docs/45 §6.2 filed it under
///   `Sources/SlopDeskHost/`. Both ends need it: the host writes ``entries()`` and the client reads
///   ``init(paneID:entries:)``. The host keeps only the capture seam (`PaneLiveness.capture(from:)`),
///   which cannot move because it reads a live `MuxChannelSession`.
public struct PaneLiveness: Equatable, Sendable {
    // MARK: Nested pairs

    /// The type-27 pair: ``SlopDeskAgentDetect``'s urgency and the notification class.
    public struct AgentState: Equatable, Sendable {
        public var state: UInt8
        public var kind: UInt8

        public init(state: UInt8, kind: UInt8) {
            self.state = state
            self.kind = kind
        }
    }

    /// The type-32 pair: OSC 9;4 progress state and percentage.
    public struct Progress: Equatable, Sendable {
        public var state: UInt8
        public var percent: UInt8

        public init(state: UInt8, percent: UInt8) {
            self.state = state
            self.percent = percent
        }
    }

    /// The PTY grid, published so a client that is not contributing to the size fold letterboxes
    /// correctly instead of guessing.
    public struct Grid: Equatable, Sendable {
        public var cols: UInt16
        public var rows: UInt16

        public init(cols: UInt16, rows: UInt16) {
            self.cols = cols
            self.rows = rows
        }
    }

    // MARK: Identity

    /// The HOST-MINTED pane id — the mux `sessionID`, which is also the document objectID.
    public var paneID: UUID

    // MARK: Facts

    /// Always emitted: its presence IS the pane object's existence.
    public var liveness: PaneLivenessState
    /// The OSC-sniffed window title. `nil` = never observed; `""` = retired by the agent.
    public var liveTitle: String?
    /// The host's verdict, not the client's guess. See ``PaneTitleFreshness``.
    public var titleFresh: Bool
    public var cwd: String?
    public var projectKey: String?
    public var foregroundProcess: String?
    /// The host's own open command block — the missing link that lets the host alone render the
    /// sidebar row for a client that has materialized zero bytes.
    public var runningCommand: String?
    public var agentState: AgentState?
    public var agentLabel: String?
    public var agentIntent: String?
    public var progress: Progress?
    public var commandRunning: Bool
    public var lastExitCode: Int32?
    public var lastDurationMS: UInt32?
    public var grid: Grid?
    /// Monotone, bumped on every working→done edge. The host holds ZERO per-client acknowledgement
    /// state; each viewer compares this against its own device-local `seenCompletionEpoch`.
    public var completionEpoch: UInt32
    /// Milliseconds since the epoch at the last observed activity; `0` = never.
    public var lastActivityMS: Int64

    public init(
        paneID: UUID,
        liveness: PaneLivenessState = .attached,
        liveTitle: String? = nil,
        titleFresh: Bool = false,
        cwd: String? = nil,
        projectKey: String? = nil,
        foregroundProcess: String? = nil,
        runningCommand: String? = nil,
        agentState: AgentState? = nil,
        agentLabel: String? = nil,
        agentIntent: String? = nil,
        progress: Progress? = nil,
        commandRunning: Bool = false,
        lastExitCode: Int32? = nil,
        lastDurationMS: UInt32? = nil,
        grid: Grid? = nil,
        completionEpoch: UInt32 = 0,
        lastActivityMS: Int64 = 0,
    ) {
        self.paneID = paneID
        self.liveness = liveness
        self.liveTitle = liveTitle
        self.titleFresh = titleFresh
        self.cwd = cwd
        self.projectKey = projectKey
        self.foregroundProcess = foregroundProcess
        self.runningCommand = runningCommand
        self.agentState = agentState
        self.agentLabel = agentLabel
        self.agentIntent = agentIntent
        self.progress = progress
        self.commandRunning = commandRunning
        self.lastExitCode = lastExitCode
        self.lastDurationMS = lastDurationMS
        self.grid = grid
        self.completionEpoch = completionEpoch
        self.lastActivityMS = lastActivityMS
    }

    // MARK: Projection

    /// This record as document entries, in canonical field order.
    ///
    /// ASKED, not built here. Which fields are emitted at all is the crate's "absent means default"
    /// rule plus the one exception that makes a pane's existence unambiguous, and a second copy of
    /// that rule puts a pane in the document the reaper cannot see — or writes a default where its
    /// absence was the answer.
    ///
    /// Only the LIVENESS fields are produced. A caller merging this into a document must therefore
    /// replace exactly these keys and leave the topology fields alone — see
    /// ``HostWorkspaceState/merge(paneLiveness:)-(PaneLiveness)``.
    public func entries() -> [WorkspaceEntry] {
        var blob = WsBlob()
        let record = flattened(into: &blob)
        let snapshot = blob.lend { bytes in
            withUnsafePointer(to: record) { flat in
                wsBytes { out, cap in
                    slopdesk_ws_pane_liveness_entries(flat, bytes.baseAddress, bytes.count, out, cap)
                }
            }
        }
        // A projection the codec then refuses is this boundary having gone wrong, not a record with
        // nothing in it — and answering no entries is what keeps that from writing a half-pane.
        guard let state = try? WorkspaceStateCodec.decodeSnapshot(snapshot) else { return [] }
        return state.sortedEntries
    }

    /// One HALF of a pane's field vocabulary, from the crate that reaps by it.
    ///
    /// The two lists PARTITION ``WorkspacePaneField`` and must keep doing so: a field in neither is
    /// written by nobody and reaped by nobody, and a field in both makes a liveness recapture
    /// silently delete a persisted title. Asked for rather than transcribed BECAUSE of that
    /// property — a second pair of lists can partition perfectly and still put a field on the wrong
    /// side of the line the host reaps by, and nothing about that disagrees loudly.
    private static func paneFields(half: UInt8) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        var needed = out.withUnsafeMutableBufferPointer { buffer in
            slopdesk_ws_pane_fields(half, buffer.baseAddress, buffer.count)
        }
        if needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            needed = out.withUnsafeMutableBufferPointer { buffer in
                slopdesk_ws_pane_fields(half, buffer.baseAddress, buffer.count)
            }
        }
        guard needed <= out.count else { return [] }
        return Array(out[0..<needed])
    }

    /// Every liveness field key for one pane — what a merge must clear before writing, so a fact that
    /// STOPPED being true (an agent that exited, a command that finished) actually disappears instead
    /// of latching forever.
    public static func livenessFields() -> [UInt8] { paneFields(half: 0) }

    /// The other half of one pane's fields — what an INTENT writes and a host restart restores.
    /// ``PaneLivenessFieldPartitionTests`` pins the partition.
    public static func topologyFields() -> [UInt8] { paneFields(half: 1) }

    // MARK: Reconstruction

    /// Reads one pane's liveness record back out of a document.
    ///
    /// ASKED, for the reason ``entries()`` is: this is the inverse of the same rule, and the two
    /// have to agree about which absences are real. Every field decodes independently and a
    /// malformed one falls back to its default rather than failing the record — these bytes came off
    /// a socket, and one bad `grid` must not blank a pane's title — while an unknown liveness byte
    /// from a newer host reads as `dead`, because rendering a live pane stale is cosmetic and
    /// rendering a dead one live is the fake-live bug.
    ///
    /// Returns `nil` only when the pane has no ``WorkspacePaneField/liveness`` entry — i.e. when the
    /// document holds no such pane.
    ///
    /// Only the named pane's own cells cross. The rule reads nothing else, so handing the whole
    /// document over would marshal every byte of it to ask about one object's twenty.
    public init?(paneID: UUID, entries state: HostWorkspaceState) {
        var blob = WsBlob()
        var cells = state.keys(ofKind: WorkspaceObjectKind.pane.rawValue, objectID: paneID)
            .map { blob.entry(WorkspaceEntry(key: $0, value: state[$0] ?? Data())) }
        var wanted = SlopDeskWsUuid(paneID)
        var found = false
        var record = SlopDeskWsPaneLiveness()

        let strings = blob.lend { bytes in
            cells.withUnsafeMutableBufferPointer { input in
                wsBytes { out, cap in
                    slopdesk_ws_pane_liveness_read(
                        input.baseAddress,
                        input.count,
                        bytes.baseAddress,
                        bytes.count,
                        &wanted,
                        &found,
                        &record,
                        out,
                        cap,
                    )
                }
            }
        }
        guard found else { return nil }
        self = Self(record, strings: strings)
    }
}

// MARK: - Marshalling

private extension WsBlob {
    /// A span for a value that may not be there. Absent is `nil`; a PRESENT span of length zero is
    /// the empty string, and the two are different facts on this wire.
    mutating func optionalSpan(_ text: String?) -> SlopDeskWsSpan {
        guard let text else { return SlopDeskWsSpan(offset: 0, len: 0, present: false) }
        return span(text)
    }
}

extension PaneLiveness {
    /// This record flattened for the crossing, its seven strings appended to `blob`.
    ///
    /// One buffer for the strings AND for the document cells that travel beside them: one pointer,
    /// one lifetime, one `withUnsafeBytes` scope, where a span per field would be seven nested ones
    /// per record and a reconciler tick carries dozens of records.
    func flattened(into blob: inout WsBlob) -> SlopDeskWsPaneLiveness {
        SlopDeskWsPaneLiveness(
            id: SlopDeskWsUuid(paneID),
            live_title: blob.optionalSpan(liveTitle),
            cwd: blob.optionalSpan(cwd),
            project_key: blob.optionalSpan(projectKey),
            foreground_process: blob.optionalSpan(foregroundProcess),
            running_command: blob.optionalSpan(runningCommand),
            agent_label: blob.optionalSpan(agentLabel),
            agent_intent: blob.optionalSpan(agentIntent),
            last_activity_ms: lastActivityMS,
            completion_epoch: completionEpoch,
            last_duration_ms: lastDurationMS ?? 0,
            last_exit_code: lastExitCode ?? 0,
            grid_cols: grid?.cols ?? 0,
            grid_rows: grid?.rows ?? 0,
            liveness: liveness.rawValue,
            agent_state: agentState?.state ?? 0,
            agent_kind: agentState?.kind ?? 0,
            progress_state: progress?.state ?? 0,
            progress_percent: progress?.percent ?? 0,
            title_fresh: titleFresh,
            command_running: commandRunning,
            has_agent: agentState != nil,
            has_progress: progress != nil,
            has_last_exit_code: lastExitCode != nil,
            has_last_duration_ms: lastDurationMS != nil,
            has_grid: grid != nil,
        )
    }

    /// The record a door answered, its spans resolved against the string buffer it filled.
    ///
    /// The `has_*` flags are read rather than a sentinel compared against, which is the whole reason
    /// they are on the wire: a grid of 0×0 and a pane whose size was never observed are different
    /// states, and picking a magic number to tell them apart would be a decision on this side of the
    /// boundary.
    init(_ record: SlopDeskWsPaneLiveness, strings: Data) {
        func text(_ span: SlopDeskWsSpan) -> String? {
            guard span.present else { return nil }
            return strings.withUnsafeBytes { ArenaText.optionalText($0, span.offset, span.len) }
        }
        self.init(
            paneID: record.id.uuid,
            // The byte the crate answered, which it has already degraded toward `dead` for anything
            // this build does not know. The `?? .dead` is the same degrade restated, for a Swift
            // enum that cannot hold a byte it has no case for.
            liveness: PaneLivenessState(rawValue: record.liveness) ?? .dead,
            liveTitle: text(record.live_title),
            titleFresh: record.title_fresh,
            cwd: text(record.cwd),
            projectKey: text(record.project_key),
            foregroundProcess: text(record.foreground_process),
            runningCommand: text(record.running_command),
            agentState: record.has_agent
                ? AgentState(state: record.agent_state, kind: record.agent_kind)
                : nil,
            agentLabel: text(record.agent_label),
            agentIntent: text(record.agent_intent),
            progress: record.has_progress
                ? Progress(state: record.progress_state, percent: record.progress_percent)
                : nil,
            commandRunning: record.command_running,
            lastExitCode: record.has_last_exit_code ? record.last_exit_code : nil,
            lastDurationMS: record.has_last_duration_ms ? record.last_duration_ms : nil,
            grid: record.has_grid ? Grid(cols: record.grid_cols, rows: record.grid_rows) : nil,
            completionEpoch: record.completion_epoch,
            lastActivityMS: record.last_activity_ms,
        )
    }
}

// MARK: - The document's liveness half

public extension HostWorkspaceState {
    /// Declares that one pane has no process, keeping only what describes a PLACE.
    ///
    /// ASKED. `cwd` and `projectKey` survive because they are still true — the directory a dead pane
    /// was working in has not moved — and because the By-Project sidebar would otherwise re-bucket
    /// every restored row the moment its shell is gone. Everything else is a claim about a running
    /// process and would render the pane fake-live. Which two fields those are is exactly the kind of
    /// line no second transcription of it stays on.
    @discardableResult
    mutating func markPaneDead(_ paneID: UUID) -> Bool {
        var wanted = SlopDeskWsUuid(paneID)
        return fold { entries, count, _, _, bytes, blobLen, changed, out, cap in
            slopdesk_ws_mark_pane_dead(entries, count, bytes, blobLen, &wanted, changed, out, cap)
        }
    }

    /// Replaces one pane's LIVENESS fields wholesale, leaving its topology fields untouched.
    ///
    /// - Returns: `true` if anything actually changed. The caller uses this to decide whether the
    ///   document's `stateNum` moves — a no-op recapture must never churn a version number, because
    ///   every subscriber pays for a version bump.
    @discardableResult
    mutating func merge(paneLiveness record: PaneLiveness) -> Bool {
        merge(paneLiveness: [record])
    }

    /// Replaces the LIVENESS half of every named pane in one crossing.
    ///
    /// ASKED. Clear-then-write, not write-over: a fact that stopped being true has to disappear.
    /// Writing only the fields the new record carries would latch `runningCommand` after the command
    /// finished and `agentLabel` after the agent exited — the same "edge published, value retained
    /// nowhere" failure this whole document exists to fix, just moved one layer up.
    ///
    /// Panes the document holds but `records` does not name are LEFT ALONE. Reaping is
    /// ``reconcile(captured:)``, a separate door with a separate failure mode, and the reason the two
    /// are not one entry point with a flag: the wrong value of that flag is the entire workspace of a
    /// host that has just restarted and captured nothing yet.
    @discardableResult
    mutating func merge(paneLiveness records: [PaneLiveness]) -> Bool {
        fold(records) { entries, count, given, givenCount, bytes, blobLen, changed, out, cap in
            slopdesk_ws_merge_pane_liveness(
                entries, count, given, givenCount, bytes, blobLen, changed, out, cap,
            )
        }
    }

    /// One reconciler pass: fold in what was captured, and decide what the rest of the panes are.
    ///
    /// ASKED, and it is the decision the naive "reap what was not captured" rule gets wrong once
    /// topology lives here. A pane the host restored from disk has no process — that is the whole
    /// point of a restart — but it is still a REAL pane in a REAL tab, and deleting it would erase
    /// the user's layout every time hostd restarted. So:
    ///
    /// - captured → its liveness is whatever the capture says, and it is not a reap candidate even
    ///   if the topology has never heard of it;
    /// - in the topology but not captured → ``markPaneDead(_:)``, rendered STALE rather than
    ///   fake-live, keeping the two fields that describe a PLACE rather than a process;
    /// - neither → reaped, because nothing owns it. That is a pane whose channel closed and whose tab
    ///   entry is gone, which is the case the old rule was actually for.
    @discardableResult
    mutating func reconcile(captured records: [PaneLiveness]) -> Bool {
        fold(records) { entries, count, given, givenCount, bytes, blobLen, changed, out, cap in
            slopdesk_ws_reconcile_panes(
                entries, count, given, givenCount, bytes, blobLen, changed, out, cap,
            )
        }
    }
}

// MARK: - The crossing

private extension HostWorkspaceState {
    /// Runs one document-mutating liveness door and adopts its answer.
    ///
    /// The document's cells and the records' strings go into ONE blob — one pointer, one lifetime,
    /// one scope — and what comes back is an encoded SNAPSHOT: the document's own byte encoding, the
    /// one every client already decodes off a host's push, so nothing here is a grammar anyone has to
    /// keep in step.
    ///
    /// `changed` short-circuits the decode as well as the version bump. This runs on a 500 ms
    /// backstop, and an idle host reconciling to the same answer must not pay for a document it is
    /// about to discard.
    mutating func fold(
        _ records: [PaneLiveness] = [],
        through door: (
            UnsafeMutablePointer<SlopDeskWsEntry>?, Int,
            UnsafeMutablePointer<SlopDeskWsPaneLiveness>?, Int,
            UnsafeMutablePointer<UInt8>?, Int,
            UnsafeMutablePointer<Bool>?,
            UnsafeMutablePointer<UInt8>?, Int,
        ) -> Int,
    ) -> Bool {
        var blob = WsBlob()
        var cells = entries.map { blob.entry(WorkspaceEntry(key: $0.key, value: $0.value)) }
        var flat = records.map { $0.flattened(into: &blob) }
        var changed = false
        let snapshot = blob.lend { bytes in
            cells.withUnsafeMutableBufferPointer { input in
                flat.withUnsafeMutableBufferPointer { given in
                    wsBytes { out, cap in
                        door(
                            input.baseAddress,
                            input.count,
                            given.baseAddress,
                            given.count,
                            bytes.baseAddress,
                            bytes.count,
                            &changed,
                            out,
                            cap,
                        )
                    }
                }
            }
        }
        // A door that changed the document and then handed back bytes the codec refuses is this
        // boundary having gone wrong, not an edit. Keeping the document as it was is the only answer
        // that cannot leave half a workspace behind.
        guard changed, let next = try? WorkspaceStateCodec.decodeSnapshot(snapshot) else { return false }
        self = next
        return true
    }
}
