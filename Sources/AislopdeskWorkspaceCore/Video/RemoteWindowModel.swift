import Foundation

// L0: extracted from the deleted SwiftUI `RemoteWindowPanel.swift`. `RemoteWindowModel` is the
// per-pane `@MainActor @Observable` LOGIC for opening one remote GUI window (PATH 2): the picker
// refresh/pick, open/close, rebind, and paste-as-keystrokes. It has no SwiftUI usage (the deleted
// `RemoteWindowPanel` view bound to it); the rebuilt UI (L6) will bind a new view to this model.
@preconcurrency
@MainActor
@Observable
public final class RemoteWindowModel {
    // MARK: Entry fields (bound to the form)

    /// Which host-side window to mirror (set by the picker, or typed in the manual fallback). Host/ports
    /// come from the app target.
    public var windowID: String
    public var title: String
    /// PANE REBIND: the owning app's name (filled by ``pick(_:)``; empty for manual entry). Persisted
    /// with the endpoint so a restored binding can re-resolve a stale CGWindowID by app+title.
    public var appName: String

    /// PANE REBIND: the store persists each committed endpoint into the pane's spec through this
    /// (wired at session materialization). Fired by ``open()``.
    public var onEndpointCommitted: ((VideoEndpoint) -> Void)?

    // MARK: Picker state (docs/31 discovery)

    /// The host's shareable windows, fetched by ``refresh()`` — what the picker lists.
    public private(set) var availableWindows: [RemoteWindowSummary] = []
    /// True while a discovery query is in flight (the panel shows a spinner).
    public private(set) var isLoading = false
    /// A short message when discovery yielded nothing / no discovery seam (the panel offers manual entry).
    public private(set) var loadError: String?

    /// Resolves the app-global ``ConnectionTarget`` (host + UDP ports) at open-time, so every video pane
    /// rides the one shared UDP flow at the app host (docs/31). The pane no longer enters a host/ports.
    private let target: @MainActor () -> ConnectionTarget

    /// The opened window's descriptor (carries the full endpoint). `nil` ⇒ the form is shown;
    /// non-nil ⇒ the live ``VideoWindowFactory`` view is shown.
    public private(set) var active: RemoteWindowDescriptor?

    // MARK: Paste as Keystrokes (per-key CGEvent typing into secure fields)

    /// The live key-injection sink the gated ``VideoWindowView`` publishes (via
    /// ``RemotePaneContext/onKeyInjectorReady``) once its session exists, and clears (`nil`) on
    /// teardown. Each call drives the host's per-event input path (`InputInjector.postKey`, plain
    /// `CGEvent`) — which types into `sudo` / SecurityAgent password fields (CGEvent keys reach the
    /// secure field even under Secure Event Input). `(keyCode, down, shift)`.
    ///
    /// READ-ONLY GATE (E21 WI-3): when the owning pane is read-only the SEAM clears this — `GuiLeafView`
    /// derives the context through ``RemotePaneContext/videoLeaf(isActive:readOnly:...)``, which binds a
    /// `nil` sink here instead of the live one. So paste-as-keystrokes is inert on a read-only pane
    /// (``canPasteKeystrokes`` is then `false` and ``pasteAsKeystrokes(_:)`` no-ops) WITHOUT any
    /// model→store coupling — the model never learns the read-only state; the seam withholds the sink.
    public var keyInjector: ((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?

    /// Whether a paste-as-keystrokes is possible right now: streaming AND a live key sink is wired. A
    /// read-only pane has no sink (the seam withholds it, see ``keyInjector``), so this is `false` there.
    public var canPasteKeystrokes: Bool { active != nil && keyInjector != nil }

    /// The in-flight paste (cancelled if a new one starts or the pane tears down).
    private var pasteTask: Task<Void, Never>?
    /// Per-character pacing — slow enough that a secure field's focus/IME keeps up, fast enough to
    /// feel instant for a password. Injectable for deterministic tests (`.zero`).
    private let pasteInterval: Duration

    /// Transient "typed N, skipped M" result of the last paste-as-keystrokes — set only when some
    /// characters had NO US-QWERTY mapping (accents / emoji / non-Latin) and were dropped, so the user
    /// learns the paste was incomplete instead of silently losing them. Auto-clears after
    /// ``pasteFeedbackDuration``; `nil` when the last paste mapped cleanly. The payload is never stored.
    public struct PasteFeedback: Sendable, Equatable {
        public var typed: Int
        public var skipped: Int
    }

    public private(set) var pasteFeedback: PasteFeedback?
    @ObservationIgnored private var pasteFeedbackTask: Task<Void, Never>?
    private let pasteFeedbackDuration: Duration

    /// The paste-guard verdict for typing `text` into this target (`targetIsSecure` = a known password /
    /// SecurityAgent field). The caller confirms before ``pasteAsKeystrokes(_:)`` on a non-`.ok` risk —
    /// e.g. a secret about to be typed into an echoing field, or a whole file into a password prompt.
    public func assessPaste(_ text: String, targetIsSecure: Bool) -> PasteRisk {
        SecretPasteClassifier.assess(text: text, targetIsSecure: targetIsSecure)
    }

    /// Replays `text` as individual key events over the live ``keyInjector`` (US-QWERTY; unmappable
    /// characters are skipped). Down+up per stroke, Shift folded into both edges, paced by
    /// ``pasteInterval``. NEVER logs the payload — it is frequently a password. No-op when no sink is
    /// wired or the text is empty. Returns the encode result so the caller can surface "skipped N".
    @discardableResult
    public func pasteAsKeystrokes(_ text: String) -> KeystrokeReplay.Encoded {
        let encoded = KeystrokeReplay.encode(text)
        // No sink → nothing was attempted, so nothing to report.
        guard let injector = keyInjector else { return encoded }
        // Surface "typed N, skipped M" when characters were dropped — BEFORE the empty-strokes return, so
        // an ALL-unmappable paste (typed 0, skipped N) still tells the user nothing was sent.
        notePasteFeedback(typed: encoded.strokes.count, skipped: encoded.skipped)
        guard !encoded.strokes.isEmpty else { return encoded }
        pasteTask?.cancel()
        let interval = pasteInterval
        let strokes = encoded.strokes
        pasteTask = Task { @MainActor in
            for stroke in strokes {
                if Task.isCancelled { return }
                injector(stroke.keyCode, true, stroke.shift)
                injector(stroke.keyCode, false, stroke.shift)
                if interval > .zero { try? await Task.sleep(for: interval) }
            }
        }
        return encoded
    }

    /// Records the transient paste feedback when characters were dropped, and schedules its auto-clear.
    /// A CLEAN paste (every character mapped) clears any STALE banner from a prior skipped paste rather
    /// than leaving it up to time out — a successful paste should not keep showing the old warning.
    private func notePasteFeedback(typed: Int, skipped: Int) {
        guard skipped > 0 else { dismissPasteFeedback()
            return
        }
        pasteFeedback = PasteFeedback(typed: typed, skipped: skipped)
        pasteFeedbackTask?.cancel()
        let d = pasteFeedbackDuration
        pasteFeedbackTask = Task { @MainActor [weak self] in
            if d > .zero { try? await Task.sleep(for: d) }
            if !Task.isCancelled { self?.pasteFeedback = nil }
        }
    }

    /// Dismisses the paste feedback (tap-to-dismiss / a new clean paste need not wait out the timer).
    public func dismissPasteFeedback() {
        pasteFeedbackTask?.cancel()
        pasteFeedback = nil
    }

    @preconcurrency
    public init(
        target: @escaping @MainActor () -> ConnectionTarget = { .default },
        windowID: String = "",
        title: String = "Remote window",
        appName: String = "",
        pasteInterval: Duration = .milliseconds(6),
        pasteFeedbackDuration: Duration = .seconds(5),
    ) {
        self.target = target
        self.windowID = windowID
        self.title = title
        self.appName = appName
        self.pasteInterval = pasteInterval
        self.pasteFeedbackDuration = pasteFeedbackDuration
    }

    // MARK: Discovery (picker)

    /// Queries the host for its shareable windows via the ``RemoteWindowDiscovery`` seam and populates
    /// ``availableWindows``. Best-effort: on no seam / empty result it sets ``loadError`` so the panel
    /// offers the manual-id fallback. Idempotent-safe to call repeatedly (Refresh / on-appear).
    public func refresh() async {
        // Coalesce overlapping refreshes (the on-appear `.task` vs a manual Refresh tap, or a double tap):
        // a second call while one is in flight is a no-op rather than racing two queries to the same host.
        guard !isLoading else { return }
        guard let query = RemoteWindowDiscovery.shared else {
            loadError = "Window discovery is unavailable — enter a window id manually."
            return
        }
        isLoading = true
        loadError = nil
        let t = target()
        let windows = await query(t.host, t.mediaPort, t.cursorPort)
        isLoading = false
        // If the user opened a window while the query was in flight, don't stamp stale picker state onto a
        // now-active pane (it would briefly show on a later close()→form).
        guard active == nil else { return }
        availableWindows = windows
        loadError = windows.isEmpty
            ? "No windows found on the host (screen-recording permission?). You can enter a window id manually."
            : nil
    }

    /// The window list narrowed by a filter query — every whitespace-separated token must match
    /// case-insensitively in the title OR the app name (token-AND, the picker's filter-field policy;
    /// 10+ windows on a busy host made the unfiltered list scroll-blind). Pure + static for tests.
    public static func filtered(
        _ windows: [RemoteWindowSummary], query: String,
    ) -> [RemoteWindowSummary] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return windows }
        return windows.filter { window in
            let haystack = "\(window.title.lowercased()) \(window.appName.lowercased())"
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    /// The message shown inside the discovered-window list when the active filter excludes every window.
    /// The list renders only when discovery found ≥1 window (and an empty filter matches all), so this is
    /// always a filter-exclusion case — name the filter AND point at the fix (clearing it reveals the
    /// `totalCount` discovered windows), rather than the dead-end "no windows match". Pure for tests.
    public static func windowFilterEmptyMessage(filter: String, totalCount: Int) -> String {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        let windowWord = totalCount == 1 ? "window" : "windows"
        return "No windows match “\(trimmed)” — clear the filter to see all \(totalCount) \(windowWord)."
    }

    /// Picks a window from the list: fills ``windowID`` + ``title`` + ``appName`` (the caller then
    /// ``open()``s).
    public func pick(_ summary: RemoteWindowSummary) {
        windowID = String(summary.windowID)
        title = summary.title.isEmpty ? summary.appName : summary.title
        appName = summary.appName
    }

    var parsedWindowID: UInt32? { UInt32(windowID.trimmingCharacters(in: .whitespaces)) }

    /// Whether a valid window id is entered. Host + UDP ports come from the app target (always valid),
    /// so a window id is all that is needed to open.
    public var canOpen: Bool { parsedWindowID != nil }

    /// Builds the descriptor from the app target (host + UDP ports) + the entered window id and marks it
    /// active (the panel then brings up the live ``VideoWindowView``). No-op if the window id is invalid.
    public func open() {
        guard let wid = parsedWindowID else { return }
        let t = target()
        active = RemoteWindowDescriptor(
            title: title.isEmpty ? "window \(wid)" : title,
            windowID: wid,
            host: t.host,
            mediaPort: t.mediaPort,
            cursorPort: t.cursorPort,
        )
        // PANE REBIND: persist the now-live binding (app+title travel with the id so a future
        // restore can re-resolve it). Fired on every open — a re-pick updates the spec too.
        onEndpointCommitted?(VideoEndpoint(
            windowID: wid,
            title: title.isEmpty ? "window \(wid)" : title,
            appName: appName,
        ))
    }

    // MARK: Stale-binding revalidation (PANE REBIND, 2026-06-12)

    /// What ``revalidateBinding()`` decided (observability/tests).
    public enum RebindOutcome: Equatable, Sendable {
        /// No discovery seam / no parseable id / host unreachable (empty list) — left as-is.
        case skipped
        /// The saved id is still valid (same app) — nothing changed.
        case kept
        /// The id was stale; re-picked the same app's window (by title tiebreak) and re-opened.
        case rebound
        /// The app has no windows on the host anymore — closed back to the picker form.
        case unbound
    }

    /// Validates the CURRENT (typically restored) binding against the host's live window list and
    /// self-heals a stale CGWindowID via ``WindowRebind``. Called once per session by
    /// `LivePaneSession.setVideoActive` AFTER the optimistic `open()` (the common no-restart case
    /// streams instantly; a stale binding re-binds within the discovery round-trip instead of
    /// sitting on a silent black pane forever). Best-effort: an unreachable host / missing seam
    /// changes nothing.
    public func revalidateBinding() async -> RebindOutcome {
        guard let query = RemoteWindowDiscovery.shared, let wid = parsedWindowID else { return .skipped }
        let t = target()
        let windows = await query(t.host, t.mediaPort, t.cursorPort)
        guard !windows.isEmpty else { return .skipped } // unreachable/empty: not evidence of staleness
        switch WindowRebind.resolve(windowID: wid, appName: appName, title: title, in: windows) {
        case .keep:
            return .kept
        case let .rebind(window):
            close()
            pick(window)
            open()
            return .rebound
        case .unresolved:
            // The window's app is gone — fall back to the entry form, pre-warmed with the list we
            // already fetched so the picker renders instantly.
            close()
            availableWindows = windows
            loadError = "\"\(title)\" is no longer open on the host — pick a window."
            return .unbound
        }
    }

    // MARK: Resize-reflow scrim signal (generic with the terminal pane)

    /// TRUE from the instant this pane is resized until the host re-captures the window at the new size
    /// and the first SHARP frame at that size renders — the video analogue of the terminal's
    /// ``TerminalViewModel/awaitingResizeReflow``. The pane resize-scrim (``PaneContainer``) waits on it
    /// so the calm overlay BRIDGES the gap during which the Metal view shows the last frame STRETCHED /
    /// upscaled (blurry) before the re-captured pixels arrive — instead of clearing on a fixed geometry
    /// settle timer that uncovers the blur early. The app-target ``VideoWindowView`` drives it:
    /// ``noteResized()`` on a layout-size change (which prompts the 1:1 host re-capture) and
    /// ``noteRendered()`` on the first frame at the new native size. A safety timeout + ``close()`` clear
    /// it so it can never stick. (The live-video pane mount is deferred — see ``PaneContainer`` — so this
    /// seam is exercised by tests today and goes live the moment the video pane is wired.)
    public private(set) var awaitingResizeReflow = false

    /// Belt-and-braces ceiling on ``awaitingResizeReflow`` (mirrors the terminal model): clears the scrim
    /// even if the host never re-captures (a frozen window, a dropped UDP flow). Instance-settable so
    /// tests drive it without real-time waits.
    @ObservationIgnored var reflowScrimTimeout: Duration = .milliseconds(1200)
    @ObservationIgnored private var reflowTimeoutTask: Task<Void, Never>?

    /// The pane was resized (a layout-size change that will prompt a host re-capture at the new native
    /// size) — arm the resize scrim until the first re-captured frame lands. (Re)starts the safety
    /// timeout. Idempotent-safe to call per layout pass during a live drag — each call just re-arms.
    public func noteResized() {
        awaitingResizeReflow = true
        reflowTimeoutTask?.cancel()
        let timeout = reflowScrimTimeout
        reflowTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.endAwaitingReflow()
        }
    }

    /// The first frame at the new native size rendered (the host re-capture caught up) — release the
    /// resize scrim. Idempotent + cheap when not awaiting.
    public func noteRendered() { endAwaitingReflow() }

    /// Clears ``awaitingResizeReflow`` + cancels the safety timeout. Idempotent — the observable is only
    /// written when it actually changes.
    private func endAwaitingReflow() {
        reflowTimeoutTask?.cancel()
        reflowTimeoutTask = nil
        if awaitingResizeReflow { awaitingResizeReflow = false }
    }

    /// Closes the remote window (tears down the live view → its orchestrator `stop()`).
    public func close() {
        active = nil
        endAwaitingReflow() // a closed window will not re-capture — never leave the scrim hung
    }
}
