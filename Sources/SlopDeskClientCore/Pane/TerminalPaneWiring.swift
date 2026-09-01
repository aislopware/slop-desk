// TerminalPaneWiring — everything the terminal leaf DOES on appear, on a live-session swap and on
// teardown, taken out of the leaf (docs/56 §3, and increment 56c's ruling: a method on a `View` is
// not a view, but nothing that is not one can reach it).
//
// WHY THIS IS NOT A DRAWING. Every declaration here was a `private func` on `TerminalLeafView`, and
// not one of them reads a design token, places a rectangle or names a view type: they assign closures
// on a durable ``TerminalViewModel``, drive a process-global keyboard lock, dial a socket, and pick a
// failure string that ``TerminalLeafPolicy`` already owns. The canvas is about to get a second
// renderer in AppKit, and a `private func` on a `struct … : View` is reachable from exactly one of
// the two halves — so every line left up there would have been HAND-TRANSLATED into a second
// language: the retain-cycle discipline, the teardown ORDER, and the `EnableSecureEventInput`
// reference balance, re-derived from prose comments. That is "one implementation, never two
// languages" broken by the very commit that claims to honour it.
//
// WHAT EACH RENDERER KEEPS is its own TRIGGER and nothing else — SwiftUI's `.task` / `.onChange` /
// `.onDisappear`, AppKit's `withObservationTracking`. ``wire(live:store:overlay:chrome:)`` and
// ``clear(live:)`` are the whole surface. The five pairs under them are `private` ON PURPOSE: a
// renderer that can call one half of a pair is a renderer that can forget the other, and four of the
// five halves are a teardown.
//
// THREE TRAPS THIS FILE OWNS, each of which was a comment on a view before it was a test:
//
//   1. THE SECURE-INPUT BALANCE IS A REFERENCE COUNT, AND A MISSED DECREMENT LOCKS THE USER'S
//      KEYBOARD OUT OF EVERY OTHER APP. `clear` calls ``SecureKeyboardEntryController/teardown()``
//      BEFORE it looks for a terminal model, and that ordering IS the rule: a pane torn down once its
//      model has gone must still release the process-global `EnableSecureEventInput` it is holding.
//      The find bar has the same shape for a smaller stake — `attach(nil)` and `onSearchAllTabs = nil`
//      run ABOVE the `guard`, so a detached bar can never be driven by a surviving model.
//   2. A MODEL OUTLIVES THE LEAF THAT WIRED IT. ``TerminalViewModel`` is owned by the
//      ``LivePaneSession`` and survives a `.id(PaneID)` remount, so every closure it stores is either
//      nilled on teardown (all of them are) or captures weakly (`[weak model]`, `[weak live]`) —
//      never a strong edge back into the session, which would retain it into a cycle through its own
//      model.
//   3. THE NAVIGATOR CHROME IS CAPTURED STRONGLY, DELIBERATELY. It is this wiring's own state and not
//      the model's, so there is no model→leaf cycle to break; `clear` nils the model's side of it.
//
// REJECTED: threading a bare ``TerminalViewModel`` plus three closures instead of the
// ``LivePaneSession`` handle. It reads lighter, and it moves the retain-cycle decision back UP into
// each renderer — which is the one decision this file exists to state once.
//
// REJECTED: holding `live` / `store` as properties. SwiftUI re-supplies both to the leaf struct on
// every pass and the session is swapped under a stable pane id, so a remembered copy is a handle to
// whichever session happened to be current when this object was minted.

import Foundation
import Observation
import SlopDeskVideoProtocol // `EnvConfig` — the env → settings-overlay resolver the autotype seam reads through
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// Per-pane chrome holder driving the Command Navigator's visibility — a reference type so the pane
/// model's `onRequestBlockNavigator` `@MainActor` closure can TOGGLE it (the seam doc: "show/hide"),
/// exactly like the find bar's ``TerminalFindBarModel``.
///
/// It lives here rather than beside the card it opens because it is not a drawing: one `Bool`, held
/// per pane (the leaf is `.id(PaneID)`-keyed, so no cross-pane bleed) and never the durable model's
/// concern. `CommandNavigatorView` — which IS a drawing, and is a second-renderer job of its own —
/// stayed where it is.
@MainActor
@Observable
package final class CommandNavigatorChrome {
    /// Whether the navigator card is mounted over this pane. Toggled by `onRequestBlockNavigator`
    /// (⌃⌘O), cleared by the card's Esc / scrim-tap / row-jump.
    package var isVisible = false

    package init() {}
}

/// The per-pane wiring a terminal leaf installs on the durable ``TerminalViewModel``, and the three
/// pieces of leaf-owned state those callbacks drive.
///
/// One instance per mounted pane — the SwiftUI leaf holds it as `@State` under its `.id(PaneID)` key,
/// an AppKit canvas as a stored property on the pane's view controller. The three holders are `let`
/// so a renderer observes THEM (each is `@Observable` where it needs to be) rather than this object.
@MainActor
package final class TerminalPaneWiring {
    /// The in-pane ⌘F find bar's view-model — a thin driver over the terminal surface's own matcher
    /// (the four-mode `find` door plus the `search:` binding-action passthrough), wired to the pane's
    /// `onRequestFind*` callbacks. It holds no match list of its own.
    package let findBar: TerminalFindBarModel

    /// The per-pane macOS Secure Keyboard Entry actuator. Driven from the model's `onHostEchoChanged`
    /// (auto, on a host no-echo password prompt) and the manual `onManualSecureInputChanged` toggle,
    /// it engages / disengages process-global `EnableSecureEventInput` with a strict single-reference
    /// balance. Inert off macOS (no-op seams).
    package let secureInput: SecureKeyboardEntryController

    /// The per-leaf Command Navigator (⌃⌘O) chrome the model's `onRequestBlockNavigator` TOGGLES.
    package let navigatorChrome: CommandNavigatorChrome

    /// Injectable in full so a test can count the process-global enable/disable calls without securing
    /// the test runner's own keyboard — the balance in trap 1 is the reason this initializer has
    /// parameters at all.
    package init(
        findBar: TerminalFindBarModel = TerminalFindBarModel(),
        secureInput: SecureKeyboardEntryController = SecureKeyboardEntryController(),
        navigatorChrome: CommandNavigatorChrome = CommandNavigatorChrome(),
    ) {
        self.findBar = findBar
        self.secureInput = secureInput
        self.navigatorChrome = navigatorChrome
    }

    // MARK: - The two halves a renderer triggers

    /// Wire all per-pane callbacks (find + secure input + hint mode + navigator + host path actions)
    /// on appear AND on every live-session swap.
    ///
    /// Idempotent by construction: every leg ASSIGNS rather than appends, so a renderer whose trigger
    /// over-fires re-installs the same closures instead of stacking them.
    ///
    /// - Parameters:
    ///   - live: the pane's session handle, or `nil` for a not-yet-live / non-terminal pane (every leg
    ///     then no-ops).
    ///   - store: the live workspace store — the host-pushed project key the code panel opens for.
    ///   - overlay: the scene's overlay coordinator, for the ⇧⌘F escalation and the host-action failure
    ///     toast. `nil` outside the app scene (tests/previews) ⇒ the escalation is a dismiss and the
    ///     failure is swallowed, never a crash.
    ///   - chrome: the shared chrome model, used ONLY to reveal the right code panel when an
    ///     open-in-code-panel action lands. `nil` ⇒ the file still opens host-side, the panel just is
    ///     not auto-revealed.
    ///   - autoSecureInput: the live "Auto Secure Input" setting. Defaulted to the stored value so the
    ///     renderer's trigger stays a one-liner; a test passes it to make the lock's inputs its own.
    package func wire(
        live: LivePaneSession?,
        store: WorkspaceStore,
        overlay: OverlayCoordinator?,
        chrome: WorkspaceChromeState?,
        autoSecureInput: Bool = SettingsKey.autoSecureInputEnabled,
    ) {
        wireFind(live: live, overlay: overlay)
        wireSecureInput(live: live, autoSecureInput: autoSecureInput)
        wireHint(live: live)
        wireNavigator(live: live)
        wirePathActions(live: live, store: store, overlay: overlay, chrome: chrome)
        wireShellCompletion(live: live)
        wireWhenceWords(live: live)
    }

    /// Clear all per-pane callbacks on teardown so a surviving model can't drive a dead leaf's state,
    /// and so the process-global secure-input reference is released on a pane close rather than leaked.
    ///
    /// Idempotent: a second call disables nothing a second time (the controller's own balance) and nils
    /// what is already `nil`.
    package func clear(live: LivePaneSession?) {
        clearFind(live: live)
        clearSecureInput(live: live)
        clearHint(live: live)
        clearNavigator(live: live)
        clearPathActions(live: live)
        clearShellCompletionWiring(live: live)
    }

    /// Reconcile this pane's Secure Input to a LIVE "Auto Secure Input" settings change.
    ///
    /// ``wire(live:store:overlay:chrome:autoSecureInput:)`` only re-syncs on a pane swap, so without
    /// this an engaged process-global lock AND the pill would linger past the user turning the setting
    /// OFF — the carryover footgun. Pushing the new value into BOTH the actuator (which releases the
    /// lock on the OFF edge) and the model's pill mirror reconciles them at once. No-op for a
    /// not-yet-live pane; inert off macOS (stub seams, and the model mirror stays `false`).
    package func reconcileSecureInput(live: LivePaneSession?, autoSecureInput: Bool) {
        guard let model = live?.terminalModel else { return }
        secureInput.setAutoSecureInput(autoSecureInput)
        model.reconcileSecureInputSetting()
    }

    // MARK: - Verbs that hold no per-pane state

    /// The `×` on a dismissible chip.
    ///
    /// Read-only releases through the MODEL, whose `onReadOnlyChanged` hook converges the store's
    /// `paneReadOnly` set; sync input disarms the WHOLE tab, because the mode is the tab's and clearing
    /// it on one pane only would leave the siblings still fanning input. Secure input carries no `×`
    /// (``PaneStatusPill/dismissHelp``), so it never reaches here.
    ///
    /// WHICH chip goes where is ``PaneWiringRules/dismissRoute(_:)``'s, pinned on the far side against
    /// the same chip's own `isDismissible` — so a fourth pill cannot ship with a `×` that does nothing.
    /// What is left here is the ACTUATING, which is the half that touches a live model and a store.
    package static func dismiss(_ pill: PaneStatusPill, live: LivePaneSession?, store: WorkspaceStore) {
        switch PaneWiringRules.dismissRoute(pill) {
        case .readOnly:
            live?.terminalModel?.exitReadOnly()
        case .syncInput:
            if let paneID = live?.id { store.disarmSyncInput(for: paneID) }
        case .nothing:
            break
        }
    }

    /// Dial this pane's channel, once the host answers for its id.
    ///
    /// The renderer's task key (``TerminalLeafPolicy/dialTaskKey(pane:mayDial:)``) already encodes the
    /// hold, and SwiftUI runs the task for the `nil` key too — so the gate is RE-ASSERTED here rather
    /// than relied upon as a scheduling accident.
    ///
    /// IDEMPOTENT: a trigger re-fires on every remount, including a pane remount on a TAB switch (the
    /// inactive tab's subtree is unmounted, then mounted again on return). It routes through the
    /// model's `connectIfNeeded()`, which no-ops on a live / in-flight / supervised channel, so a tab
    /// switch never tears down a healthy session or wipes the replay ring (the
    /// scrollback-lost-on-tab-switch regression). A genuinely idle / dead channel still dials.
    package static func connectIfNeeded(live: LivePaneSession?, store: WorkspaceStore) async {
        guard store.panesMayDial else { return }
        await live?.connection?.connectIfNeeded()
    }

    /// Hand this pane to the `SLOPDESK_AUTOTYPE` OUT-path proof seam (``AutotypeSeam``), which owns the
    /// once-per-launch latch. Unset in normal use, so a production launch is unaffected.
    ///
    /// Resolved through ``EnvConfig`` (real env FIRST, then the settings overlay) rather than off
    /// `ProcessInfo` directly. Same `Optional<String>`, same latch, same unset-means-off default —
    /// what the direct read skipped is the overlay tier `config.toml`'s `[env]` table writes into.
    package static func runAutotypeIfRequested(live: LivePaneSession?) async {
        guard let live else { return }
        let connected = if case .connected = live.connection?.status { true } else { false }
        let model = live.terminalModel
        await AutotypeSeam.run(
            command: EnvConfig.string("SLOPDESK_AUTOTYPE"),
            isTarget: live.isAutotypeTarget,
            isConnected: connected,
            send: model.map { model in { model.sendInput($0) } },
        )
    }

    // MARK: - Find (⌘F / ⌘G / ⇧⌘G)

    /// Wire the pane's ⌘F / ⌘G / ⇧⌘G callbacks to the find-bar holder (the seam the store fires via
    /// `requestFind*InActivePane()`). No-op for a non-terminal / not-yet-live pane (`terminalModel ==
    /// nil`); `terminalModel` is non-nil from session creation for a terminal pane, so this lands on the
    /// first trigger.
    private func wireFind(live: LivePaneSession?, overlay: OverlayCoordinator?) {
        guard let model = live?.terminalModel else { return }
        let bar = findBar
        bar.attach(model)
        model.onRequestFind = { bar.open() }
        // Copy-mode `?` opens the SAME bar biased BACKWARD so its `n`/`N` step against the forward sense
        // (vim parity). Without this the `?` handler falls back to `onRequestFind` (forward) and the
        // backward bias never lands.
        model.onRequestFindBackward = { bar.open(backward: true) }
        model.onRequestFindNext = { bar.next() }
        model.onRequestFindPrev = { bar.previous() }
        // "Search all tabs" (find.png's `rectangle.stack` button): escalate the in-pane find to cross-tab
        // Global Search (⇧⌘F), seeded with the live query. The coordinator is captured BY VALUE (a
        // long-lived scene object); `nil` outside the app scene ⇒ the button just dismisses the bar.
        bar.onSearchAllTabs = { seed in overlay?.openGlobalSearch(seed: seed) }
    }

    /// Detach the holder + nil the callbacks so the model stops referencing a torn-down leaf's state.
    /// The two lines above the `guard` are deliberate: a leaf whose model has already gone must still
    /// end up with a bar that nothing can drive.
    private func clearFind(live: LivePaneSession?) {
        findBar.attach(nil)
        findBar.onSearchAllTabs = nil
        guard let model = live?.terminalModel else { return }
        model.onRequestFind = nil
        model.onRequestFindBackward = nil
        model.onRequestFindNext = nil
        model.onRequestFindPrev = nil
    }

    // MARK: - Secure input (the reference-counted process-global lock)

    /// Wire the pane's SECURE-INPUT actuator: sync the controller to the model's current secure-input
    /// inputs plus the live Auto-Secure-Input setting, then drive it on each change, so macOS
    /// process-global Secure Keyboard Entry engages on a host no-echo password prompt (auto) or on the
    /// manual toggle and disengages on the inverse edge.
    ///
    /// The three setters come BEFORE ``SecureKeyboardEntryController/observeAppActivity()``, which is
    /// idempotent and starts the controller watching the app-frontmost edge — so an engaged lock is
    /// RELEASED whenever slopdesk is backgrounded and re-acquired on return, never leaked process-wide
    /// to other apps' keyboards. Each setter reconciles, and the controller's single `engaged` flag is
    /// what makes three reconciles at most one `EnableSecureEventInput()`.
    ///
    /// No-op for a non-terminal / not-yet-live pane; inert off macOS (stub seams).
    private func wireSecureInput(live: LivePaneSession?, autoSecureInput: Bool) {
        guard let model = live?.terminalModel else { return }
        let controller = secureInput
        controller.setAutoSecureInput(autoSecureInput)
        controller.setHostNoEcho(model.hostNoEcho)
        controller.setManualOn(model.manualSecureInput)
        controller.observeAppActivity()
        model.onHostEchoChanged = { controller.setHostNoEcho($0) }
        model.onManualSecureInputChanged = { controller.setManualOn($0) }
    }

    /// Force-disengage secure input + nil the callbacks on teardown, so the process-global
    /// `EnableSecureEventInput` reference is ALWAYS released on a pane close and a surviving model can't
    /// drive a dead leaf's controller.
    ///
    /// ``SecureKeyboardEntryController/teardown()`` runs above the `guard` and that is the whole point:
    /// the lock is process-global and the model is not. A pane whose model went first would otherwise
    /// hold the keyboard for every other app on the machine, with nothing on screen to say so.
    private func clearSecureInput(live: LivePaneSession?) {
        secureInput.teardown()
        guard let model = live?.terminalModel else { return }
        model.onHostEchoChanged = nil
        model.onManualSecureInputChanged = nil
    }

    // MARK: - Hint mode (⌘⇧J / ⌘⇧Y)

    /// Wire the pane's Hint Mode actuation: the model resolves a label (macOS key-resolve or iOS
    /// tap-on-label) and fires ``TerminalViewModel/onHintConfirmed`` with the target + intent; this is
    /// the thin actuator (open path → host RPC, open URL → client, copy → client pasteboard, reveal →
    /// host RPC — the SAME `LinkActionPolicy` the ⌘click / Jump-To paths use). `[weak model]` so the
    /// stored closure never retains the model into a cycle (also nilled on teardown). No-op off-terminal.
    private func wireHint(live: LivePaneSession?) {
        guard let model = live?.terminalModel else { return }
        model.onHintConfirmed = { [weak model] target, intent in
            guard let model else { return }
            TerminalHintActuator.perform(target, intent: intent, model: model)
        }
    }

    /// Nil the hint callback so the durable terminal model stops referencing this torn-down leaf.
    private func clearHint(live: LivePaneSession?) {
        live?.terminalModel?.onHintConfirmed = nil
    }

    // MARK: - Command Navigator (⌃⌘O)

    /// Wire the pane's Command Navigator toggle: ⌃⌘O routes through the store
    /// (`requestBlockNavigatorInActivePane` → `activeTerminalModel.onRequestBlockNavigator`), so this
    /// closure fires only when THIS pane is active. It TOGGLES the per-pane ``CommandNavigatorChrome``.
    /// No `[weak chrome]` needed: the chrome is this wiring's own state, not the model's, so there is
    /// no model→leaf retain cycle (``clear(live:)`` nils the model's reference on teardown). No-op for a
    /// non-terminal / not-yet-live pane.
    private func wireNavigator(live: LivePaneSession?) {
        guard let model = live?.terminalModel else { return }
        let chrome = navigatorChrome
        model.onRequestBlockNavigator = { chrome.isVisible.toggle() }
    }

    /// Nil the navigator callback so the durable terminal model stops referencing this torn-down leaf's
    /// chrome (the leaf is `.id(PaneID)`-keyed and can be rebuilt while the live session survives).
    private func clearNavigator(live: LivePaneSession?) {
        live?.terminalModel?.onRequestBlockNavigator = nil
    }

    // MARK: - Host path actions (open / reveal / open-in-code-panel)

    /// Wire the pane's host OPEN / REVEAL path callbacks to the live `MetadataClient` — so ⌘click
    /// "Open", ⌘⇧click "Reveal in Finder", the right-click Open / Reveal items, Jump-To open/reveal, and
    /// Hint-to-open/reveal on a detected PATH all route to the HOST Mac's Finder/app (a path lives on
    /// the host, not the client).
    ///
    /// The client provider captures `live` WEAKLY (so the model-stored closure never retains the live
    /// session into a cycle) and reads the CURRENT façade on each fire — it is replaced on every
    /// reconnect, and `activeMetadataClient` is `nil` while disconnected. A `.notFound` / `.error` /
    /// timeout raises a transient error toast rather than being swallowed. No-op for a non-terminal /
    /// not-yet-live pane.
    private func wirePathActions(
        live: LivePaneSession?,
        store: WorkspaceStore,
        overlay: OverlayCoordinator?,
        chrome: WorkspaceChromeState?,
    ) {
        guard let model = live?.terminalModel else { return }
        HostPathActions.wire(
            model: model,
            client: { [weak live] in live?.connection?.activeMetadataClient },
            revealCodePanel: { [weak live] in
                // Open-in-editor is the second doorway through the code panel's open gate: the host has
                // already routed the file into the workbench, so the panel must mount it — a reveal that
                // landed on the gate's button would ask permission for a thing already done. The pane's
                // host-pushed key is the root the panel will render for.
                if let pane = live?.id, let root = store.hostPushedProjectKey(pane) {
                    chrome?.openCodeProject(root)
                }
                chrome?.revealCodeSidebar()
            },
            onResult: { action, path, ok in
                guard !ok else { return }
                overlay?.pushToast(Toast(
                    id: "host-path-action",
                    flavor: .error,
                    // The subject is the ACTION that failed, not a sentence about failing: the `FAILED`
                    // eyebrow already carries that, and lower-case keeps the instrument register the
                    // rest of the card is set in.
                    title: TerminalLeafPolicy.pathActionFailureTitle(action),
                    body: path,
                    // No `paneKey`: this reports a FAILED host action the user just took in the pane
                    // they are looking at — there is nowhere else to go, so the card stays a plain
                    // notice.
                ))
            },
        )
    }

    /// Nil the host path callbacks so the durable terminal model stops referencing this torn-down leaf.
    private func clearPathActions(live: LivePaneSession?) {
        guard let model = live?.terminalModel else { return }
        HostPathActions.clear(model: model)
    }

    // MARK: - The user's own shell completion (verb 23)

    /// Point the pane's Tab key at the HOST's captive zsh — ``MetadataClient/shellComplete(cursor:buffer:)``,
    /// `docs/68` §11. This is the leg that makes the differentiator fire: without it the editor ranks
    /// only what the client can see (paths, history, variables, the seeded command table) and the
    /// user's own completions — their plugin manager's, their company CLI's, whatever a package
    /// dropped into `site-functions` — are never asked.
    ///
    /// Same provider shape as ``wirePathActions(live:store:overlay:chrome:)`` and for the same
    /// reason: `live` is captured WEAKLY and the façade is read on each fire, because it is replaced
    /// on every reconnect. While disconnected the sink answers ``MetadataClient/ShellCompletionAnswer/notReady``
    /// rather than nothing, so the availability latch is not spent on being offline.
    private func wireShellCompletion(live: LivePaneSession?) {
        guard let model = live?.terminalModel else { return }
        model.shellCompletionSink = { [weak live] cursor, buffer in
            guard let client = live?.connection?.activeMetadataClient else { return .notReady }
            return await client.shellComplete(cursor: cursor, buffer: buffer)
        }
    }

    /// Point the pane's prompt at the same captive zsh for the OTHER question — which of the words
    /// typed so far it can actually find (``MetadataClient/whenceWords(request:)``, `docs/68` §11.1).
    ///
    /// Wired beside the completion sink and torn down with it, because the two are one shell: the
    /// availability latch ``TerminalViewModel/shellCompletionAvailable`` is shared, so a host that
    /// answers "not zsh" to either stops being asked either.
    private func wireWhenceWords(live: LivePaneSession?) {
        guard let model = live?.terminalModel else { return }
        model.whenceSink = { [weak live] request in
            guard let client = live?.connection?.activeMetadataClient else { return .notReady }
            return await client.whenceWords(request: request)
        }
    }

    /// Drop both shell sinks and re-arm the availability latch for the next host.
    private func clearShellCompletionWiring(live: LivePaneSession?) {
        live?.terminalModel?.clearShellCompletion()
    }
}
