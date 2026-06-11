import Foundation

// MARK: - Identity

/// Stable identity for a single pane (a leaf in the ``PaneNode`` tree).
///
/// A `PaneID` is the join key between the two halves of the workspace architecture
/// (docs/22 §1.1): the **tree of intent** (this pure value tree) and the **table of liveness**
/// (the `[PaneID: any PaneSessionHandle]` registry in the later `WorkspaceStore`). It is minted
/// once when a leaf is created and is **stable for the lifetime of that pane's session** —
/// split / focus / zoom / resize re-renders never change it, only a true session swap does.
/// That stability is load-bearing: SwiftUI keys each leaf host view with `.id(PaneID)` so a
/// `GhosttySurface` / video pipeline / input `Coordinator` is never reused across panes
/// (docs/22 §7, the `.id(PaneID)` identity hazard).
public struct PaneID: Hashable, Codable, Sendable {
    public let raw: UUID
    /// Mints a fresh identity. The default is the common path (a brand-new pane); pass an
    /// explicit `UUID` only when reconstructing a known identity (e.g. decode, or a test that
    /// pins a value for assertions).
    public init(raw: UUID = UUID()) { self.raw = raw }
}

/// Stable identity for a ``PaneGroup`` — a named, ordered collection of panes on the single canvas
/// (the replacement for the retired tab concept, docs/31).
///
/// Mirrors ``PaneID``: minted once, stable across the group's lifetime, survives the persistence
/// round-trip (docs/22 §6) so a pane's `groupID` membership and the sidebar's group order stay valid
/// after restore.
public struct PaneGroupID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}

// MARK: - Leaf intent (what a pane IS — never a live object)

/// What a pane *is*. The kind selects which proven per-session stack the live layer will
/// materialize for the leaf (docs/22 §7): a plain remote terminal, a Claude Code terminal with
/// a second read-only inspector channel, or a remote-GUI video window.
///
/// `String`-raw + hand-stable so the persisted JSON discriminator is human-readable and
/// versionable.
public enum PaneKind: String, Codable, Sendable, Equatable {
    /// A remote PTY terminal (PATH 1 byte pipeline).
    case terminal
    /// A Claude Code terminal — a `terminal` plus the read-only structured inspector channel.
    case claudeCode
    /// A remote-GUI video window (PATH 2 UDP media + cursor side-channel).
    case remoteGUI
}

/// Which remote window a `.remoteGUI` (video) pane mirrors. The host + UDP ports are no longer here —
/// they live ONCE on the app-global ``ConnectionTarget`` (docs/31). All video panes ride the one shared
/// UDP flow at the app host; only the per-pane `windowID` selects which host-side window to stream.
/// Persisted with the tree so a restored video pane remembers its window + title; the actual UDP is
/// opened against the app target.
public struct VideoEndpoint: Codable, Sendable, Equatable {
    /// The host-side window being mirrored (ScreenCaptureKit window id).
    public var windowID: UInt32
    /// Human-readable window title (shown in pane chrome before the stream is live).
    public var title: String
    public init(windowID: UInt32, title: String) {
        self.windowID = windowID
        self.title = title
    }
}

/// The full value-typed description of a leaf: its kind, its display title, and (for `.remoteGUI`) the
/// window it mirrors. The connection host is NOT here — terminals/Claude open a channel on the app-global
/// ``ConnectionTarget`` and `.remoteGUI` opens a lane on the same host's UDP flow, selecting its window
/// via ``video``.
///
/// A `PaneSpec` is pure intent: it is what the pane *should* be, not a handle to anything live.
/// The store reads it to materialize a session; mutating it (e.g. rename) is done through
/// ``PaneNode/updatingSpec(_:_:)`` and triggers a reconcile downstream.
public struct PaneSpec: Codable, Sendable, Equatable {
    public var kind: PaneKind
    public var title: String
    /// Set for `remoteGUI` panes (which host-side window to mirror).
    public var video: VideoEndpoint?

    public init(kind: PaneKind, title: String, video: VideoEndpoint? = nil) {
        self.kind = kind
        self.title = title
        self.video = video
    }
}

// MARK: - Focus intent

/// A focus-movement intent, resolved geometrically against the solved layout (docs/22 §2.1).
///
/// The four cardinal directions move to the nearest pane in that direction *as the user sees it*
/// (``FocusResolver/neighbor(of:_:in:)`` works on the same rects the layout renders, never on
/// abstract tree position). `next` / `previous` cycle through the pre-order leaf list with wrap
/// (``FocusResolver/cycle(_:from:forward:)``), which is what `⌘]` / `⌘[` and a compact swipe map
/// to.
public enum FocusDirection: Sendable, Equatable {
    case left
    case right
    case up
    case down
    /// Cycle forward through the leaves (wraps past the end).
    case next
    /// Cycle backward through the leaves (wraps past the start).
    case previous
}
