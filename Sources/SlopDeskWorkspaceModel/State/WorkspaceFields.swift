import Foundation

// MARK: - Field vocabulary

/// The field bytes of each object kind (docs/45 §5.3).
///
/// These are RAW VALUES ON THE WIRE — frozen the moment a golden vector carries one. They live here,
/// beside ``WorkspaceObjectKind``, because the host writes them and the client reads them and neither
/// may guess: a field number invented independently on two sides is a silent divergence with no
/// decoder to catch it (every value is length-prefixed, so a mis-numbered field decodes cleanly into
/// the wrong meaning).
///
/// Nothing in the codec maps THROUGH these enums. An unknown field byte is kept verbatim, exactly
/// like an unknown `kindTag` — see ``WorkspaceStateCodec``. They are a naming discipline for the two
/// ends, not a validation gate.

/// `kindTag 0` — the singleton root object, addressed by ``WorkspaceObjectKind/rootObjectID``.
public enum WorkspaceRootField {
    public static let sessionOrder: UInt8 = 0
    public static let activeSessionID: UInt8 = 1
    public static let hostDisplayName: UInt8 = 2
    public static let layoutPresets: UInt8 = 3
    public static let launchPresets: UInt8 = 4
    public static let sessionTemplates: UInt8 = 5
    public static let closedTabRing: UInt8 = 6
    /// The host-owned session that parents panes with no client — ctl-spawned panes (docs/45 §4.1).
    public static let unattachedSessionID: UInt8 = 7
}

/// `kindTag 1` — a session, addressed by its `SessionID`.
public enum WorkspaceSessionField {
    public static let name: UInt8 = 0
    public static let tabOrder: UInt8 = 1
    public static let activeTabID: UInt8 = 2
    public static let detachedPanes: UInt8 = 3
    public static let focusMRU: UInt8 = 4
}

/// `kindTag 2` — a tab, addressed by its `TabID`.
public enum WorkspaceTabField {
    public static let title: UInt8 = 0
    public static let sessionID: UInt8 = 1
    public static let layoutStructure: UInt8 = 2
    public static let activePaneID: UInt8 = 3
    public static let zoomedPaneID: UInt8 = 4
    public static let syncInputArmed: UInt8 = 5
    public static let userRenamed: UInt8 = 6
}

/// `kindTag 3` — a pane, addressed by the HOST-MINTED pane id (the mux `sessionID`).
///
/// Split by ownership, because the split is what Phase 4 ships:
/// - **Topology** (``kind``, ``title``, ``userRenamed``, ``videoTarget``, ``spawnCwd``) is written by
///   an intent and persisted.
/// - **Liveness** (everything else) is derived from the running process, republished on every host
///   restart, and deliberately NOT persisted — restoring `commandRunning = 1` for a process that no
///   longer exists is the "fake-live" render docs/45 §6.5 exists to prevent.
public enum WorkspacePaneField {
    public static let kind: UInt8 = 0
    public static let title: UInt8 = 1
    public static let userRenamed: UInt8 = 2
    /// The OSC-sniffed window title. Was `PaneSpec.lastKnownTitle` — a client cache of
    /// `MuxChannelSession._currentTitle` with no invalidation signal, which is the reported bug.
    public static let liveTitle: UInt8 = 3
    /// The host's VERDICT on whether ``liveTitle`` still describes what is on screen. Replaces the
    /// client's two-stamp guess (`programTitle(for:)`); the four rules are ``PaneTitleFreshness``.
    public static let titleFresh: UInt8 = 4
    public static let cwd: UInt8 = 5
    public static let projectKey: UInt8 = 6
    public static let foregroundProcess: UInt8 = 7
    /// The host's own open command block. The client's `TerminalBlockModel` is per-materialization,
    /// so a client that has rendered zero bytes cannot reproduce the sidebar title chain at all.
    public static let runningCommand: UInt8 = 8
    /// `[u8 state][u8 kind]` — the type-27 pair.
    public static let agentState: UInt8 = 9
    public static let agentLabel: UInt8 = 10
    public static let agentIntent: UInt8 = 11
    /// `[u8 state][u8 percent]` — the type-32 pair.
    public static let progress: UInt8 = 12
    public static let commandRunning: UInt8 = 13
    public static let lastExitCode: UInt8 = 14
    public static let lastDurationMS: UInt8 = 15
    /// `[u16 cols][u16 rows]` — published so a non-contributing client letterboxes instead of guessing.
    public static let grid: UInt8 = 16
    public static let liveness: UInt8 = 17
    /// A monotone counter bumped on every working→done edge. The host holds ZERO per-client
    /// acknowledgement state; each viewer compares it against its own `seenCompletionEpoch`.
    public static let completionEpoch: UInt8 = 18
    public static let lastActivityMS: UInt8 = 19
    public static let videoTarget: UInt8 = 20
    public static let spawnCwd: UInt8 = 21
}

/// `kindTag 4` — one divider, addressed by its `SplitNodeID`.
///
/// Weights are their OWN object rather than part of `tab/layoutStructure` so two clients dragging two
/// different dividers write two different keys and cannot clobber each other (docs/45 §5.3).
public enum WorkspaceSplitNodeField {
    public static let weight: UInt8 = 0
}

/// `kindTag 5` — a project, addressed by a UUID derived from its key.
public enum WorkspaceProjectField {
    public static let key: UInt8 = 0
    /// The type-35 body verbatim — so a never-seen-this-host client renders the git line immediately
    /// instead of waiting for the first FSEvents edge.
    public static let gitSummary: UInt8 = 1
}

// MARK: - Liveness

/// How real a pane's process is right now (`pane/liveness`, docs/45 §4.1).
///
/// The distinction a client cannot make for itself: after a hostd restart the topology is restored
/// from disk but `DetachedSessionStore` is in-process, so every restored pane is ``dead`` — and must
/// render STALE (dimmed, no busy dot), never fake-live.
public enum PaneLivenessState: UInt8, Sendable, CaseIterable {
    /// A live PTY with a client attached.
    case attached = 0
    /// A live PTY with no client attached — the shell keeps running (tmux semantics).
    case detached = 1
    /// No process: restored from disk, evicted from the detached store, or the child exited.
    case dead = 2
}

// MARK: - titleFresh

/// The `pane/titleFresh` decision (docs/45 §4.4), as a pure function of two host-owned timestamps.
///
/// It lives here — not in the host target — because it IS the fix for the reported bug and deserves a
/// test that runs without a PTY. The host owns both inputs (the OSC-title stamp and the command
/// segmenter's open-block start), so the host ships the verdict rather than the two stamps; the
/// client-side comparison it replaces (`programTitle(for:)`) failed permanently whenever one of its
/// two in-memory stamp dictionaries was empty, which is every cold client start.
public enum PaneTitleFreshness {
    /// - Parameters:
    ///   - titleStampedAt: when the current `liveTitle` was sniffed; `nil` when no title has arrived.
    ///   - commandStartedAt: when the CURRENT command block opened; `nil` at a prompt.
    ///   - liveness: a pane with no process can have no fresh title.
    public static func isFresh(
        titleStampedAt: TimeInterval?,
        commandStartedAt: TimeInterval?,
        liveness: PaneLivenessState,
    ) -> Bool {
        // Rule 4 — a dead pane's restored title describes a process that no longer exists. Without
        // this the host would apply rule 1 to it (no open block → trust) and render a ghost title
        // forever, unrecoverably: restored scrollback is appended with `control: []` and bypasses
        // `HostOutputSniffer`, so a replayed OSC escape can never regenerate the type-21 push.
        guard liveness != .dead else { return false }
        // No title at all is not a freshness question.
        guard let titleStampedAt else { return false }
        // Rule 1 — no open command block: TRUST. Hookless shells (Starship without OSC 133) never
        // open a block, and must not lose their titles for it. This is the half of the bug that a
        // reattach re-assert alone does not fix.
        guard let commandStartedAt else { return true }
        // Rules 2 and 3 — a title stamped at or after the current command started describes THAT
        // command; one stamped before it describes whatever ran previously.
        return titleStampedAt >= commandStartedAt
    }
}
