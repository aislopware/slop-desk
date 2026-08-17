import CSlopDeskFFI
import Foundation

/// Everything the host knows about one pane's RUNNING PROCESS, as a value.
///
/// This is the record that answers the question the reported bug came down to: *what is true about
/// this pane right now?* Today the host derives every one of these facts with a stateful parser and
/// then publishes them only as EDGE-TRIGGERED events (types 21/23/26/27/32/33/34/36) — so a client
/// that was not listening at the instant of the edge can never learn the fact and has no way to ask.
/// Collecting them into a value the host retains is what makes the document askable.
///
/// **Liveness only.** The topology half of `pane/*` (`kind`, `title`, `userRenamed`, `videoTarget`,
/// `spawnCwd`) is written by an intent and persisted; those fields are deliberately absent here and
/// land in Phase 5. This record is derived from a live process and is never persisted — restoring
/// `commandRunning = 1` for a process that no longer exists is exactly the "fake-live" render
/// docs/45 §6.5 exists to prevent.
///
/// **Absent means default.** A field is emitted only when it carries a non-default value, with ONE
/// exception: ``liveness`` is always emitted, so the presence of a pane object in the document is
/// never ambiguous. `nil` (never observed) and `""` (retired) stay distinct — a zero-length value is
/// first-class here, because an empty type-21 title is already this codebase's
/// agent-title-ownership retirement signal.
///
/// - Note: this lives in the MODEL target, not the host, deliberately — docs/45 §6.2 filed it under
///   `Sources/SlopDeskHost/`. Both ends need it: the host writes ``entries()`` and the client reads
///   ``init(paneID:entries:)``. One round-trippable value beats an encoder and a decoder maintained
///   apart, and it buys a headless round-trip test with no PTY in sight. The host keeps only the
///   capture seam (`PaneLiveness.capture(from:)`).
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
    /// Only the LIVENESS fields are produced. A caller merging this into a document must therefore
    /// replace exactly these keys and leave the topology fields alone — see
    /// ``HostWorkspaceState/merge(paneLiveness:)``.
    public func entries() -> [WorkspaceEntry] {
        var out: [WorkspaceEntry] = []
        func put(_ field: UInt8, _ value: Data?) {
            guard let value else { return }
            out.append(WorkspaceEntry(key: WorkspaceKey(.pane, paneID, field), value: value))
        }
        func putString(_ field: UInt8, _ value: String?) {
            put(field, value.map { WorkspaceStateCodec.encodeString($0) })
        }
        putString(WorkspacePaneField.liveTitle, liveTitle)
        if titleFresh { put(WorkspacePaneField.titleFresh, WorkspaceStateCodec.encodeBool(true)) }
        putString(WorkspacePaneField.cwd, cwd)
        putString(WorkspacePaneField.projectKey, projectKey)
        putString(WorkspacePaneField.foregroundProcess, foregroundProcess)
        putString(WorkspacePaneField.runningCommand, runningCommand)
        if let agentState {
            put(
                WorkspacePaneField.agentState,
                WorkspaceStateCodec.encodeU8Pair(agentState.state, agentState.kind),
            )
        }
        putString(WorkspacePaneField.agentLabel, agentLabel)
        putString(WorkspacePaneField.agentIntent, agentIntent)
        if let progress {
            put(
                WorkspacePaneField.progress,
                WorkspaceStateCodec.encodeU8Pair(progress.state, progress.percent),
            )
        }
        if commandRunning { put(WorkspacePaneField.commandRunning, WorkspaceStateCodec.encodeBool(true)) }
        put(WorkspacePaneField.lastExitCode, lastExitCode.map { WorkspaceStateCodec.encodeI32($0) })
        put(WorkspacePaneField.lastDurationMS, lastDurationMS.map { WorkspaceStateCodec.encodeU32($0) })
        if let grid { put(WorkspacePaneField.grid, WorkspaceStateCodec.encodeU16Pair(grid.cols, grid.rows)) }
        // ALWAYS emitted — the pane object's existence marker.
        put(WorkspacePaneField.liveness, WorkspaceStateCodec.encodeU8(liveness.rawValue))
        if completionEpoch != 0 {
            put(WorkspacePaneField.completionEpoch, WorkspaceStateCodec.encodeU32(completionEpoch))
        }
        if lastActivityMS != 0 {
            put(WorkspacePaneField.lastActivityMS, WorkspaceStateCodec.encodeI64(lastActivityMS))
        }
        return out
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
    /// Every field decodes independently and a malformed one is DROPPED to its default rather than
    /// failing the record: these bytes came off a socket, and one bad `grid` must not blank a pane's
    /// title. Returns `nil` only when the pane has no ``WorkspacePaneField/liveness`` entry — i.e.
    /// when the document holds no such pane.
    public init?(paneID: UUID, entries: HostWorkspaceState) {
        func value(_ field: UInt8) -> Data? {
            entries[WorkspaceKey(.pane, paneID, field)]
        }
        func string(_ field: UInt8) -> String? {
            value(field).flatMap { WorkspaceStateCodec.decodeString($0) }
        }
        guard let livenessByte = value(WorkspacePaneField.liveness)
            .flatMap({ WorkspaceStateCodec.decodeU8($0) })
        else { return nil }
        // An unknown liveness byte from a newer host is treated as `dead`: rendering a pane STALE
        // when it is actually live is a cosmetic miss, while rendering a dead pane live is the
        // fake-live bug. Degrade toward the safe side.
        let liveness = PaneLivenessState(rawValue: livenessByte) ?? .dead
        let agentPair = value(WorkspacePaneField.agentState).flatMap { WorkspaceStateCodec.decodeU8Pair($0) }
        let progressPair = value(WorkspacePaneField.progress).flatMap { WorkspaceStateCodec.decodeU8Pair($0) }
        let gridPair = value(WorkspacePaneField.grid).flatMap { WorkspaceStateCodec.decodeU16Pair($0) }
        self.init(
            paneID: paneID,
            liveness: liveness,
            liveTitle: string(WorkspacePaneField.liveTitle),
            titleFresh: value(WorkspacePaneField.titleFresh)
                .flatMap { WorkspaceStateCodec.decodeBool($0) } ?? false,
            cwd: string(WorkspacePaneField.cwd),
            projectKey: string(WorkspacePaneField.projectKey),
            foregroundProcess: string(WorkspacePaneField.foregroundProcess),
            runningCommand: string(WorkspacePaneField.runningCommand),
            agentState: agentPair.map { AgentState(state: $0.0, kind: $0.1) },
            agentLabel: string(WorkspacePaneField.agentLabel),
            agentIntent: string(WorkspacePaneField.agentIntent),
            progress: progressPair.map { Progress(state: $0.0, percent: $0.1) },
            commandRunning: value(WorkspacePaneField.commandRunning)
                .flatMap { WorkspaceStateCodec.decodeBool($0) } ?? false,
            lastExitCode: value(WorkspacePaneField.lastExitCode)
                .flatMap { WorkspaceStateCodec.decodeI32($0) },
            lastDurationMS: value(WorkspacePaneField.lastDurationMS)
                .flatMap { WorkspaceStateCodec.decodeU32($0) },
            grid: gridPair.map { Grid(cols: $0.0, rows: $0.1) },
            completionEpoch: value(WorkspacePaneField.completionEpoch)
                .flatMap { WorkspaceStateCodec.decodeU32($0) } ?? 0,
            lastActivityMS: value(WorkspacePaneField.lastActivityMS)
                .flatMap { WorkspaceStateCodec.decodeI64($0) } ?? 0,
        )
    }
}

// MARK: - Merge

public extension HostWorkspaceState {
    /// Declares that one pane has no process, keeping only what describes a PLACE.
    ///
    /// `cwd` and `projectKey` survive because they are still true — the directory a dead pane was
    /// working in has not moved — and because the By-Project sidebar would otherwise re-bucket every
    /// restored row the moment its shell is gone. Everything else is a claim about a running process
    /// and would render the pane fake-live.
    @discardableResult
    mutating func markPaneDead(_ paneID: UUID) -> Bool {
        merge(paneLiveness: PaneLiveness(
            paneID: paneID,
            liveness: .dead,
            cwd: string(WorkspaceKey(.pane, paneID, WorkspacePaneField.cwd)),
            projectKey: string(WorkspaceKey(.pane, paneID, WorkspacePaneField.projectKey)),
        ))
    }

    /// Replaces one pane's LIVENESS fields wholesale, leaving its topology fields untouched.
    ///
    /// Clear-then-write, not write-over: a fact that stopped being true has to disappear. Writing
    /// only the fields the new record carries would latch `runningCommand` after the command
    /// finished and `agentLabel` after the agent exited — the same "edge published, value retained
    /// nowhere" failure this whole document exists to fix, just moved one layer up.
    ///
    /// - Returns: `true` if anything actually changed. The caller uses this to decide whether the
    ///   document's `stateNum` moves — a no-op recapture must never churn a version number, because
    ///   every subscriber pays for a version bump.
    @discardableResult
    mutating func merge(paneLiveness record: PaneLiveness) -> Bool {
        var changed = false
        var next = [WorkspaceKey: Data]()
        for entry in record.entries() { next[entry.key] = entry.value }
        for field in PaneLiveness.livenessFields() {
            let key = WorkspaceKey(.pane, record.paneID, field)
            let incoming = next[key]
            if self[key] != incoming {
                self[key] = incoming
                changed = true
            }
        }
        return changed
    }
}
