// TerminalLeafLifecycle — the terminal leaf's WIRING LIFE, once, for both imperative shells.
//
// ``TerminalPaneWiring`` already owns what a leaf DOES on appear and on teardown. What stayed behind
// in `MacTerminalLeafView` and `TerminalLeafView` was the half that decides WHEN: the seven things
// the mounter hands a leaf, the `isWired` latch, the attach/detach pair, the three pushes
// (`setLive` / `setFocused` / `setCwd`), the pill gates, and the two `.task(id:)` keys with their
// cancellation. None of that is AppKit or UIKit — it is a latch, six stored handles and two `Task`s —
// and it was written out twice, line for line (docs/56 §3, CLAUDE.md's "one implementation, never
// two languages").
//
// The shell keeps ONE stored property, `life`, and implements ``TerminalLeafHosting`` — five
// callbacks, each of which is the shell doing the ONLY thing its framework spells differently:
// building the tree, mounting the pixels, re-pointing its key responder, arming its observation,
// ending it. Everything else is here, and neither shell names a view type on the way in or out.

import Foundation
import SlopDeskVideoProtocol
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - What the mounter hands a leaf

/// The seven handles a terminal leaf is built with.
///
/// A VALUE rather than seven `init` parameters, because both renderers had the same seven typed out
/// in the same order and then assigned one by one — and an eighth would have had to be added to two
/// initialisers, two property blocks and two call sites. The leaf's own `init` is now one parameter
/// wide, and this is the type that widens instead.
package struct TerminalLeafDependencies {
    /// The pane's live session, if it has one yet.
    package var live: LivePaneSession?
    /// Whether the workspace's focus is on this pane.
    package var isFocused: Bool
    /// The host's last reported cwd (OSC 7).
    package var cwd: String?
    package var store: WorkspaceStore
    /// The overlay presenter, for the paths that raise a toast or a sheet. `nil` in a bare test.
    package var overlay: OverlayCoordinator?
    /// The shared chrome model, for the open-in-code-panel reveal. `nil` ⇒ the file still opens.
    package var chrome: WorkspaceChromeState?
    /// The per-pane wiring. Defaulted so a renderer builds one and a test injects its own.
    package var wiring: TerminalPaneWiring

    /// `@MainActor` for ONE reason: the `wiring` default. ``TerminalPaneWiring`` is main-actor
    /// isolated, so its default value expression cannot be evaluated from a nonisolated init — and the
    /// default is what keeps a test from having to build a wiring it does not care about.
    @MainActor
    package init(
        live: LivePaneSession?,
        isFocused: Bool,
        cwd: String?,
        store: WorkspaceStore,
        overlay: OverlayCoordinator?,
        chrome: WorkspaceChromeState?,
        wiring: TerminalPaneWiring = TerminalPaneWiring(),
    ) {
        self.live = live
        self.isFocused = isFocused
        self.cwd = cwd
        self.store = store
        self.overlay = overlay
        self.chrome = chrome
        self.wiring = wiring
    }
}

// MARK: - The five things only a renderer can do

/// The leaf's framework half, as seen from its lifecycle.
///
/// Five callbacks, and every one of them is a place where AppKit and UIKit genuinely part: a view
/// tree, a mounted surface, a key responder, an observation arm and its end. The lifecycle calls them
/// in one order; neither shell decides that order any more.
@MainActor
package protocol TerminalLeafHosting: AnyObject {
    /// Build the leaf's own view tree. Called once, from ``TerminalLeafLifecycle/start(host:)``.
    func buildLeafTree()

    /// Drop whatever pixels are mounted and mount the current session model's.
    ///
    /// Called at start and again whenever the MODEL changes under a stable pane id. The surface is
    /// never dropped by ``TerminalLeafLifecycle/detach()`` — see its header for why that asymmetry is
    /// deliberate — so this is the only path that takes libghostty's threads down.
    func mountTerminalSurface()

    /// The session HANDLE changed; the model may not have. The phone re-points its key responder here
    /// and the Mac has nothing to do, which is why it carries a default.
    func terminalSessionChanged()

    /// Re-arm the shell's ONE tracked read of everything it draws or triggers on.
    func followTerminalState()

    /// End that read. A callback landing after the wiring is cleared would re-arm against a model
    /// this leaf no longer drives.
    func unfollowTerminalState()

    /// Take down anything MODAL over the pane (the Command Navigator card) with no animation — the
    /// leaf is leaving the tree, so there is nothing left to fade over.
    func dropPaneModals()
}

package extension TerminalLeafHosting {
    func terminalSessionChanged() {}
}

// MARK: - The two trigger keys

/// The two `.task(id:)` keys a leaf triggers on, read together because they are read in one pass of
/// the shell's tracking block and applied in one call.
package struct TerminalLeafTaskKeys: Equatable {
    package let dial: PaneID?
    package let autotype: PaneID?

    /// Spelled out because the implicit memberwise initialiser of a `package` struct is `internal`,
    /// and the phone's shell builds an empty pair as the default of its one-pass reading value.
    package init(dial: PaneID?, autotype: PaneID?) {
        self.dial = dial
        self.autotype = autotype
    }
}

// MARK: - The life

/// A terminal leaf's wiring life: what it was handed, whether it is wired, and the four pushes the
/// mounter makes.
///
/// ⚠️ THE ONE ASYMMETRY, and it is the reason ``detach()`` and ``TerminalLeafHosting/mountTerminalSurface()``
/// are not a pair. The WIRING detaches when the leaf leaves the view tree, because the thing it holds
/// that must never leak is process-global: an engaged `EnableSecureEventInput` outliving its pane
/// holds the keyboard for every other app on the machine, with nothing on screen to say so. It is
/// idempotent and re-installable, so re-attaching costs nothing. The SURFACE does not:
/// `detachSurface()` drops libghostty's renderer and io threads, which is not re-installable and
/// would take the session with it — and a leaf can leave the tree without its pane going away (a
/// split rearrange re-parents it).
@MainActor
package final class TerminalLeafLifecycle {
    /// The pane's live session. Pushed by ``setLive(_:)``, never written by the shell.
    package private(set) var live: LivePaneSession?
    /// The host's last reported cwd. Pushed by ``setCwd(_:)``.
    package private(set) var cwd: String?
    /// Whether the workspace's focus is on this pane. Pushed by ``setFocused(_:)``.
    package private(set) var isFocused: Bool
    package let store: WorkspaceStore
    package let overlay: OverlayCoordinator?
    package let chrome: WorkspaceChromeState?
    package let wiring: TerminalPaneWiring

    /// `controls.auto-secure-input`, as last ACTED on. Kept because the lock is reconciled on the
    /// EDGE, not on the reading: a config edit to an unrelated key re-runs the shell's arm and must
    /// not re-engage a process-global lock the user turned off.
    private var autoSecureInput = SettingsKey.autoSecureInputEnabled
    /// `controls.secure-input-indicator` — the chip gate. No edge to speak of; re-reading the pill
    /// conditions is the whole of applying it.
    private var secureInputIndicator = SettingsKey.secureInputIndicatorEnabled

    /// The two `.task(id:)` keys, as last acted on, and the tasks they started. A task fires when its
    /// key MOVES, which is the whole of ``TerminalLeafPolicy``'s argument: a key that is already the
    /// pane's id while the gate is shut is a task that ran once, too early, and never again.
    private var keys = TerminalLeafTaskKeys(dial: nil, autotype: nil)
    private var dialTask: Task<Void, Never>?
    private var autotypeTask: Task<Void, Never>?

    /// Whether the wiring is installed. The wiring is idempotent, but re-installing it on every window
    /// change would also re-arm the observation for no reason.
    package private(set) var isWired = false

    private weak var host: TerminalLeafHosting?

    package init(_ dependencies: TerminalLeafDependencies) {
        live = dependencies.live
        isFocused = dependencies.isFocused
        cwd = dependencies.cwd
        store = dependencies.store
        overlay = dependencies.overlay
        chrome = dependencies.chrome
        wiring = dependencies.wiring
    }

    // MARK: Starting

    /// The leaf's whole startup, in the ONE order that lands: the tree, then the pixels, then the
    /// wiring and the first tracked read.
    package func start(host: TerminalLeafHosting) {
        self.host = host
        host.buildLeafTree()
        host.mountTerminalSurface()
        attach()
    }

    // MARK: Attach / detach

    /// The leaf moved in or out of the view tree — the framework-free reading of `viewDidMoveToWindow`
    /// and `didMoveToWindow`.
    ///
    /// A leaf with neither a window nor a superview has LEFT; one that has a window is in. The middle
    /// case — a superview but no window yet — is neither, and stays wired if it already was.
    package func viewTreeChanged(hasWindow: Bool, hasSuperview: Bool) {
        if !hasWindow, !hasSuperview {
            detach()
        } else if hasWindow {
            attach()
        }
    }

    package func attach() {
        guard !isWired else { return }
        isWired = true
        wire()
        applyCwd()
        host?.followTerminalState()
    }

    package func detach() {
        guard isWired else { return }
        isWired = false
        // End the armed observation FIRST: a callback that lands after the wiring is cleared would
        // re-arm against a model this leaf no longer drives.
        host?.unfollowTerminalState()
        cancelTriggers()
        // The card is a MODAL over this pane and the leaf is leaving the tree: it goes with it. The
        // chrome flag is left alone — it is the wiring's, and a re-attach re-reads it, so a pane
        // re-parented by a split rearrange comes back with its navigator still open.
        host?.dropPaneModals()
        wiring.clear(live: live)
    }

    private func wire() {
        wiring.wire(
            live: live, store: store, overlay: overlay, chrome: chrome,
            autoSecureInput: autoSecureInput,
        )
    }

    // MARK: What the mounter pushes

    /// A session arrived, or was swapped under a stable pane id. Re-wires, and rebuilds the pixels if
    /// the MODEL changed.
    package func setLive(_ live: LivePaneSession?) {
        guard live !== self.live else { return }
        let hadModel = self.live?.terminalModel
        if isWired { wiring.clear(live: self.live) }
        self.live = live
        if live?.terminalModel !== hadModel { host?.mountTerminalSurface() }
        host?.terminalSessionChanged()
        guard isWired else { return }
        wire()
        applyCwd()
        host?.followTerminalState()
    }

    /// The pane's workspace focus moved. Answers whether it actually MOVED, so the shell pushes the
    /// new value into its surface only on the edge.
    package func setFocused(_ isFocused: Bool) -> Bool {
        guard isFocused != self.isFocused else { return false }
        self.isFocused = isFocused
        return true
    }

    /// The host reported a new cwd (OSC 7). It changes independently of the session id, which is why
    /// it gets its own push rather than being folded into the wiring's. The link overlay resolves
    /// relative paths against the MODEL rather than a copy, so nothing else has to move.
    package func setCwd(_ cwd: String?) {
        guard cwd != self.cwd else { return }
        self.cwd = cwd
        applyCwd()
    }

    package func applyCwd() {
        live?.terminalModel?.linkCwd = cwd
    }

    // MARK: What the shell's arm reads

    /// The config-file edge, read INSIDE the shell's tracking block.
    ///
    /// `AppConfig` is a plain locked global, so the two settings are not observable on their own — the
    /// REVISION is, and reading it here is what makes a saved config file reconcile every open pane.
    /// The indicator is STORED rather than returned because ``pillConditions()`` reads it off `self`
    /// on the very next line.
    package func readAutoSecureInput() -> Bool {
        _ = ConfigRevision.shared.generation
        secureInputIndicator = SettingsKey.secureInputIndicatorEnabled
        return SettingsKey.autoSecureInputEnabled
    }

    /// Everything the pill gates read, taken once per pass.
    ///
    /// Every field is an OBSERVABLE mirror — never the `@ObservationIgnored` `isReadOnly` /
    /// `isCopyMode` the renderer's key path reads — so reading them HERE is what makes the chips light
    /// and clear reactively. A not-yet-live pane reads as all-false, which shows no chip.
    package func pillConditions() -> PaneStatusConditions {
        guard let model = live?.terminalModel else { return PaneStatusConditions() }
        return PaneStatusConditions(
            readOnly: model.readOnlyBadgeActive,
            copyMode: model.copyModeBadgeActive,
            hintMode: model.hintMode != nil,
            secureInput: model.secureInputActive,
            secureInputIndicator: secureInputIndicator,
            syncInput: live.map { store.syncInputArmed(for: $0.id) } ?? false,
        )
    }

    /// The two trigger keys for this pass, read INSIDE the shell's tracking block.
    package func readTaskKeys() -> TerminalLeafTaskKeys {
        TerminalLeafTaskKeys(
            dial: TerminalLeafPolicy.dialTaskKey(pane: live?.id, mayDial: store.panesMayDial),
            autotype: TerminalLeafPolicy.autotypeTaskKey(
                pane: live?.id,
                isTarget: live?.isAutotypeTarget ?? false,
                status: live?.connection?.status,
            ),
        )
    }

    // MARK: What the shell's arm applies

    /// Reconcile the process-global lock to a LIVE `controls.auto-secure-input` change, and answer
    /// whether it moved — a caller that gets `true` must re-ask ``pillConditions()``, because the
    /// reading it already has is the pre-reconcile one.
    ///
    /// Only on the AUTO edge: the wiring re-syncs on a pane swap, so without this an engaged lock
    /// would linger past the user turning the setting off.
    package func reconcileSecureInput(auto: Bool) -> Bool {
        guard auto != autoSecureInput else { return false }
        autoSecureInput = auto
        wiring.reconcileSecureInput(live: live, autoSecureInput: auto)
        return true
    }

    /// The framework-free reading of two `.task(id:)`s: a task runs when its key MOVES, and a key that
    /// went to `nil` cancels rather than starts.
    package func applyTaskKeys(_ keys: TerminalLeafTaskKeys) {
        if keys.dial != self.keys.dial {
            dialTask?.cancel()
            dialTask = nil
            if keys.dial != nil {
                let live = live
                let store = store
                dialTask = Task { @MainActor in
                    await TerminalPaneWiring.connectIfNeeded(live: live, store: store)
                }
            }
        }
        if keys.autotype != self.keys.autotype {
            autotypeTask?.cancel()
            autotypeTask = nil
            if keys.autotype != nil {
                let live = live
                autotypeTask = Task { @MainActor in
                    await TerminalPaneWiring.runAutotypeIfRequested(live: live)
                }
            }
        }
        self.keys = keys
    }

    private func cancelTriggers() {
        dialTask?.cancel()
        dialTask = nil
        autotypeTask?.cancel()
        autotypeTask = nil
        keys = TerminalLeafTaskKeys(dial: nil, autotype: nil)
    }
}

// MARK: - The chip column's insertion point

/// Where a newly wanted chip goes in the pane's top-trailing column.
///
/// The insertion point is measured against what is STILL in the stack, which includes anything
/// currently animating out. Counting only the kept predecessors would put a new chip above a leaving
/// one and make the column jump. Generic over the slot and over "where is this slot's view", so the
/// arithmetic is written once and each renderer answers the second half in its own stack's terms.
package enum LeafChipColumn {
    package static func insertionIndex<Slot: Equatable>(
        of slot: Slot, in desired: [Slot], position: (Slot) -> Int?,
    ) -> Int {
        desired.prefix(while: { $0 != slot }).compactMap(position).max().map { $0 + 1 } ?? 0
    }
}
