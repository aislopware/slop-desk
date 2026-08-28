import CoreGraphics
import Foundation
import Network
import SlopDeskAgentDetect
import SlopDeskClient
import SlopDeskInspector
import SlopDeskNet
import SlopDeskTransport
import SlopDeskWorkspaceModel

// MARK: - WorkspaceStore (the one @MainActor @Observable owner)

/// The single owner of the workspace: it holds the pure ``Workspace`` tree of intent and reconciles
/// the `[PaneID: any PaneSessionHandle]` table of liveness against it after every mutation
/// (docs/22 §1.1, §2.3).
///
/// ### The shape of every mutation
/// Each public intent method does exactly two things, in order:
/// 1. apply a **pure** tree op (returns a new `Workspace`), and
/// 2. call ``reconcile()`` to materialize sessions for new leaves and tear down orphaned ones.
///
/// Because every mutation funnels through `reconcile()`, the load-bearing invariant
/// `Set(registry.keys) == Set(allLeafIDs)` holds after *any* sequence of ops, and there is exactly
/// ONE ``LivePaneSession`` (hence one ordered-OUT stream, one events consumer, one `ReconnectManager`)
/// per ``PaneID`` — the four byte-pipeline invariants by construction (docs/22 §1.2).
///
/// ### The test seam
/// Sessions are built through the injected `makeSession` factory — NOT a fake `SlopDeskClient` (which is
/// impossible) and NEVER a real `HostServer` (forbidden, pool deadlock). Tests inject a
/// `FakePaneSession`; production injects ``LivePaneSession/make(paneID:spec:spawnCwd:makeClient:makeInspector:target:)``.
@preconcurrency
@MainActor
@Observable
public final class WorkspaceStore {
    // MARK: State

    /// The `Session → Tab → Pane` split tree (``TreeWorkspace``, docs/42 §"W4 — Store retarget") — a
    /// PROJECTION of the workspace document (docs/45 §7.2), and the store's SINGLE source of truth.
    ///
    /// Nothing assigns to it. The tree-mutation methods below stage an INTENT
    /// (``WorkspaceStore/stage(_:_:)``), the channel folds the host's own applier into the optimistic
    /// layer, and this reads the result back — so what is on screen is what the host is about to
    /// publish, and two clients converge because there is one owner.
    ///
    /// **With no topology it is EMPTY**, and that is the whole state: a store with no channel, or one
    /// whose host refused the class, renders nothing and every mutation below is a silent no-op. It is
    /// deliberately not a fallback to a locally-owned tree — that dual path is exactly what this
    /// phase removes.
    ///
    /// Memoized against ``workspaceMirrorRevision`` because a projection walks every cell in the
    /// document, and `tree` is read dozens of times per pass: every tracked arm in both shells reads it,
    /// and each canvas re-walks it while laying out.
    public var tree: TreeWorkspace {
        observeWorkspaceMirror()
        if let cached = treeProjection, cached.revision == workspaceMirrorRevision { return cached.tree }
        var projected = mirroredTopology?.tree ?? TreeWorkspace(sessions: [], activeSessionID: nil)
        // A device that does not follow the host's focus rides its own on top (docs/45 §8.2) — which is
        // what lets a phone look at one tab while the Studio works in another.
        if let focus = deviceFocus {
            projected = Self.applying(focus, to: projected)
        }
        // The divider PREVIEW rides on top: a drag frame is a local overlay, never an intent (see
        // ``setDividerWeightLive(splitID:leadingChildIndex:leadingWeight:)``).
        if let live = liveDividerWeight {
            projected = WorkspaceTreeOps.setDividerWeight(
                splitID: live.split, leadingChildIndex: live.index, leadingWeight: live.weight, in: projected,
            )
        }
        treeProjection = (workspaceMirrorRevision, projected)
        return projected
    }

    /// The last projection and the mirror revision it was built from.
    @ObservationIgnored
    private var treeProjection: (revision: UInt, tree: TreeWorkspace)?

    /// The mirror's WHOLE topology — the tree, the sync-input set, the focus MRU, the closed-tab ring
    /// and the `spawnCwd` map — memoized against ``workspaceMirrorRevision``, exactly as ``tree`` is.
    ///
    /// ``WorkspaceMirrorBox/topology`` is a plain computed property over
    /// ``WorkspaceMirrorBox/resolved``, so every read of it copies the entire entry map and then
    /// re-runs ``WorkspaceTopology/init(entries:)`` over every cell in the document. ``tree`` had a
    /// memo and the OTHER halves did not, which made ``syncInputTabs`` — read once per keystroke by
    /// ``fanSyncInput(from:_:)`` and once per SIDEBAR ROW by
    /// `SidebarRowPresentation.reading(for:store:fallbackTitle:)` — pay for the whole projection to
    /// answer whether one tab is in a `Set`. On a sidebar of `R` rows that is `R` full projections per
    /// render pass: quadratic in pane count, for a set membership test.
    ///
    /// The key is the one ``tree`` already trusts, and it inherits ``tree``'s correctness exactly:
    /// every writer that can move the mirror goes through ``WorkspaceMirrorBox/onChange``, which bumps
    /// the counter, and the two LOCAL overlays that never touch the mirror (the divider preview and
    /// this device's own focus) bump it themselves for this reason. A revision that over-invalidates
    /// costs one projection; one that under-invalidates would freeze the layout, so the counter is
    /// deliberately the coarser of the two.
    var mirroredTopology: WorkspaceTopology? {
        observeWorkspaceMirror()
        if let cached = topologyProjection, cached.revision == workspaceMirrorRevision {
            return cached.topology
        }
        let projected = workspaceMirror.topology
        topologyProjection = (workspaceMirrorRevision, projected)
        return projected
    }

    /// The last whole-topology projection and the mirror revision it was built from. A cached `nil`
    /// is an ANSWER — "this mirror holds no workspace" is the state a client spends every
    /// re-subscribe in, and re-deriving it per read would leave the one case with no document the one
    /// case that still walks the document.
    @ObservationIgnored
    private var topologyProjection: (revision: UInt, topology: WorkspaceTopology?)?

    /// ``displayOrderedPaneIDs()``'s answer and the ⌘-digit map derived from it, against the same
    /// revision. Storage lives here because an extension cannot hold it; the derivation is in
    /// `WorkspaceStore+TabOrdering.swift` beside the walk it caches.
    ///
    /// Every input that walk reads is the mirror's: the tree, each pane's spec kind, and each pane's
    /// project key (`pane/projectKey` else `pane/cwd`). So the revision is a sound key for it for the
    /// same reason it is one for ``tree``, and the ⌘-held rail asks for it once per ROW.
    @ObservationIgnored
    var displayOrderProjection: (revision: UInt, order: [PaneID], shortcuts: [PaneID: Int])?

    /// The in-flight divider drag's weight, overlaid onto the projection until
    /// ``commitDividerResize()`` stages it. `nil` between drags.
    @ObservationIgnored
    var liveDividerWeight: (split: SplitNodeID, index: Int, weight: Double)?

    /// Where THIS device is looking while ``DevicePreferences/followSessionFocus`` is off (docs/45
    /// §8.2) — overlaid onto the projection, never sent as an intent. `nil` while this device follows,
    /// which is the only state ``setFollowSessionFocus(_:)`` leaves it in when the flag goes back on.
    @ObservationIgnored
    var deviceFocus: DeviceFocus?

    /// The automation environment ``bootstrapFromEnvironment(_:)`` was handed before a document
    /// existed, held until one does. `nil` once it has run, or when it never had to wait.
    @ObservationIgnored
    var armedBootstrapEnvironment: [String: String]?

    /// The autoconnect layout that environment resolved to, minted ONCE and seeded locally so the
    /// window mounts it immediately. Kept so the run that finally reaches a document adopts the very
    /// tree the panes are already dialling — a second `Session.singlePane` there would mint pane ids
    /// no running shell has. `nil` outside automation, and once the adopt has gone out.
    @ObservationIgnored
    var armedBootstrapShape: BootstrapShape?

    /// The layout this client restored at launch, held until a host document turns up to offer it to
    /// (``runArmedLaunchAdoptIfPossible()``). `nil` once offered, and on the canvas path.
    ///
    /// The seeded TOPOLOGY, not the tree: it carries the cached `spawnCwd` for every restored pane,
    /// and by the time the offer goes out the mirror holds the host's own first frame instead.
    @ObservationIgnored
    var pendingLaunchAdopt: WorkspaceTopology?

    /// The intent id ``runArmedLaunchAdoptIfPossible()`` staged this launch's offer under, or `nil`
    /// when no offer ever went out. The dial hold waits on THIS patch and nothing else.
    @ObservationIgnored
    var launchAdoptIntentID: UUID?

    /// Whether the panes on screen may open their host channels — see ``panesMayDial``.
    ///
    /// STORED and observed, recomputed by ``refreshPaneDialGate()`` at each of the four points that
    /// can move it. It has to be stored: the inputs are `@ObservationIgnored` launch state and the
    /// channel's own state (a plain class), so a computed property reading them would register NOTHING
    /// with Observation and never wake the arm whose connect keys on it — the release edge would reach
    /// no one and the panes would stay dark.
    ///
    /// Written by ``refreshPaneDialGate()`` and nowhere else; read through ``panesMayDial``.
    var paneDialGate = true

    /// How long the hold may stand with no answer of any kind before it opens anyway.
    ///
    /// The arm nothing else bounds: a host that ACCEPTS `channelClass 1` and then publishes no frame
    /// leaves the subscription in `.opening` for good (``WorkspaceChannelClient/State/live(_:)`` is
    /// published only when a frame folds), and a hold with no release is a window of panes that never
    /// connect — strictly worse than the churn it prevents. Injectable so a test can pin the release
    /// without spending it.
    var paneDialHoldBackstop: Duration = .seconds(WorkspaceMirrorBox.pendingTimeout)

    /// The `host:port` whose OWN document is what the panes on screen came from, or `nil` while
    /// nothing a host published has landed.
    ///
    /// The provenance half of ``panesMayDial``: an id may be dialled at the host that named it and
    /// nowhere else. Stamped by ``noteFoldedDocumentProvenance()`` when a document frame folds — the
    /// fold, not any other reason the mirror announces itself, because between committing a new
    /// target and the re-subscribe that answers it the mirror still holds the PREVIOUS host's
    /// document, and stamping there would file one machine's layout under the other's name.
    @ObservationIgnored
    var dialConfirmedHostKey: String?

    /// The fold count ``noteFoldedDocumentProvenance()`` last acted on, so a repaint is told from a
    /// frame. Goes backwards on a `reset()`, which is what makes a re-subscribe unconfirmed again.
    @ObservationIgnored
    var lastFoldedDocumentFrames: UInt64 = 0

    /// Whether ``paneDialHoldBackstop`` has run out on the CURRENT hold episode. Cleared by a connect
    /// to a different host (``commitConnectionTarget(_:)``), which starts a new one.
    @ObservationIgnored
    var paneDialHoldExpired = false

    /// Whether an app-connection establish still owes its panes a fan-out — see
    /// ``armPaneRedialOnDocument()``. Set on every establish, spent by the first document frame the
    /// attached host folds.
    @ObservationIgnored
    var paneRedialAwaitsDocument = false

    /// The armed backstop, cancelled the moment the hold releases on an answer.
    @ObservationIgnored
    var paneDialHoldBackstopTask: Task<Void, Never>?

    /// The workspace channel's own state, mirrored here because ``WorkspaceChannelClient`` is a plain
    /// class — publishing its transitions is this store's job. Kept in step by
    /// ``attachWorkspaceChannel(_:)``'s state hook.
    @ObservationIgnored
    var workspaceChannelState: WorkspaceChannelClient.State = .idle

    /// Records (or clears) the divider preview.
    ///
    /// Bumps ``workspaceMirrorRevision`` even though nothing in the document moved: that counter is
    /// both the projection cache's key and the Observation shadow every `tree` reader binds to, so a
    /// drag frame that skipped it would neither repaint nor invalidate.
    func setLiveDividerWeight(_ next: (split: SplitNodeID, index: Int, weight: Double)?) {
        liveDividerWeight = next
        workspaceMirrorRevision &+= 1
    }

    /// The table of liveness: 1:1 with ``tree``'s leaves. It used to be 1:1 with whichever of two models
    /// was live, and a `liveModel` selector decided which reconcile drove it; the canvas model was deleted
    /// in both languages, so there is one model, one reconcile, and nothing left to arbitrate.
    private var registry: [PaneID: any PaneSessionHandle] = [:]

    /// ⌘⇧U's walk memory (visited-set / origin / last-walk-focused) — see
    /// ``jumpToOldestAttentionPane()``. A `let` reference type so the walk's bookkeeping stays out of
    /// Observation: no view reads it, and a step mutating it must never invalidate view bodies.
    let attentionWalk = AttentionWalkBox()

    /// TRUE while an INTERACTIVE divider drag is in progress (a pane-divider OR the sidebar/inspector
    /// `NSSplitView` divider) — bracketed by ``setTerminalResizeSuspended(_:)``'s begin (`true`) / end
    /// (`false`). The pane resize-scrim reads it so the overlay stays up across a PAUSED drag (mouse held,
    /// cursor still): otherwise the per-frame geometry-settle timer clears the scrim mid-drag and it flashes
    /// back on release (the host grid-send is DEFERRED to release, so nothing else holds the scrim during the
    /// pause). ``PaneContainer`` gates it on THIS pane actually changing size, so only resized panes scrim.
    public private(set) var isInteractiveResizeActive = false

    /// The injection seam (docs/22 §0). Takes a ``PaneMaterialization`` — id, spec and spawn cwd —
    /// because the pane's own id is what it presents to the host on `channelOpen`, so the factory
    /// needs it before it builds the client, not after.
    private let makeSession: @MainActor (PaneMaterialization) -> any PaneSessionHandle

    /// Maximum number of video panes that may hold a LIVE video stack at once (docs/22 §7 the
    /// 2N-UDP / N-VTDecompression / N-CVDisplayLink ceiling). Injectable; default 2. The app resolves it
    /// per device class via ``VideoCapPolicy`` (phone 1 / pad 2 / mac 3); the store keeps the plain `Int`
    /// shape and is agnostic to how the number was chosen.
    ///
    /// ### UDP-mux interaction — cap is intentionally per-pane
    /// Same-host video panes SHARE one UDP flow (2 sockets/host, not 2N), but each pane STILL owns its own
    /// `VTDecompressionSession` + `CVDisplayLink` + Metal renderer — only the UDP socket is shared. The
    /// scarce resources the cap bounds (decode + composite) stay strictly per-pane, so the per-pane cap can
    /// never under-count live decoders. Mux only weakens the "2N-UDP" term to "2-per-host", making the cap
    /// more conservative, never wrong — a per-host socket count would loosen admission for no headroom gain.
    public let liveVideoCap: Int

    /// A monotonic nudge the GUI leaves track to RE-ATTEMPT video admission for gated panes.
    /// The store can't flip a pane's liveness itself — admission is **leaf-driven**: only an on-screen pane
    /// decodes, via `MacGuiLeafView` / `GuiLeafView`'s `applyActivation` → ``activateVideo(_:)``. So when a
    /// slot frees (a video pane deactivated, or an active-video pane closed), no one promotes a
    /// queued-but-still-on-screen gated pane.
    ///
    /// This is what closes that. Each GUI leaf folds this generation into its
    /// `GuiPaneReadout.activationKey(paneHash:promotionGeneration:isVisible:)` INSIDE its
    /// `withObservationTracking` closure, so a bump wakes the arm, the key changes, and `applyActivation`
    /// re-calls `activateVideo` (still cap-gated, so the ceiling holds). The key is what makes the retry
    /// idempotent: an arm that re-fires for some unrelated reason recomputes the SAME key and returns early.
    ///
    /// A PROJECTION of ``VideoSlotLedger/generation``, written only by ``publishVideoSlots(_:)`` from a
    /// door result. The guard that keeps a no-op deactivate or a non-video close from churning the view is
    /// the ledger's, not this side's — this property carries no logic at all, only the last answer.
    public private(set) var videoPromotionGeneration: Int = 0

    /// The TAB whose sidebar row should open its inline rename field — set by the ⌘R / palette "Rename Pane"
    /// + the sidebar row context-menu "Rename" entry on the LIVE tree shell, CONSUMED by the rail row
    /// (``RailRowsBuilder`` lights `isEditing` on that tab's representative pane row; the field commits via
    /// ``renamePane(_:to:)`` and clears through ``clearTabRenameRequest()``). A pending ID rather than a
    /// fired-and-missed counter, so a not-yet-mounted row still acts on the pending value.
    public private(set) var pendingTabRename: TabID?

    /// Requests the inline rename on the ACTIVE TAB — the ⌘R chord's target (the sidebar rail row's
    /// inline-rename field, set via ``pendingTabRename``). No-op without an active tab. This is the
    /// command-layer "Rename" entry the binding registry routes to.
    public func requestRenameActivePane() {
        guard let tabID = tree.activeSession?.activeTab?.id else { return }
        pendingTabRename = tabID
    }

    /// The tab strip consumed the tab-rename request (its inline field is open) — or it became moot.
    public func clearTabRenameRequest() {
        pendingTabRename = nil
    }

    /// Requests the inline rename on an ARBITRARY tab `tabID` (the sidebar row context-menu "Rename"
    /// entry) — sets ``pendingTabRename`` so THAT tab's representative rail row opens its rename
    /// field, even when it is not the active tab. Twin of ``requestRenameActivePane()`` for a mouse-reachable
    /// target the user right-clicked rather than the keyboard-active one.
    public func requestRenameTab(_ tabID: TabID) {
        pendingTabRename = tabID
    }

    /// Where the value tree is persisted (docs/22 §6). Injectable so tests point at a temp dir and a
    /// store built with `nil` persistence (the default for the FakePaneSession test seam) never
    /// touches disk. The app passes a real ``WorkspacePersistence``.
    private let persistence: WorkspacePersistence?

    /// Where the DEVICE-LOCAL facts are persisted (docs/45 §7.3) — the preset library, the latched video
    /// modes, the per-host connection target and ``DevicePreferences/followSessionFocus``. Injectable on
    /// the same terms as ``persistence``: `nil` (the test/automation default) never touches disk.
    private let devicePreferencesStore: DevicePreferencesStore?

    /// The live device-local facts. Loaded once at init and written through on every edit, so the
    /// projected layout — which is host-owned and shared by every client — can never regenerate them away.
    public private(set) var devicePreferences: DevicePreferences

    /// Mutates ``devicePreferences`` and writes it through. Best-effort: a failed write keeps the previous
    /// good file, and with no ``devicePreferencesStore`` the edit is purely in-memory. Internal so the
    /// cross-file store extensions (session templates) share the one edit path.
    func mutateDevicePreferences(_ transform: (inout DevicePreferences) -> Void) {
        transform(&devicePreferences)
        try? devicePreferencesStore?.save(devicePreferences)
    }

    /// Sets whether this device follows the host's session focus (docs/45 §8.2).
    ///
    /// Both directions move ``deviceFocus``, because the flag is the only thing that decides which of
    /// the two views this device renders and neither answer may wait for a tap.
    ///
    /// - ON drops the overlay: a device that has resumed following must show what the host says is
    ///   focused, and a surviving overlay would pin it to a tab no other client can see it on. That
    ///   is also why the overlay needs no second guard on the flag — the only way to hold one is to
    ///   be unfollowing.
    /// - OFF takes hold of what this device is looking at *now*
    ///   (``currentViewAsDeviceFocus()``). With no overlay recorded the projection is host truth
    ///   verbatim, so the other client that is dragging this one goes on dragging it — and this
    ///   switch is reached for precisely while that is happening.
    public func setFollowSessionFocus(_ following: Bool) {
        guard devicePreferences.followSessionFocus != following else { return }
        mutateDevicePreferences { $0.followSessionFocus = following }
        setDeviceFocus(following ? nil : currentViewAsDeviceFocus())
    }

    /// Where the last picture of the host's document is cached (docs/45 §7.3), so a cold launch paints
    /// real folder names before a packet moves. Injectable on the same terms as ``persistence``:
    /// `nil` (the test/automation default) never touches disk.
    private let documentCache: WorkspaceCacheStore?

    /// The `host:port` the cache was SEEDED from — the connect gate's launch target, and the only
    /// host this run's picture can honestly be filed under.
    private let documentCacheSeedHostKey: String

    /// The `host:port` the cache is written under. EMPTY reads as nothing and writes nothing: a
    /// picture with no host on it can never be shown to the right one.
    ///
    /// Cleared for the rest of the run by a connect to a DIFFERENT host than the seed
    /// (``commitConnectionTarget(_:)``). The facts are absolute paths on ONE machine's filesystem, so
    /// after a mid-session host switch the mirror holds a mix of two — and a mixed picture belongs to
    /// neither. The next launch seeds from whichever host the MRU then names, so this self-heals in
    /// one launch rather than persisting a blend forever.
    private var documentCacheHostKey: String

    /// The ``ConnectionTarget`` this app run is talking to — seeded by the app shell from the
    /// ``AppConnection`` MRU at launch and re-stamped by ``commitConnectionTarget(_:)`` on every
    /// successful connect. Purely presentational (the pane status bar names the host); the live
    /// connection itself is owned by ``AppConnection``, never by the store.
    public var committedConnectionTarget: ConnectionTarget?

    /// How long to coalesce a burst of mutations before writing the tree (docs/22 §6 "debounced on
    /// mutation"). One write per quiet period, not one per keystroke-driven split/resize.
    private let saveDebounce: Duration

    /// How long to let a closed video pane's stack ACTUALLY release before the store frees its
    /// ``liveVideoCap`` slot. `teardown()` sets `RemoteWindowModel.active = nil`, which only ARMS the
    /// release: the GUI leaf's tracked arm wakes, hops to the next main-loop turn, unmounts the surface →
    /// `VideoWindowPipeline.deactivate()` → detached `session.stop()` closing the two UDP `NWConnection`s +
    /// `VTDecompressionSession` + display link — completing a few runloop turns AFTER `teardown()` returns.
    /// Freeing the slot immediately could admit a sibling while the outgoing stack is still up (cap+1 — no
    /// crash/leak, just a momentary over-commit). `stop()` is one ordered task
    /// (`VideoWindowPipeline.awaitStopped()`), but it lives inside the platform video view the store cannot
    /// name, unreachable for a direct store `await`; so the store holds the slot for this bounded settle past
    /// `teardown()` to cover the unmount→stop lag. Injectable; DEFAULT `.zero` frees the slot immediately, so the OFF /
    /// terminal-only paths never enter this gate. The PRODUCTION app opts in with a small window
    /// (``ClientComposition``, the composition root). The real dismantle→stop lag is not
    /// hardware-measured.
    private let videoTeardownSettle: Duration

    /// The pending debounced-save task. Cancelled + replaced on each mutation so only the last
    /// mutation in a burst actually writes; cancel-safe (a cancelled sleep simply returns).
    private var saveTask: Task<Void, Never>?

    /// The pending debounced `workspace-cache.json` write, on the same terms as ``saveTask`` — its
    /// own task because a fact change and a layout change are different edges (see
    /// ``scheduleDocumentCacheSave()``).
    @ObservationIgnored var documentCacheSaveTask: Task<Void, Never>?

    /// A monotonic save-generation guard (mirrors ``FocusGenerationGuard``). Each `scheduleSave()` bumps it
    /// and captures the value; the debounced write re-checks it on a MainActor hop BEFORE writing and skips
    /// if superseded, and the trailing `saveTask = nil` clears the handle ONLY if still current — so
    /// a superseded (already-past-sleep) prior task can neither clobber the file with a stale snapshot NOR
    /// nil out the newest handle and strand it uncancellable. Pure MainActor Int bookkeeping.
    /// `internal private(set)`: only the store bumps it, but the guard is observable to the `@testable`
    /// tests via ``isCurrentSaveGeneration(_:)``.
    private(set) var saveGeneration = 0

    /// The pure generation-guard predicate the debounced write consults before writing: a
    /// captured `generation` is still current iff it equals the live ``saveGeneration``. Mirrors
    /// `FocusGenerationGuard.isCurrent(_:)`. Factored out so the production write path and the test
    /// assert the EXACT SAME logic (not a re-implementation). MainActor-isolated; pure read.
    func isCurrentSaveGeneration(_ generation: Int) -> Bool {
        saveGeneration == generation
    }

    /// Suppresses the debounced save during construction (the initial `reconcile()` would otherwise
    /// re-write a just-loaded file with identical bytes). Flipped off once init completes.
    private var savingEnabled = false

    /// In-flight teardown tasks spawned by ``reconcile()`` (teardown is `async`; reconcile is called inline
    /// by synchronous mutations). Tracked so tests — and a deliberate shutdown — can `await` every orphaned
    /// session's `teardown()` via ``quiesce()``. The registry invariant (`keys == leafIDs`) holds the instant
    /// reconcile returns (orphans removed synchronously); `quiesce()` only waits for the *cleanup*.
    ///
    /// Keyed by a monotonic id (not an array) so each task self-prunes its own entry on completion without
    /// the task-captures-itself chicken-and-egg — freeing the handle promptly rather than on the next
    /// orphaning reconcile. Every site (reconcile insert, self-remove, `quiesce()` drain) runs on
    /// `@MainActor`, so the bookkeeping is serialized with no data race.
    private var teardownTasks: [Int: Task<Void, Never>] = [:]
    /// The next teardown-task id (monotonic, wraps harmlessly).
    private var nextTeardownID = 0

    /// The live-video admission LEDGER (docs/22 §7): the ceiling, which panes are decoding, which have
    /// closed but not finished letting go, and the promotion counter over them. A Rust handle
    /// (``VideoSlotLedger``) rather than three stored properties, because it is state AND the decisions
    /// over that state — see its own doc-comment for why that earns a handle.
    ///
    /// A `let` to a reference type, so nothing about mutating it is `@Observable`; ``videoSlotsRevision``
    /// is what carries the change back into the view graph.
    private let videoSlots: VideoSlotLedger

    /// The narrow `@Observable` counter that makes ``hasFreeVideoSlot(for:)`` reactive, bumped from every
    /// site that mutates ``videoSlots`` and from nowhere else.
    ///
    /// It exists because Swift's Observation tracks per STORED PROPERTY and the ledger is not one: a
    /// `GuiLeafView.display` reading the whole `registry` instead would re-render on EVERY unrelated pane
    /// materializing or closing, where this re-renders only on a cap-relevant edge. Deliberately NOT
    /// ``videoPromotionGeneration``, which is guarded to slot-FREEING transitions and would therefore miss
    /// a pane going live — and whose count the cap tests pin.
    private var videoSlotsRevision = 0

    /// The last layout the view solved, cached so geometric ``move(_:)`` can resolve a neighbour
    /// without the store knowing the view's size. `nil` until the view reports one (compact mode never
    /// solves a multi-pane layout — `.next`/`.previous` still work via the pre-order cycle fallback).
    private var lastSolvedLayout: SolvedLayout?

    /// The full `SplitContainer` container bounds (origin .zero, `geo.size`) the active tab last reported
    /// via ``updateContainerBounds(_:)``. A fallback input to ``treeGeometryBounds`` (directional focus /
    /// move-pane resolution) before the first solved-layout report. `nil` until the view reports one.
    private var lastContainerBounds: CGRect?

    /// The single-focus arbiter for the iOS multi-visible (iPad-regular) input path (docs/22 §7). One per
    /// workspace. The regular `PaneTreeView` leaves route their `TerminalInputHost` first-responder through
    /// this so a stale async `becomeFirstResponder` callback can never win (resign-before-become + generation
    /// reject). Compact mode mounts one host and skips it. Cross-platform-compilable (the UIKit calls inside
    /// are `#if os(iOS)`). Exposed so the view layer can drive `focus(_:)` on a focus change.
    public let focusCoordinator = PaneFocusCoordinator()

    /// The per-pane block-bookmark persistence seam + the per-pane jump-to-failed cursor, bundled into
    /// one stored holder (``BlockBookmarkSeam``) so the store body stays under the lint ceiling. The seam's
    /// `load`/`save` are wired by the app to the ``PreferencesStore`` (`settings.blockBookmarks.v1`), keyed
    /// by `bookmarkScopeKey` — the per-MATERIALIZATION token, NOT the stable `PaneID`. A relaunch mints a
    /// fresh segmenter that re-numbers blocks from 0, so keying by pane id re-applied a prior run's raw
    /// indices onto unrelated commands; the scope key deliberately starts a relaunch with NO stars, while
    /// staying stable across a transport reconnect within one launch.
    /// Left default (tests / previews) bookmarks are in-memory only. The `jumpCursor` records the block
    /// index the last jump-to-failed landed on so a repeated ⌃⌘⇧[ / ⌃⌘⇧] walks every failure in order.
    /// `@ObservationIgnored`: wiring, not view state. `internal` so the WorkspaceStore+Blocks extension
    /// reaches it (extensions can't add stored state).
    @ObservationIgnored var blockBookmarks = BlockBookmarkSeam()

    // MARK: Init

    /// - Parameters:
    ///   - restoringTree: a decoded ``TreeWorkspace`` to restore (SHAPE + INTENT only — sessions start
    ///     idle, docs/22 §6). `nil` ⇒ ``TreeWorkspace/defaultWorkspace()`` (one terminal pane).
    ///   - makeSession: the session factory seam (production: `LivePaneSession.make`; tests:
    ///     `{ FakePaneSession($0) }`).
    ///   - liveVideoCap: concurrent live-video ceiling (default 2).
    ///   - persistence: where to debounce-save the live model after mutations (docs/22 §6). `nil` (the
    ///     default) ⇒ no disk writes, so the pure/fake test seam never touches the filesystem; the app
    ///     passes a real ``WorkspacePersistence``.
    ///   - devicePreferences: where the device-local facts persist (docs/45 §7.3). `nil` (the default)
    ///     ⇒ in-memory only, so the pure test seam never touches `device-prefs.json`.
    ///   - documentCache: where the last picture of the host's document is cached (docs/45 §7.3).
    ///     `nil` (the default) ⇒ no disk, so the pure test seam never touches `workspace-cache.json`.
    ///   - cacheHostKey: the `host:port` that cache belongs to — the connect gate's launch target.
    ///     Empty (the default) reads and writes nothing.
    ///   - saveDebounce: the mutation-coalescing window before a write (default 600ms).
    @preconcurrency
    public init(
        restoringTree: TreeWorkspace? = nil,
        makeSession: @escaping @MainActor (PaneMaterialization) -> any PaneSessionHandle,
        liveVideoCap: Int = 2,
        persistence: WorkspacePersistence? = nil,
        devicePreferences: DevicePreferencesStore? = nil,
        documentCache: WorkspaceCacheStore? = nil,
        cacheHostKey: String = "",
        saveDebounce: Duration = .milliseconds(600),
        videoTeardownSettle: Duration = .zero,
    ) {
        self.makeSession = makeSession
        self.liveVideoCap = liveVideoCap
        videoSlots = VideoSlotLedger(cap: liveVideoCap)
        self.persistence = persistence
        devicePreferencesStore = devicePreferences
        self.devicePreferences = devicePreferences?.load() ?? DevicePreferences()
        self.documentCache = documentCache
        documentCacheSeedHostKey = cacheHostKey
        documentCacheHostKey = cacheHostKey
        self.saveDebounce = saveDebounce
        self.videoTeardownSettle = videoTeardownSettle
        // The mirror is a plain value in a plain box — nothing about folding a frame into it is
        // `@Observable`. This is the one wire that makes a document change repaint anything, and the
        // one place a host frame can move a completion counter with no local edge firing at all.
        workspaceMirror.onChange = { [weak self] in
            guard let self else { return }
            workspaceMirrorRevision &+= 1
            reconcileSeenCompletionEpochDocument()
            refreshUnseenDoneForAllPanes()
            // …and the one place the TABLE OF LIVENESS learns of a leaf nothing local asked for.
            reconcileTreeFromDocument()
            // …and the one place a host's own document arrives, which is what makes the ids in it
            // dialable at that host and no other.
            noteFoldedDocumentProvenance()
            // …and where the launch offer's verdict arrives: an `intentResult` snaps its patch away
            // (refused) or the frame behind it retires the patch (accepted). Either answer releases
            // the dial hold, and it has to be AFTER the reconcile above — the panes that then dial
            // are the ones that pass just materialized.
            refreshPaneDialGate()
            // …and the one place a reconnect whose fan-out found an EMPTY document gets its panes
            // back: this frame is what puts them on screen, and the two lines above are what make
            // them dialable at the host that just sent it.
            redialArmedPanesOnConfirmedDocument()
        }
        // Seed the mirror with the tree the store just restored, so `workspaceMirror.topology` is a
        // real layout from the first instant rather than `nil` until a host frame happens to arrive.
        // A client with no channel — headless, a test — never gets one, and a nil
        // topology is silent: `WorkspaceMirrorBox.stageIntent` returns `nil` for it and every call
        // built on that becomes a no-op with nothing logged anywhere.
        //
        // The per-pane facts come from the cache alongside it. They are what makes the FIRST paint a
        // sidebar of folder names in their project sections, and what puts a respawned shell back in
        // its project directory: the client has no live shell to ask on launch, so a fact it does not
        // remember is a fact that is gone.
        // Launch-only: fold persisted detached panes back into tabs (satellite windows do not restore
        // across relaunch — v1; a quit/crash while detached loses nothing). NEVER inside `normalized()`,
        // which runs op-internally and would undo a live detach.
        let seeded = (restoringTree ?? .defaultWorkspace()).normalized().redockingDetachedPanes()
        let seededTopology = seedWorkspaceMirror(
            from: seeded,
            cache: documentCache?.load(hostKey: cacheHostKey) ?? HostWorkspaceState(),
        )
        // …and hold it for a host that has never had a workspace of its own, which is how a layout
        // built before this client ever spoke to a document gets uploaded instead of discarded
        // (``runArmedLaunchAdoptIfPossible()``). The SEEDED TOPOLOGY, so the offer carries each pane's
        // spawn directory as well as its place in the tree — the cache is the only thing that still
        // knows it, and the host's own first frame replaces these entries before the offer goes out.
        pendingLaunchAdopt = seededTopology
        // The init reconcile materializes the tree's leaves through the registry diff every later
        // mutation goes through, so a restored layout and a live one take the exact same path.
        reconcileTree()
        savingEnabled = true // arm debounced saves only AFTER the restore reconcile
    }

    // MARK: - Accessors

    /// The live handle for `id`, or `nil` if no such leaf is materialized.
    public func handle(for id: PaneID) -> (any PaneSessionHandle)? { registry[id] }

    /// Every materialized live handle (unordered; whole-registry sweeps are per-handle idempotent so order
    /// can't matter). Internal so the `registry` stays private to this file.
    var allSessionHandles: [any PaneSessionHandle] { Array(registry.values) }

    /// Whether pane `id`'s shell currently reports a running foreground command (the live
    /// ``PaneSessionHandle/isShellBusy`` bit), or `false` for an unmaterialized pane. Exposes the busy
    /// signal to the rail (the ``TabBadgeResolver`` "running" input) WITHOUT leaking the
    /// private `registry` handle — calling it inside a `withObservationTracking` closure registers the arm
    /// on the handle, exactly like ``PanePresentation/busy(handle:)``.
    public func paneIsBusy(_ id: PaneID) -> Bool { registry[id]?.isShellBusy ?? false }

    /// Whether pane `id`'s plain BUSY DOT (``TabBadgeKind/commandBusy``) should render: the shell is
    /// busy AND the current command has been running at least the configured reveal delay
    /// (``SettingsKey/tabBadgeBusyDelaySecondsValue``, default 1 s) — a fast `ls`/`cd` never flashes
    /// the rail. The `isBusy` input BOTH badge-resolution call sites feed to ``TabBadgeGating/resolve``
    /// (the rail's `chrome(...)` and ``unseenAttentionPanes`` — they must agree). A busy shell with no
    /// start stamp shows immediately (fail-visible — the stamp and the busy bit ride the same OSC-133
    /// `.running` edge, so this is a defensive default, not a path). Everything else (close guards,
    /// broadcast checks) keeps reading the raw ``paneIsBusy(_:)`` — a busy shell must confirm a close
    /// from second zero. `now` is injectable for deterministic threshold tests.
    public func paneShowsBusyDot(_ id: PaneID, now: Date = Date()) -> Bool {
        guard paneIsBusy(id) else { return false }
        guard let startedAt = paneCommandStartedAt[id] else { return true }
        let elapsed = now.timeIntervalSince(startedAt)
        return !elapsed.isLess(than: SettingsKey.tabBadgeBusyDelaySecondsValue)
    }

    /// Folds every live pane's PATH-1 connection status into a compact ``WorkspaceConnectionAlert``
    /// for the collapsed-sidebar connection indicator, or `nil` when all panes are healthy. Iterates the tree
    /// in DFS order (a STABLE worst-pane tie-break) and reads each materialized ``LivePaneSession``'s channel
    /// status; a video pane / faked handle contributes a `nil` status (never an alarm). Calling it inside a
    /// `withObservationTracking` closure registers the arm on EVERY pane's ``ConnectionViewModel/status``, so
    /// the chip redraws as panes drop / recover — the same observation seam
    /// ``PanePresentation/connectionStatus(_:)`` relies on. The breadth is the point AND the cost: one arm
    /// depends on every live pane's status, so it must sit in a chrome-scoped arm rather than a per-pane one.
    public func connectionAlert() -> WorkspaceConnectionAlert? {
        // Union in the DETACHED (satellite) panes — they left the tree but their handles are live
        // (reconcile's widened desired set), and a satellite's dropped connection must still trip the
        // sidebar alarm. Appended after the tree so the tiled DFS tie-break order is unchanged.
        let ids = tree.allPaneIDs() + tree.detachedPaneIDs()
        let entries: [(pane: PaneID, status: ConnectionStatus?)] = ids.map { id in
            (pane: id, status: (registry[id] as? LivePaneSession)?.connection?.status)
        }
        return WorkspaceConnectionAlert.resolve(from: entries)
    }

    /// All live sessions (registry values). Order is unspecified — callers that need a stable order
    /// derive it from the tree's `allLeafIDs()`.
    public var allSessions: [any PaneSessionHandle] { Array(registry.values) }

    // MARK: - Layout reporting (for geometric focus move)

    /// The view reports the layout it just solved for the active tab so the store can resolve
    /// geometric focus moves (``move(_:)``) against the exact rects the user sees (docs/22 §2.1).
    /// View-only state — does NOT touch the tree or registry, so reporting it never reconciles.
    public func updateSolvedLayout(_ solved: SolvedLayout) {
        lastSolvedLayout = solved
    }

    /// The active-tab `SplitContainer` reports its FULL container bounds (origin .zero, `geo.size`) — a
    /// fallback for the geometric ops before the first solved-layout report (``treeGeometryBounds``).
    /// View-only state — never touches the tree, so reporting it never reconciles.
    public func updateContainerBounds(_ bounds: CGRect) {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        lastContainerBounds = bounds
    }

    // MARK: - Pane mutations (pure op → reconcile)

    // MARK: - Close undo (single slot) + busy-shell close guard

    /// The pane awaiting close CONFIRMATION — because its shell reported a running command (⌘W on a
    /// busy shell — killing the session would kill the command), or because it is its project's LAST
    /// pane (closing it closes the whole project — ``projectClosed(byRemoving:)``). The view observes
    /// this and shows a confirmation dialog; ``confirmPendingClose()`` / ``cancelPendingClose()`` resolve
    /// it. `internal(set)` so the `WorkspaceStore+CloseConfirmation` extension's park/resolve helpers can
    /// arm/clear it.
    public internal(set) var pendingClose: PaneID?

    /// The whole TAB awaiting close CONFIRMATION (⌘⇧W "Close Tab" on a tab whose policy/busy-shell guard
    /// says confirm). A tab close is NOT a single-leaf close: confirming it must drop EVERY pane
    /// in the tab, so it is parked as the ``TabID`` (not the active leaf) and resolved through
    /// ``closeTab(_:)``. Mutually exclusive with ``pendingClose`` — ``parkPaneClose(_:)`` /
    /// ``parkTabClose(_:)`` keep exactly one armed so only one confirmation dialog is ever up. Resolved by
    /// ``confirmPendingClose()`` / ``cancelPendingClose()``. In-memory only.
    public internal(set) var pendingTabCloseID: TabID?

    /// The ACTIVE session awaiting a WINDOW-close confirmation. A macOS window maps to an
    /// slopdesk ``Session`` (the macOS window hosts the whole ``TreeWorkspace``; closing it confirms
    /// against the active session's tab count — see `docs/DECISIONS.md`). Parked by ``requestCloseWindow()``
    /// when ``SettingsKey/closeConfirmWindow`` says confirm; resolved by ``confirmPendingWindowClose()``
    /// (which closes that session) / ``cancelPendingWindowClose()``. The macOS `windowShouldClose` reads this
    /// to decide whether to block the NSWindow close while the confirmation dialog resolves. In-memory only.
    public private(set) var pendingWindowClose: SessionID?

    /// The TREE busy-shell close guard — an idle leaf closes immediately (cascading the tab/session),
    /// a leaf mid-command parks behind the
    /// ``pendingClose`` confirmation. A leaf that is its By-Project section's LAST pane
    /// (``projectClosed(byRemoving:)``) parks too, whatever the policy says: closing it closes the whole
    /// project, and the dialog warns before the rail section silently disappears. The chrome close
    /// button and ⌘W on a SPECIFIC leaf both route through here so the guards are honoured uniformly
    /// (the `closePaneTree(_:)` direct call stays for tests / the active-pane convenience). No-op if `id`
    /// is not a live tree leaf.
    public func requestClosePaneTree(_ id: PaneID) {
        guard tree.contains(id) else { return }
        if closeConfirmationNeeded(scope: .pane, pane: id) || projectClosed(byRemoving: [id]) != nil {
            parkPaneClose(id)
        } else {
            closePaneTree(id)
        }
    }

    /// Whether a close in `scope` must park behind a confirmation prompt, evaluating the scope's
    /// configured ``CloseConfirmationPolicy`` against the live tree state.
    ///
    /// - `.pane` (⌘W) reads ``CloseConfirmationPolicy/process`` — the busy-shell guard ALONE. ⌘W is a PANE
    ///   gesture: it never inherits the Tab / Window policy, not even when the pane is its tab's last leaf and
    ///   the emptied tab goes with it (there is no such thing as a pane-less tab, so that cascade is a
    ///   consequence of the pane close, not a tab close the user asked to confirm). The Tab / Window policies
    ///   belong to the Close Tab and ⌘⇧W Close Window affordances.
    /// - `.tab` reads ``SettingsKey/closeConfirmTab``; `.window` reads ``SettingsKey/closeConfirmWindow``.
    ///
    /// The BUSY input is the busy-shell signal (`pane` for `.pane`; ANY pane in the active tab for `.tab`; ANY
    /// pane in the active session for `.window`). The TAB-COUNT input is how many tabs the close would
    /// DESTROY — the whole point of `multiple_tabs` ("this would lose more than one tab") — so a `.tab` close
    /// feeds `1` (closing one tab loses exactly one) and only `.window` feeds the session's `tabs.count`.
    /// Feeding the window's count to a tab/pane close is what made a lone-pane ⌘W claim "this window has
    /// multiple tabs". The pure truth table lives in
    /// ``CloseConfirmationPolicy/shouldConfirm(_:isBusy:tabCount:)``. Under the default `.process` policy every
    /// scope collapses to "confirm iff busy".
    func closeConfirmationNeeded(scope: CloseScope, pane: PaneID? = nil) -> Bool {
        switch scope {
        case .pane:
            let busy = pane.map { registry[$0]?.isShellBusy == true } ?? false
            return CloseConfirmationPolicy.shouldConfirm(.process, isBusy: busy, tabCount: 0)
        case .tab:
            let busy = anyShellBusy(tree.activeSession?.activeTab?.allPaneIDs() ?? [])
            return CloseConfirmationPolicy.shouldConfirm(SettingsKey.closeConfirmTab, isBusy: busy, tabCount: 1)
        case .window:
            let busy = anyShellBusy(tree.activeSession?.allPaneIDs() ?? [])
            return CloseConfirmationPolicy.shouldConfirm(
                SettingsKey.closeConfirmWindow,
                isBusy: busy,
                tabCount: tree.activeSession?.tabs.count ?? 0,
            )
        }
    }

    /// Whether ANY pane in `ids` reports a running child process (the busy-shell signal). Drives the
    /// tab- / window-scope busy input for ``closeConfirmationNeeded(scope:pane:)``.
    private func anyShellBusy(_ ids: [PaneID]) -> Bool {
        ids.contains { registry[$0]?.isShellBusy == true }
    }

    /// The WINDOW-close GATE (the macOS `windowShouldClose` route). A macOS window maps to an
    /// slopdesk ``Session`` (the macOS NSWindow hosts the whole ``TreeWorkspace``; see `docs/DECISIONS.md`),
    /// so the confirmation is evaluated against the ACTIVE session — ``SettingsKey/closeConfirmWindow`` over
    /// the active session's tab count + any busy pane. A pure gate: when confirmation is needed it parks
    /// ``pendingWindowClose`` (the macOS delegate then BLOCKS the NSWindow close while the dialog resolves);
    /// when it is NOT needed it clears the park and lets the caller proceed (the macOS gate returns `true`,
    /// so the NSWindow closes normally — the persisted layout is preserved, never wiped on a plain close).
    /// The window → ``Session`` close action fires on the explicit ``confirmPendingWindowClose()``. No-op
    /// without an active session.
    public func requestCloseWindow() {
        guard let session = tree.activeSession else {
            pendingWindowClose = nil
            return
        }
        pendingWindowClose = closeConfirmationNeeded(scope: .window) ? session.id : nil
    }

    /// Confirms the parked window close (the confirmation dialog's "Close" button): closes the parked session
    /// (window → ``Session``) and clears ``pendingWindowClose``. No-op when nothing is pending.
    public func confirmPendingWindowClose() {
        guard let id = pendingWindowClose else { return }
        pendingWindowClose = nil
        closeSession(id)
    }

    /// Dismisses the window-close confirmation without closing.
    public func cancelPendingWindowClose() {
        pendingWindowClose = nil
    }

    // MARK: - Pane switcher (⌃⇥ press-and-hold, MRU-ordered)

    /// The live ⌃⇥ switcher, or `nil` while it is closed. Set by ``openOrStepPaneSwitcher(forward:armedByModifier:)``,
    /// cleared by ``commitPaneSwitcher()`` / ``cancelPaneSwitcher()``.
    ///
    /// PURELY LOCAL, deliberately: a pane focus is a host-owned intent (`.focusPane`), so staging one per
    /// highlight step would broadcast every intermediate pane of a cycle to every other client attached to
    /// this workspace. The highlight moves here; only the commit stages.
    public internal(set) var paneSwitcher: PaneSwitcher?

    /// `true` while a step is showing its highlighted pane LOCALLY (the follow-along preview, on by
    /// default — ``SettingsKey/paneSwitcherPreviewEnabled``). Set with ``paneSwitcherFocusBeforePreview``,
    /// which is what a cancel puts back; the pair is one piece of state in two fields because "no preview
    /// running" and "preview running over a nil device focus" are different things.
    var paneSwitcherPreviewing = false

    /// The device focus in force when the preview began — restored on cancel AND before a commit, so the
    /// transient overlay never outlives the gesture that made it.
    var paneSwitcherFocusBeforePreview: DeviceFocus?

    /// `true` while the sidebar shows its ⌘-digit NUMBER hints — ⌘ held past the hold threshold.
    /// `WorkspaceKeyDispatcher` owns the NSEvent monitor and the timing; this is only the observable
    /// fact the rail rows read (each swaps its leading run for ``shortcutNumber(for:)``). Purely local
    /// presentation state, like ``paneSwitcher``.
    public private(set) var shortcutHintActive = false

    /// Set by the key dispatcher on ⌘ transitions. Change-guarded so the `.flagsChanged` stream (one
    /// event per modifier transition, hint or not) never invalidates the rail's observers for free.
    public func setShortcutHintActive(_ active: Bool) {
        guard shortcutHintActive != active else { return }
        shortcutHintActive = active
    }

    /// The TREE panes this device has navigated to, most-recent first, deduped and capped. The switcher's
    /// recency source (``WorkspaceStore/paneSwitcherMRU`` composes it with the host's tab ring).
    ///
    /// Per-client, like tmux's `client->last_session` and unlike `session/focusMRU`: that shared ring
    /// exists because CLOSE is an intent and two clients must pick the same successor, while "the pane I
    /// was just in" is a fact about one keyboard. Session state, never persisted — a ring restored from
    /// disk would send the first ⌃⇥ of a launch somewhere the user has no memory of being.
    ///
    /// Fed at the ONE choke point every local navigation passes through (``stageFocus(tab:)`` /
    /// ``stageFocus(pane:)``), so a rail click, a ⌘-digit, a palette jump and the switcher's own commit
    /// all record identically — and the preview, which writes device focus directly, records nothing.
    public private(set) var paneVisitMRU: [PaneID] = []

    /// Deep enough to cover a working set, short enough that a stale id cannot linger for a whole
    /// session. Matches ``WorkspaceTopology/focusMRUCap`` doubled, because panes outnumber tabs.
    public static let paneVisitMRUCap = 32

    /// WHAT THE LAST LOCAL NAVIGATION NAMED — a tab, or a pane. See ``FocusIntent`` (and the whole
    /// rule in `WorkspaceStore+FocusLanding.swift`); the stored halves live here because
    /// `@Observable` synthesises on them.
    /// `internal(set)` (not `private(set)`) so the recorder in `WorkspaceStore+FocusLanding.swift`
    /// can write it — same reason ``retainedSessionIDs`` is; still not publicly settable.
    public internal(set) var lastFocusIntent: FocusIntent?
    var focusIntentSeq: UInt64 = 0

    /// Fronts `id` in the visit ring. Dead ids are not pruned here — ``PaneSwitcher/candidates(active:mru:ordered:)``
    /// intersects with the live pane set on every open, so a pane that closes simply stops being offered.
    /// The push is ``RecentsRing/pushing(_:into:cap:retaining:)``, the one ring policy every ring here runs.
    func notePaneVisit(_ id: PaneID) {
        paneVisitMRU = RecentsRing.pushing(id, into: paneVisitMRU, cap: Self.paneVisitMRUCap)
    }

    // MARK: - Recent-pane MRU (quick-switch to the previously-focused pane)

    // MARK: - Synchronized input (tmux synchronize-panes)

    /// The set of tab IDs for which per-tab synchronized input is ON (Zellij `ToggleActiveSyncTab`): every
    /// keystroke typed in the focused pane of a sync-armed tab is ALSO sent to every OTHER pane in that
    /// same tab.
    ///
    /// HOST TRUTH, carried as `tab/syncInputArmed` and persisted with the rest of the topology
    /// (DECISIONS, Multi-client Phase 5b). tmux models `synchronize-panes` as a server-side window
    /// option and it has to be one: hosting only the armed bit while fanning client-side would mean
    /// another client's keystrokes silently do not fan.
    var syncInputTabs: Set<TabID> {
        observeWorkspaceMirror()
        return mirroredTopology?.syncInputTabs ?? []
    }

    /// Reentrancy guard for ``fanSyncInput(from:_:)``: when a fan-out mirrors bytes into a SIBLING
    /// target, that sibling's own `TerminalViewModel.sendInput` re-fires the sync tap — without this
    /// guard each keystroke would cross-multiply across the group (N panes → N² sends → a feedback storm).
    /// Set only for the synchronous duration of one fan-out (all on the main actor, so a flag suffices).
    private var isFanningSyncInput = false

    /// Toggles per-tab synchronized input for `tabID` (Zellij `ToggleActiveSyncTab`). When ON, every
    /// keystroke typed in any pane of the tab is also mirrored into the tab's other panes via
    /// ``fanSyncInput(from:_:)``. Idempotent when called on the same tab twice (insert → remove cycle).
    public func toggleSyncInput(tabID: TabID) {
        // ASSIGN, never toggle (DECISIONS, Multi-client Phase 5 ruling 2): the desired state travels,
        // so two clients asking at once converge on it instead of cancelling each other out.
        stage(.setSyncInput, WorkspaceIntentArgs.encode(id: tabID.raw, flag: !syncInputTabs.contains(tabID)))
    }

    /// Whether pane `id`'s tab is armed for synchronized input — the `⚠ SYNC INPUT` pill's visibility
    /// gate (every keystroke typed in this pane is mirrored into the tab's other panes, and theirs into
    /// this one). Armed state MUST be visible: an invisibly-armed tab is a cross-pane input leak the
    /// user cannot explain (field report: two same-project panes "leaking into each other"). Reading
    /// this inside a tracked arm registers it on `syncInputTabs`, so the pill lights/clears live.
    public func syncInputArmed(for paneID: PaneID) -> Bool {
        guard let (_, tabID) = tree.tab(containing: paneID) else { return false }
        return syncInputTabs.contains(tabID)
    }

    /// Disarms synchronized input for the tab containing `paneID` — the pill's `×`. Idempotent; a
    /// pane outside any tab is a no-op.
    public func disarmSyncInput(for paneID: PaneID) {
        guard let (_, tabID) = tree.tab(containing: paneID) else { return }
        stage(.setSyncInput, WorkspaceIntentArgs.encode(id: tabID.raw, flag: false))
    }

    /// The per-tab synchronized-input fan-out (Zellij `ToggleActiveSyncTab`): mirrors the bytes that the
    /// source pane just sent to its own shell into every OTHER pane in the same tab, when sync is armed for
    /// that tab. The source pane is intentionally SKIPPED (it already delivered locally via `inputSink`);
    /// sibling delivery is through ``PaneSessionHandle/sendBytes(_:)`` (→ their input funnel). The existing
    /// ``isFanningSyncInput`` guard (a `@MainActor` flat flag) is the re-entry guard: a sibling's
    /// `sendInput` re-fires `syncInputTap`, which would call
    /// `fanSyncInput` again — the guard collapses the re-entrant call to a no-op, preventing a fan-storm.
    /// Returns the number of siblings reached (0 when disarmed, single-pane tab, or re-entrant).
    @discardableResult
    public func fanSyncInput(from sourceID: PaneID, _ data: Data) -> Int {
        guard !data.isEmpty, !isFanningSyncInput else { return 0 }
        // Resolve the containing tab by scanning sessions.
        guard let (_, tabID) = tree.tab(containing: sourceID) else { return 0 }
        guard syncInputTabs.contains(tabID) else { return 0 }
        // Find the Tab value to enumerate siblings.
        var tab: Tab?
        for session in tree.sessions {
            if let found = session.tabs.first(where: { $0.id == tabID }) { tab = found
                break
            }
        }
        guard let tab else { return 0 }
        let siblings = tab.allPaneIDs().filter { $0 != sourceID }
        guard !siblings.isEmpty else { return 0 }
        // KEYBOARD-ONLY mirror (see ``SyncInputByteFilter``): the tap rides `sendInput`, which also
        // carries the terminal's query replies (CPR/DA/XTWINOPS/DECRPM) and mouse/focus reports.
        // Mirroring those into a sibling shell that never asked types garbage onto its command line —
        // and a later mirrored `↩` executes it. Strip everything that is not a key/paste byte.
        let bytes = Array(SyncInputByteFilter.keyboardOnly(data))
        guard !bytes.isEmpty else { return 0 }
        isFanningSyncInput = true
        defer { isFanningSyncInput = false }
        var reached = 0
        for id in siblings {
            registry[id]?.sendBytes(bytes)
            reached += 1
        }
        return reached
    }

    // MARK: - Command palette recents

    /// The most-recently-run palette COMMANDS, most-recent-first (non-persisted session state), held as
    /// the palette CATALOG IDs (`"action.newTerminalTab"`, …). The ⌘K palette surfaces these at the top
    /// when the query is empty, so the verbs you use most are one keystroke away. Only true command verbs
    /// are recorded (not pane/tab/window jumps — those have their own always-present sections).
    ///
    /// The id, not a command enum: the ring's ONLY consumer looks the row back up in
    /// ``ActionsPaletteSource/catalog``, so anything richer than the key it looks up by is a second
    /// spelling of the catalog that can drift from it.
    public private(set) var recentCommands: [String] = []
    /// How many recents to keep.
    public static let recentCommandsCap = 5

    /// Records a run command's catalog id at the front of the recents ring (dedup-to-front, capped) through
    /// ``RecentsRing/pushing(_:into:cap:retaining:)``, the one ring policy every ring here runs.
    public func recordRecentCommand(_ catalogID: String) {
        recentCommands = RecentsRing.pushing(catalogID, into: recentCommands, cap: Self.recentCommandsCap)
    }

    // MARK: - Clipboard history ring

    /// Recent clipboard texts, most-recent-first (non-persisted session state — clipboard history is
    /// transient and often sensitive). Fed by the polling ``ClipboardMonitor`` where the platform
    /// permits an unattended read, and by every live read through ``currentLocalClipboard()`` — which
    /// is what fills it on iOS. The pill's "Paste Recent" submenu replays any entry into a remote pane.
    public private(set) var clipboardRing: [String] = []
    /// How many clips to keep.
    public static let clipboardRingCap = 20

    /// A LIVE reader of the current local clipboard text, injected by the app (macOS: `NSPasteboard`),
    /// so the pure store/routing stays platform-free + testable. The ⌥⌘V "Paste as Keystrokes" chord +
    /// the pane context menu read the CURRENT clipboard through this (not the up-to-1s-stale ring head),
    /// and it works even when clipboard-history recording is OFF (an empty ring). `nil` (the headless /
    /// test default) ⇒ fall back to ``clipboardRing`` head via ``currentLocalClipboard()``.
    @ObservationIgnored public var clipboardTextProvider: (() -> String?)?

    /// The PROBE twin of ``clipboardTextProvider``: does the local clipboard hold text, WITHOUT reading
    /// it. Injected by the app (``ClientPasteboard/hasText()``), for the same reason its twin is — the
    /// store stays platform-free. `nil` (the headless / test default) ⇒ ``localClipboardHasText()``
    /// answers from the ``clipboardRing`` head alone, exactly as ``currentLocalClipboard()`` does.
    ///
    /// It exists because a renderer may not call the other one. On iOS a content read raises the modal
    /// "Allow Paste?" alert, and a redraw path may run many times per interaction — so an affordance that
    /// greys itself out by asking
    /// "is there anything to paste?" needs a question that discloses nothing
    /// (``SystemPasteboard/hasPlainText``).
    @ObservationIgnored public var clipboardHasTextProbe: (() -> Bool)?

    /// Where an ATTENDED read of the local clipboard goes besides the caller that asked for it —
    /// ``ClipboardSyncEngine`` installs itself here (in its own `init`, given the store) and pushes the
    /// clip to the HOST's pasteboard.
    ///
    /// It exists because the phone had no client→host clipboard path at all. The engine's timer cannot
    /// snapshot content on iOS (the modal "Allow Paste?" alert — see
    /// ``SystemPasteboard/unattendedContentReadIsPermitted``), and the engine's own docs answered that
    /// with "the local clip reaches the host through the paths the user asked to paste on" — prose that
    /// was never true of any path: every one of them TYPES the text into a pane and none called
    /// `setClipboard`. So a copy on the phone was invisible to a ⌘V on the host. This seam is that
    /// sentence made real, and it is deliberately fed from ``currentLocalClipboard()`` rather than from
    /// a new affordance: that function IS the attended read, on both halves, and on the Mac the tick
    /// has usually pushed the same clip a moment earlier and the engine's content compare drops it.
    ///
    /// `nil` (the headless / test default) ⇒ an attended read syncs nowhere, exactly as before.
    @ObservationIgnored public var attendedLocalClipboardSink: ((String) -> Void)?

    /// Brings a DETACHED pane's satellite `NSWindow` to the front, injected by the app (macOS:
    /// `SatelliteWindowsCoordinator`) so the pure store stays AppKit-free + testable. Returns `true` iff a
    /// satellite for `paneID` was found and revealed. `nil` (the headless / test default) or a `false`
    /// return means ``openDesktopWindow(displayID:)`` still returns the existing pane WITHOUT
    /// revealing it — better a silent no-op than a duplicate live video stream.
    @ObservationIgnored public var revealSatelliteWindow: ((PaneID) -> Bool)?

    /// The current local clipboard text: the injected ``clipboardTextProvider`` if wired, else the most
    /// recent recorded clip (``clipboardRing`` head). `nil`/empty ⇒ nothing to paste.
    ///
    /// A LIVE read is also a RECORDING, and that is what gives the phone a clipboard history at all.
    /// Every caller of this is a paste the user asked for — the ⌥⌘V chord, the palette command, the
    /// remote-GUI pane's paste plate — which on iOS is the only moment the system permits reading
    /// pasteboard content without ambushing the user with an "Allow Paste?" alert (see
    /// ``SystemPasteboard/unattendedContentReadIsPermitted``). On macOS the polling
    /// ``ClipboardMonitor`` has usually recorded the same clip a tick earlier and ``recordClip(_:)``
    /// dedups it to a no-op, so this is one behaviour on both halves rather than a phone special case.
    /// A LIVE read is also a RECORDING **and a SYNC** — see ``attendedLocalClipboardSink`` for why the
    /// second one hangs off this function and not off an affordance of its own. The sink is fed the
    /// text UNCONDITIONALLY (not through ``recordClip(_:)``'s history gate): turning clipboard HISTORY
    /// off says "do not retain my clips", not "do not let my two machines share a clipboard", and the
    /// engine keeps no history — it pushes one clip and forgets it.
    public func currentLocalClipboard() -> String? {
        guard let text = clipboardTextProvider?() else { return clipboardRing.first }
        recordClip(text)
        attendedLocalClipboardSink?(text)
        return text
    }

    /// Whether a paste-the-current-clipboard affordance has anything to type — WITHOUT reading the
    /// clipboard. The ENABLEMENT sibling of ``currentLocalClipboard()``, and the only one of the pair a
    /// renderer may call: on iOS the content read raises the modal "Allow Paste?" alert, so asking it
    /// from a redraw or a tracked arm's handler puts that alert on screen once per pass, unprompted —
    /// and a tracked arm re-fires on inputs that have nothing to do with the clipboard.
    ///
    /// It mirrors its sibling's FALLBACK, which is the whole difficulty: `currentLocalClipboard()` is
    /// `clipboardTextProvider?() ?? clipboardRing.first`, so a probe that consulted only the board would
    /// grey the button out on a headless store / an unreadable board that would still have pasted the
    /// ring head. A `false` from the probe means the live read would come back `nil` — the same
    /// condition that hands the paste over to the ring — so the ring is exactly where this looks next.
    ///
    /// ONE case is looser than the paste, and it is the price of not reading: a board holding only
    /// whitespace probes TRUE (the platforms answer "has a string", not "has a string worth typing"),
    /// so the item is lit and the tap's own ``ClipboardPasteMenu/isPastable(_:)`` guard makes it a
    /// no-op. A wasted tap, versus an alert nobody asked for.
    public func localClipboardHasText() -> Bool {
        if clipboardHasTextProbe?() == true { return true }
        return ClipboardPasteMenu.isPastable(clipboardRing.first)
    }

    /// Records `text` at the front of the ring (deduped — a repeat moves to front), capped at
    /// ``clipboardRingCap`` through ``RecentsRing/pushing(_:into:cap:retaining:)``, the one ring policy every
    /// ring here runs. The two GATES stay in Swift because they are gates rather than ring policy: it skips
    /// empty/whitespace, and skips everything when the user has turned OFF clipboard-history recording
    /// (Settings ▸ Advanced ▸ Privacy) — the single chokepoint, so a copied secret is never retained when
    /// recording is disabled. Read at fire-time so the toggle applies live.
    public func recordClip(_ text: String) {
        guard SettingsKey.recordClipboardHistoryEnabled else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clipboardRing = RecentsRing.pushing(text, into: clipboardRing, cap: Self.clipboardRingCap)
    }

    /// Clears the clipboard history (a privacy affordance).
    public func clearClipboardRing() { clipboardRing = [] }

    // MARK: - Explicit pane notifications (OSC 9 / OSC 777)

    /// The app's notification poster, wired after construction (the store is cross-platform headless;
    /// the `UNUserNotificationCenter` poster is macOS-app-side). Called when a pane's child requests an
    /// explicit notification (OSC 9 / OSC 777); the app posts it carrying the pane id so a click can
    /// ``revealPane(_:)``. `nil` in tests / headless ⇒ the notification is dropped (no UN dependency).
    public var onPaneNotification: ((_ paneID: PaneID, _ paneTitle: String, _ title: String, _ body: String) -> Void)?

    /// A pane's fresh-vs-resumed verdict after a completed RECONNECT (forwarded from its
    /// ``ConnectionViewModel``). The app wires this to a small transient toast so the user knows whether the
    /// drop reattached the SAME live shell (`.resumedSession` — scrollback/history intact) or spawned a
    /// FRESH shell (`.freshShell` — the previous session ended and its context is gone). Fires at most once
    /// per drop→reconnect; never on a first-ever connect or a deliberate ⇧⌘R. `nil` in tests / headless ⇒
    /// the verdict is dropped. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored
    public var onSessionResumeOutcome: ((_ paneID: PaneID, _ outcome: SlopDeskClient.SessionResumeOutcome) -> Void)?

    /// A NON-pane-scoped client copy just landed on the clipboard (palette "Copy Path", host-window rail
    /// "Copy Window Title" — actions whose trigger surface has no pane to host the transient `COPIED · N`
    /// chip). The app wires this to the overlay coordinator's window-level chip. Pane-scoped copies never
    /// route here — they publish ``TerminalViewModel/copyReceipt`` on their own pane instead. `nil` in
    /// tests / headless ⇒ the confirmation is dropped. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onLocalCopy: ((_ text: String) -> Void)?

    /// Fires ``onLocalCopy`` for a completed non-pane-scoped clipboard write. Empty text is a no-op
    /// (nothing was copied ⇒ nothing to confirm).
    public func noteLocalCopy(_ text: String) {
        guard !text.isEmpty else { return }
        onLocalCopy?(text)
    }

    /// A REOPENABLE tab just landed on the DOCUMENT's ⇧⌘T ring — a close that removed a tab, whether
    /// the user closed the tab or its last pane. The app wires this to the overlay coordinator's
    /// transient "TAB CLOSED · ⇧⌘T REOPENS" notice, the undo affordance for the workspace's most
    /// destructive routine action.
    ///
    /// Fired by ``stageClose(_:_:)`` on the ring's NEWEST RECORD actually changing, which is why it
    /// can no longer promise something the host did not do: a pane close that left its tab alive
    /// records nothing and stays silent. `nil` in tests / headless ⇒ the cue is dropped.
    /// `@ObservationIgnored`: wiring.
    @ObservationIgnored public var onTabCloseRecorded: (() -> Void)?

    /// A layout change was asked for while nothing could carry it — no workspace channel, a channel
    /// that is not `.live`, or one whose host has published no topology (docs/45 §7.2).
    ///
    /// The workspace is the document's, so with the document out of reach every split, close, ⌘T and
    /// divider drag is a no-op. The store keeps rendering the last layout it knows, so the window
    /// looks entirely normal and the gesture simply does not happen — which is indistinguishable from
    /// a UI that ignored it. The app wires this to the overlay coordinator's transient notice, so the
    /// refusal is at least SAID. `nil` in tests / headless. `@ObservationIgnored`: wiring.
    @ObservationIgnored public var onLayoutChangeUnavailable: (() -> Void)?

    /// A TELEPORT focus (``jumpToPaneTree(_:)``) just CROSSED a tab (or session) boundary — the whole
    /// viewport changed in one frame with no cue of where it landed. Carries the ``JumpBreadcrumb``
    /// destination line ("session ▸ tab" / "tab"); the app wires it to the overlay coordinator's
    /// transient `JUMPED · …` notice. A same-tab focus never fires (absent, never wrong). The breadcrumb
    /// embeds OSC/PTY-settable titles — the app-side wiring masks secrets before display. `nil` in
    /// tests / headless ⇒ the cue is dropped. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onCrossTabJump: ((_ breadcrumb: String) -> Void)?

    /// View-injected overlay-toggle closures the per-pane hardware-keyboard ``TerminalKeyInterceptor`` threads
    /// into ``WorkspaceBindingRegistry/route`` (see ``routeInterceptedKey(_:)``). On iOS the per-pane
    /// interceptor is the ONLY hardware-chord path (no app-level NSEvent monitor; macOS's
    /// `WorkspaceKeyDispatcher` PREEMPTS the surface, so these stay all-`nil` there and the dispatcher owns
    /// the overlay chords). `nil` members ⇒ a graceful no-op, so a chord like ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌃↩ from
    /// a focused iPad terminal opens its overlay instead of dying.
    @ObservationIgnored public var overlayKeyToggles = WorkspaceOverlayKeyToggles()

    /// Routes a child-requested notification from pane `id` to the app poster. Internal seam — wired
    /// onto each terminal pane's connection in ``reconcile()``.
    func handlePaneNotification(id: PaneID, paneTitle: String, title: String, body: String) {
        onPaneNotification?(id, paneTitle, title, body)
    }

    /// Reveals the pane whose id string (`PaneID.raw.uuidString`) matches — the entry point for the
    /// notification-click handler, which only carries the string from `userInfo`. No-op on an
    /// unparseable / unknown id (the pane was closed).
    ///
    /// A notification click is a TELEPORT: ``jumpToPaneTree(_:)`` switches session + tab + pane to the
    /// originating pane and leaves a breadcrumb on the tab it crossed.
    public func revealPane(byIDString idString: String) {
        guard let uuid = UUID(uuidString: idString) else { return }
        jumpToPaneTree(PaneID(raw: uuid))
    }

    // MARK: - Reconnect (palette / recovery)

    /// Re-dials pane `id`'s connection — the recovery path for a `.failed` / `.unreachable` / dropped
    /// terminal pane (the command palette's "Reconnect Pane"). `ConnectionViewModel.connect()` already
    /// tears down the prior session and re-dials the stored `host`/`port`, so it is correct from ANY
    /// non-connected state; a no-op for a pane with no live connection (a video / faked handle).
    /// The connect runs in a detached `Task` (the store mutation surface stays synchronous), exactly as
    /// the leaf's connect-on-appear does.
    public func reconnect(_ id: PaneID) {
        // Gate on the app-global connection (docs/31): a pane channel must NOT build the shared mux while
        // the connect-gate is still up (it would come up un-pinned, leaving the gate stuck at
        // `.disconnected` with a live connection + orphan host shell behind it). The scene-level ⇧⌘R /
        // "Reconnect Pane" command is enabled before first connect, so this is the one un-gated mux-build
        // side door — close it. `nil` (tests / no app connection) ⇒ allowed, preserving headless behavior.
        if let isAppConnected, !isAppConnected() { return }
        guard let handle = registry[id], let connection = (handle as? LivePaneSession)?.connection else { return }
        // Re-check on the MainActor, right before dialing, that the pane is STILL backed by the SAME
        // handle. The guard above resolves synchronously, but the dial runs in a detached Task; if
        // `closePane(id)` runs in the interim, reconcile() removes the handle and tears its
        // connection down (deliberatelyClosed = true). Without this re-check the captured `connection`'s
        // `connect()` would CLEAR deliberatelyClosed and open a fresh socket for a pane that no longer
        // exists — a live, supervised, reconnecting zombie connection stranded for a closed pane.
        Task { @MainActor [weak self] in
            guard let self, paneStillRegistered(id, as: handle) else { return }
            await connection.connect()
        }
    }

    /// Whether pane `id` is STILL backed by `handle` in the registry (reference identity). The re-check
    /// the detached ``reconnect(_:)`` Task does before dialing, so a pane removed from the registry
    /// (by a `closePane` reconcile) between the synchronous resolve and the Task running is
    /// not revived. Internal — a test seam, not part of the public store API.
    func paneStillRegistered(_ id: PaneID, as handle: any PaneSessionHandle) -> Bool {
        guard let current = registry[id] else { return false }
        return current === handle
    }

    // MARK: - Spec mutation (rename / fill endpoint)

    // MARK: - Video activation (cap-enforced)

    /// Requests live-video activation for video pane `id`, enforcing ``liveVideoCap`` (docs/22
    /// §7). Returns `true` if the pane is now active, `false` if the cap is already saturated by OTHER
    /// active video panes (the caller then shows the gated placeholder until a slot frees). A no-op
    /// `true` if it is already active. Non-video panes return `false`.
    @discardableResult
    public func activateVideo(_ id: PaneID) -> Bool {
        guard let handle = registry[id] else { return false }
        // The two facts the ledger cannot know — whether this pane decodes video at all, and whether it
        // is decoding right now — are readings off the live handle, so they cross as ARGUMENTS. The
        // ladder they used to be spelled as is the door's.
        switch videoSlots.admit(id, isVideo: handle.kind.isVideo, alreadyLive: handle.isVideoActive) {
        case .refuse:
            return false
        case .alreadyLive:
            return true
        case .proceed:
            handle.setVideoActive(true)
            // Report what the pane ACTUALLY did, not what was asked of it: an activation the stack
            // refused must not book a slot nobody is standing in.
            noteVideoLiveness(id, handle.isVideoActive)
            return handle.isVideoActive
        }
    }

    /// Whether a live-video slot is currently free FOR pane `id` — a pure READ that answers with the
    /// exact arithmetic ``activateVideo(_:)``'s admission uses, with NO mutation. The view layer consults
    /// this to tell the two false-activation reasons apart: a video pane whose `activateVideo`
    /// would refuse because the cap is **saturated** (→ the gated placeholder) versus one that is merely
    /// **unconfigured** (→ the entry form so the user can still dial in).
    ///
    /// The self-exclusion (an already-decoding pane sees its own slot as free) and the accounting for a
    /// closed pane whose stack has not released are the ledger's, so this side cannot drift from what an
    /// admission attempt this same tick would decide — it is the same door.
    ///
    /// ``observeVideoSlots()`` is what makes it reactive, and it is deliberately narrow: a read of the
    /// whole `registry` would re-render this leaf on EVERY unrelated pane materializing or closing.
    public func hasFreeVideoSlot(for id: PaneID) -> Bool {
        observeVideoSlots()
        return videoSlots.admits(id)
    }

    /// Deactivates live video for pane `id` — the GUI leaf's off-screen branch (`applyActivation` with
    /// `isVisible == false`) and its `teardown()` — freeing a cap slot.
    ///
    /// `wasActive` is the reading taken BEFORE the pane is stood down, and it is what the ledger's guard
    /// reads: a no-op deactivate (an already-idle / unknown / non-video pane) freed nothing, so
    /// ``videoPromotionGeneration`` must not move — otherwise standing down a never-admitted pane
    /// would spuriously re-trigger every gated sibling's retry for no gained slot.
    public func deactivateVideo(_ id: PaneID) {
        let wasActive = registry[id]?.isVideoActive == true
        registry[id]?.setVideoActive(false)
        publishVideoSlots(videoSlots.standDown(id, wasLive: wasActive))
    }

    /// Registers an Observation dependency on the live-video ledger, for a read that answers from it.
    ///
    /// The ledger is a Rust handle, not a stored property, so nothing about calling into it is
    /// observable on its own. Mirrors ``observeWorkspaceMirror()``, which does the same job for the
    /// document replica.
    private func observeVideoSlots() { _ = videoSlotsRevision }

    /// Writes the ledger's answer into the two projections and nowhere else.
    ///
    /// ``videoPromotionGeneration`` is dirty-guarded because the ledger only moves it on a transition
    /// that actually FREED a slot; ``videoSlotsRevision`` always moves, because every call here changed
    /// something a cap read would see.
    private func publishVideoSlots(_ generation: Int) {
        if videoPromotionGeneration != generation { videoPromotionGeneration = generation }
        videoSlotsRevision &+= 1
    }

    /// Records what a pane's stack ACTUALLY is after something flipped it, and republishes.
    private func noteVideoLiveness(_ id: PaneID, _ live: Bool) {
        videoSlots.noteLive(id, live)
        videoSlotsRevision &+= 1
    }

    // MARK: - Lifecycle fan-out (one site, AWAITED)

    /// iOS background: pause EVERY session, AWAITED. The single fan-out point — a `TaskGroup` whose
    /// child tasks hop onto the main actor and pause each session, but the WHOLE group is awaited
    /// before the app suspends (no fire-and-forget — docs/22 §4, §11.4).
    ///
    /// The child tasks capture only the Sendable ``PaneID`` and re-resolve the (main-actor-isolated,
    /// non-`Sendable`) handle inside the `@MainActor` body, so nothing non-`Sendable` crosses an actor
    /// boundary. The sessions are themselves `@MainActor`, so their `pause()` bodies serialize on the
    /// main actor; the `TaskGroup` is what guarantees every one is awaited.
    public func pauseAll() async {
        let ids = Array(registry.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.pauseSession(id) }
            }
        }
    }

    /// iOS foreground: resume EVERY session, AWAITED (mirror of ``pauseAll()``).
    public func resumeAll() async {
        let ids = Array(registry.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.resumeSession(id) }
            }
        }
    }

    /// Pauses one session by id on the main actor (the `TaskGroup` child-task body — only the Sendable
    /// `PaneID` crosses; the handle is re-resolved here, never sent across the boundary).
    private func pauseSession(_ id: PaneID) async {
        await registry[id]?.pause()
        // `pause()` flips `isVideoActive` directly on the handle (bypassing ``deactivateVideo(_:)``) —
        // resync the ledger so ``hasFreeVideoSlot(for:)`` stays truthful.
        syncActiveVideoMirror(id)
    }

    private func resumeSession(_ id: PaneID) async {
        await registry[id]?.resume()
        // `resume()` flips `isVideoActive` directly too (re-opens video active before pause) — same resync.
        syncActiveVideoMirror(id)
    }

    /// Reconciles the ledger's view of `id` against its CURRENT handle state — idempotent, the single
    /// re-sync point for the two sites that flip `isVideoActive` OUTSIDE ``activateVideo(_:)`` /
    /// ``deactivateVideo(_:)`` (``pauseSession(_:)`` / ``resumeSession(_:)``).
    ///
    /// Deliberately silent on the promotion counter: a pause is a fan-out over every pane at once, and a
    /// resume consumes a slot rather than freeing one, so neither is a promotion edge for a gated pane.
    private func syncActiveVideoMirror(_ id: PaneID) {
        noteVideoLiveness(id, registry[id]?.isVideoActive == true)
    }

    /// Awaits every in-flight orphan ``PaneSessionHandle/teardown()`` spawned by ``reconcile()`` to
    /// complete. The registry invariant already holds the moment a mutation returns (orphans are
    /// removed synchronously); this is for callers that must observe the *cleanup* having finished —
    /// app shutdown, and the reconcile/teardown-ordering tests (docs/22 §8). Idempotent; after it
    /// returns, no teardown is pending.
    ///
    /// LOOPS to a fixpoint: a teardown task awaits on the main actor, so a `reconcile()` that
    /// runs DURING one of these awaits (e.g. a mutation interleaved by the awaiting suspension) can
    /// insert a brand-new teardown task into `teardownTasks` after we snapshot it. A single
    /// snapshot-clear-await pass would drop that newcomer; instead we re-snapshot until the dict is
    /// empty, so every task — including ones spawned mid-drain — is awaited. Each pass clears its own
    /// snapshot's keys; a task that self-prunes after we cleared is a harmless no-op removeValue.
    public func quiesce() async {
        while !teardownTasks.isEmpty {
            let tasks = teardownTasks
            teardownTasks.removeAll()
            for task in tasks.values {
                await task.value
            }
        }
        // Defensive: after every teardown has completed, no video stack can still be tearing
        // down, so the in-flight video accounting must be empty. Clear it so a dropped release (a task
        // whose ``VideoSlotLedger/release(_:)`` somehow did not run) can never strand a phantom slot
        // against the cap. Silent on the promotion counter — a repair is not a slot opening.
        videoSlots.clearReleasing()
        videoSlotsRevision &+= 1
    }

    // MARK: - Tree-path mutations (delegate to WorkspaceTreeOps, then reconcileTree)

    /// The tree-of-intent mutation surface (docs/42) — the store's ONLY mutation surface. Each method
    /// applies a **pure** ``WorkspaceTreeOps`` transform (returns a new ``TreeWorkspace``) and then calls
    /// ``reconcileTree()`` to materialize/orphan the registry. They keep the **specs == leafIDs invariant**
    /// (the ops do). The kind is taken EXPLICITLY (`kind:`) — these methods do NOT resolve a settings
    /// default; it is the CALLER (the command routing) that resolves the user's default before invoking
    /// them.

    /// Splits the active pane along `axis`, inserting a new leaf of `kind` (focused). `leading == true`
    /// places the new leaf on the LEADING side of the active pane (left of a `.horizontal` split / above a
    /// `.vertical` split) — the split-left (⌘⌥D) / split-up (⌘⌥⇧D) chords; the default `false` keeps the
    /// natural trailing insert (the ⌘D right / ⌘⇧D down split). Tree no-op when there is no active pane.
    public func splitActivePane(axis: SplitAxis, kind: PaneKind, leading: Bool = false) {
        splitActivePane(axis: axis, kind: kind, leading: leading, launchGrace: .milliseconds(1400))
    }

    /// Core of ``splitActivePane(axis:kind:leading:)``. `launchGrace` is kept for call-site + overload parity
    /// with the paths that still schedule a deferred send, but this path types no startup `cd` — the
    /// inherited cwd rides `channelOpen` (host-side spawn), so the grace is unused here (`_`).
    func splitActivePane(axis: SplitAxis, kind: PaneKind, leading: Bool, launchGrace _: Duration) {
        // Video never enters the workspace tree (docs/DECISIONS.md 2026-07-23) — the desktop lives in
        // its own OS window; a video-kind split request is a no-op, not a video leaf.
        guard !kind.isVideo, let active = tree.activeSession?.activeTab?.activePane else { return }
        // Resolve the new pane's initial cwd from the NEW-SPLIT working-directory policy against the active
        // pane's last-known cwd and stamp it on the new spec. The live session factory sends that cwd in the
        // mux `channelOpen`, so the host spawns the PTY there directly.
        let activeCwd = inheritableCwd(of: active)
        let inheritedCwd = SettingsKey.workingDirectoryNewSplit.resolve(activePaneCwd: activeCwd)
        // The CLIENT mints the id (DECISIONS, Multi-client Phase 5 ruling 1): the optimistic overlay
        // cannot insert a leaf it has no id for, so a host-minted one would make every split wait a
        // round trip before anything appeared. `splitPane` lands the new leaf focused.
        let newID = PaneID()
        guard stage(.splitPane, WorkspaceIntentArgs.encode(
            target: active.raw, axis: axis, before: leading, newPane: newID, spawnCwd: inheritedCwd,
        )) else { return }
        seedNewPaneFacts(newID, spawnCwd: inheritedCwd, inheritingFrom: active)
        reconcileTree()
    }

    /// Splits the specific pane `target` along `axis`, inserting a new leaf of `kind` (focused).
    /// Video kinds no-op (video never enters the tree — docs/DECISIONS.md 2026-07-23).
    public func splitPaneTree(_ target: PaneID, axis: SplitAxis, kind: PaneKind) {
        guard !kind.isVideo else { return }
        guard stage(.splitPane, WorkspaceIntentArgs.encode(
            target: target.raw, axis: axis, before: false, newPane: PaneID(), spawnCwd: nil,
        )) else { return }
        reconcileTree()
    }

    /// Closes pane `target` with the full cascade (collapse + rebalance; empty tab → close tab; empty
    /// session → close session unless last; last pane → re-seed a default). Reconcile tears down the
    /// removed leaves and materializes any re-seeded one.
    public func closePaneTree(_ target: PaneID) {
        // Clear a matching parked busy-close so confirming/closing the same leaf twice cannot strand a
        // phantom confirmation dialog (mirrors the canvas `closePane(_:)` `pendingClose` clear).
        if pendingClose == target { pendingClose = nil }
        // ONE op for both shapes: the applier branches on `isDetached` itself, so a detached pane's
        // entry + spec are dropped (reconcile then tears the zombie handle down) and a tiled one
        // cascades. The tab it may take with it goes onto the DOCUMENT's reopen ring, and the
        // successor is picked host-side from the shared MRU — two clients computing it from two local
        // rings pick two different tabs.
        // WHERE THE KEYBOARD LANDS is decided BEFORE the close, from the visit ring — the tree op's own
        // refocus is the closing pane's geometric NEIGHBOUR, which in an `A | B | C` row always hands
        // `B`'s close to `A` however long the user had been working between `C` and `B` (user-reported
        // 2026-08-10: "it focuses some arbitrary pane"). The pane you were just in is the one you meant.
        let landing = paneCloseLanding(closing: target)
        guard stageClose(.closePane, WorkspaceIntentArgs.encode(pane: target)) else { return }
        // Said as an INTENT rather than computed inside the close, so every client lands on the same
        // pane: the ring is this keyboard's own (docs/45 — "the pane I was just in" is a fact about one
        // client), but the FOCUS it resolves to is shared the moment it is named. Staged before the
        // reconcile, so both patches land in one render — the geometric refocus is never on screen.
        if let landing, tree.contains(landing),
           tree.activeSession?.activeTab?.activePane != landing
        {
            stageFocus(pane: landing)
        }
        reconcileTree()
    }

    // MARK: - Detach a pane to its own window (satellite) / reattach

    /// Every detached (own-window) pane in session order then detach order — the satellite-window
    /// coordinator diffs its NSWindows against this. `@Observable` via ``tree``.
    public var detachedPanes: [DetachedPane] {
        tree.sessions.flatMap(\.detached)
    }

    /// Detaches pane `target` into its own OS window: the leaf leaves the split tree but its spec + live
    /// registry handle survive (reconcile unions detached ids into the desired set), so the PTY / video
    /// session keeps running and only the VIEW remounts in the satellite window the app-layer coordinator
    /// opens for it. No-op if `target` is not a tree leaf (already detached / absent).
    public func detachPaneToWindow(_ target: PaneID) {
        guard stage(.detachPane, WorkspaceIntentArgs.encode(pane: target)) else { return }
        reconcileTree()
    }

    /// Reattaches detached pane `target` back into a tab (origin tab when alive, else a fresh tab of
    /// its own — never a dock into an unrelated active tab) and reveals it. The satellite-window
    /// coordinator closes the window when the pane leaves ``detachedPanes``. No-op if `target` is not
    /// detached.
    public func reattachPane(_ target: PaneID) {
        guard stage(.reattachPane, WorkspaceIntentArgs.encode(pane: target)) else { return }
        reconcileTree()
    }

    /// Reattaches detached pane `target` BESIDE leaf `anchor` — the drag-to-merge commit: the satellite
    /// window's grab strip dropped on an edge band of a tree pane (a sidebar-row drop uses the row's pane
    /// as the anchor). KEEPS `PaneID`, so reconcile is a registry no-op (the live session survives; only
    /// the view remounts in the main window). ONE reconcile, fired from the gesture's `.onEnded`. No-op if
    /// `target` is not detached, `anchor` is absent / in another session, or the insert would breach the
    /// depth ceiling.
    ///
    /// TWO intents: the dock back into the tree, then the placement. `reattachPane` names only the
    /// pane -- where a returning pane LANDS is the tree's own rule (origin tab, else a fresh one) --
    /// so the destination is expressed by the op that already means "put this pane beside that one".
    public func reattachPaneTree(_ target: PaneID, beside anchor: PaneID, axis: SplitAxis, before: Bool) {
        guard stage(.reattachPane, WorkspaceIntentArgs.encode(pane: target)) else { return }
        stage(.movePane, WorkspaceIntentArgs.encode(
            source: target, target: anchor, axis: axis, before: before,
        ))
        reconcileTree()
    }

    /// Reattaches detached pane `target` at the ACTIVE tab's outermost `edge` — the drag-to-merge gutter
    /// drop on the main canvas. KEEPS `PaneID` (no surface teardown); ONE reconcile on release. No-op if
    /// `target` is not detached / its session is not active / the dock would breach the depth ceiling.
    public func reattachPaneToActiveTabRootEdgeTree(_ target: PaneID, edge: PaneDropEdge) {
        guard stage(.reattachPane, WorkspaceIntentArgs.encode(pane: target)) else { return }
        if let tab = activeTreeTab {
            stage(.dockPaneAtTabEdge, WorkspaceIntentArgs.encode(dock: target, tab: tab, edge: edge))
        }
        reconcileTree()
    }

    /// Reattaches detached pane `target` into a FRESH tab (the drag-to-merge "New Tab" drop). KEEPS
    /// `PaneID` (no surface teardown); ONE reconcile on release. No-op if `target` is not detached.
    public func reattachPaneToNewTabTree(_ target: PaneID) {
        guard stage(.reattachPane, WorkspaceIntentArgs.encode(pane: target)) else { return }
        // A reattach that already landed in a fresh tab leaves nothing to break out of, and the op
        // refuses a lone leaf -- so the second intent is the "it went home to a shared tab" case.
        stage(.breakPaneToTab, WorkspaceIntentArgs.encode(pane: target))
        reconcileTree()
    }

    /// Reattaches every detached pane (the "Reattach All Panes" menu/palette action).
    public func reattachAllPanes() {
        for entry in detachedPanes {
            stage(.reattachPane, WorkspaceIntentArgs.encode(pane: entry.pane))
        }
        reconcileTree()
    }

    /// Detaches the active tab's active pane (the chord / menu routing target). No-op without one.
    public func detachActivePane() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        detachPaneToWindow(active)
    }

    /// Toggles render-only zoom on the active tab's active pane (the tree is untouched). Tree no-op when
    /// there is no active pane.
    public func toggleZoomTree() {
        guard let tab = tree.activeSession?.activeTab, let active = tab.activePane else { return }
        // ASSIGN, never toggle (DECISIONS, Multi-client Phase 5 ruling 2): a toggle over shared state
        // resolves differently depending on how many clients sent it.
        let zoomed = tab.zoomedPane == active
        guard stage(.setZoom, WorkspaceIntentArgs.encode(id: active.raw, flag: !zoomed)) else { return }
        reconcileTree()
    }

    /// Moves focus in `direction` from the active pane, resolved geometrically against the active tab
    /// solved into `bounds` (the store passes the live viewport; tests pass any finite rect).
    ///
    /// The neighbour is resolved HERE, against the layout this client is looking at, and the winner
    /// travels as an id -- the host has no viewport and cannot answer "which pane is to the left".
    public func moveFocusTree(_ direction: FocusDirection, bounds: CGRect) {
        let next = WorkspaceTreeOps.moveFocus(direction, bounds: bounds, in: tree)
        guard let landed = next.activeSession?.activeTab?.activePane,
              landed != tree.activeSession?.activeTab?.activePane else { return }
        guard stageFocus(pane: landed) else { return }
        reconcileTree()
    }

    /// Moves tree focus in `direction` — the keyboard / menu / command-palette entry point that has no
    /// `GeometryReader` of its own. Resolves against ``treeGeometryBounds``: the view-reported layout when one
    /// has landed (``updateSolvedLayout(_:)``, wired from `SplitContainer`'s layout pass), else a nominal rect
    /// — direction is scale-invariant for the tiled tree (`moveFocusTree` re-solves into the bounds), so the
    /// ⌃⌘arrow chords are NEVER dead. Deliberately NOT gated on a layout report: a wait-for-a-report guard
    /// blocks forever if no mounted view happens to call `updateSolvedLayout`, silently no-opping every
    /// directional chord.
    public func moveFocusTreeUsingReportedLayout(_ direction: FocusDirection) {
        moveFocusTree(direction, bounds: treeGeometryBounds)
    }

    /// Adds a new tab (single leaf of `kind`) to the active session and selects it; materializes its leaf.
    /// The tab lands at the configured ``SettingsKey/newTabPosition`` (the `new-tab-position` setting): `.auto`/
    /// `.end` append, `.afterCurrent` inserts after the active tab. The ⌘T gesture
    /// (``newTerminalPane(_:)`` `.newTab`) funnels through here, so it inherits the same placement.
    public func newTab(kind: PaneKind) {
        newTab(kind: kind, launchGrace: .milliseconds(1400))
    }

    /// Core of ``newTab(kind:)``. `launchGrace` is kept for call-site + overload parity with the paths that
    /// still schedule a deferred send (chat / agent-resume call this then defer their OWN command), but this
    /// path types no startup `cd` — the inherited cwd rides `channelOpen`, so the grace is unused (`_`).
    ///
    /// `kind` is likewise unused: `spawnTab` mints a terminal, and video never enters the tree
    /// (docs/DECISIONS.md 2026-07-23). It stays in the signature because the call sites name it.
    func newTab(kind _: PaneKind, launchGrace _: Duration) {
        // Resolve the new tab's initial cwd from the NEW-TAB working-directory policy against the active
        // pane's last-known cwd (none when there is no active pane) and stamp it on the new spec. The host
        // starts the PTY in that cwd; no visible startup `cd` is sent.
        guard let session = tree.activeSessionID else { return }
        let activePane = tree.activeSession?.activeTab?.activePane
        let activeCwd = inheritableCwd(of: activePane)
        let inheritedCwd = SettingsKey.workingDirectoryNewTab.resolve(activePaneCwd: activeCwd)
        // Both ids are CLIENT-minted, so the optimistic overlay can draw the tab before the host
        // answers (DECISIONS, Multi-client Phase 5 ruling 1).
        let newID = PaneID()
        guard stage(.spawnTab, WorkspaceIntentArgs.encode(
            session: session, newPane: newID, position: SettingsKey.newTabPosition, spawnCwd: inheritedCwd,
        )) else { return }
        seedNewPaneFacts(newID, spawnCwd: inheritedCwd, inheritingFrom: activePane)
        reconcileTree()
    }

    /// Stamps a freshly-created pane's two inherited facts: where its shell starts, and which project
    /// section it draws in on the FIRST frame. The one funnel every new-pane gesture (split / new tab /
    /// new window) passes through, so the two can't be seeded by three transcriptions that drift.
    ///
    /// The project key is seeded only when it genuinely covers the new cwd (see
    /// ``inheritableProjectKey(of:covering:)``); the host's own type-34 for the child's PTY confirms or
    /// corrects it either way.
    ///
    /// The spawn directory is NOT written here: it rides the intent's own `cwd` argument (ops 6 / 12 /
    /// 13 / 18 all carry one) and lands in the document's topology, which is what makes a relaunch
    /// respawn the pane where the user put it rather than at `$HOME`.
    private func seedNewPaneFacts(_ id: PaneID, spawnCwd: String?, inheritingFrom parent: PaneID?) {
        // The document's own `pane/cwd` for a pane whose shell has not started yet is the dir it is
        // being started IN — that is what the rail, the title chain and the section bucket read.
        if let spawnCwd { setLastKnownCwd(spawnCwd, for: id) }
        if let key = inheritableProjectKey(of: parent, covering: spawnCwd) {
            setProjectKey(key, for: id)
        }
    }

    /// The working directory of pane `id` sanitized as an INHERIT SOURCE for a new tab / split / window: a
    /// transient plugin-cache dir (``PaneSpec/looksLikeTransientPluginCwd(_:)`` — `…/owner---repo`) is
    /// dropped to `nil`. Without this a racing `cwd`/`gitStatus` probe that caught the shell mid zinit
    /// turbo `builtin cd` can seed the NEW pane's cwd — poisoning its spawn dir, its folder-name title,
    /// AND its By-Project group (the "new pane lands in zsh-users---zsh-autosuggestions" symptom). Mirrors the
    /// spawn-seed guard in `LivePaneSession.initialCwd` and the write guard in ``setLastKnownCwd(_:for:)``.
    /// `nil` pane / no cwd ⇒ `nil` (the policy then resolves the host default).
    private func inheritableCwd(of id: PaneID?) -> String? {
        StoreSeed.inheritableCwd(id.flatMap { paneCwd(for: $0) })
    }

    /// The parent pane's HOST-pushed `pane/projectKey`, seeded onto a new split/tab/window pane so the
    /// child sections under the parent's project on the FIRST frame — without it the
    /// child sections by its raw inherited cwd (a repo SUBDIRECTORY tears off into its own
    /// subdir-named section) until the host's type-34 for the child's own PTY round-trips.
    /// Guarded by SUBTREE COVERAGE: the seed applies only when `inheritedCwd` sits inside the key's
    /// subtree — a stale key across an un-re-pushed `cd`, or a working-directory policy that
    /// resolves a fixed dir, would otherwise file the child under the wrong project. A cwd-fallback
    /// parent (no host key yet) seeds nothing: the child's identical cwd fallback already sections
    /// it beside the parent. The host's own push (seeded server-side at spawn) re-confirms or
    /// corrects the seed either way.
    private func inheritableProjectKey(of id: PaneID?, covering inheritedCwd: String?) -> String? {
        StoreSeed.inheritableProjectKey(
            id.flatMap { projectKey(for: $0) }, coveringCwd: inheritedCwd,
        )
    }

    /// Closes tab `tabID` (dropping its panes) and cascades like ``closePaneTree(_:)``.
    ///
    /// No successor argument: the HOST picks it, from the shared MRU ring and then the project-section
    /// rule. Two clients computing it from two local rings pick two different tabs.
    public func closeTab(_ tabID: TabID) {
        guard stageClose(.closeTab, WorkspaceIntentArgs.encode(tab: tabID)) else { return }
        reconcileTree()
    }

    /// Close the active tab of the active session (the ⌘⇧W "Close Tab" routing target). A no-op when
    /// there is no active tab. The tree ops cascade an emptied session / re-seed a default like
    /// `closeTab(_:)` does. Routed through ``closeConfirmationNeeded(scope:pane:)`` — under the default
    /// ``CloseConfirmationPolicy/process`` policy this closes immediately unless a pane in the tab is busy,
    /// while `.always` parks the close behind a confirmation. (`.multipleTabs` cannot fire here: closing one
    /// tab loses exactly one tab, so the Settings tab row does not offer it.) A tab holding a project's
    /// LAST pane(s) (``projectClosed(byRemoving:)``) parks regardless of policy — closing it closes the
    /// project, and the dialog warns before the rail section disappears.
    public func closeActiveTab() {
        guard let tab = tree.activeSession?.activeTab else { return }
        if closeConfirmationNeeded(scope: .tab) || projectClosed(byRemoving: tab.allPaneIDs()) != nil {
            // Park the WHOLE tab (its `TabID`, not a single leaf): `confirmPendingClose` resolves a tab park
            // through `closeTab(_:)`, so confirming drops every pane in the tab. Parking a single leaf
            // instead would keep its siblings, regressing ⌘⇧W into a one-pane close.
            parkTabClose(tab.id)
        } else {
            closeTab(tab.id)
        }
    }

    /// Whether the sessions sidebar is collapsed (hidden). Toggled by ⌘B (Muxy parity). In-memory only —
    /// a fresh launch shows the sidebar. Observed by `SplitWorkspaceView` which drops the rail + divider
    /// when true.
    public var sidebarCollapsed: Bool = false

    /// Flip the sessions-sidebar collapsed state (the ⌘B "Toggle Sidebar" routing target).
    public func toggleSidebarCollapsed() { sidebarCollapsed.toggle() }

    /// Selects tab at `index` in the active session — a pure active-state change (the FULL leaf set stays
    /// registered; only focus follows). Reconcile is a registry no-op.
    public func selectTab(_ index: Int) {
        // The intent names the TAB, never the slot: an index resolved on the host would land on a
        // different tab the moment another client reorders or closes one.
        guard let session = tree.activeSession, session.tabs.indices.contains(index) else { return }
        guard stageFocus(tab: session.tabs[index].id) else { return }
        reconcileTree()
        // Badge auto-clear: acknowledge any completion/done badge for every pane in the newly-active tab
        // regardless of HOW the tab switch was triggered (keyboard ⌘1–⌘9, cycleTab, NavigatorColumn, or a
        // direct selectTab call). The `NavigatorColumn.selectRow` badge loop keeps its own copy so it fires
        // even for a same-tab pane-focus that never reaches `selectTab`.
        if let tab = tree.activeSession?.activeTab {
            for id in tab.allPaneIDs() { clearAgentBadge(id) }
        }
    }

    /// Adds a new session (one tab, one leaf of `kind`) and selects it; materializes its leaf. The new
    /// session's leaf inherits the configured ``SettingsKey/workingDirectoryNewWindow`` policy (the "New
    /// Window" working-directory setting) resolved against the active pane's last-known cwd.
    public func newSession(name: String, kind: PaneKind) {
        newSession(name: name, kind: kind, launchGrace: .milliseconds(1400))
    }

    /// Core of ``newSession(name:kind:)``. `launchGrace` is kept for call-site + overload parity with
    /// `newTab` / `splitActivePane`, but this path types no startup `cd` — the inherited cwd rides
    /// `channelOpen` (host-side spawn), so the grace is unused here (`_`).
    func newSession(name: String, kind _: PaneKind, launchGrace _: Duration) {
        // Resolve the new window's initial cwd from the NEW-WINDOW policy against the active pane's
        // last-known cwd (none when there is no active pane), stamp it on the new spec, and let the host
        // spawn the PTY directly in that cwd. Mirrors `newTab` / `splitActivePane`.
        let activePane = tree.activeSession?.activeTab?.activePane
        let activeCwd = inheritableCwd(of: activePane)
        let inheritedCwd = SettingsKey.workingDirectoryNewWindow.resolve(activePaneCwd: activeCwd)
        let previous = tree.activeSessionID
        let newID = PaneID()
        guard stage(.newSession, WorkspaceIntentArgs.encode(
            newSession: SessionID(), newPane: newID, name: name, spawnCwd: inheritedCwd,
        )) else { return }
        seedNewPaneFacts(newID, spawnCwd: inheritedCwd, inheritingFrom: activePane)
        // Keep the OUTGOING session mounted: creating + switching to a new session must not dismantle the
        // session you just left — otherwise returning to it repaints from the lossy ring.
        if let newID = tree.activeSessionID { noteActiveSessionChanged(to: newID, from: previous) }
        reconcileTree()
    }

    /// Closes session `sessionID` (dropping all its tabs/panes) and selects another (or re-seeds a default
    /// when it was the last). Reconcile tears down its leaves.
    public func closeSession(_ sessionID: SessionID) {
        guard stage(.closeSession, WorkspaceIntentArgs.encode(session: sessionID)) else { return }
        noteSessionClosed(sessionID) // drop it from the keep-mounted retention LRU; keep the now-active one
        reconcileTree()
    }

    /// SESSION-RETENTION LRU: the most-recent-first session ids whose pane subtrees the
    /// keep-mounted compositor keeps MOUNTED (at `opacity 0`) even while inactive — so an A→B→A round-trip
    /// does NOT dismantle A's ghostty surfaces and repaint them from the lossy 256 KB ring (dropped prompts
    /// on unfocused panes, blank alt-screen TUIs). Capped at ``retainedSessionCap`` (active + previous;
    /// LRU-evicted beyond) so we never hold every session's live Metal surface on-window. `SplitContainer`
    /// renders a hidden layer for each retained session's tabs; retained-but-inactive sessions have no active
    /// tab, so their panes are hidden + non-interactive (and, off-screen, their video panes release their
    /// `liveVideoCap` slots via the visibility-driven lifecycle). `internal(set)` so the
    /// `WorkspaceStore+Lifecycle` retention helpers can mutate it; still not publicly settable.
    public internal(set) var retainedSessionIDs: [SessionID] = []

    /// Selects session `sessionID` — a pure active-state change (the full leaf set stays registered).
    ///
    /// Expressed as `focusTab` on the session's own active tab: no op names a session directly, and
    /// the applier repoints `activeSessionID` at whichever session owns the named tab — which is the
    /// same change, said in the vocabulary the document has.
    public func selectSession(_ sessionID: SessionID) {
        guard let session = tree.sessions.first(where: { $0.id == sessionID }),
              let tab = session.activeTab ?? session.tabs.first else { return }
        noteActiveSessionChanged(to: sessionID, from: tree.activeSessionID)
        guard stageFocus(tab: tab.id) else { return }
        reconcileTree()
    }

    // MARK: - Tree mutations (the shell wrappers the IDE views drive)

    /// Focuses leaf `id` in the tree (sets its tab's `activePane` + selects that session/tab). The full
    /// leaf set stays registered — a pure active-state change. The IDE shell calls this on a leaf tap.
    public func focusPaneTree(_ id: PaneID) {
        guard tree.contains(id) else { return }
        let alreadyActive = tree.activeSession?.activeTab?.activePane == id
        guard !alreadyActive else { return }
        guard stageFocus(pane: id) else { return }
        reconcileTree()
    }

    /// ``focusPaneTree(_:)`` for a TELEPORT — a jump whose destination was not visually pointed at
    /// (⌘⇧U attention walk, a palette / Open Quickly row, a Global Search hit, a notification /
    /// connection-alert click). When the landing CROSSED a tab (or session) boundary it fires
    /// ``onCrossTabJump`` with the ``JumpBreadcrumb`` destination line, so the shell can flash a
    /// "JUMPED · session ▸ tab" orientation cue. A same-tab focus (or a no-op on a gone pane) stays
    /// silent — the cue is for the disorienting whole-viewport swap only. Deliberate navigation
    /// (a labeled rail row / tab click) keeps calling ``focusPaneTree(_:)`` directly: the user chose
    /// that destination by name, so a chip would be noise.
    public func jumpToPaneTree(_ id: PaneID) {
        let beforeTab = tree.activeSession?.activeTab?.id
        focusPaneTree(id)
        guard let session = tree.activeSession, let tab = session.activeTab,
              tab.id != beforeTab, tab.contains(id) else { return }
        onCrossTabJump?(JumpBreadcrumb.text(
            sessionName: session.name,
            tabTitle: JumpBreadcrumb.tabDisplayTitle(
                tab: tab, specs: session.specs, liveTitle: { liveProgramTitle(for: $0) },
            ),
            includeSession: tree.sessions.count > 1,
        ))
    }

    /// Drag-resizes the divider between children `leadingChildIndex` and `leadingChildIndex + 1` of split
    /// `splitID` by `delta` (in flex-weight units, sum-preserving + clamped). The leaf set is unchanged, so
    /// the reconcile only persists. The `DividerHandle` view converts a pixel drag → a weight delta and
    /// calls this on the active tab's split.
    public func resizeDividerTree(splitID: SplitNodeID, leadingChildIndex: Int, delta: Double) {
        // The delta is resolved against the weights on screen; the op writes ABSOLUTE weights, so what
        // travels is the settled number rather than an increment two clients could both apply.
        let next = WorkspaceTreeOps.resizeDivider(
            splitID: splitID, leadingChildIndex: leadingChildIndex, delta: delta, in: tree,
        )
        guard let weight = Self.leadingWeight(splitID: splitID, index: leadingChildIndex, in: next) else { return }
        guard stage(.setDividerWeight, WorkspaceIntentArgs.encode(
            split: splitID, leadingIndex: leadingChildIndex, leadingWeight: weight,
        )) else { return }
        reconcileTree()
    }

    /// Ejects leaf `id` into a NEW tab of its session (Zellij/Herdr "break pane"); the source tab
    /// collapses/rebalances. No-op if it is its tab's only leaf.
    public func breakPaneToTab(_ id: PaneID) {
        guard stage(.breakPaneToTab, WorkspaceIntentArgs.encode(pane: id)) else { return }
        reconcileTree()
    }

    /// Renames tab `tabID`. Pure metadata — the leaf set is unchanged, so the reconcile only persists.
    public func renameTab(_ tabID: TabID, to title: String) {
        guard stage(.renameTab, WorkspaceIntentArgs.encode(id: tabID.raw, name: title)) else { return }
        reconcileTree()
    }

    /// Renames PANE `id` by writing its spec `title` (the rail row displays the pane-spec title via
    /// ``RailRowsBuilder/rowTitle(kind:spec:)``, whose precedence lets an explicit rename WIN over the cwd
    /// folder name). A blank/whitespace title is a no-op — clearing back to the folder name is done by not
    /// renaming, never by storing an empty title (which the row would then have to special-case). Live-model
    /// aware via ``updateSpecLive(_:_:)``, so the rename persists in whichever model is current.
    ///
    /// Also sets ``PaneSpec/userRenamed`` — the unambiguous "this title is a custom user identity" flag
    /// ``RailRowsBuilder/rowTitle(kind:spec:processLabel:)`` gates the rename branch on. Inferring the flag
    /// from `title != liveTitle` instead misfires for shells that emit changing OSC titles.
    public func renamePane(_ id: PaneID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateSpecLive(id) {
            $0.title = trimmed
            $0.userRenamed = true
        }
    }

    /// Renames session `sessionID`. Pure metadata — the leaf set is unchanged.
    public func renameSession(_ sessionID: SessionID, to name: String) {
        guard stage(.renameSession, WorkspaceIntentArgs.encode(id: sessionID.raw, name: name)) else { return }
        reconcileTree()
    }

    // MARK: - Tree command-routing conveniences (the keyboard/menu/palette entry points)

    /// Splits the active pane along `axis`, inserting a leaf of the user's default kind (Settings ▸
    /// Canvas). The command/menu/palette "split right/down" entry — it resolves the default kind here,
    /// because the CALLER, not the tree ops, owns default-kind resolution.
    public func splitActivePaneDefault(axis: SplitAxis) {
        splitActivePane(axis: axis, kind: .terminal)
    }

    /// The SINGLE source of the default new-session name — "Session N" where N is one past the current
    /// session count, so a created session is never blank. Every session-minting path (the agent control
    /// backend, session templates) names through THIS, so the paths can never drift.
    public var defaultSessionName: String {
        "Session \(tree.sessions.count + 1)"
    }

    // MARK: - Launch presets (Warp launch-configuration parity)

    /// The user's launch presets (built-ins + any they created), in display order. The settings / palette
    /// read this; ``applyLaunchPreset(_:)`` opens one.
    public var launchPresets: [LaunchPreset] { devicePreferences.launchPresets }

    /// Adds (or replaces, by id) a launch preset, then persists. The settings "save preset" path.
    public func upsertLaunchPreset(_ preset: LaunchPreset) {
        mutateDevicePreferences { prefs in
            if let idx = prefs.launchPresets.firstIndex(where: { $0.id == preset.id }) {
                prefs.launchPresets[idx] = preset
            } else {
                prefs.launchPresets.append(preset)
            }
        }
    }

    /// Removes a launch preset by id, then persists. The settings "delete preset" path.
    public func removeLaunchPreset(_ id: UUID) {
        mutateDevicePreferences { $0.launchPresets.removeAll { $0.id == id } }
    }

    /// Resets the launch-preset list back to the shipped built-ins (settings "reset to defaults").
    public func resetLaunchPresetsToBuiltIns() {
        mutateDevicePreferences { $0.launchPresets = LaunchPreset.builtIns }
    }

    /// Applies a launch preset by id: opens a NEW TAB whose first pane runs the preset's command (and, for
    /// a two-pane preset, splits it and runs the secondary command), then types each pane's keystrokes once
    /// its PTY is live. Returns the created pane ids (for tests / the caller), or `[]` for an unknown id.
    ///
    /// The keystroke send is deferred ~1.4s after materialize (the same "let the remote prompt come up"
    /// grace the autotype path uses) — the PTY shell must be ready before the `cd`/command lands. Pure
    /// expansion is done by ``LaunchPresetEngine`` (unit-tested); the store only materializes + sends.
    @discardableResult
    public func applyLaunchPreset(_ id: UUID) -> [PaneID] {
        guard let preset = devicePreferences.launchPresets.first(where: { $0.id == id }) else { return [] }
        return applyLaunchPreset(preset)
    }

    /// Applies an explicit ``LaunchPreset`` value (used by the apply-by-id path and directly by the palette
    /// for a transient preset). See ``applyLaunchPreset(_:)`` by id for the contract.
    @discardableResult
    public func applyLaunchPreset(_ preset: LaunchPreset) -> [PaneID] {
        let plan = LaunchPresetEngine.plan(for: preset)
        guard let first = plan.panes.first, let session = tree.activeSessionID else { return [] }

        // Pane 0: a new tab carrying the preset's first pane. The spawn cwd rides the intent, so the
        // document carries it and the materialize reads it back off the topology.
        let firstID = PaneID()
        guard stage(.spawnTab, WorkspaceIntentArgs.encode(
            session: session, newPane: firstID, position: .auto, spawnCwd: first.spawnCwd,
        )) else { return [] }
        var createdIDs = [firstID]

        // Pane 1 (optional): split pane 0 along the preset's axis.
        if let axis = plan.splitAxis, plan.panes.count > 1 {
            let secondID = PaneID()
            if stage(.splitPane, WorkspaceIntentArgs.encode(
                target: firstID.raw, axis: axis, before: false, newPane: secondID,
                spawnCwd: plan.panes[1].spawnCwd,
            )) {
                createdIDs.append(secondID)
            }
        }
        for (paneID, pane) in zip(createdIDs, plan.panes) {
            // The preset NAMES its panes ("htop", "Claude Code"). Every op that mints a pane titles it
            // with the crate's default, so the name is a rename — which is also what it is: an
            // authored identity the next OSC title must not overwrite.
            if !pane.spec.title.isEmpty, pane.spec.title != TreeWorkspaceDefaults.paneTitle {
                stage(.renamePane, WorkspaceIntentArgs.encode(id: paneID.raw, name: pane.spec.title))
            }
            guard let cwd = pane.spawnCwd, !cwd.isEmpty else { continue }
            setLastKnownCwd(cwd, for: paneID)
        }
        reconcileTree()

        // Send each pane's keystrokes once its PTY is live (deferred — the shell prompt must come up first).
        let sends: [(PaneID, [UInt8])] = zip(createdIDs, plan.panes.map(\.keystrokes)).map { ($0, $1) }
        for (paneID, bytes) in sends where !bytes.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1400))
                self?.registry[paneID]?.sendBytes(bytes)
            }
        }
        return createdIDs
    }

    // MARK: - Find-in-terminal

    /// Opens the ⌘F find bar over the active pane (the keyboard / menu / right-click "Find…" entry). Routes
    /// to the active terminal's ``TerminalViewModel/onRequestFind`` (set by ``TerminalLeafView``); a no-op
    /// for a non-terminal active pane or an empty shell. The find bar's PURE engine is
    /// ``TerminalSearchController`` (unit-tested).
    public func requestFindInActivePane() {
        guard let active = tree.activeSession?.activeTab?.activePane,
              let live = registry[active] as? LivePaneSession else { return }
        live.terminalModel?.onRequestFind?()
    }

    // MARK: - Global Search (cross-tab scrollback search)

    /// The most-recent Global Search results (⇧⌘F), or `nil` before the first run. IN-MEMORY only (NOT
    /// persisted) — a relaunch starts blank. `@Observable` (a normal stored var) so `GlobalSearchView`
    /// re-renders as results land; `private(set)` so only ``runGlobalSearch(query:caseSensitive:isRegex:)``
    /// mutates it. Reopening ⇧⌘F shows the last results until the query is re-run.
    public private(set) var globalSearch: GlobalSearchResults?

    /// The query / flags the last Global Search ran with (so the overlay restores its field + `Aa`/`.*` pills
    /// when reopened). IN-MEMORY only; mutated only by ``runGlobalSearch(query:caseSensitive:isRegex:)``.
    public private(set) var globalSearchQuery: String = ""
    public private(set) var globalSearchCaseSensitive = false
    public private(set) var globalSearchRegex = false

    /// The per-pane scrollback sources for the OPEN ⇧⌘F overlay, mirrored across the libghostty seam
    /// ONCE per overlay-open (``beginGlobalSearchSession()``) and reused for every keystroke's in-memory match
    /// pass (``runGlobalSearch(query:caseSensitive:isRegex:)``) — so typing does NOT re-snapshot the full
    /// scrollback of every pane across the seam on each character. `nil` while the overlay is closed (dropped
    /// by ``endGlobalSearchSession()``); a re-open re-snapshots fresh scrollback. `@ObservationIgnored`: a
    /// derived buffer, not view state (the rendered `globalSearch` results carry the observation).
    @ObservationIgnored private var globalSearchSourceCache: [GlobalSearchSource]?

    /// Moves (swaps) the active pane with its geometric neighbour in `direction` (Zellij "move pane") —
    /// the keyboard/menu/palette entry point that has no `GeometryReader` of its own. Mirrors
    /// ``moveFocusTreeUsingReportedLayout(_:)``: resolves against ``treeGeometryBounds`` (the reported
    /// layout when available, else a nominal rect — the neighbour relation is scale-invariant), so the
    /// ⌥⌘⇧arrow chords are never dead; a no-op when there is no neighbour on the requested side. The moved
    /// pane keeps focus (its `PaneID` is unchanged, so reconcile is a registry no-op). No-op without an
    /// active pane.
    public func swapActivePaneInDirection(_ direction: FocusDirection) {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        // The geometric neighbour is resolved HERE, against the layout this client is looking at, and
        // the resolved PAIR travels — the host has no viewport to answer "which pane is to the left".
        let moved = WorkspaceTreeOps.movePaneInDirection(active, direction, bounds: treeGeometryBounds, in: tree)
        guard let partner = Self.swapPartner(of: active, before: tree, after: moved) else { return }
        guard stage(.swapPanes, WorkspaceIntentArgs.encode(swap: active, with: partner)) else { return }
        reconcileTree()
    }

    /// Resizes the active pane along `direction` by nudging the nearest enclosing split's divider
    /// (`.right`/`.down` grow it, `.left`/`.up` shrink it) — the keyboard counterpart to a drag-resize.
    /// STRUCTURAL (no geometry / solved layout needed): `.left`/`.right` act on the enclosing horizontal
    /// split, `.up`/`.down` on the enclosing vertical split. The leaf set is unchanged, so reconcile is a
    /// registry no-op. No-op without an active pane / no enclosing split. The op is sum-preserving + clamped
    /// at the min-weight floor.
    public func resizeActivePane(_ direction: FocusDirection, step: Double = 0.1) {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        // The enclosing split + child index are structural, so they resolve locally and the settled
        // ABSOLUTE weight travels as one `setDividerWeight`.
        let next = WorkspaceTreeOps.resizeActivePane(active, direction, step: step, in: tree)
        guard let change = Self.changedDividerWeight(before: tree, after: next) else { return }
        guard stage(.setDividerWeight, WorkspaceIntentArgs.encode(
            split: change.split, leadingIndex: change.index, leadingWeight: change.weight,
        )) else { return }
        reconcileTree()
    }

    /// Resets the active tab's split weights to an EQUAL share (tmux "select-layout even-*"), leaving any
    /// `.fixed` bands untouched. STRUCTURAL — the tree shape + leaf set are unchanged, so reconcile is a
    /// registry no-op. No-op without an active pane.
    public func balanceActivePaneSplits() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        // `setTabLayout` rebuilds every split at an equal `.flex(1)` share, which IS the even reset —
        // so the shape alone carries it and no weight has to travel.
        guard stageTabLayout(containing: active, of: WorkspaceTreeOps.balanceSplits(
            activeTabContaining: active, in: tree,
        )) else { return }
        reconcileTree()
    }

    /// The cycle cursor for ``cycleLayout()`` — the last preset applied via the layout commands. UI-only
    /// (not persisted, like the palette/cheat-sheet overlay state); after a manual split/close it may no
    /// longer match the actual shape, but ``cycleLayout()`` just advances the enum deterministically, so it
    /// self-heals on the next press.
    private var lastAppliedLayout: WorkspaceTreeOps.LayoutPreset?

    /// Re-tiles the active tab's tiled tree into `preset` (tmux/zellij `select-layout`), preserving every
    /// pane `PaneID`. Un-zooms first (a re-tile under a full-screen zoom is meaningless). STRUCTURAL — the
    /// leaf set is unchanged, so reconcile materializes/tears down nothing (the no-teardown invariant; every
    /// surface stays mounted). No-op (a 0/1-leaf tab, or no active pane) leaves the tree unchanged.
    public func applyLayout(_ preset: WorkspaceTreeOps.LayoutPreset) {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        guard stageTabLayout(containing: active, of: WorkspaceTreeOps.applyLayout(
            preset, activeTabContaining: active, in: tree,
        )) else { return }
        lastAppliedLayout = preset
        reconcileTree()
    }

    /// Steps the active tab through the ``WorkspaceTreeOps/LayoutPreset`` presets (the "Cycle Layout"
    /// command, ⌃⌘L), re-tiling into the next one each press. Un-zooms first. STRUCTURAL — the leaf set is
    /// unchanged (no teardown). No-op without an active pane.
    public func cycleLayout() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        let (next, applied) = WorkspaceTreeOps.cycleLayout(
            activeTabContaining: active, from: lastAppliedLayout, in: tree,
        )
        guard stageTabLayout(containing: active, of: next) else { return }
        lastAppliedLayout = applied
        reconcileTree()
    }

    // cycleTab / selectTabNumber (the next-prev + ⌘1…⌘9 tab-navigation entries) live in
    // `WorkspaceStore+TabOrdering.swift` — pure `selectTab` conveniences, factored out to keep this class
    // body under the `type_body_length` ceiling.

    // MARK: - Rolled-up agent status (sidebar/tab dots)

    /// The per-pane Claude status the detection signals reduce to. Defaults ``ClaudeStatus/none`` for every
    /// leaf; the detection wiring (foreground-process watch + hooks + manifest fallback) feeds real verdicts
    /// in from the `LivePaneSession`. Stored on the store so the sidebar/chrome dots have a single
    /// observable source. PRUNED to the live leaf set on every reconcile, in the shared diff core alongside
    /// `selectedPanes` / `nativeFrameSize`.
    public internal(set) var paneAgentStatus: [PaneID: ClaudeStatus] = [:]

    /// The per-pane host-provided agent LABEL (the type-27 `label`: the blocking prompt / last assistant
    /// line) — the cheap, host-trusted activity summary the sidebar shows under the session name. No
    /// scrollback access, no LLM, no round-trip; carried verbatim on the wire. PRUNED to the live leaf
    /// set alongside ``paneAgentStatus``. An empty / whitespace label is treated as absent (no key).
    public internal(set) var paneAgentLabel: [PaneID: String] = [:]

    /// The per-pane host-latched agent-session INTENT (wire type 36): the session's first titleable
    /// prompt, sticky for the session's whole life — the sidebar agent row's TITLE ("fix the flaky
    /// CI test" instead of the `claude` every agent row shares). Host-computed from the
    /// `UserPromptSubmit` hook, change-edge deduped, re-asserted on reattach; an empty push (the
    /// session ended) removes the key. Written by ``setAgentIntent(_:for:)``. PRUNED to the live
    /// leaf set alongside ``paneAgentStatus``.
    public internal(set) var paneAgentIntent: [PaneID: String] = [:]

    /// The per-pane COARSE foreground-process name the host reports (wire type 26 — the display-only hint
    /// ``LivePaneSession/foregroundProcessName`` captures), mirrored onto the store so the sidebar rail
    /// can show the trailing process label ("zsh") and ``TabBadgeResolver`` can classify a `caffeinate`/`sudo`
    /// session WITHOUT reaching into the private handle. Written by ``setForegroundProcess(_:for:)`` from
    /// ``handleAgentSignal(id:event:)``; an empty / whitespace name removes the key. PRUNED to the live leaf
    /// set alongside ``paneAgentStatus``.
    public internal(set) var paneForegroundProcess: [PaneID: String] = [:]

    /// The per-pane OSC 9;4 PROGRESS mirror (wire type 32) — the SINGLE observable source the sidebar
    /// tab badge (via ``TabBadgeResolver`` → ``RailRowsBuilder``) and the macOS Dock aggregate
    /// (``rollupProgress(forSession:)``) both read. Written by ``handleProgress(_:for:)`` from each live
    /// pane's `.progress` event (``Connection/ConnectionViewModel`` `onProgressUpdate` → the store hook in
    /// `wireMaterializedLeaf`); a ``ProgressState/clear`` removes the key. A progress edge bumps
    /// ``completionFlashTick`` so the rail repaints. PRUNED to the live leaf set alongside
    /// ``paneForegroundProcess``. The methods live in `WorkspaceStore+Progress.swift`; the stored dict stays
    /// here so `@Observable` synthesises on it.
    public internal(set) var paneProgress: [PaneID: PaneProgress] = [:]

    /// The per-pane ``AgentBadgeGates`` OVERRIDE map — the tab-context-menu badge toggles. An absent key ⇒
    /// the pane follows the GLOBAL default (``SettingsKey/agentBadgeGates``); ``agentBadgeGates(for:)``
    /// resolves override-else-global, and ``RailRowsBuilder`` feeds it to ``TabBadgeGating/resolve(...)``.
    /// Pure VIEW state, NOT persisted (a runtime affordance, like ``paneReadOnly``). PRUNED to the live leaf
    /// set alongside ``paneAgentStatus``.
    public internal(set) var paneAgentBadgeOverrides: [PaneID: AgentBadgeGates] = [:]

    // MARK: - Read-only mode (the per-pane input gate's single source of truth)

    /// The set of panes currently in READ-ONLY mode. The SINGLE observable source of truth the
    /// `🔒 READ ONLY ×` pill, the sidebar lock indicator, and ``isReadOnly(for:)`` all read — so a flip
    /// from ANY entry point (the pill `×`, the View-menu item, the command-palette term, or a programmatic
    /// `setPaneReadOnly`) converges to one value. Written by the per-pane seams in
    /// `WorkspaceStore+ReadOnly.swift` AND mirrored from each live ``TerminalViewModel/onReadOnlyChanged``
    /// (wired in ``wireMaterializedLeaf``). Pure VIEW state, NOT persisted (a runtime toggle — no launch
    /// config key). PRUNED to the live leaf set alongside ``paneAgentStatus``.
    public internal(set) var paneReadOnly: Set<PaneID> = []

    // MARK: - Sidebar tab mirrors (the sidebar is ALWAYS grouped By-Project, in creation order)

    /// The per-TAB MANUAL status-badge override set by `slopdesk tab badge --kind <kind>`
    /// (the client-control CLI). An EXPLICIT override that wins over the per-pane DERIVED badge
    /// (``TabBadgeResolver`` — agent / completion / busy / progress) for the tab's REPRESENTATIVE (active)
    /// pane row in the sidebar rail and the `tab list` badge column. Keyed by ``TabID`` (the badge is
    /// per-tab); being explicit, it bypasses the per-pane agent-badge gates. Pure VIEW state, NOT persisted
    /// (a runtime affordance like ``paneAgentBadgeOverrides``). Written by
    /// ``setTabBadgeOverride(_:for:)``; PRUNED on every ``reconcileTree()`` (TabID-keyed → in
    /// ``pruneTreeSidebarMirrors``, not the pane-keyed prune).
    public internal(set) var tabBadgeOverrides: [TabID: TabBadgeKind] = [:]

    /// PROJECT-scoped compact git summary (branch / ahead / behind / breakdown counts) — keyed by the
    /// NORMALIZED By-Project key (``TabOrderingEngine/normalizedProjectKey(_:)`` of a `gitStatus` reply's
    /// `repoRoot`, else the probed pane's own section key) and rendered on the sidebar SECTION HEADER.
    /// One repo = one section = one summary: every pane in the section shares the repo's state, so a
    /// per-pane mirror was N copies of the same line. Refreshed via ``refreshGitSummary(for:from:)`` on
    /// command completion (OSC 133;D), on a cwd change, on reconnect, and by the project-scoped
    /// snapshot-cadence scheduler (``shouldRefreshGitOnSnapshot(_:now:)``); PRUNED to the live sections'
    /// key set on reconcile. Runtime-only; never persisted.
    public internal(set) var projectGitSummary: [String: PaneGitSummary] = [:]

    /// Projects with an in-flight `gitStatus` fetch — de-dupes concurrent requests ACROSS panes: a
    /// reconnect burst / completion storm over N same-repo panes collapses to one RPC. Cleared as each
    /// reply lands (or is dropped).
    private var projectGitInFlight: Set<String> = []

    /// When each project's ``projectGitSummary`` entry was last fetched — the freshness clock the
    /// ~3 s RTT-snapshot edge consults so every VISIBLE project (not just the focused pane's) self-heals
    /// its header line, at most once per staleness window per project (bounded, never a poll). Stamped by
    /// ``applyGitSummary(_:toplevel:fallbackKey:at:)``; PRUNED with ``projectGitSummary``. Runtime-only.
    public internal(set) var projectGitFetchedAt: [String: Date] = [:]

    /// When a HOST PUSH (the event-driven wire type 35, fed through
    /// ``applyPushedProjectGitSummary(_:repoRoot:at:)``) last landed per project. While one is fresh the
    /// snapshot-cadence poll backs off to ``gitSummaryPushGraceWindow`` — the host's FSEvents watcher owns
    /// freshness and polling would only duplicate it; an old host that never pushes leaves this empty and
    /// the poll cadence stands. PRUNED with ``projectGitSummary``. Runtime-only.
    var projectGitPushedAt: [String: Date] = [:]

    /// The COALESCING memory for the attention notification: the last status we fired an
    /// attention edge for, per pane. So a flap that re-enters the same attention state (`done → working →
    /// done`) does not re-notify — only a transition INTO `needsPermission`/`done` from the last-notified
    /// state fires. PRUNED with `paneAgentStatus` so a recycled / closed pane id can't leak or mis-flap.
    var lastNotifiedStatus: [PaneID: ClaudeStatus] = [:]

    /// The PARKED attention notification per pane (herdr's `pending_agent_notifications`): a notify-worthy
    /// edge waits ``agentAttentionDeliveryDelay`` and is delivered only if the pane STILL holds the status
    /// that earned it — a flap that resolves inside the window never reaches the user. Every genuine status
    /// change REPLACES the pane's pending entry; `generation` guards against a stale one-shot delivering an
    /// entry that was superseded and re-parked with the same status. PRUNED with `lastNotifiedStatus`.
    /// `@ObservationIgnored`: delivery timing, not view state.
    @ObservationIgnored
    var pendingAgentAttention: [PaneID: (status: ClaudeStatus, generation: UInt64)] = [:]

    /// Monotonic ticket for ``pendingAgentAttention`` entries — bumped per park.
    @ObservationIgnored
    var agentAttentionGeneration: UInt64 = 0

    /// The injectable one-shot behind the parked attention delivery (its own property, like
    /// ``doneSettleScheduler``, so a test capturing it never swallows another boundary's arm).
    @ObservationIgnored
    public var agentAttentionScheduler = WorkspaceStore.mainRunLoopFlashDecay

    /// The THIN attention-notification sink (the same seam shape as ``onLongCommandNotify`` /
    /// ``onPaneNotification``): the app shell sets it to call `explicitNotifier.notifyExplicit(...)` on a
    /// needsPermission/done EDGE. Kept off the store so `UNUserNotificationCenter` never enters the store
    /// (→ the edge logic stays headless-testable with a spy). `nil` in tests / headless / iOS ⇒ dropped.
    /// `needsInput == true` for `.needsPermission` (blocked), `false` for `.done`. `detail` is the cheap
    /// host label (the blocking line) when present.
    public var onAgentAttention: ((_ paneIDKey: String, _ name: String, _ needsInput: Bool, _ detail: String?) -> Void)?

    // setAgentStatus + the agent-status reads/rollups/edge live in `WorkspaceStore+Attention.swift`
    // (keeping this class under the type-body-length ceiling). The stored `paneAgentStatus` /
    // `paneAgentLabel` / `lastNotifiedStatus` / `onAgentAttention` stay here because `@Observable`
    // synthesises on them.

    // MARK: - Background-pane command-completion awareness (badge + focus-gated notify)

    /// The per-pane "a command finished while you were elsewhere" badge: a green ✓ / red ✗ a BACKGROUND
    /// pane carries until you look at it (mirrors ``paneAgentStatus``). Set only for an UNFOCUSED pane,
    /// cleared when the pane gains focus (or the app returns active). PRUNED to the live leaf set alongside
    /// ``paneAgentStatus``. `internal(set)` so the badge mutators in `WorkspaceStore+Completion.swift` (a
    /// same-module extension) can write it; still read-only to other modules.
    public internal(set) var panePendingCompletion: [PaneID: PaneCompletionBadge] = [:]

    /// RUNTIME-ONLY per-pane "when did this clean completion land" mirror — the EPHEMERAL `completedAt` that
    /// lets the badge flash decay from ``TabBadgeKind/completed`` (the brief checkmark) to
    /// ``TabBadgeKind/finished`` (the persistent accent dot). Stamped on a `.success` completion-badge edge
    /// (``setCompletionBadge(_:for:)``) and on an agent's entry into ``ClaudeStatus/done``
    /// (``setAgentStatus(_:for:)``); read by ``completionFreshness(forPane:now:)`` vs "now". NOT persisted
    /// (it resets on relaunch, harmlessly); PRUNED to the live leaf set alongside ``panePendingCompletion``.
    public internal(set) var paneCompletedAt: [PaneID: Date] = [:]

    /// RUNTIME-ONLY per-pane "when did this pane last see an attention-relevant edge" mirror — the `since`
    /// FALLBACK for the unseen-attention queue's age ordering (``UnseenAttentionEntry/since``) when no
    /// clean-completion stamp exists (a BLOCKED `needsPermission` agent / a `.failure` badge never stamps
    /// ``paneCompletedAt``). Stamped by the ``setAgentStatus(_:for:at:)`` chokepoint (genuine transitions
    /// only) and the ``setCompletionBadge(_:for:at:)`` set-edge. Per-PANE (not per-tab), so a tab-level
    /// recency stamp cannot stand in for it. NOT persisted; PRUNED to the live leaf set alongside
    /// ``paneCompletedAt``.
    public internal(set) var paneAttentionAt: [PaneID: Date] = [:]

    /// RUNTIME-ONLY per-pane "when did the current foreground command start" stamp — the busy-dot
    /// REVEAL anchor ``paneShowsBusyDot(_:now:)`` compares against "now" so the plain
    /// ``TabBadgeKind/commandBusy`` dot appears only once a command has run past the configured delay.
    /// Stamped on the command-START edge (``handleCommandStarted(id:at:)`` — which also arms the one-shot
    /// that re-renders the rail at the reveal boundary), cleared on completion. NOT persisted;
    /// PRUNED to the live leaf set alongside ``paneCompletedAt``.
    public internal(set) var paneCommandStartedAt: [PaneID: Date] = [:]

    /// RUNTIME-ONLY unread agent-finish latch — panes whose agent hit `.done` while the user was NOT
    /// watching (``isSourcePaneVisible(_:)`` false at the edge) and that have not been visited since.
    /// The host's status machine decays its own `done → idle` after seconds (its job is "what is claude
    /// doing", not "has the user seen it"), so the CLIENT owns unreadness: latched at the
    /// ``setAgentStatus(_:for:at:)`` `.done` edge, cleared by visiting (``clearAgentBadge(_:)`` — tab
    /// switch / focus / ⌘⇧U) or by the agent doing something new (`.working` / `.needsPermission`).
    /// The t3code/herdr model: "done" is unread-completion, orthogonal to the live status. Feeds
    /// ``TabBadgeGating/resolve(...)`` `unseenAgentDone`. NOT persisted; PRUNED to the live leaf set.
    /// The client's replica of the host-owned workspace document (docs/45 §7).
    ///
    /// Shared with ``WorkspaceChannelClient``: host frames land in its `entries`, the per-pane
    /// control sinks write its `fastPath`, and host truth erases an overlay entry for any key it
    /// supplies. One instance is the point — two would let the two producers disagree forever.
    public let workspaceMirror = WorkspaceMirrorBox()

    /// The mirror's `@Observable` shadow: bumped on every change the box reports, and READ by every
    /// store funnel that answers from the mirror.
    ///
    /// Without it a mirror read registers no Observation dependency at all, and the row would sit on
    /// its old value until some unrelated mutation happened to repaint it. That is precisely the
    /// multi-client case: a client whose only source of news is the document changes nothing of its
    /// own, so "some unrelated mutation" never comes. Carries no data — it exists only to invalidate,
    /// exactly like ``completionFlashTick``.
    public internal(set) var workspaceMirrorRevision: UInt = 0

    /// Registers the caller's Observation dependency on ``workspaceMirror``. Every store read funnel
    /// that answers from the mirror opens with this — a funnel that forgets it renders once and then
    /// goes deaf, which is a failure with no symptom until a second client is watching.
    func observeWorkspaceMirror() {
        _ = workspaceMirrorRevision
    }

    /// The channel feeding ``workspaceMirror``'s host truth. `nil` headless and in tests — the
    /// control-push overlay then drives the UI on its own.
    @ObservationIgnored
    public internal(set) var workspaceChannel: WorkspaceChannelClient?

    /// The PROJECTION of `pane/completionEpoch` vs ``seenCompletionEpoch`` — never written directly;
    /// ``refreshUnseenDone(for:)`` owns it. Kept as a Set because every read already binds to one.
    public internal(set) var paneUnseenDone: Set<PaneID> = []

    /// Device-local: the completion counter this device has already READ for each pane, keyed by the
    /// pane's DOCUMENT id. Compared against `pane/completionEpoch`; the host holds no per-client
    /// acknowledgement state at all, which is what lets any number of clients each answer for itself.
    public internal(set) var seenCompletionEpoch: [UUID: UInt32] = [:]

    /// Which document ``seenCompletionEpoch`` was recorded under. A host mints a fresh epoch on every
    /// start and its counters restart with it, so a map carried across that would be measured against
    /// the wrong scale — see ``reconcileSeenCompletionEpochDocument()``.
    @ObservationIgnored public internal(set) var seenCompletionEpochDocument: UUID?

    /// The device-store seam behind ``seenCompletionEpoch``. Left default the map is in-memory only.
    @ObservationIgnored public var completionSeen = CompletionSeenSeam()

    /// RUNTIME-ONLY per-pane "how long has the user been LOOKING at this finished pane" clock — the dwell
    /// anchor behind ``refreshFocusedDoneSettle(at:)``. Stamped when a pane becomes focused (app active)
    /// while carrying a finished-turn marker (a live ``ClaudeStatus/done`` or the ``paneUnseenDone``
    /// latch); dropped the moment it stops being either, so the window measures an UNBROKEN watch.
    /// Only ever holds FOCUSED panes — an unfocused pane's marker keeps waiting for a visit, unchanged.
    /// NOT persisted; PRUNED to the live leaf set alongside ``paneCompletedAt``.
    public internal(set) var paneDoneDwellSince: [PaneID: Date] = [:]

    /// How long a FOCUSED pane keeps its finished-turn marker before the client acknowledges it for you.
    ///
    /// The marker's clear path is ``clearAgentBadge(_:)``, which runs on a SELECTION change (tab switch,
    /// rail click, ⌘⇧U). Returning to the app selects nothing, so a turn that finished while you were away
    /// held its marker on the pane you were already staring at until you clicked away and back. Long enough
    /// that the marker still does its job — you see that a turn ended — and short enough that a pane you
    /// are actually reading stops shouting about it.
    public static let focusedDoneSettleWindow: TimeInterval = 30

    /// RUNTIME-ONLY per-pane "when did the agent's current turn start" stamp — set on the genuine entry
    /// into ``ClaudeStatus/working`` (``setAgentStatus(_:for:at:)``), cleared when the pane leaves
    /// `.working`. The sidebar row's trailing slot renders a live elapsed readout off it while the
    /// agent thinks (the slot's process label says "claude" the whole time — the DURATION is the
    /// information). NOT persisted; PRUNED to the live leaf set.
    public internal(set) var paneWorkingSince: [PaneID: Date] = [:]

    /// How long a clean completion shows its brief ``TabBadgeKind/completed`` checkmark flash before it
    /// settles to the persistent ``TabBadgeKind/finished`` accent dot. Short — the flash is meant to be a beat,
    /// not a dwell — but long enough to register. Compared against ``paneCompletedAt`` in
    /// ``completionFreshness(forPane:now:)``.
    public static let completedFlashWindow: TimeInterval = 3

    /// A lightweight monotonic counter the sidebar rail OBSERVES so the completion-badge flash can decay on
    /// its own. ``completionFreshness(forPane:now:)`` reads the wall clock at row-BUILD time — NOT an
    /// `@Observable` dependency — so once a quiet completed pane stops mutating the store, nothing re-renders
    /// its row and the brief ``TabBadgeKind/completed`` checkmark would stick forever (until an unrelated
    /// mutation / focusing the tab clears it). When a clean completion stamps ``paneCompletedAt``, the store
    /// arms a one-shot (``flashDecayScheduler``) that after ``completedFlashWindow`` bumps this tick → the
    /// rail re-renders EXACTLY ONCE and the row settles to the ``TabBadgeKind/finished`` dot. The bump
    /// carries no row data; it exists ONLY to invalidate the observing view at the flash-window boundary.
    public internal(set) var completionFlashTick: UInt = 0

    /// The injectable one-shot that drives the ``completionFlashTick`` bump at the flash-window boundary:
    /// called as `flashDecayScheduler(completedFlashWindow) { bump }` right after a clean completion
    /// stamps ``paneCompletedAt``. The default (``mainRunLoopFlashDecay``) fires on the main run loop — a
    /// per-completion one-shot, NOT a global per-second timer, so a quiet workspace never re-renders the rail
    /// on a tick. Tests inject a stub that CAPTURES the `bump` (and delay) and fires it synchronously, for a
    /// deterministic boundary re-render with no wall-clock `Task.sleep`. `@ObservationIgnored`: wiring, not
    /// view state (like ``onLongCommandNotify``).
    @ObservationIgnored
    public var flashDecayScheduler = WorkspaceStore.mainRunLoopFlashDecay

    /// The injectable one-shot that re-evaluates the focused-pane finish settle at the dwell boundary —
    /// armed by ``refreshFocusedDoneSettle(at:)`` when a watch STARTS. A finished agent stops mutating the
    /// store, so without this nothing would ever look again and the settle would only land as a side effect
    /// of unrelated traffic. Its own property (not ``flashDecayScheduler``) so the two boundaries stay
    /// independently injectable — a test capturing one must not swallow the other's arm. Same default
    /// (a main-run-loop one-shot, not a global timer). `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored
    public var doneSettleScheduler = WorkspaceStore.mainRunLoopFlashDecay

    /// Whether the app is foregrounded/active — fed by each shell from its own framework's signal:
    /// `NSApplication.shared.isActive` plus the did-become/resign-active notifications on the Mac, the
    /// scene delegate's foreground/background callbacks on the phone. Defaults `true` so a headless store (tests) treats the active
    /// leaf as focused. Combined with the active-leaf identity it forms the "is this pane focused" gate
    /// used by both the badge and the long-command notification.
    public var isAppActive: Bool = true {
        didSet {
            // Returning to active means you are now looking at the focused leaf — clear its pending badge.
            if isAppActive, !oldValue { clearActiveLeafCompletionBadge() }
            // Either edge moves the focused-finish watch: returning STARTS it on the pane already under the
            // user's eyes (the case no selection change ever covers), leaving ABANDONS it (a marker must
            // never expire while nobody is there to read it).
            if isAppActive != oldValue { refreshFocusedDoneSettle() }
        }
    }

    /// Which DETACHED (satellite-window) pane, if any, currently holds the AppKit key-window state — the
    /// focus truth for a pane living outside every tab's split tree, where ``tree/activeSession``'s
    /// active-tab/active-pane chain can never point (docs/DECISIONS.md — detach ↔ reattach). Written by
    /// ``noteSatelliteKey(paneID:isKey:)``, which the app layer (``SatelliteWindowsCoordinator``) calls
    /// from the satellite `NSWindow`'s `didBecomeKey`/`didResignKey`. Read by ``isPaneFocused(_:)`` so a
    /// command finishing in the satellite the user is actively looking at neither badges nor notifies.
    public internal(set) var keySatellitePaneID: PaneID?

    /// Records a satellite window's key-state transition for ``keySatellitePaneID``. `isKey == true` sets
    /// it (the satellite the user is now looking at); `isKey == false` clears it ONLY if `paneID` is still
    /// the current holder — a stale resign racing a newer satellite's become-key must not clobber it.
    public func noteSatelliteKey(paneID: PaneID, isKey: Bool) {
        if isKey {
            keySatellitePaneID = paneID
        } else if keySatellitePaneID == paneID {
            keySatellitePaneID = nil
        }
    }

    /// FULLSCREEN ⇒ system-key capture (docs/DECISIONS.md 2026-07-22): the satellite window
    /// delegate reports enter/exit of native fullscreen; a fullscreen desktop window auto-arms
    /// immersive capture WITHOUT touching the latched per-target toggle. Routed through the
    /// ``PaneSessionHandle`` seam — a graceful no-op for a terminal / empty / not-streaming pane.
    public func noteSatelliteFullscreen(paneID: PaneID, isFullscreen: Bool) {
        handle(for: paneID)?.noteFullscreenPresentation(isFullscreen)
    }

    /// The THIN long-command notification sink: the app sets it to call
    /// `notifier.notifyIfLong(...)`. Kept off the store so `UNUserNotificationCenter` never enters the
    /// store (→ the focus-gated handler stays unit-testable with a spy). `nil` in tests / headless ⇒ the
    /// notification is dropped (the badge still updates). Carries the pane id STRING so a click reveals it.
    public var onLongCommandNotify: ((
        _ paneIDKey: String,
        _ paneTitle: String,
        _ exitCode: Int32?,
        _ durationMS: UInt32,
    ) -> Void)?

    // The badge query/setter/rollup methods + the focus-gated `handleCommandCompleted` handler live in
    // `WorkspaceStore+Completion.swift` (keeping this class under the type-body-length ceiling, like the
    // block ops). The stored properties stay here because `@Observable` synthesises on them.

    // MARK: - reconcileTree (the LIVE tree path)

    /// The tree-driven counterpart of ``reconcile()``, diffing `tree.allPaneIDs()` against the registry.
    /// Delegates the whole load-bearing diff to the shared
    /// ``reconcileRegistry(desiredLeafIDs:spec:onMaterialize:)`` — the same orphan-remove-then-teardown,
    /// ``VideoSlotLedger`` ceiling-accounting, cache pruning, and `makeSession`/`adopt(id:)` materialize the
    /// canvas path uses — but sourced from ``tree`` via `tree.spec(for:)`.
    ///
    /// It wires the SAME per-leaf side effects the canvas `reconcile()` does (pane-rebind /
    /// `onEndpointCommitted`, OSC-9 `onExplicitNotification`), marks the autotype target, syncs the focus
    /// coordinator to the TREE's active pane, and schedules the debounced save. Those side effects are inert
    /// for the pure-diff unit tests (`FakePaneSession` is not a `LivePaneSession`, and such stores carry no
    /// `persistence`), so the tree-reconcile suite still pins the bare diff. Idempotent.
    public func reconcileTree() {
        reconcileTree(acknowledgingFocus: true)
    }

    /// - Parameter acknowledgingFocus: whether this pass counts as THIS USER arriving at the focused
    ///   pane — clearing its completion badge and re-pointing the focused-finish watch. True for every
    ///   local gesture, which is what routes here; false for
    ///   ``reconcileTreeFromDocument()``, because a change another client (or the host) published is
    ///   not this device visiting anything. Unread-completion is a per-DEVICE fact, and a remote
    ///   focus move acknowledging a finish nobody here looked at is how the ✓ disappears unseen.
    func reconcileTree(acknowledgingFocus: Bool) {
        // The diff writes the mirror (`pruneWorkspaceMirror` clears a gone pane's overlay), and every
        // mirror write announces itself — so without this the document hook below would re-enter the
        // very pass that triggered it, once per cleared pane.
        isReconcilingTree = true
        defer { isReconcilingTree = false }
        reconcileRegistry(
            // Detached panes (own-window satellites) are OUT of the tree but stay DESIRED — their live
            // handles (PTY stream / video session) must survive the detach; only the view remounts.
            desiredLeafIDs: tree.allPaneIDs() + tree.detachedPaneIDs(),
            spec: { tree.spec(for: $0) },
            onMaterialize: { [weak self] id, handle in
                self?.wireMaterializedLeaf(id: id, handle: handle)
            },
        )
        // Mark the SLOPDESK_AUTOTYPE target (the first leaf in DFS order) + sync the focus coordinator to
        // the tree's active pane (the iPad-regular first-responder arbiter), then debounce-save. Mirrors the
        // canvas `reconcile()` tail; the model-aware save persists the tree (see `scheduleSave`).
        let autotypeTarget = tree.allPaneIDs().first
        for (id, handle) in registry {
            (handle as? LivePaneSession)?.isAutotypeTarget = (id == autotypeTarget)
        }
        if let focused = tree.activeSession?.activeTab?.activePane, focusCoordinator.focusedPane != focused {
            focusCoordinator.focus(focused)
        }
        if acknowledgingFocus {
            // THE VISIT RING records every pane this user ARRIVES at, not only the ones a navigation
            // NAMED. The two `stageFocus` choke points cannot see the rest: a split's new leaf, a
            // close's landing, a reopened tab's pane. Left out, the ring had a hole exactly where the
            // working set is — split a pane, work in it, focus a sibling, close it, and the landing was
            // resolved against a ring that had never heard of the pane the user had just been living in
            // (found by `PaneCloseLandingTests` 2026-08-10; ⌃⇥ had the same hole). `acknowledgingFocus`
            // is what keeps this THIS device's arrivals: a focus another client published is not a visit.
            if let focused = tree.activeSession?.activeTab?.activePane, focused != paneVisitMRU.first {
                notePaneVisit(focused)
            }
            // A pane that just gained focus (selectTab / selectSession / focusPaneTree all route here) is
            // being watched — clear its pending command-completion badge.
            clearActiveLeafCompletionBadge()
            // …and re-point the focused-finish watch at whatever is focused NOW (the pane that just lost
            // focus abandons its clock; a newly focused pane still carrying a marker starts one).
            refreshFocusedDoneSettle()
        }
        // Prune the tree-keyed sidebar mirrors (the manual tab badges) to the live tree. Keyed by
        // TabID, so pruned here against the tree rather than in the pane-keyed `reconcileRegistry`
        // cache-prune. The helper lives in WorkspaceStore+TabOrdering.
        pruneTreeSidebarMirrors()
        scheduleSave()
    }

    /// TRUE for the duration of ``reconcileTree()``. The document hook reads it, and nothing else does.
    @ObservationIgnored
    var isReconcilingTree = false

    /// The per-new-leaf wiring the live reconcile runs for a materialized ``LivePaneSession`` — factored
    /// out of the canvas `reconcile()`'s `onMaterialize` closure so the tree path and the canvas path
    /// run the IDENTICAL pane-rebind + OSC-9 wiring (no second copy to drift). A no-op for a fake handle.
    private func wireMaterializedLeaf(id: PaneID, handle: any PaneSessionHandle) {
        // PANE REBIND: persist every committed video endpoint into the pane's spec so a relaunch
        // re-streams the bound window instead of re-showing the picker. The leaf set is unchanged by the
        // spec update, so the nested reconcile is a no-op + save. The title follows the binding only
        // while it was tracking the previous binding (a user rename survives re-picks).
        if let model = (handle as? LivePaneSession)?.remoteWindow {
            model.onEndpointCommitted = { [weak self, weak model] endpoint in
                guard let self else { return }
                updateSpecLive(id) { spec in
                    if spec.video == nil || spec.title == spec.video?.title {
                        spec.title = endpoint.title
                    }
                    spec.video = endpoint
                }
                // LATCHED-MODE RESTORE follows the TARGET: every (re-)commit — first open of a restored
                // binding, a picker re-pick, a display switch, a stale-id rebind — re-seeds the model
                // from the target's saved modes (`close()` reset the runtime just before). The
                // fresh session's sink publishes then re-assert each wish. No entry ⇒ leave the model
                // as-is (nothing saved for this target; the post-close defaults are already correct).
                if let saved = devicePreferences.videoModesByTarget[endpoint.modesKey] {
                    model?.seedModes(saved)
                }
            }
            // LATCHED-MODE PERSISTENCE: every explicit mode toggle persists under the pane's TARGET key
            // (`DevicePreferences.videoModesByTarget`) — target-keyed, not pane-keyed, so a close-tab →
            // reopen-the-same-target restores it (the reopened target mints a brand-new pane/spec).
            model.onModesChanged = { [weak self] modes in
                self?.persistVideoModes(modes, for: id)
            }
            // Seed a freshly-materialized pane whose spec already carries its binding (a relaunch
            // restore / openRemoteWindow / ⌥⌘N desktop mint) — reconcile is synchronous, so this lands
            // before any view publishes a sink.
            if let key = tree.spec(for: id)?.video?.modesKey,
               let saved = devicePreferences.videoModesByTarget[key]
            {
                model.seedModes(saved)
            }
        }
        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777): route a terminal pane's child-requested notification
        // to the app poster, tagged with this pane id so a click reveals it.
        let connection = (handle as? LivePaneSession)?.connection
        connection?.onExplicitNotification = { [weak self] paneTitle, title, body in
            self?.handlePaneNotification(id: id, paneTitle: paneTitle, title: title, body: body)
        }
        // CLAUDE AUTO-DETECT: fold the agent-detection wire signals (types 26/27) into this pane's
        // ClaudeStatusMachine and mirror the result into `paneAgentStatus` (→ the sidebar/tab/chrome dots).
        connection?.onAgentSignal = { [weak self] event in
            self?.handleAgentSignal(id: id, event: event)
        }
        // Forward this pane's fresh-vs-resumed reconnect verdict to the app's toast sink, tagged with the
        // pane id so the "reattached / fresh shell" toast identifies (and can focus) it.
        connection?.onResumeOutcomeResolved = { [weak self] outcome in
            self?.onSessionResumeOutcome?(id, outcome)
        }
        // OSC 9;4 PROGRESS (wire type 32): mirror this pane's validated taskbar-style progress into
        // `paneProgress` (→ the sidebar tab badge + the macOS Dock aggregate). A `.clear` arrives as `nil` and
        // removes the indicator; `handleProgress` bumps `completionFlashTick` on an edge so the rail repaints.
        connection?.onProgressUpdate = { [weak self] progress in
            self?.handleProgress(progress, for: id)
        }
        // OSC 7 cwd edge: keep the spec's inheritance source fresh as soon as the shell reports `cd`.
        connection?.onWorkingDirectoryChanged = { [weak self] cwd in
            self?.setLastKnownCwd(cwd, for: id)
        }
        // HOST-computed By-Project key (wire type 34): persist every pushed edge into the pane spec so the
        // sidebar sections render from the host's truth (and a cold relaunch renders them from disk).
        connection?.onProjectKeyChanged = { [weak self] key in
            self?.setProjectKey(key, for: id)
        }
        // HOST-PUSHED project git summary (wire type 35): the FSEvents watcher's event-driven truth.
        // Project-keyed and dirty-guarded at the sink, so N same-repo panes each receiving the push
        // converge on one write.
        connection?.onProjectGitStatusChanged = { [weak self] summary, repoRoot in
            self?.applyPushedProjectGitSummary(summary, repoRoot: repoRoot)
        }
        // HOST-latched agent-session intent (wire type 36): the sticky agent-row title source.
        connection?.onAgentIntentChanged = { [weak self] intent in
            self?.setAgentIntent(intent, for: id)
        }
        // COMMAND-START STALE-BADGE CLEAR (progress-state.md): a new command beginning (OSC 133;C) clears this
        // pane's stale completion ✓/✗ so a busy background pane resolves to the running spinner, not the prior
        // run's exit badge.
        connection?.onCommandStarted = { [weak self] in
            self?.handleCommandStarted(id: id)
        }
        // BACKGROUND-PANE COMMAND-COMPLETION: route a finished command (OSC 133;D, type 23) to the
        // focus-gated store handler — badges an UNFOCUSED pane (✓/✗) and fires the long-command
        // notification only when backgrounded.
        connection?.onCommandCompleted = { [weak self, weak connection] exitCode, durationMS in
            guard let self else { return }
            // See ``PaneLabel/completionNotificationTitle(title:cwd:liveTitle:)`` — prefers the live
            // OSC 0/2 shell title over the static spec title so the banner/toast identifies WHICH
            // command/directory finished.
            let title = completionNotificationTitle(for: id)
            handleCommandCompleted(id: id, exitCode: exitCode, durationMS: durationMS, paneTitle: title)
            // cwd-freshness fallback: refresh this pane's last-known cwd from the host `cwd` RPC on
            // command completion too, so shells without OSC 7 still update the inherit source for the next
            // new tab / split. `[weak connection]` avoids a retain cycle (the closure is owned by `connection`).
            refreshCwd(for: id, from: connection)
            // The sidebar git line follows every completed command (a commit / checkout / touch changes
            // branch + dirty state) — same validate-then-drop RPC idiom as the cwd refresh above.
            refreshGitSummary(for: id, from: connection)
        }
        // LIVE TITLE: the shell's OSC title folds into `pane/liveTitle` + `pane/titleFresh`, which is
        // what the whole title chain reads back through. Every push lands (even an unchanged one): a
        // repeated push proves the running program is STILL asserting it, half of the freshness verdict.
        connection?.onTitleChanged = { [weak self] title in
            self?.noteTitlePushed(title, for: id)
        }
        // The RTT-snapshot edge (~3 s cadence) and reconnect: the pane already presents its own id as
        // its session identity, so there is nothing to transcribe — only the two refreshes it gates.
        connection?.onResumeIdentitySnapshot = { [weak self, weak connection] _, _ in
            guard let self else { return }
            // GIT-LINE population/staleness on the RTT-snapshot edge (~3 s): populate once when absent
            // (a freshly-attached pane gets its line before the first OSC 133;D), then re-fetch ONLY the
            // ACTIVE pane and ONLY when its cached line is older than `gitSummaryStaleWindow` — so a pane
            // that sits idle after the first populate still self-heals its line (a sibling-pane commit / a
            // detached-session drift) without the snapshot cadence becoming a git-status poll. A genuine
            // reconnect refreshes unconditionally via `onReconnected` below.
            if shouldRefreshGitOnSnapshot(id) {
                refreshGitSummary(for: id, from: connection)
            }
            // HOST-AUTHORITATIVE cwd on ATTACH: a shell that emits no OSC-7 (Starship / hookless) never
            // reports its cwd until a command completes, so a freshly-connected pane's title sits at the
            // "Terminal" fallback. The snapshot edge is the earliest recurring post-connect signal — pull the
            // host cwd ONCE here (populate-once gate) so the folder-name title lands without waiting for a
            // command. The gate closes the moment `pane/cwd` is set, so this never becomes a cwd poll.
            // `retries` collapses the up-to-3 s wait for the FIRST landing into ~1 s when the metadata client
            // is briefly not ready at the first snapshot (it self-heals via the cadence regardless).
            if shouldRefreshCwdOnAttach(id) {
                refreshCwd(for: id, from: connection, retries: 3)
            }
        }
        // RECONNECT git-line refresh: a REAL reconnect edge (distinct from the steady-state RTT snapshot
        // above) spawns a fresh host shell and may have missed sibling-pane commits / detached drift while
        // the link was down — ALWAYS re-fetch this pane's git line. Fires once per reconnect, so it is not
        // a poll.
        connection?.onReconnected = { [weak self, weak connection] in
            guard let self else { return }
            refreshGitSummary(for: id, from: connection)
            // HOST-AUTHORITATIVE cwd on RECONNECT: a mux reconnect may have RESPAWNED a fresh host
            // shell (no server-side resume), so this pane's live cwd is only knowable from the host. Pull
            // it via the `proc_pidinfo` `cwd` RPC (shell-agnostic — needs no OSC-7) so the cwd-derived
            // title re-lands immediately instead of collapsing to "Terminal" until the next command
            // completes. Paired with the unconditional `initialCwd` hint (SlopDeskClient.connect) that
            // puts the respawned shell back in the project dir, so this reads the RIGHT cwd, not `$HOME`.
            // `retries` matters MOST here: the reconnect edge has no populate-once cadence to fall back on
            // (`pane/cwd` is already non-nil), so a single-shot pull that raced the control plane would
            // never re-fire — the bounded retry guarantees the fresh-shell cwd re-lands.
            refreshCwd(for: id, from: connection, retries: 3)
            // INSPECTOR RE-ARM across a link flap: the inspector second channel (terminal port + 1) dies
            // with the same link drop, but the host's reattach re-assert re-emits the SAME type-27
            // status — the `applyDetectedStatus` dedupe guard eats it, so the status transition can
            // never re-open the channel (and macOS never drives pause()/resume()). This reconnect edge
            // is the one once-per-flap signal left: tear down the stale client and re-subscribe fresh
            // (full re-tail; the model's upsert/dedup makes the replay safe). Resolved from the registry
            // at fire time (not captured) so a pane torn down mid-flap is a clean no-op; a `.none` pane
            // no-ops inside the session.
            (registry[id] as? LivePaneSession)?.reestablishInspectorOnReconnect()
        }
        // SYNC-INPUT (Zellij ToggleActiveSyncTab): when the per-tab sync flag is on, mirror this pane's
        // keystrokes into every other pane in its tab. The `isFanningSyncInput` guard prevents a sibling's
        // re-entrant sendInput from looping back into another fan-out. A no-op while disarmed.
        let terminal = (handle as? LivePaneSession)?.terminalModel
        terminal?.syncInputTap = { [weak self] data in self?.fanSyncInput(from: id, data) }
        // TILING from the terminal surface: the renderer's right-click "Split Right/Down" fires
        // `onContextMenuSplit` (the rebindable ⌘D/⌘⇧D flows through `wireKeyInterceptor` → the shared
        // `route(...)`, not here). A split MINTS a pane, so it offers the pane-type chooser (terminal / remote
        // window), not a hard-coded terminal. Focus THIS pane first so the chooser's active-pane split targets
        // the surface the user acted on. No chooser host (headless / no titlebar) → a direct terminal split.
        // `true` = side-by-side (horizontal), `false` = stacked (vertical).
        terminal?.onContextMenuSplit = { [weak self] horizontal in
            self?.splitFromContextMenu(paneID: id, horizontal: horizontal)
        }
        // Hand the libghostty surface its PURE keybinding interceptor (the override-aware single-chord
        // table). The helper lives in WorkspaceStore+Keybinding so this body stays under the lint ceiling
        // (same pattern as `seedBlockBookmarks`).
        wireKeyInterceptor(terminal: terminal)
        // FOCUS-ON-CLICK: the surface's mouseDown calls `onRequestFocus`; route it to the tree focus so the
        // workspace focus (chrome / inspector / which pane the next split or close targets) follows a click.
        terminal?.onRequestFocus = { [weak self] in self?.focusPaneTree(id) }
        // READ-ONLY convergence: mirror a flip of THIS pane's input gate — by the pill `×`,
        // the View-menu item, the command-palette term, or the model's own toggle — into the store's
        // `paneReadOnly` set (the single source the pill + the sidebar lock both read). The closure writes
        // the set DIRECTLY (not back through `setPaneReadOnly`, which also drives the model) so there is no
        // re-entrant loop with the model's `isReadOnly` didSet; both writers land the same value, idempotent.
        terminal?.onReadOnlyChanged = { [weak self] on in
            guard let self else { return }
            if on { paneReadOnly.insert(id) } else { paneReadOnly.remove(id) }
        }
        // BOOKMARKS: seed the pane's block model from persistence + wire its change closure to persist
        // back (the helper lives in WorkspaceStore+Blocks so this body stays under the lint ceiling).
        seedBlockBookmarks(id: id, handle: handle)
    }

    /// Folds one Claude-Code agent-detection event (wire types 26/27) for pane `id` into the owning
    /// ``LivePaneSession``'s state machine, then mirrors the new ``ClaudeStatus`` into ``paneAgentStatus``
    /// so the sidebar/tab/chrome agent marks (`StatusDotView`) light up live. The session owns the dedupe + the
    /// dynamic inspector open/close; `setAgentStatus` is itself idempotent.
    private func handleAgentSignal(id: PaneID, event: SlopDeskClient.Event) {
        guard let session = registry[id] as? LivePaneSession else { return }
        let status = session.feedAgentSignal(event)
        // CAPTURE the cheap host-provided label (the type-27 blocking prompt / last line) for the sidebar
        // activity summary — set BEFORE setAgentStatus so an attention edge's notification detail reads the
        // fresh label. type 26 carries no label, so only type 27 updates it.
        if case let .claudeStatus(_, _, label) = event {
            setAgentLabel(label, for: id)
        }
        // Mirror the COARSE foreground-process name (wire type 26) onto the store so the sidebar
        // rail's trailing process label + the `caffeinate`/`sudo` ``TabBadgeResolver`` classification can
        // read it without reaching into the private handle. Display-only — it never touches the agent
        // status (the type-27 verdict stays authoritative, exactly as `LivePaneSession.feedAgentSignal`).
        if case let .foregroundProcess(name) = event {
            setForegroundProcess(name, for: id)
        }
        // Agent activity counts as tab activity, but the recency stamp rides the genuine status change
        // INSIDE `setAgentStatus` (the per-pane status-write chokepoint) — so a working / blocked background
        // tab floats up under the `.updated` sort, and non-wire status writes stamp too. A blanket
        // per-signal stamp HERE would be wrong: it also fires on a type-26 foreground-process change, which
        // carries no status transition.
        // A QUIET type-27 (`kind == 4`) is a status change the host has already ruled bookkeeping — the
        // `/compact` boundary, whose `.working → .idle` would otherwise read as the hook-less completion
        // edge and announce a finish nobody asked about. The dots still move; only the announcement is
        // withheld. type-26 carries no kind, so only a type-27 fold can be quiet.
        var quiet = false
        if case .claudeStatus = event { quiet = session.lastStatusKind.isQuiet }
        setAgentStatus(status, for: id, quiet: quiet)
    }

    /// LATCHED-MODE PERSISTENCE (the `RemoteWindowModel.onModesChanged` sink): records pane `id`'s
    /// explicit mode toggles under its TARGET key in ``DevicePreferences/videoModesByTarget`` — keyed by
    /// target (display / owning app), not pane, so a close-tab → reopen-the-same-target restores them.
    /// DEVICE-LOCAL, not workspace state: a 27" Studio and an iPhone attached to the same host must not
    /// share an immersive-mode latch. Default-normalized to a removed entry + dirty-guarded (a redundant
    /// fire never churns a write). A still-unbound pane (no endpoint yet) has no key to file under.
    private func persistVideoModes(_ modes: VideoPaneModes, for id: PaneID) {
        guard let spec = tree.spec(for: id),
              let key = spec.video?.modesKey else { return }
        let normalized: VideoPaneModes? = modes.isDefault ? nil : modes
        guard devicePreferences.videoModesByTarget[key] != normalized else { return }
        mutateDevicePreferences { $0.videoModesByTarget[key] = normalized }
    }

    // MARK: - reconcileRegistry (the shared, leaf-source-agnostic diff core)

    /// The leaf-source-agnostic core BOTH ``reconcile()`` (canvas) and ``reconcileTree()`` (tree) share, so
    /// the subtlest store logic — orphan detection/removal, the ``liveVideoCap`` ceiling-accounting
    /// (``videoSlots`` / `videoPromotionGeneration` / the `videoTeardownSettle` teardown `Task`),
    /// per-pane cache pruning, and materialize-via-`makeSession` + `adopt(id:)` — exists ONCE. Two
    /// hand-synced copies would be a maintenance hazard: the two paths must diff IDENTICALLY. The caller
    /// supplies the canonical-order `desiredLeafIDs` + a `spec(for:)` lookup; an optional `onMaterialize`
    /// runs its per-new-leaf side wiring (pane-rebind / OSC-9). After it returns:
    ///
    ///   `Set(registry.keys) == Set(desiredLeafIDs)`
    ///
    /// Steps, in order (see ``reconcile()``'s doc for the full rationale):
    /// 1. **Prune per-pane caches** to the live leaf set (a closed/switched-away pane drops out; caches can't
    ///    grow unbounded).
    /// 2. **Orphan removal (synchronous) + teardown (async, launched not awaited)** — the registry entry is
    ///    removed synchronously so `keys == leafIDs` holds the instant this returns; an orphan holding a live
    ///    video stack keeps its cap slot (the ledger's releasing set + the close-time / completion-site
    ///    `videoPromotionGeneration` nudges + the `videoTeardownSettle` hold) until it actually releases.
    /// 3. **Materialize new leaves** — `makeSession(spec)` + `adopt(id:)` per new leaf, then `onMaterialize`.
    private func reconcileRegistry(
        desiredLeafIDs: [PaneID],
        spec: (PaneID) -> PaneSpec?,
        onMaterialize: ((PaneID, any PaneSessionHandle) -> Void)? = nil,
    ) {
        let leafSet = Set(desiredLeafIDs)

        // 1. Prune the per-pane mirrors below to the live leaf set in lockstep — a closed pane must drop out so
        // the dict can't grow unbounded and no stale entry surfaces in a rollup / on a recycled id.
        // Agent status (absent key reads `.none`):
        if !paneAgentStatus.isEmpty {
            paneAgentStatus = paneAgentStatus.filter { leafSet.contains($0.key) }
        }
        // Agent label + attention-notify coalescing memory: a recycled id must re-arm cleanly so the
        // next genuine edge notifies (no mis-flap).
        if !paneAgentLabel.isEmpty {
            paneAgentLabel = paneAgentLabel.filter { leafSet.contains($0.key) }
        }
        // Agent-session intent (the type-36 title latch):
        if !paneAgentIntent.isEmpty {
            paneAgentIntent = paneAgentIntent.filter { leafSet.contains($0.key) }
        }
        if !lastNotifiedStatus.isEmpty {
            lastNotifiedStatus = lastNotifiedStatus.filter { leafSet.contains($0.key) }
        }
        if !pendingAgentAttention.isEmpty {
            pendingAgentAttention = pendingAgentAttention.filter { leafSet.contains($0.key) }
        }
        // Completion badge (✓/✗):
        if !panePendingCompletion.isEmpty {
            panePendingCompletion = panePendingCompletion.filter { leafSet.contains($0.key) }
        }
        // Completion-timestamp mirror (the badge-flash decay clock):
        if !paneCompletedAt.isEmpty {
            paneCompletedAt = paneCompletedAt.filter { leafSet.contains($0.key) }
        }
        // Attention-edge timestamp mirror (the NEEDS-ATTENTION `since` fallback):
        if !paneAttentionAt.isEmpty {
            paneAttentionAt = paneAttentionAt.filter { leafSet.contains($0.key) }
        }
        // Command-start stamp (the busy-dot reveal clock):
        if !paneCommandStartedAt.isEmpty {
            paneCommandStartedAt = paneCommandStartedAt.filter { leafSet.contains($0.key) }
        }
        // Unread agent-finish latch (Set-prune idiom, like `paneReadOnly` below):
        if !paneUnseenDone.isEmpty, !paneUnseenDone.isSubset(of: leafSet) {
            paneUnseenDone.formIntersection(leafSet)
        }
        // Focused-finish watch clock (the dwell behind the focused-pane settle):
        if !paneDoneDwellSince.isEmpty {
            paneDoneDwellSince = paneDoneDwellSince.filter { leafSet.contains($0.key) }
        }
        // The workspace document's client side: drop closed panes' overlays, and tell the host what
        // this client is now looking at (dirty-guarded at the channel — most reconciles are not a
        // view change).
        pruneWorkspaceMirror(keeping: leafSet)
        pruneCompletionSeen(keeping: leafSet)
        publishWorkspacePresence()
        // Working-turn start stamp (the trailing-slot elapsed readout):
        if !paneWorkingSince.isEmpty {
            paneWorkingSince = paneWorkingSince.filter { leafSet.contains($0.key) }
        }
        // Foreground-process mirror (process label / privilege badge):
        if !paneForegroundProcess.isEmpty {
            paneForegroundProcess = paneForegroundProcess.filter { leafSet.contains($0.key) }
        }
        // Project git summary + clocks (the section-header git line) — PROJECT-keyed, so the live set
        // is the union of the live panes' effective section keys, not the leaf set itself:
        if !projectGitSummary.isEmpty || !projectGitFetchedAt.isEmpty || !projectGitPushedAt.isEmpty {
            let liveKeys = Set(leafSet.compactMap { effectiveGitProjectKey($0) })
            if !projectGitSummary.isEmpty {
                projectGitSummary = projectGitSummary.filter { liveKeys.contains($0.key) }
            }
            if !projectGitFetchedAt.isEmpty {
                projectGitFetchedAt = projectGitFetchedAt.filter { liveKeys.contains($0.key) }
            }
            if !projectGitPushedAt.isEmpty {
                projectGitPushedAt = projectGitPushedAt.filter { liveKeys.contains($0.key) }
            }
        }
        // OSC 9;4 progress mirror (else a stale spinner/bar survives in a Dock rollup):
        if !paneProgress.isEmpty {
            paneProgress = paneProgress.filter { leafSet.contains($0.key) }
        }
        // READ-ONLY set (absent id reads writable). Mirrors the `selectedPanes` Set-prune idiom above
        // (intersect, not reallocate, only when needed).
        if !paneReadOnly.isEmpty, !paneReadOnly.isSubset(of: leafSet) {
            paneReadOnly.formIntersection(leafSet)
        }
        // Agent-badge override map:
        if !paneAgentBadgeOverrides.isEmpty {
            paneAgentBadgeOverrides = paneAgentBadgeOverrides.filter { leafSet.contains($0.key) }
        }

        // 2. Orphans: remove from the registry synchronously (the registry is the source of truth for
        //    "what is live"), then drive teardown. Removing first guarantees the invariant holds the
        //    instant reconcile returns, even though teardown's async cleanup completes slightly after.
        let orphans = registry.filter { !leafSet.contains($0.key) }.map(\.value)
        for orphan in orphans {
            registry.removeValue(forKey: orphan.id)
            // Whether this orphan is STILL holding a live video stack, read NOW — before the async
            // teardown nils it. That reading is the whole of what the ledger needs: a pane that was
            // decoding keeps its cap slot booked until its teardown actually releases the resources,
            // and closing one is itself a slot-freeing event worth nudging a gated sibling for. Which
            // of those two things happens is the door's decision, not this line's.
            let holdsStack = orphan.kind.isVideo && orphan.isVideoActive
            publishVideoSlots(videoSlots.orphan(orphan.id, holdsStack: holdsStack))
        }
        if !orphans.isEmpty {
            // Teardown in a dedicated task, in registry-removal order, each awaited inside the task (no
            // fire-and-forget races: this single task serializes the disconnect order across the
            // orphaned sessions). The task is tracked in `teardownTasks` so `quiesce()` can await the
            // cleanup to finish, and self-prunes its own entry on completion (id-keyed) so a completed
            // teardown frees its handle promptly. NOTE: the task is launched here, NOT awaited inline —
            // reconcile is synchronous (see the doc-comment's same-tick ceiling note).
            let id = nextTeardownID
            nextTeardownID &+= 1
            teardownTasks[id] = Task { @MainActor in
                for orphan in orphans {
                    await orphan.teardown()
                    // For a video orphan that was holding a live stack, `teardown()` only KICKS OFF
                    // the release — it sets `RemoteWindowModel.active = nil`, and the actual
                    // UDP/VTDecompression/display-link teardown happens a few runloop turns later, when the
                    // GUI leaf's woken arm unmounts the surface → `VideoWindowPipeline.deactivate()` →
                    // detached `session.stop()`.
                    // Hold the cap slot for `videoTeardownSettle` past `teardown()` so a same-tick sibling
                    // cannot be admitted while the outgoing stack is still up (transient cap+1). Only
                    // entered for an orphan the ledger actually booked (a video pane that was live) and
                    // only when a settle is configured, so the terminal-only / `.zero`-settle paths are
                    // unaffected. The sleep is cancel-safe.
                    if self.videoSlots.isReleasing(orphan.id), self.videoTeardownSettle > .zero {
                        try? await Task.sleep(for: self.videoTeardownSettle)
                    }
                    // The orphan's video resources are released — stop counting it against the cap, and
                    // publish the COMPLETION-SITE nudge. The close-time bump fired while this slot was
                    // STILL counted, so a same-tick gated reopen was refused and parked on the "Video
                    // paused" placeholder; this is the instant the slot ACTUALLY frees, so that pane
                    // re-attempts now rather than waiting for an unrelated event to nudge it. Whether
                    // there is a nudge at all is the ledger's — an unbooked orphan freed nothing.
                    // Serialized on the main actor with `activateVideo`'s read, so a same-tick reopen sees
                    // the slot freed only after the real release.
                    self.publishVideoSlots(self.videoSlots.release(orphan.id))
                }
                self.teardownTasks.removeValue(forKey: id)
            }
        }

        // 3. New leaves: materialize an idle session for each, binding its identity to the leaf id, then
        //    let the caller wire it (the canvas path's pane-rebind / OSC-9 closures).
        for id in desiredLeafIDs where registry[id] == nil {
            guard let spec = spec(id) else { continue }
            let handle = makeSession(PaneMaterialization(id: id, spec: spec, spawnCwd: spawnCwd(for: id)))
            (handle as? PaneSessionIDAdopting)?.adopt(id: id)
            registry[id] = handle
            onMaterialize?(id, handle)
        }
    }

    // MARK: - Persistence (debounced; cancel-safe)

    /// The PERSISTABLE snapshot of the live tree right now, or `nil` when there is nothing to write.
    ///
    /// ``tree`` is a PROJECTION: with no document it is a workspace of zero sessions — the absence of a
    /// layout, not an empty one. Writing that out would replace the only copy of what the next launch
    /// restores from, and the client is in exactly that state on the way to every re-subscribe
    /// (``WorkspaceChannelClient/stop()`` resets the mirror before ``start()``) and for as long as a host
    /// that does not serve the channel keeps refusing it.
    private func persistableSnapshot() -> TreeWorkspace? {
        mirroredTopology == nil ? nil : tree
    }

    /// Schedules a debounced save of the value tree (docs/22 §6): cancels any pending save and starts a
    /// fresh one, so a burst of mutations writes exactly once after the quiet period. Cancel-safe (a
    /// superseded task's `Task.sleep` throws `CancellationError`, which `try?` swallows before any write). A
    /// no-op until `savingEnabled` (set after the init reconcile) and when no `persistence` is configured
    /// (the fake/test seam never touches disk). The supersession-guard-plus-atomic-write critical section
    /// lives in the body below.
    private func scheduleSave() {
        guard savingEnabled, let persistence else { return }
        saveTask?.cancel()
        // Snapshot the (Sendable, value-typed) PERSISTABLE tree now, so the write reflects this mutation.
        guard let snapshot = persistableSnapshot() else { return }
        let debounce = saveDebounce
        saveGeneration &+= 1
        let generation = saveGeneration
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return // superseded by a newer mutation (cancelled) — that one will write.
            }
            // The supersession re-check AND the atomic write are ONE main-actor critical
            // section: `await MainActor.run` re-checks `saveGeneration` and, only if still current, writes,
            // never releasing the actor between guard and rename. `saveImmediately()` also writes on the main
            // actor under a bumped generation, so the two RENAMES serialize there and a stale snapshot's
            // rename can never interleave between a newer write's guard and rename. `Task.cancel()` cannot
            // stop a task already past its sleep, so the generation guard — decided on the actor where every
            // `saveGeneration` mutation happens — is what lets `saveImmediately()` / a newer write win.
            // Encoding the small layout tree on the main actor is acceptable; the (now-current) handle clear
            // happens in the same block.
            await MainActor.run { [weak self] in
                guard let self, isCurrentSaveGeneration(generation) else { return }
                // A failed save keeps the previous good file (best-effort).
                try? persistence.save(snapshot)
                saveTask = nil
            }
        }
    }

    /// Writes the live tree synchronously NOW (the scenePhase-background path — docs/22 §6), cancelling
    /// any in-flight debounced save first so the two never race. Best-effort: a thrown error is
    /// swallowed (the previous good file is kept). A no-op when no `persistence` is configured.
    public func saveImmediately() {
        saveDocumentCacheNow()
        guard let persistence else { return }
        // Bump the generation so any in-flight (already-past-sleep) debounced task reliably loses the
        // trailing-clear guard and cannot resurrect/nil the handle after this explicit save.
        saveGeneration &+= 1
        saveTask?.cancel()
        saveTask = nil
        guard let snapshot = persistableSnapshot() else { return }
        try? persistence.save(snapshot)
    }

    // MARK: - Document cache (docs/45 §7.3)

    /// Coalesces a burst of fact changes into one `workspace-cache.json` write.
    ///
    /// Its own debounce rather than a ride on ``scheduleSave()``: the tree and the facts move on
    /// different edges — a `cd` changes no layout at all, and a divider drag changes no fact — so
    /// sharing a timer would make each one pay for the other's churn. The window is the same, and
    /// both are best-effort: a failed write keeps the previous good picture.
    func scheduleDocumentCacheSave() {
        guard savingEnabled, documentCache != nil else { return }
        documentCacheSaveTask?.cancel()
        let debounce = saveDebounce
        documentCacheSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return // superseded by a newer change (cancelled) — that one will write.
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                documentCacheSaveTask = nil
                saveDocumentCacheNow()
            }
        }
    }

    /// Writes the cache synchronously NOW — the scenePhase-background path, and what
    /// ``saveImmediately()`` folds in so quitting never loses the last `cd`.
    func saveDocumentCacheNow() {
        guard let documentCache else { return }
        documentCacheSaveTask?.cancel()
        documentCacheSaveTask = nil
        // The facts are scoped to the live leaves, and those come from the projection — so with no
        // document there are no facts to write, only the absence of them. Same rule as
        // ``persistableSnapshot()``, for the same window.
        guard mirroredTopology != nil else { return }
        try? documentCache.save(documentFactsSnapshot(), hostKey: documentCacheHostKey)
    }

    // MARK: - Tree lookups

    /// Whether the app-global connection is up — set by the app shell after construction so the store can
    /// gate the scene-level "Reconnect Pane" command before the first connect (else ⇧⌘R would build the
    /// shared mux behind the connect-gate). `nil` in tests / headless ⇒ no gating.
    public var isAppConnected: (@MainActor () -> Bool)?

    /// The ⌘+ / ⌘- / ⌘0 font-zoom seam — wired by the app shell to the live ``PreferencesStore`` so a zoom
    /// mutates the SINGLE source of truth (`terminal.fontSize`), keeping the Settings "Size" stepper in
    /// sync. The store fires it ONLY for a terminal active pane (the no-op-off-terminal contract the
    /// FontScroll hooks already hold). `nil` in tests / headless ⇒ the zoom is a clean no-op.
    public var onFontSizeStep: ((FontSizeStep) -> Void)?

    /// The cwd-visit sink: fired with the pane's NEW working directory whenever ``setLastKnownCwd(_:for:)``
    /// records a CHANGED cwd (passes the dirty guard). The app wires this to ``FolderFrecencyStore/record(cwd:)``
    /// so the Open-Quickly **Folders** filter learns the directories you visit — but the store stays
    /// shell- and Folders-agnostic: a plain `(String) -> Void`, not a dependency on the Folders module. `nil` in
    /// tests / headless ⇒ no frecency side effect. Dirty-guarded, so a re-focus / unchanged refresh never
    /// records a phantom visit.
    public var onCwdVisited: ((String) -> Void)?

    /// Records the app-global connection ``ConnectionTarget`` (called by ``AppConnection/onTargetCommitted``
    /// on a successful connect).
    ///
    /// The target is DEVICE-LOCAL: it is filed in ``DevicePreferences/connectionByHostKey`` under
    /// `host:port`, so re-dialling a known host restores the video ports it was reached on, and the
    /// layout — which every attached client shares — carries no host association at all.
    public func commitConnectionTarget(_ target: ConnectionTarget) {
        let previousHostKey = attachedHostKey
        committedConnectionTarget = target
        let key = DevicePreferences.hostKey(for: target)
        // The cache is a picture of ONE host. A connect to a different one than this run was
        // seeded from leaves the mirror holding facts about two machines, so it stops being
        // written rather than filing one host's folders under the other's name.
        documentCacheHostKey = key == documentCacheSeedHostKey ? key : ""
        // …and so is the LAYOUT. This is the one place that can see the document being projected
        // belongs to a machine other than the one now being dialled, and it runs BEFORE the
        // connection reports up (``AppConnection`` commits the target first), so the hold is in
        // place by the time the establish fan-out asks every pane to dial.
        if key != previousHostKey {
            paneDialHoldExpired = false // a new host is a new hold, with its own full window
            refreshPaneDialGate()
        }
        guard devicePreferences.connectionByHostKey[key] != target else { return }
        mutateDevicePreferences { $0.connectionByHostKey[key] = target }
    }

    // MARK: - Titles

    private func defaultTitle(for kind: PaneKind) -> String {
        PaneChooserRegistry.option(for: kind).title
    }
}

// MARK: - Interactive layout drags (commit-on-release)

public extension WorkspaceStore {
    /// Swaps two leaves in the active tab — the commit for a drag-to-move: you grabbed `source`'s top handle
    /// and dropped it onto `target`. Both keep their `PaneID`, so reconcile is a registry no-op (no surface
    /// teardown) and only the solved geometry changes. ONE reconcile, fired from the gesture's `.onEnded`
    /// (the live drag is the view's overlay) so the keystroke / terminal-resize path stays quiet during the
    /// drag. No-op if the ids are equal or either is absent / they are in different tabs.
    func swapPanesTree(_ source: PaneID, _ target: PaneID) {
        guard source != target else { return }
        guard stage(.swapPanes, WorkspaceIntentArgs.encode(swap: source, with: target)) else { return }
        reconcileTree()
    }

    /// Relocates `source` to sit beside `target` along `axis`, on the BEFORE side when `before` (else after)
    /// — the commit for a drag-to-EDGE drop: you grabbed `source`'s top handle and dropped it on an edge of
    /// `target`, so it becomes a new row/column on that side (the directional re-split — this is also how a
    /// split is reoriented from side-by-side to stacked). `source` keeps its `PaneID`, so reconcile tears
    /// down nothing — only the solved geometry changes. ONE reconcile, fired from the gesture's `.onEnded`.
    /// No-op if the ids are equal / either is absent / they are in different tabs, or the relocation would
    /// not change the tree.
    func moveLeafTree(_ source: PaneID, beside target: PaneID, axis: SplitAxis, before: Bool) {
        guard source != target else { return }
        guard stage(.movePane, WorkspaceIntentArgs.encode(
            source: source, target: target, axis: axis, before: before,
        )) else { return }
        reconcileTree()
    }

    /// Docks `source` to the OUTERMOST `edge` of its tab — the commit for a drag-to-CONTAINER-edge drop: you
    /// dragged `source`'s handle into the container's outer gutter, so it becomes a full-span column
    /// (`.left`/`.right`) or row (`.top`/`.bottom`). `source` keeps its `PaneID`, so reconcile tears down
    /// nothing. ONE reconcile, fired from the gesture's `.onEnded`. No-op if `source` is absent, its tab has
    /// only one leaf, the dock would breach the depth ceiling, or it would not change the tree (already
    /// docked there).
    func moveLeafToRootEdgeTree(_ source: PaneID, edge: PaneDropEdge) {
        guard let tab = tree.tab(containing: source)?.1 else { return }
        guard stage(.dockPaneAtTabEdge, WorkspaceIntentArgs.encode(
            dock: source, tab: tab, edge: edge,
        )) else { return }
        reconcileTree()
    }

    /// Relocates `source` beside `target` — ACROSS tabs of the same session when needed. The commit for a
    /// rail-drag MOVE of an already-streamed window dropped on a pane's edge band (docs/45): the window's
    /// existing pane leaves its tab (a sole-leaf tab closes) and lands beside the pane under the cursor,
    /// KEEPING its `PaneID` so reconcile tears down nothing — the live stream survives the move. ONE
    /// reconcile on release. Same-tab drops keep `moveLeafTree`'s no-op rules; cross-session moves are
    /// no-ops (the pane's spec cannot leave its session's side table).
    func moveLeafAcrossTabsTree(_ source: PaneID, beside target: PaneID, axis: SplitAxis, before: Bool) {
        guard source != target else { return }
        guard stage(.movePane, WorkspaceIntentArgs.encode(
            source: source, target: target, axis: axis, before: before,
        )) else { return }
        reconcileTree()
    }

    /// Docks `source` at the ACTIVE tab's outermost `edge` — across tabs of the same session when needed.
    /// The commit for a rail-drag MOVE of an already-streamed window dropped in the container gutter
    /// (docs/45). KEEPS `PaneID` (no surface teardown); ONE reconcile on release; no-op when nothing
    /// would change (already docked there / sole pane of the active tab).
    func moveLeafToActiveTabRootEdgeTree(_ source: PaneID, edge: PaneDropEdge) {
        guard let tab = activeTreeTab else { return }
        guard stage(.dockPaneAtTabEdge, WorkspaceIntentArgs.encode(
            dock: source, tab: tab, edge: edge,
        )) else { return }
        reconcileTree()
    }

    /// Brings pane `id` fully into view — the one-call "take me to this pane" the right rail's streamed
    /// rows and the rail-drag move commit share. A background-tab pane routes through ``selectTab(_:)``
    /// FIRST: `focusPaneTree` alone would also land on the right tab (`focusPane` repoints session + tab),
    /// but it skips `selectTab`'s badge auto-clear — and a tab the user was just taken to has been seen,
    /// the same rule a left-rail row click applies.
    func revealPaneTree(_ id: PaneID) {
        if let session = tree.activeSession,
           let index = session.tabIndex(containing: id),
           index != session.activeTabIndex
        {
            selectTab(index)
        }
        focusPaneTree(id)
    }

    /// Suspends/resumes host grid-resize delivery for EVERY live terminal pane — the shell raises this for
    /// the duration of a sidebar/inspector-divider drag. Dragging an AppKit `NSSplitView` divider
    /// live-resizes the content column every cell-step; for a remote terminal each forward is a host PTY
    /// reflow + a re-streamed redraw. Holding them and flushing the final grid ONCE on release keeps the
    /// content from re-rendering per drag step (the same commit-on-release rule as the pane divider). The
    /// non-terminal handles (`.desktop`) have no `terminalModel`, so they are skipped.
    func setTerminalResizeSuspended(_ suspended: Bool) {
        // The interactive-resize bracket for BOTH dividers (the pane divider's own begin/end —
        // `MacPaneDivider` / `PaneDividerView` — and the AppKit sidebar divider's drag-active/settle).
        // Drives the pane scrim's "drag in progress" hold so
        // a PAUSED drag keeps the overlay up (see ``isInteractiveResizeActive``).
        isInteractiveResizeActive = suspended
        for handle in allSessions {
            (handle as? LivePaneSession)?.terminalModel?.setResizeSuspended(suspended)
        }
    }

    /// LIVE pane-divider drag: set the leading child's ABSOLUTE flex weight (clamped) and re-solve the layout,
    /// WITHOUT reconciling the registry or persisting. A divider drag changes only weights, not the SET of
    /// panes, so each frame is a pure tree assign + a canvas re-layout (the panes resize live). The shell
    /// brackets the drag with ``setTerminalResizeSuspended(_:)`` — holding the host grid-resize send until
    /// release, the "update the layout live but defer the server event to drag-end" rule — and commits once on
    /// release via ``commitDividerResize()``.
    ///
    /// A PREVIEW, not an intent: one intent per drag frame would flood the channel and make every
    /// other client watch the drag. ``WorkspaceStore/tree`` overlays it onto the projection, and
    /// ``commitDividerResize()`` discards it the instant the single real intent is staged.
    func setDividerWeightLive(splitID: SplitNodeID, leadingChildIndex: Int, leadingWeight: Double) {
        setLiveDividerWeight((split: splitID, index: leadingChildIndex, weight: leadingWeight))
    }

    /// Commits a finished live divider drag: reconcile (housekeeping) + persist the settled ratio ONCE. The
    /// per-frame ``setDividerWeightLive(splitID:leadingChildIndex:leadingWeight:)`` skips this, so it runs a
    /// single time on release rather than every frame.
    func commitDividerResize() {
        // Read the CLAMPED weight off the preview rather than the raw drag number: the op is
        // sum-preserving, so what the user actually saw is what must travel.
        if let live = liveDividerWeight,
           let settled = Self.leadingWeight(splitID: live.split, index: live.index, in: tree)
        {
            setLiveDividerWeight(nil)
            stage(.setDividerWeight, WorkspaceIntentArgs.encode(
                split: live.split, leadingIndex: live.index, leadingWeight: settled,
            ))
        }
        reconcileTree()
    }

    /// Evens ONLY the double-clicked seam — the divider between children `leadingChildIndex` and
    /// `leadingChildIndex + 1` of split `splitID` resets to an equal pair share (sum-preserving), while
    /// every OTHER divider's dragged ratio survives. The `PaneDivider` double-click target; the whole-tab
    /// even reset stays on ``balanceActivePaneSplits()`` (the ⌃⌘= chord). The leaf set is unchanged, so
    /// reconcile is a registry no-op.
    func evenDividerTree(splitID: SplitNodeID, leadingChildIndex: Int) {
        let next = WorkspaceTreeOps.evenDivider(splitID: splitID, leadingChildIndex: leadingChildIndex, in: tree)
        guard let weight = Self.leadingWeight(splitID: splitID, index: leadingChildIndex, in: next) else { return }
        guard stage(.setDividerWeight, WorkspaceIntentArgs.encode(
            split: splitID, leadingIndex: leadingChildIndex, leadingWeight: weight,
        )) else { return }
        reconcileTree()
    }

    /// The bounds the tree's geometric ops (directional focus / move-pane) solve the active tab into:
    /// the union of the frames the view last reported via ``updateSolvedLayout(_:)`` (the exact geometry
    /// the user sees), else the reported container bounds (``updateContainerBounds(_:)``), else a nominal
    /// desktop rect — a directional neighbour is scale-invariant on the tiled tree (cf.
    /// `FocusResolver.neighbor(of:_:in:)`, which reads solved frames), so a chord fired
    /// before the first layout report still resolves correctly instead of dying.
    private var treeGeometryBounds: CGRect {
        if let solved = lastSolvedLayout, !solved.frames.isEmpty {
            var bounds = CGRect.null
            for rect in solved.frames.values { bounds = bounds.union(rect) }
            if !bounds.isNull, bounds.width > 0, bounds.height > 0 { return bounds }
        }
        if let reported = lastContainerBounds, reported.width > 0, reported.height > 0 {
            return reported
        }
        return CGRect(x: 0, y: 0, width: 1280, height: 800)
    }
}

// MARK: - Find-in-terminal + Global Search command entries

public extension WorkspaceStore {
    /// The ACTIVE pane's live copy receipt, or `nil` when it has none (or is not a terminal).
    ///
    /// The seam that let the copy chip collapse to ONE mount (user-directed 2026-08-11). A pane-scoped copy
    /// publishes on its own ``TerminalViewModel/copyReceipt`` — which is right, it is the pane's state — but
    /// the CONFIRMATION used to be mounted there too, bottom-trailing inside the pane, while pane-less
    /// copies (palette "Copy Path") drew at the island's foot. One event, two homes. Reading the active
    /// pane's receipt from the island's chip stack keeps the state where it belongs and moves only the
    /// mount. ACTIVE rather than every pane on purpose: a copy is made in the pane the user is typing in,
    /// and a background pane's receipt is a cue for a place they are not looking at.
    ///
    /// A method, not a property, for the reason ``connectionAlert()`` is one: the call registers
    /// observation on the live model, so the chip appears and expires reactively.
    func activePaneCopyReceipt() -> CopyReceipt? {
        guard let active = tree.activeSession?.activeTab?.activePane else { return nil }
        return (registry[active] as? LivePaneSession)?.terminalModel?.copyReceipt
    }

    /// Clears the active pane's copy receipt (its chip's dwell elapsed). Idempotent, and a no-op for a
    /// non-terminal / receipt-less pane.
    func clearActivePaneCopyReceipt() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        (registry[active] as? LivePaneSession)?.terminalModel?.clearCopyReceipt()
    }

    /// Advances the active pane's find bar to the NEXT match (the ⌘G keyboard / menu entry).
    /// Routes to the active terminal's ``TerminalViewModel/onRequestFindNext``; when that is unset (the bar
    /// has never been opened) it FALLS BACK to ``onRequestFind`` so ⌘G OPENS the find bar — faithful
    /// "find next opens find". A no-op for a non-terminal active pane / empty shell.
    func requestFindNextInActivePane() {
        guard let active = tree.activeSession?.activeTab?.activePane,
              let model = (registry[active] as? LivePaneSession)?.terminalModel else { return }
        if let next = model.onRequestFindNext { next() } else { model.onRequestFind?() }
    }

    /// Steps the active pane's find bar to the PREVIOUS match (the ⇧⌘G entry). Same
    /// open-if-closed fallback as ``requestFindNextInActivePane()``.
    func requestFindPrevInActivePane() {
        guard let active = tree.activeSession?.activeTab?.activePane,
              let model = (registry[active] as? LivePaneSession)?.terminalModel else { return }
        if let prev = model.onRequestFindPrev { prev() } else { model.onRequestFind?() }
    }

    /// Runs `query` across EVERY live terminal pane's scrollback (session → tab → pane order),
    /// building the grouped results the ⇧⌘F surface renders. Snapshots each live terminal pane's
    /// ``TerminalViewModel/searchScrollbackLines()`` into a ``GlobalSearchSource`` (group title = the pane's
    /// spec title, falling back to its last-known shell title, else "Tab"), then delegates the match math to
    /// the PURE ``GlobalSearchController/run(sources:query:caseSensitive:isRegex:)`` — the SAME engine the
    /// in-pane find bar uses, never a second matcher. Non-terminal (video) and never-connected panes
    /// contribute no lines and so are simply absent.
    func runGlobalSearch(query: String, caseSensitive: Bool, isRegex: Bool) {
        globalSearchQuery = query
        globalSearchCaseSensitive = caseSensitive
        globalSearchRegex = isRegex
        // Re-run only the IN-MEMORY match pass over the per-overlay scrollback snapshot (gathered ONCE on
        // open by ``beginGlobalSearchSession()``), so a keystroke does not re-mirror every pane's scrollback
        // across the libghostty seam. Fall back to a fresh snapshot when no overlay session is active
        // (defensive — e.g. a direct call from a test or the seed path before begin); the results are
        // identical either way.
        let sources = globalSearchSourceCache ?? collectGlobalSearchSources()
        globalSearch = GlobalSearchController.run(
            sources: sources, query: query, caseSensitive: caseSensitive, isRegex: isRegex,
        )
    }

    /// Snapshot every live terminal pane's scrollback into searchable sources ONCE and cache them for
    /// the open ⇧⌘F overlay. Called on overlay-OPEN (a re-open re-snapshots fresh scrollback); keystrokes then
    /// re-run only the in-memory match pass over this cache via ``runGlobalSearch(query:caseSensitive:isRegex:)``.
    func beginGlobalSearchSession() {
        globalSearchSourceCache = collectGlobalSearchSources()
    }

    /// Drop the cached scrollback sources when the overlay CLOSES so the next open re-snapshots fresh
    /// scrollback (and the mirrored buffers don't outlive the overlay).
    func endGlobalSearchSession() {
        globalSearchSourceCache = nil
    }

    /// Crosses the libghostty seam to mirror EVERY live terminal pane's scrollback (session → tab → pane order)
    /// into a ``GlobalSearchSource`` (group title = the pane's spec title, else its last-known shell title, else
    /// "Tab"). The ONLY cross-seam step in Global Search; ``runGlobalSearch`` caches its result per overlay-open
    /// so keystrokes don't repeat it. Non-terminal (video) and never-connected panes contribute no lines and so
    /// are simply absent. Resolves the model through the ``TerminalModelProviding`` seam
    /// (not an `as? LivePaneSession` cast) so it stays headlessly testable with a recording double.
    private func collectGlobalSearchSources() -> [GlobalSearchSource] {
        var sources: [GlobalSearchSource] = []
        for session in tree.sessions {
            for tab in session.tabs {
                for paneID in tab.allPaneIDs() {
                    guard let spec = session.spec(for: paneID), spec.kind == .terminal,
                          let model = (registry[paneID] as? TerminalModelProviding)?.terminalModel else { continue }
                    let title = spec.title.isEmpty ? (liveProgramTitle(for: paneID) ?? "Tab") : spec.title
                    sources.append(GlobalSearchSource(
                        paneID: paneID,
                        sessionID: session.id,
                        tabID: tab.id,
                        groupTitle: title,
                        lines: model.searchScrollbackLines(),
                    ))
                }
            }
        }
        return sources
    }

    /// Jumps to a Global Search hit — selects its session, its tab, and focuses its pane
    /// (``focusPaneTree(_:)`` resolves session+tab+pane together), then RE-ARMS the pane's in-surface
    /// libghostty search near the hit so the amber highlight + scroll-to-match land on the result.
    /// A no-op if the pane is gone.
    func jumpToGlobalSearchResult(_ hit: GlobalSearchHit) {
        guard tree.contains(hit.paneID) else { return }
        jumpToPaneTree(hit.paneID) // selects hit.sessionID + hit.tabID + focuses hit.paneID (+ breadcrumb)
        guard let model = (registry[hit.paneID] as? TerminalModelProviding)?.terminalModel else { return }
        // Click-to-line: ALWAYS scroll straight to the clicked hit's mirror row so the landing is
        // correct in every mode and independent of the current viewport. The literal `search:` matcher is armed
        // for the amber highlight ONLY in literal + case-INSENSITIVE mode (the one mode it matches faithfully);
        // case-sensitive literal and regex modes clear any stale highlight and just scroll — matching the find
        // bar's literal-highlight ceiling. Pass the tracked case-sensitivity AND regex flags so the controller
        // branches correctly. The pure controller computes the ordered actions; an empty query yields none.
        let actions = GlobalSearchController.navigationActions(
            for: hit,
            query: globalSearchQuery,
            caseSensitive: globalSearchCaseSensitive,
            isRegex: globalSearchRegex,
            // Map the logical (unwrapped) hit line to the physical grid row `scroll_to_row` addresses — the
            // mirror collapses soft-wrapped rows, so a heavily-wrapped pane would otherwise land rows too high.
            lines: model.searchScrollbackLines(),
            columns: model.searchGridColumns(),
        )
        for action in actions {
            model.performSearchSurfaceAction(action)
        }
    }

    /// Closes the active pane through the busy-shell guard: an idle pane closes immediately,
    /// a pane mid-command parks behind the `pendingClose` confirmation — and so does its project's
    /// LAST pane (closing it closes the project; the dialog warns first, mirroring
    /// ``requestClosePaneTree(_:)``). No-op without an active pane.
    func requestCloseActivePaneTree() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        if closeConfirmationNeeded(scope: .pane, pane: active) || projectClosed(byRemoving: [active]) != nil {
            parkPaneClose(active)
        } else {
            closePaneTree(active)
        }
    }

    /// Breaks the active pane out into a new tab (the "break pane to tab" command entry).
    /// No-op without an active pane.
    func breakActivePaneToTab() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        breakPaneToTab(active)
    }

    /// Toggles render-only zoom on the active pane (the "zoom/maximize" command entry).
    func toggleZoomActivePane() { toggleZoomTree() }
}

// MARK: - Production session factory

public extension WorkspaceStore {
    /// The production `makeSession` factory: wires ``LivePaneSession`` with a mux-backed client
    /// factory and an inspector builder. The app passes `WorkspaceStore.liveMakeSession(...)` as
    /// `makeSession` so tests can substitute `{ FakePaneSession($0.spec) }` instead (docs/22 §0).
    ///
    /// - Parameters:
    ///   - makeInspector: builds the read-only `InspectorClient` for a terminal endpoint (subscribed
    ///     dynamically once a `claude` is detected), or `nil` when no second channel is available.
    ///     Defaults to ``liveMakeInspector(_:)`` — a lazily-connecting NWConnection #2 client (see
    ///     that function for the unproven-host guardrail).
    ///   - muxRegistry: the per-host shared-connection pool. Every `SlopDeskClient` is backed by a
    ///     logical channel over the per-host shared `MuxNWConnection` (refcounted by the registry).
    static func liveMakeSession(
        makeInspector: @escaping @MainActor (ConnectionTarget) -> InspectorClient? = liveMakeInspector,
        muxRegistry: ConnectionRegistry,
        target: @escaping @MainActor () -> ConnectionTarget = { .default },
    ) -> @MainActor (PaneMaterialization) -> any PaneSessionHandle {
        // Every pane is backed by a logical channel over the per-host shared `MuxNWConnection`
        // (refcounted by the registry), connecting to the ONE app-global `target`. This is the SOLE
        // client-side construction site; nothing on the per-message path is touched.
        let effectiveMakeClient = muxBackedClientFactory(registry: muxRegistry)
        return { seed in
            LivePaneSession.make(
                paneID: seed.id, spec: seed.spec, spawnCwd: seed.spawnCwd,
                makeClient: effectiveMakeClient, makeInspector: makeInspector, target: target,
            )
        }
    }

    /// Builds a `@Sendable (SlopDeskClient.ResumeSeed?) -> SlopDeskClient` whose clients route over the
    /// shared mux connection pooled by `registry`. Each `SlopDeskClient` is constructed with an
    /// injected `makeTransport` that vends a fresh `MuxClientTransport` bound to the registry's
    /// acquire/release — so the channel is opened on the shared connection at `connect()` and released
    /// (refcount--) at `close()`, with the shared transport torn down only when the LAST pane's channel
    /// goes. The registry is `@MainActor`; the transport's acquire/release closures hop onto the main
    /// actor to call it.
    ///
    /// The `resumeSeed` parameter is passed straight through to `SlopDeskClient.init(resumeSeed:)`, which
    /// sets `sessionID` / `highestContiguousSeq` / `highestSeqFed` synchronously as part of construction
    /// (`docs/DECISIONS.md`). Seeding a restored pane's identity AFTER this factory returns the client —
    /// a fire-and-forget `Task { await c.seedResumeIdentity(...) }` — races the separately-scheduled
    /// `connect()` Task on the actor's mailbox, so the seed MUST ride `init`. `nil` = a fresh /
    /// never-restored pane (no seed, no race).
    private static func muxBackedClientFactory(
        registry: ConnectionRegistry,
    ) -> @Sendable (SlopDeskClient.ResumeSeed?) -> SlopDeskClient {
        { @Sendable resumeSeed in
            SlopDeskClient(
                makeTransport: {
                    MuxClientTransport(
                        // The class the transport announces reaches the registry hop, which puts it
                        // on the `channelOpen`. A pane here — a read-only view (class 2) is opened
                        // by a transport constructed with that class, not by a flag on this one.
                        acquire: { host, port, sessionID, lastReceivedSeq, channelClass, initialCwd in
                            try await registry.acquire(
                                host: host,
                                port: port,
                                sessionID: sessionID,
                                lastReceivedSeq: lastReceivedSeq,
                                channelClass: channelClass,
                                initialCwd: initialCwd,
                            )
                        },
                        release: { host, port, channelID in
                            await registry.release(host: host, port: port, channelID: channelID)
                        },
                    )
                },
                resumeSeed: resumeSeed,
            )
        }
    }

    /// Builds the production read-only ``InspectorClient`` for a terminal pane's `endpoint` (subscribed
    /// dynamically once a `claude` is detected in it).
    ///
    /// ### Guardrail (docs/22 §7): the LIVE network inspector path is NOT runtime-proven
    /// PATH 1 (the terminal byte-pipeline) is proven; the inspector second channel (NWConnection #2) is wired
    /// cleanly but **no host-side inspector serving / port exists yet** (no `slopdesk-hostd` inspector daemon
    /// to invent). So this returns a *ready, lazily-connecting* client rather than eagerly dialing: it stands
    /// up an ``NWByteChannel`` over a fresh `NWConnection` to `host:inspectorPort` (the ``inspectorPort(for:)``
    /// convention) but does NOT `start()` it — the channel connects on the first `send`/`subscribe`, driven by
    /// ``LivePaneSession/subscribeInspector()`` (the leaf's `.task` on appear). Against a host that
    /// doesn't serve the port the connection never completes its handshake and the fold yields no cards — the
    /// terminal is unaffected. The FOLD logic is fully unit-testable in-process via `LoopbackByteChannel.pair()`
    /// + ``InspectorClient/init(channel:)`` (docs/22 §8), independent of this builder. Real-network inspector
    /// serving is a hardware followup.
    ///
    /// Returns `nil` only when no inspector port can be derived (terminal on the top port).
    @MainActor
    static func liveMakeInspector(_ target: ConnectionTarget) -> InspectorClient? {
        guard let port = inspectorPort(for: target),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: nwPort,
            using: NWByteChannel.parameters(),
        )
        // The channel connects lazily: NWByteChannel.start() is idempotent and is triggered by the
        // first send (the `subscribe(fromSeq:)` in LivePaneSession.subscribeInspector). We do not start
        // it here so a plain terminal (no claude detected) opens no inspector socket.
        let channel = NWByteChannel(connection: connection, label: "slopdesk.inspector.channel")
        return InspectorClient(channel: channel)
    }
}

// MARK: - New-pane gesture (direct terminal mint)

/// Factored into a same-file extension (like `splitFromContextMenu`) so the new-pane entry point stays
/// OUT of the `WorkspaceStore` primary body's `type_body_length` budget.
public extension WorkspaceStore {
    /// Create a new TERMINAL pane placed by `context` and FOCUSED. Every new-pane gesture (⌘T / ⌘D /
    /// the `+` button / the context-menu splits) mints a terminal DIRECTLY — the in-pane kind chooser
    /// is retired: the default kind gets the hot path, and every non-terminal kind has its own
    /// explicit shortcut (⌥⌘N desktop; Open Quickly / the picker for windows), so a kind question on
    /// the hot path has no second answer left. cwd inheritance is the `newTab` / `splitActivePane`
    /// placement + inherit path, unchanged.
    func newTerminalPane(_ context: NewPanePlacement) {
        switch context {
        case let .split(axis, leading): splitActivePane(axis: axis, kind: .terminal, leading: leading)
        case .newTab: newTab(kind: .terminal)
        }
    }

    /// Pane `id`'s WORKING DIRECTORY — where its shell IS (`pane/cwd`, field 5), read through the
    /// mirror so a host frame and this client's own control-push overlay answer through one funnel.
    /// Shared by ``setLastKnownCwd(_:for:)``'s dirty guard, the attach-edge cwd-pull gate
    /// ``shouldRefreshCwdOnAttach(_:)`` and ``effectiveGitProjectKey(_:)``.
    ///
    /// Distinct from ``spawnCwd(for:)``, which is where the shell was asked to START.
    func paneCwd(for paneID: PaneID) -> String? {
        observeWorkspaceMirror()
        return workspaceMirror.string(.pane, documentPaneID(paneID), WorkspacePaneField.cwd)
    }

    /// Whether the connect/reconnect snapshot edge should pull pane `id`'s cwd from the host. TRUE
    /// only while `pane/cwd` is still empty — a POPULATE-ONCE gate so the ~3 s RTT-snapshot
    /// cadence never becomes a cwd poll. A shell that emits no OSC-7 (Starship / hookless) would otherwise
    /// sit at the "Terminal" fallback until its first command completes; one host `proc_pidinfo` pull on
    /// attach lands the folder-name title. Once any source populates the cwd this returns false and stops.
    func shouldRefreshCwdOnAttach(_ id: PaneID) -> Bool {
        paneCwd(for: id) == nil
    }

    /// Records the host-resolved working directory of pane `paneID` as `pane/cwd` — the single sink
    /// every cwd source (OSC 7, the `cwd` RPC, the palette resolver) funnels through, so the titlebar /
    /// rail / palette all mirror the same value. Writes the mirror's FAST PATH, which host truth erases
    /// the moment the document supplies the same key; guarded against an unchanged value so a re-focus
    /// spends nothing.
    func setLastKnownCwd(_ cwd: String, for paneID: PaneID) {
        // Both gates at once: drop a TRANSIENT plugin-cache-dir reading before it can poison the
        // inherit source, and drop an unchanged one. The live-cwd sources are `proc_pidinfo`-based
        // (`refreshCwd` on command completion, the palette's `cwd()` resolver), which race a plugin
        // manager's turbo `builtin cd`; without the first guard a later new-tab / split / relaunch
        // spawns its PTY in e.g. `…/zsh-users---zsh-autosuggestions` instead of the real project cwd.
        guard StoreSeed.acceptsCwd(cwd, current: paneCwd(for: paneID)) else { return }
        workspaceMirror.writeFastPath(
            pane: documentPaneID(paneID), field: WorkspacePaneField.cwd, string: cwd,
        )
        // Remember it for the next cold launch: the folder name is what the rail titles this row by,
        // and a client that starts with the host unreachable has no other way to know it.
        scheduleDocumentCacheSave()
        // The cwd just CHANGED (the guard above proves it differs from the stored value), so this is a
        // genuine visit — notify the frecency sink. Kept after the dirty guard so an unchanged re-focus is silent.
        onCwdVisited?(cwd)
        // The sidebar git line follows the cwd: a `cd` can enter/leave/switch repos, so refetch this
        // pane's summary. The stale line stays visible until the fresh reply lands (no flicker on a
        // same-repo `cd`); the post-completion `refreshCwd` funnels through here ONLY when the cwd
        // actually changed (the dirty guard above), so this never double-fetches a quiet completion.
        refreshGitSummary(for: paneID, from: (handle(for: paneID) as? LivePaneSession)?.connection)
    }

    /// Pane `id`'s HOST-computed By-Project key (`pane/projectKey`, field 6), read through the mirror —
    /// the ``setProjectKey(_:for:)`` dirty guard's mirror of ``paneCwd(for:)``.
    func projectKey(for paneID: PaneID) -> String? {
        observeWorkspaceMirror()
        return workspaceMirror.string(.pane, documentPaneID(paneID), WorkspacePaneField.projectKey)
    }

    /// Records the HOST-computed By-Project key (wire type 34) as `pane/projectKey` — the write sink
    /// ``ConnectionViewModel/onProjectKeyChanged`` funnels into, mirroring ``setLastKnownCwd(_:for:)``:
    /// a transient plugin-cache reading (``PaneSpec/looksLikeTransientPluginCwd(_:)`` — the host's resolver
    /// can race a zinit turbo `builtin cd` just as a client-side `gitStatus` sweep can) is DROPPED, and an
    /// unchanged value short-circuits so a reattach re-assert spends nothing.
    /// ``paneProjectKey(_:)`` reads it back for the sidebar sectioning.
    func setProjectKey(_ key: String, for paneID: PaneID) {
        guard StoreSeed.acceptsProjectKey(key, current: projectKey(for: paneID)) else { return }
        workspaceMirror.writeFastPath(
            pane: documentPaneID(paneID), field: WorkspacePaneField.projectKey, string: key,
        )
        // Persisted with the cwd, and for the same reason: without it a cold launch collapses every
        // By-Project section into one "Other" bucket until each pane's own channel reconnects.
        scheduleDocumentCacheSave()
    }

    // MARK: - Spawn cwd (where the shell STARTS)

    /// Where pane `id`'s shell was asked to start (`pane/spawnCwd`, field 21) — the value that rides
    /// the mux `channelOpen` so the host spawns the PTY there directly, with no visible startup `cd`.
    ///
    /// Deliberately NOT `pane/cwd`: that is where the shell IS right now. A respawn after a host
    /// restart has no live shell to ask, and starting it at the last-observed cwd would silently
    /// relocate a pane the user placed deliberately.
    ///
    /// Read through the MIRROR, so a host whose document carries this pane's spawn directory and a
    /// client that minted it locally answer with one value. A device-local dictionary here would give
    /// two clients of one document two different answers for where the same pane's shell belongs.
    ///
    /// The resolution order is the mirror's own: the TOPOLOGY (`entries`, where the intent that minted
    /// the pane put it) before the fast path, which is only reached for a pane the document does not
    /// name yet — a launch-time cache row whose leaf has not been re-published. That order is what
    /// makes a relaunch respawn a restored pane in its last spawn directory rather than `$HOME`.
    ///
    /// The empty string is RETIRED, not a directory — it maps back to `nil` so the host takes its own
    /// default rather than being handed a path of nothing.
    func spawnCwd(for id: PaneID) -> String? {
        observeWorkspaceMirror()
        guard let cwd = workspaceMirror.string(.pane, documentPaneID(id), WorkspacePaneField.spawnCwd),
              !cwd.isEmpty else { return nil }
        return cwd
    }

    /// Records where a pane's shell should start, on the FAST PATH.
    ///
    /// Not the mint path: a pane the client creates carries its spawn directory in the intent's own
    /// `cwd` argument (ops 6 / 12 / 13 / 18 all take one), so the value lands in the document's
    /// topology where every client and the host read the same answer. What is left for this is the
    /// facts that never went through an intent — the launch cache re-seeded at startup — which is why
    /// it writes the overlay lane and schedules the cache save.
    func setSpawnCwd(_ cwd: String?, for id: PaneID) {
        guard spawnCwd(for: id) != cwd else { return }
        workspaceMirror.writeFastPath(
            pane: documentPaneID(id), field: WorkspacePaneField.spawnCwd, string: cwd,
        )
        scheduleDocumentCacheSave()
    }

    /// cwd-freshness fallback: pull pane `id`'s current working directory from the host `cwd` RPC
    /// (`proc_pidinfo` — shell-agnostic, needs no OSC-7) and persist it via the dirty-guarded
    /// ``setLastKnownCwd(_:for:)``, so a `cd` in this pane becomes the inherit source for the NEXT new tab /
    /// split AND the folder-name title lands without waiting for the shell to emit anything. A `nil`
    /// connection / failed RPC is a silent no-op (validate-then-drop); the metadata client's 5 s timeout
    /// bounds the await.
    ///
    /// **Attach-edge retry.** On a fresh (re)connect the pane's `activeMetadataClient` can
    /// briefly be `nil` — the control plane is still being (re)established — so a single-shot pull can MISS
    /// and leave the title at "Terminal" until the next ~3 s RTT-snapshot retry (and the RECONNECT caller,
    /// whose `pane/cwd` is already non-nil, has NO populate-once retry at all). `retries > 0` re-arms a
    /// short-delayed retry up to `retries` times, stopping the instant the RPC answers — so the cwd lands in
    /// ~1 RTT on connect and a reconnect that respawned a fresh shell reliably re-reads the host cwd.
    /// `retries == 0` (the command-completion caller, where the client is long-since live) keeps the
    /// original single-shot behaviour. The bounded retry holds `connection` strongly only for its ~1 s
    /// window; a torn-down connection just answers `nil` and exhausts the budget.
    private func refreshCwd(for id: PaneID, from connection: ConnectionViewModel?, retries: Int = 0) {
        guard let connection else { return }
        Task { @MainActor [weak self] in
            if let cwd = await connection.activeMetadataClient?.cwd() {
                self?.setLastKnownCwd(cwd, for: id)
                return
            }
            // Metadata client not ready yet (or the RPC failed): re-arm a bounded, short-delayed retry so
            // the attach-edge pull is not a one-shot. Stops as soon as `self`/the budget is gone.
            guard let self, retries > 0 else { return }
            try? await Task.sleep(for: .milliseconds(300))
            refreshCwd(for: id, from: connection, retries: retries - 1)
        }
    }

    // MARK: - Section git line (the PROJECT-scoped compact summary)

    /// Pane `id`'s effective SECTION key for the git-summary store: the ``paneProjectKey(_:)``
    /// precedence (host-pushed key, else the cwd fallback, plugin dirs guarded out) read
    /// model-agnostically and NORMALIZED (``TabOrderingEngine/normalizedProjectKey(_:)``) so it equals
    /// the sidebar's bucketing key exactly. `nil` ⇒ the pane has no section identity yet (no cwd) —
    /// no git bookkeeping.
    func effectiveGitProjectKey(_ id: PaneID) -> String? {
        StoreGitCadence.sectionKey(hostKey: projectKey(for: id), cwd: paneCwd(for: id))
    }

    /// Refreshes the git summary of pane `id`'s PROJECT (``projectGitSummary`` → the sidebar section
    /// header) from the host `gitStatus` RPC on the pane's OWN metadata channel. Fired on command
    /// completion (OSC 133;D, beside ``refreshCwd(for:from:)``), on a cwd CHANGE
    /// (``setLastKnownCwd(_:for:)`` — a `cd` can enter/leave/switch repos), on reconnect, and by the
    /// project-scoped snapshot scheduler. The stale value stays visible until the fresh reply lands (no
    /// flicker); a `nil` connection / failed RPC is a silent no-op (validate-then-drop). The in-flight
    /// set de-dupes BY PROJECT: N same-repo panes reconnecting / completing together collapse to one
    /// RPC — `git status --porcelain` output is repo-root-relative, so any pane in the project answers
    /// for all of them.
    func refreshGitSummary(for id: PaneID, from connection: ConnectionViewModel?) {
        guard let connection else { return }
        let key = effectiveGitProjectKey(id)
        // A keyless pane (no cwd landed yet) still de-dupes — per PANE, its only identity.
        let inFlightKey = key ?? "pane:\(id.raw.uuidString)"
        guard !projectGitInFlight.contains(inFlightKey) else { return }
        projectGitInFlight.insert(inFlightKey)
        // The alias/no-repo booking key must be the pane's CWD-ONLY fallback — never a host-pushed
        // key. A host key can be STALE across an un-re-pushed cross-repo `cd` (nothing client-side
        // invalidates it; the host re-pushes asynchronously), and booking the NEW repo's reply
        // under the OLD repo's key would overwrite an unrelated section's genuinely-correct header.
        let aliasKey = StoreGitCadence.aliasCandidate(
            hostKey: projectKey(for: id), cwd: paneCwd(for: id),
        )
        Task { @MainActor [weak self] in
            let payload = await connection.activeMetadataClient?.gitStatus()
            guard let self else { return }
            projectGitInFlight.remove(inFlightKey)
            guard let payload else { return }
            applyGitSummary(
                PaneGitSummary(payload: payload), toplevel: payload.repoRoot, fallbackKey: aliasKey,
            )
        }
    }

    /// Pane `id`'s HOST-pushed key alone (guarded like ``paneProjectKey(_:)``'s first leg), `nil`
    /// while the pane is still on its cwd fallback — the alias-booking eligibility test above, and
    /// the code panel's ensure gate (`MacCodePanelColumn`): ensuring on the transient pre-push cwd
    /// would spawn a stranded code-server for a root the project does not actually have.
    func hostPushedProjectKey(_ id: PaneID) -> String? {
        StoreGitCadence.hostPushedKey(projectKey(for: id))
    }

    /// Re-probe pane `id`'s project git line on demand through its OWN live connection. A video /
    /// faked pane (no ``LivePaneSession``) is a silent no-op via ``refreshGitSummary(for:from:)``'s
    /// `nil`-connection guard.
    func refreshGitSummary(for id: PaneID) {
        refreshGitSummary(for: id, from: (handle(for: id) as? LivePaneSession)?.connection)
    }

    /// The section-header context-menu "Refresh Git Status" entry: re-probe `key`'s project through
    /// the FIRST live pane sectioned under it. No live pane (a ghost section mid-teardown) ⇒ no-op.
    func refreshGitSummary(forProject key: String) {
        let normalized = TabOrderingEngine.normalizedProjectKey(key)
        guard let pane = tree.allPaneIDs().first(where: { id in
            effectiveGitProjectKey(id) == normalized
                && (handle(for: id) as? LivePaneSession)?.connection != nil
        }) else { return }
        refreshGitSummary(for: pane)
    }

    /// Applies a freshly-fetched git `summary` under its PROJECT key: the reply's `toplevel`
    /// (repo root) when the cwd is a repo, else `fallbackKey` (the probed pane's own section key — a
    /// no-repo dir books its "clean, no repo" reading so the scheduler backs off for that section too).
    /// When the probed pane is still sectioned by a cwd FALLBACK that differs from the toplevel (the
    /// host's type-34 for it hasn't landed), the summary is MIRRORED under that alias too, so the
    /// interim section's header is already correct; reconcile prunes the alias once the section
    /// re-keys. Both writes are dirty-guarded (no `@Observable` churn on a quiet re-fetch); the
    /// freshness stamp always lands. `now` is injectable for deterministic staleness tests.
    func applyGitSummary(
        _ summary: PaneGitSummary, toplevel: String, fallbackKey: String?, at now: Date = Date(),
    ) {
        // Which keys this reading is the truth for — including whether it is a truth at all. A reading
        // taken while the shell was transiently inside a plugin-cache dir (a zinit turbo `builtin cd`
        // the `gitStatus` RPC raced) is dropped WHOLE: its `toplevel` is the PLUGIN's repo and its
        // branch/changed counts are that plugin's, not the user's project.
        guard let plan = StoreGitCadence.booking(toplevel: toplevel, fallbackKey: fallbackKey) else {
            return
        }
        bookGitSummary(summary, under: plan.primary, at: now)
        // The alias is the caller's own fallback key, and it rides along only when the rule says it
        // sits INSIDE the toplevel's subtree — any other relation means a stale/foreign key, and
        // booking there would poison an unrelated section's header.
        if plan.alias, let fallbackKey { bookGitSummary(summary, under: fallbackKey, at: now) }
    }

    /// Files one reading under one key: dirty-guarded so a quiet re-fetch spends no `@Observable`
    /// churn, with the freshness stamp landing either way — that is what makes the cadence back off
    /// for a section whose line did not change.
    private func bookGitSummary(_ summary: PaneGitSummary, under key: String, at now: Date) {
        if projectGitSummary[key] != summary { projectGitSummary[key] = summary }
        projectGitFetchedAt[key] = now
    }

    /// Applies a HOST-PUSHED project git summary (wire type 35 — the FSEvents watcher's event-driven
    /// truth, already folded by the connection layer). Books the push clock so the snapshot-cadence
    /// poll backs off (``gitSummaryPushGraceWindow``) while pushes keep arriving.
    func applyPushedProjectGitSummary(_ summary: PaneGitSummary, repoRoot: String, at now: Date = Date()) {
        guard let key = StoreGitCadence.pushedKey(repoRoot: repoRoot) else { return }
        bookGitSummary(summary, under: key, at: now)
        projectGitPushedAt[key] = now
    }

    /// How long a BACKGROUND project's header line stays "fresh" on the ~3 s RTT-snapshot edge before
    /// a re-fetch is allowed — long enough that the snapshot cadence is never a git-status poll, short
    /// enough that every visible section self-heals within a minute.
    static var gitSummaryStaleWindow: TimeInterval { StoreGitCadence.staleWindow }

    /// The tighter window for the ACTIVE project (the section the focused pane sits in) — the header
    /// the user is most likely acting on tracks external changes (editor saves, another terminal's
    /// commit) within seconds, still only ~4 subprocess spawns per window host-side.
    static var gitSummaryStaleWindowActiveProject: TimeInterval {
        StoreGitCadence.staleWindowActiveProject
    }

    /// The poll back-off while HOST PUSHES (wire type 35) are fresh: the watcher already delivers
    /// event-driven updates, so the poll degrades to a slow safety net (it re-arms itself the moment
    /// pushes stop arriving for this long).
    static var gitSummaryPushGraceWindow: TimeInterval { StoreGitCadence.pushGraceWindow }

    /// Whether the ~3 s RTT-snapshot edge should re-fetch pane `id`'s PROJECT git line: ALWAYS when
    /// the project has no entry yet (initial populate), else when its entry is older than the
    /// project's staleness window — ``gitSummaryStaleWindowActiveProject`` for the focused pane's
    /// project, ``gitSummaryStaleWindow`` for background ones, ``gitSummaryPushGraceWindow`` while
    /// host pushes are fresh. Because the clock is PER PROJECT (stamped on every apply) and the
    /// in-flight set de-dupes across panes, N panes ticking every ~3 s still cost at most one RPC per
    /// project per window — background projects included, which is what keeps an inactive section's
    /// header honest without a per-pane poll.
    func shouldRefreshGitOnSnapshot(_ id: PaneID, now: Date = Date()) -> Bool {
        guard let key = effectiveGitProjectKey(id) else { return false }
        // The two clocks stay here and cross as INTERVALS; the two sets stay here and cross as the
        // booleans the rule actually reads. A project with no entry lends no interval, which is the
        // initial populate the rule answers `true` for.
        return StoreGitCadence.refreshDue(
            inFlight: projectGitInFlight.contains(key),
            sinceFetch: projectGitFetchedAt[key].map(now.timeIntervalSince),
            sincePush: projectGitPushedAt[key].map(now.timeIntervalSince),
            activeProject: isActiveProject(key),
        )
    }

    /// Whether `key` is the FOCUSED pane's project — the active session's active tab's active pane.
    /// Drives the tighter active-project staleness window.
    func isActiveProject(_ key: String) -> Bool {
        guard let focused = tree.activeSession?.activeTab?.activePane else { return false }
        return effectiveGitProjectKey(focused) == key
    }
}
