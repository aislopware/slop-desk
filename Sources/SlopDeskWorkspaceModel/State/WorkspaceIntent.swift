import CSlopDeskFFI
import Foundation

// MARK: - Ops

/// The topology changes a client may ASK for (docs/45 §5.4). The raw value is the `op` byte inside a
/// type-17 `intent` request, so these numbers are frozen once a golden vector carries one.
///
/// Every one names a topology change `slopdesk_wire::document::apply` knows how to make. This file is
/// the ENCODE half only: what a client asks for and how it spells the ask. The decode half — the
/// bounds-checked `Reader` and the byte→enum readings that went with it — lived here until the
/// applier moved to Rust, and was deleted with it rather than kept as a second decoder nothing calls.
public enum WorkspaceIntentOp: UInt8, Sendable, CaseIterable {
    /// The legacy one-shot: a client uploads its own tree to a host whose document is untouched.
    case adoptWorkspace = 0
    case renamePane = 1
    case renameTab = 2
    case renameSession = 3
    case closePane = 4
    case closeTab = 5
    case splitPane = 6
    case movePane = 7
    case reorderTabs = 8
    case focusTab = 9
    case focusPane = 10
    case setSyncInput = 11
    case spawnPane = 12
    case spawnTab = 13
    case setZoom = 14
    case detachPane = 15
    case reattachPane = 16
    /// The ONLY writer of `splitNode/weight`.
    case setDividerWeight = 17
    case newSession = 18
    case closeSession = 19
    case reopenClosedTab = 20
    /// ⌃⌘T — eject a pane into a new tab of its session.
    case breakPaneToTab = 21
    /// Exchange two leaves in place. Backs both the drag-onto-pane swap and the directional move: the
    /// client resolves the geometric neighbour against the layout IT is looking at and sends the
    /// resolved pair, so the host never needs a viewport to answer "which pane is to the left".
    case swapPanes = 22
    /// Dock a pane at an OUTER edge of a tab, wrapping the whole tab root. No `(source, target, axis,
    /// before)` triple can express it — there is no target leaf, the target is the container.
    case dockPaneAtTabEdge = 23
    /// Re-shape a tab from a whole `layoutStructure`. One op for every re-tile: apply a preset, cycle
    /// to the next one, and balance the splits are all "this tab now has this shape".
    case setTabLayout = 24
    /// Mint a pane straight into a session's DETACHED set — how a `.desktop` pane is born, and the
    /// only intent that can write `pane/kind`.
    case spawnDetachedPane = 25
    /// Re-point an EXISTING pane's video binding. The display switcher and the window re-pick both
    /// move a stream that is already running, so the mint's target cannot be the last word: without
    /// this the document keeps naming the display the pane opened on, and a relaunch re-streams it.
    case setPaneVideoTarget = 26
}

// MARK: - Outcome

/// What one intent did.
///
/// A model-local enum rather than the protocol's `WorkspaceIntentStatus` because this target has ZERO
/// package dependencies — that is the constraint that lets hostd import it at all. The host maps one
/// onto the other at the wire edge, which is the only place the two need to agree.
public enum WorkspaceIntentOutcome: Equatable, Sendable {
    /// The desired state now holds. Reported even when nothing CHANGED: focusing an already-focused
    /// pane is a satisfied request, and a state-transfer system has no business distinguishing them —
    /// that is also what makes a duplicated intent free.
    case applied(WorkspaceTopology)
    /// A bootstrap that arrived too late: the document has already been touched.
    case rejectedStale
    /// Well-formed but not allowed — a malformed payload, a proposed id already in use, a structure
    /// that would breach the depth cap or break the specs invariant.
    case rejectedInvalid
    /// A referenced pane / tab / session is not in the document.
    case rejectedNotFound
    case unknownOp

    public var topology: WorkspaceTopology? {
        guard case let .applied(topology) = self else { return nil }
        return topology
    }
}

// MARK: - Arguments

/// The per-op argument payloads, hand-rolled big-endian like everything else that crosses the wire.
///
/// `WorkspaceTreeOps` is exercised today only from the client's `@MainActor` store with trusted local
/// input. Running it inside a host actor exposes it to a network peer, so every payload here is
/// validate-then-drop: counts bounded before allocating, strings strict UTF-8 and capped, no field
/// force-unwrapped, and — the part the tree ops have never needed — every referenced id checked
/// against the document before the op runs.
public enum WorkspaceIntentArgs {
    /// Cap on a name a client may set. Long enough for any real title, short enough that a peer
    /// cannot make the host retain megabytes per rename. Every cap here is ASKED FOR, because the
    /// host validates against its own copy before it allocates: a client encoding to a larger
    /// transcribed number builds intents the document silently drops.
    public static let maxNameBytes = slopdesk_ws_intent_limit(0)
    /// Cap on a `reorderTabs` list. Real sessions have single-digit tab counts.
    public static let maxTabCount = slopdesk_ws_intent_limit(1)
    /// Cap on the two blobs that carry a whole sub-payload — a `layoutStructure` and a
    /// `videoTarget`. Both are bounded by their own grammars once decoded; this bounds them BEFORE
    /// anything is copied out of the reader.
    public static let maxBlobBytes = slopdesk_ws_intent_limit(2)

    // MARK: Encode

    public static func encode(pane: PaneID) -> Data { WorkspaceStateCodec.encodeUUID(pane.raw) }
    public static func encode(tab: TabID) -> Data { WorkspaceStateCodec.encodeUUID(tab.raw) }
    public static func encode(session: SessionID) -> Data { WorkspaceStateCodec.encodeUUID(session.raw) }

    public static func encode(id: UUID, name: String) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(id)
        out.append(encodeName(name))
        return out
    }

    public static func encode(id: UUID, flag: Bool) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(id)
        out.append(flag ? 1 : 0)
        return out
    }

    /// `splitPane` / `spawnPane`: `[16B target][u8 axis][u8 before][16B newPane][u16 len][spawnCwd]`.
    ///
    /// The NEW pane's id is PROPOSED BY THE CLIENT, not minted by the host. docs/45 has the client
    /// learn it back from the resulting diff; proposing is strictly better and the reason is latency:
    /// an optimistic overlay cannot insert a leaf it has no id for, so a host-minted id makes every
    /// split wait a round trip before anything appears. It also makes a retried intent idempotent.
    /// The host still decides — a proposed id already in use is `rejectedInvalid`.
    public static func encode(
        target: UUID,
        axis: SplitAxis,
        before: Bool,
        newPane: PaneID,
        spawnCwd: String?,
    ) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(target)
        out.append(axis == .horizontal ? 0 : 1)
        out.append(before ? 1 : 0)
        out.append(WorkspaceStateCodec.encodeUUID(newPane.raw))
        out.append(encodeName(spawnCwd ?? ""))
        return out
    }

    /// `movePane`: `[16B source][16B target][u8 axis][u8 before]`.
    public static func encode(source: PaneID, target: PaneID, axis: SplitAxis, before: Bool) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(source.raw)
        out.append(WorkspaceStateCodec.encodeUUID(target.raw))
        out.append(axis == .horizontal ? 0 : 1)
        out.append(before ? 1 : 0)
        return out
    }

    /// `reorderTabs`: `[16B session][u16 n][16B tab]*`.
    public static func encode(session: SessionID, tabOrder: [TabID]) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(session.raw)
        out.append(WorkspaceStateCodec.encodeUUIDList(tabOrder.map(\.raw)))
        return out
    }

    /// `spawnTab`: `[16B session][16B newPane][u8 position][u16 len][spawnCwd]`.
    public static func encode(
        session: SessionID,
        newPane: PaneID,
        position: NewTabPosition,
        spawnCwd: String?,
    ) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(session.raw)
        out.append(WorkspaceStateCodec.encodeUUID(newPane.raw))
        out.append(positionByte(position))
        out.append(encodeName(spawnCwd ?? ""))
        return out
    }

    /// `newSession`: `[16B session][16B newPane][u16 len][name][u16 len][spawnCwd]`.
    ///
    /// The cwd rides alongside the name because a new window INHERITS one. Without it the pane's
    /// starting directory is unrepresentable and every new session silently opens at the host default
    /// — the same fact `splitPane` and `spawnTab` already carry.
    public static func encode(
        newSession: SessionID,
        newPane: PaneID,
        name: String,
        spawnCwd: String?,
    ) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(newSession.raw)
        out.append(WorkspaceStateCodec.encodeUUID(newPane.raw))
        out.append(encodeName(name))
        out.append(encodeName(spawnCwd ?? ""))
        return out
    }

    /// `swapPanes`: `[16B a][16B b]`.
    public static func encode(swap a: PaneID, with b: PaneID) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(a.raw)
        out.append(WorkspaceStateCodec.encodeUUID(b.raw))
        return out
    }

    /// `dockPaneAtTabEdge`: `[16B source][16B tab][u8 edge]`.
    ///
    /// The tab is named even though the source's own tab could be derived, because it is what makes
    /// the intent SELF-VALIDATING: the client is asserting which container it saw the pane docked
    /// into, and a host whose tree has since moved the pane elsewhere refuses instead of docking it
    /// somewhere the user never pointed at.
    public static func encode(dock source: PaneID, tab: TabID, edge: PaneDropEdge) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(source.raw)
        out.append(WorkspaceStateCodec.encodeUUID(tab.raw))
        out.append(edgeByte(edge))
        return out
    }

    /// `setTabLayout`: `[16B tab][layoutStructure bytes]`.
    ///
    /// The SAME encoding `tab/layoutStructure` carries in the document — one shape grammar, so a
    /// client can round-trip the layout it is looking at straight back as an intent.
    public static func encode(tab: TabID, layout: WorkspaceLayoutNode) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(tab.raw)
        out.append(WorkspaceStateCodec.encodeLayout(layout))
        return out
    }

    /// `spawnDetachedPane`: `[16B newPane][u8 kind][u16 len][videoTarget]`.
    ///
    /// A zero length is "no target" — a detached terminal. The blob is the `pane/videoTarget`
    /// encoding, so what the intent proposes and what the document publishes are the same bytes.
    public static func encode(detachedPane: PaneID, kind: PaneKind, video: VideoEndpoint?) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(detachedPane.raw)
        out.append(WorkspacePaneKindTag.byte(for: kind))
        appendBlob(video.map { WorkspaceStateCodec.encodeVideoTarget($0) } ?? Data(), to: &out)
        return out
    }

    /// `setPaneVideoTarget`: `[16B pane][u16 len][videoTarget]`.
    ///
    /// The same blob `spawnDetachedPane` carries, so the mint and the re-point speak one grammar. A
    /// zero length UNBINDS the pane — a picker cleared, a target that went away — which stays
    /// distinct from "the bytes did not decode".
    public static func encode(pane: PaneID, video: VideoEndpoint?) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(pane.raw)
        appendBlob(video.map { WorkspaceStateCodec.encodeVideoTarget($0) } ?? Data(), to: &out)
        return out
    }

    /// `reopenClosedTab`: `[u16 lifoIndex][u8 position]`.
    ///
    /// The index counts from the END of the ring — `0` is the most recently closed tab, the one a
    /// `popLast()` would return. Index-addressed rather than implicit because Open-Quickly's Recent
    /// rows must reopen row N, and always popping the newest is exactly the bug that produced.
    public static func encode(reopenLIFOIndex: Int, position: NewTabPosition) -> Data {
        let index = UInt16(truncatingIfNeeded: max(0, reopenLIFOIndex))
        var out = Data([UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index)])
        out.append(positionByte(position))
        return out
    }

    /// `setDividerWeight`: `[16B split][u16 leadingIndex][u64 BE Double.bitPattern]`.
    ///
    /// The leading weight only — the op is sum-preserving, so naming the trailing one too would let a
    /// hostile pair sum to something the solver has to repair anyway.
    public static func encode(split: SplitNodeID, leadingIndex: Int, leadingWeight: Double) -> Data {
        var out = WorkspaceStateCodec.encodeUUID(split.raw)
        let index = UInt16(truncatingIfNeeded: max(0, leadingIndex))
        out.append(UInt8(truncatingIfNeeded: index >> 8))
        out.append(UInt8(truncatingIfNeeded: index))
        let bits = leadingWeight.bitPattern
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
        return out
    }

    /// Appends `blob` behind its `u16` big-endian length, writing exactly the number of bytes that
    /// length DECLARES.
    ///
    /// The port of `slopdesk_wire::document::intent::put_blob`, and it closes what this file used to
    /// do at both of its call sites: write a WRAPPED length (`count >> 8`, `count`) and then append
    /// every byte regardless. Past 64 KiB the two disagree, and a length that lies is not a big
    /// blob — it is a MIS-SPLIT FRAME: the decoder stops the blob early and reads its tail as the
    /// next field, or runs past it into the next one. Clamping the length and cutting the payload to
    /// it keeps the frame self-consistent whatever the caller hands over.
    ///
    /// The fix is invisible in the golden vectors on purpose, and that is the point rather than a
    /// gap in them: ``maxBlobBytes`` (16 KiB) refuses anything remotely this large on the way back
    /// in, so no payload a real client sends is within four times of the boundary and every pinned
    /// byte sequence is unchanged. What moves is only the pathological case, and it moves from "a
    /// frame that decodes as something else" to "a frame that decodes to a truncated blob the host
    /// then rejects" — a refusal instead of a corruption.
    ///
    /// One helper for both call sites rather than the two identical copies that were here: two
    /// copies is exactly how one of them gets fixed alone.
    private static func appendBlob(_ blob: Data, to out: inout Data) {
        let declared = UInt16(clamping: blob.count)
        out.append(UInt8(truncatingIfNeeded: declared >> 8))
        out.append(UInt8(truncatingIfNeeded: declared))
        out.append(blob.prefix(Int(declared)))
    }

    private static func encodeName(_ name: String) -> Data {
        let bytes = WorkspaceStateCodec.encodeString(name, maxBytes: maxNameBytes)
        var out = Data([UInt8(truncatingIfNeeded: bytes.count >> 8), UInt8(truncatingIfNeeded: bytes.count)])
        out.append(bytes)
        return out
    }

    static func positionByte(_ position: NewTabPosition) -> UInt8 {
        switch position {
        case .auto: 0
        case .end: 1
        case .afterCurrent: 2
        }
    }

    /// The dock edge as a byte — ``PaneDropEdge/byte``, which every door taking an edge reads.
    static func edgeByte(_ edge: PaneDropEdge) -> UInt8 { edge.byte }
}
