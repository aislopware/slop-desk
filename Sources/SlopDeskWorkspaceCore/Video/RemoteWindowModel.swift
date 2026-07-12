import Foundation

// Per-pane `@MainActor @Observable` LOGIC for opening one remote GUI window (PATH 2): picker
// refresh/pick, open/close, rebind, and paste-as-keystrokes. No SwiftUI usage (a rebuilt view binds to it).
@preconcurrency
@MainActor
@Observable
public final class RemoteWindowModel {
    // MARK: Entry fields (bound to the form)

    /// Which host-side window to mirror (picker or manual fallback). Host/ports come from the app target.
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

    /// Resolves the app-global ``ConnectionTarget`` (host + UDP ports) at open-time so every video pane
    /// rides the one shared UDP flow at the app host (docs/31).
    private let target: @MainActor () -> ConnectionTarget

    /// The opened window's descriptor (carries the full endpoint). `nil` ⇒ the form is shown;
    /// non-nil ⇒ the live ``VideoWindowFactory`` view is shown.
    public private(set) var active: RemoteWindowDescriptor?

    // MARK: Paste as Keystrokes (per-key CGEvent typing into secure fields)

    /// The live key-injection sink ``VideoWindowView`` publishes (via
    /// ``RemotePaneContext/onKeyInjectorReady``) once its session exists, cleared (`nil`) on teardown.
    /// Each call drives the host's per-event input path (`InputInjector.postKey`, plain `CGEvent`) — CGEvent
    /// keys reach `sudo` / SecurityAgent password fields even under Secure Event Input. `(keyCode, down, shift)`.
    ///
    /// READ-ONLY GATE: on a read-only pane the SEAM binds a `nil` sink here (`GuiLeafView` →
    /// ``RemotePaneContext/videoLeaf(isActive:readOnly:...)``), so paste-as-keystrokes is inert
    /// (``canPasteKeystrokes`` `false`, ``pasteAsKeystrokes(_:)`` no-ops) WITHOUT any model→store coupling —
    /// the model never learns the read-only state; the seam withholds the sink.
    public var keyInjector: ((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?

    /// RESIZE (numeric popover): the live ``VideoWindowView`` publishes this once its session exists
    /// (cleared `nil` on teardown / when read-only). The "Resize…" popover calls it to request an ABSOLUTE
    /// host-window POINT size; `(width, height)`. `nil` ⇒ no live sink (no button).
    public var resizeInjector: ((_ width: Double, _ height: Double) -> Void)?

    /// Whether the resize control should be live: streaming AND a resize sink is wired (withheld while
    /// read-only). `GuiLeafView` gates the "Resize…" button on this.
    public var canResizeWindow: Bool { active != nil && resizeInjector != nil }

    /// The remote window's CURRENT POINT size, pushed by ``VideoWindowView`` on the first decoded frame and
    /// every host-/popover-driven resize (via ``noteWindowGeometry(currentW:currentH:maxW:maxH:)``). `nil`
    /// until the first frame; the "Resize…" popover pre-fills its width/height fields from it.
    public private(set) var windowPointSize: CGSize?
    /// The MAX resizable POINT size the host reported (its display bounds), pushed by ``VideoWindowView``
    /// once the host's `displayMax` lands. `nil` until known — the popover then leaves its fields uncapped
    /// (the host still clamps server-side). The host's resize-to-display-origin makes this max reachable.
    public private(set) var windowMaxPointSize: CGSize?

    /// HOST-WINDOW RESIZE: the live view pushes the window's current + max resizable POINT sizes here.
    /// Current pre-fills the popover; max (once known) caps its fields. A zero/absent max leaves the max
    /// uncapped — and once known it persists (a later zero-max push never clears it).
    public func noteWindowGeometry(currentW: Double, currentH: Double, maxW: Double, maxH: Double) {
        if currentW > 0, currentH > 0 { windowPointSize = CGSize(width: currentW, height: currentH) }
        if maxW > 0, maxH > 0 { windowMaxPointSize = CGSize(width: maxW, height: maxH) }
    }

    /// The host-announced stream CADENCE (frames/sec), pushed by ``VideoWindowView`` on the initial cadence
    /// and every FPS-governor change. `nil` until the first lands. The sidebar's Connection section shows it
    /// as a per-pane "FPS" row (hidden for terminal panes). It is the host's negotiated encode rate — NOT a
    /// client-measured present throughput.
    public private(set) var streamFps: Int?

    /// Records the host-announced cadence. A non-positive value is ignored (a spurious zero never blanks the
    /// row — the last good reading stands). Only writes the observable on a real change.
    public func noteStreamFps(_ fps: Int) {
        guard fps > 0, streamFps != fps else { return }
        streamFps = fps
    }

    /// CONNECTION STATS: client-measured video PAYLOAD bitrate (kilobits/sec), pushed ~1 Hz by
    /// ``VideoWindowView``. Unlike ``streamFps`` a ZERO is a real reading (idle-skip = nothing flows), so it
    /// is kept; only a negative (nonsense) value is dropped. `nil` until the first report lands.
    public private(set) var streamKbps: Int?

    /// Records one ~1 Hz bitrate reading. Only writes the observable on a real change.
    public func noteStreamKbps(_ kbps: Int) {
        guard kbps >= 0, streamKbps != kbps else { return }
        streamKbps = kbps
    }

    /// STALL SCRIM: whether the stream is STALLED — the host went
    /// silent (no frame AND no 1 s host heartbeat) past the stall threshold, so the pane overlays a
    /// "Reconnecting…" scrim over the frozen last frame. Pushed by ``VideoWindowView`` on every flip (sticky
    /// through the client's self-heal rebuild — clears only when traffic actually resumes). Defaults `false`.
    public private(set) var isStreamStalled = false

    /// When the current stall was detected (`nil` while live) — drives the scrim's frame-age caption
    /// ("RECONNECTING · 12S"). Set/cleared together with ``isStreamStalled``.
    public private(set) var streamStalledAt: Date?

    /// Records a stall flip from the live view. Only writes the observable on a real change.
    public func noteStreamStalled(_ stalled: Bool) {
        guard isStreamStalled != stalled else { return }
        isStreamStalled = stalled
        streamStalledAt = stalled ? Date() : nil
    }

    /// Request an ABSOLUTE host-window POINT size from the "Resize…" popover (no-op when no sink is wired —
    /// not streaming or read-only). The host clamps to the window's achievable min/max and re-anchors at its
    /// display origin so an up-to-display-max size takes.
    public func resizeWindow(toWidth width: Double, height: Double) {
        resizeInjector?(width, height)
    }

    /// VIEWPORT CONTROLS (client-side zoom + pan-lock): the live ``VideoWindowView`` publishes this once its
    /// session exists (cleared `nil` on teardown). The bottom control bar zooms the actual-size video sublayer
    /// and freezes the edge-hover auto-pan. These are pure CLIENT compositor ops (never touch the host), so —
    /// UNLIKE ``resizeInjector`` — the sink is NOT withheld while read-only. The argument is a raw command byte
    /// (``ViewportCommand``); the `UInt8` keeps the app-target ``VideoWindowView`` decoupled from this module.
    public var viewportInjector: ((_ command: UInt8) -> Void)?

    /// Whether the footer viewport controls (zoom / lock) are live: streaming AND a viewport sink is wired.
    public var canControlViewport: Bool { active != nil && viewportInjector != nil }

    /// The client-viewport commands carried by ``viewportInjector`` as their raw `UInt8` (the structural-byte
    /// contract shared with the app-target ``VideoWindowView``, which switches on the same values).
    public enum ViewportCommand: UInt8, Sendable {
        case zoomIn = 0
        case zoomOut = 1
        case reset = 2
        case toggleLock = 3
    }

    /// Drive one client-viewport ``ViewportCommand`` through the live ``viewportInjector`` (no-op when no sink).
    public func sendViewport(_ command: ViewportCommand) { viewportInjector?(command.rawValue) }

    /// RELEASE STUCK INPUT (the manual escape hatch): a zero-arg closure ``VideoWindowView`` publishes
    /// once its session exists (via ``RemotePaneContext/onInputReleaseReady``; cleared `nil` on teardown,
    /// WITHHELD by the seam while read-only — it sends host input). Firing it synthesizes a key-UP for every
    /// held modifier + a mouse-UP for every button through the existing synthetic-release paths, clearing a
    /// modifier/button the host was left holding despite the automatic redundancy+dedup (e.g. every release
    /// datagram of a burst lost).
    public var inputReleaseInjector: (() -> Void)?

    /// Whether the palette's "Release Stuck Input" can act right now: streaming AND a live release sink
    /// is wired (withheld while read-only).
    public var canReleaseStuckInput: Bool { active != nil && inputReleaseInjector != nil }

    /// Fire the manual stuck-input release (no-op when no sink is wired — not streaming / read-only).
    public func releaseStuckInput() { inputReleaseInjector?() }

    /// Whether a paste-as-keystrokes is possible right now: streaming AND a live key sink is wired. A
    /// read-only pane has no sink (the seam withholds it, see ``keyInjector``), so this is `false` there.
    public var canPasteKeystrokes: Bool { active != nil && keyInjector != nil }

    /// The in-flight paste (cancelled if a new one starts or the pane tears down).
    private var pasteTask: Task<Void, Never>?
    /// The in-flight post-pick binding revalidation (see ``pickAndOpen(_:)``) — cancelled if the user
    /// re-picks or the pane closes, so a stale query can't unbind a freshly re-picked window. Readable so a
    /// test can `await` its completion deterministically (the setter stays private).
    @ObservationIgnored private(set) var revalidationTask: Task<Void, Never>?
    /// TEARDOWN GENERATION: bumped by every ``close()``. ``revalidateBinding()`` snapshots it before
    /// suspending on the discovery query and drops its verdict if it changed — outer-task cancellation is
    /// only cooperative, so without this a close() racing the await would let a stale `.rebind` verdict
    /// silently re-open a torn-down pane's video stream.
    @ObservationIgnored private var closeGeneration: UInt64 = 0
    /// Per-character pacing — slow enough that a secure field's focus/IME keeps up, fast enough to
    /// feel instant for a password. Injectable for deterministic tests (`.zero`).
    private let pasteInterval: Duration

    /// Transient "typed N, skipped M" result of the last paste — set only when some characters had NO
    /// US-QWERTY mapping (accents / emoji / non-Latin) and were dropped, so the user learns the paste was
    /// incomplete. Auto-clears after ``pasteFeedbackDuration``; `nil` when the last paste mapped cleanly. The
    /// payload is never stored.
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
        guard keyInjector != nil else { return encoded }
        // Surface "typed N, skipped M" when characters were dropped — BEFORE the empty-strokes return, so
        // an ALL-unmappable paste (typed 0, skipped N) still tells the user nothing was sent.
        notePasteFeedback(typed: encoded.strokes.count, skipped: encoded.skipped)
        guard !encoded.strokes.isEmpty else { return encoded }
        pasteTask?.cancel()
        let interval = pasteInterval
        let strokes = encoded.strokes
        pasteTask = Task { @MainActor [weak self] in
            for stroke in strokes {
                if Task.isCancelled { return }
                // READ-ONLY GATE: re-read the LIVE sink each iteration, not a value captured at
                // spawn. If the seam clears `keyInjector` mid-paste (pane switched to read-only), the remaining
                // strokes are withheld — keystrokes stop reaching the host (incl. a secure field) the instant
                // the lock lands, not at the end of the paste.
                guard let injector = self?.keyInjector else { return }
                injector(stroke.keyCode, true, stroke.shift)
                injector(stroke.keyCode, false, stroke.shift)
                if interval > .zero { try? await Task.sleep(for: interval) }
            }
        }
        return encoded
    }

    /// Records the transient paste feedback when characters were dropped, and schedules its auto-clear.
    /// A CLEAN paste clears any STALE banner from a prior skipped paste rather than letting it time out.
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

    /// Pre-warms the picker list from the LIVE host-window feed (see docs/45):
    /// the panel renders instantly from ≤2 s-fresh push data instead of waiting a discovery round
    /// trip; the on-appear ``refresh()`` still runs its wire round (freshness re-validated). No-op
    /// once a window is open (the same stale-stamp guard `refresh()` takes) or with nothing to show.
    public func prewarm(_ windows: [RemoteWindowSummary]) {
        guard active == nil, !windows.isEmpty else { return }
        availableWindows = windows
        loadError = nil
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
    /// The list renders only when discovery found ≥1 window (empty filter matches all), so this is always a
    /// filter-exclusion case — name the filter AND point at the fix (clearing it reveals `totalCount`
    /// windows), not the dead-end "no windows match". Pure for tests.
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

    /// The user picked `window` and wants it live. Opens optimistically (surface mounts instantly on the
    /// common case), THEN revalidates the binding against a FRESH host query.
    ///
    /// WHY not a bare `pick`+`open`: the picker list is fetched on appear and only refreshed manually, so a
    /// window can close on the host between fetch and tap. The host then rejects the dead CGWindowID SILENTLY
    /// (`helloAck(accepted:false)` → zero client effects, or the mux drops the hello) — the pane streams a
    /// permanent black surface with NO error. Revalidation re-queries the live list: if the window is gone it
    /// closes back to the picker with a ``loadError`` (the re-pick affordance); if the id was merely recycled
    /// it re-binds the same app+title; a live window is `.kept` (one extra query, no visible change). Mirrors
    /// the restored-binding self-heal (``LivePaneSession`` runs it once on restore).
    public func pickAndOpen(_ window: RemoteWindowSummary) {
        pick(window)
        open()
        revalidationTask?.cancel()
        revalidationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await revalidateBinding()
        }
    }

    // MARK: Stale-binding revalidation (PANE REBIND)

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

    /// Validates the CURRENT (typically restored) binding against the host's live window list and self-heals
    /// a stale CGWindowID via ``WindowRebind``. Called once per session by `LivePaneSession.setVideoActive`
    /// AFTER the optimistic `open()` (a stale binding re-binds within the discovery round-trip instead of
    /// sitting on a silent black pane). Best-effort: an unreachable host / missing seam changes nothing.
    public func revalidateBinding() async -> RebindOutcome {
        guard let query = RemoteWindowDiscovery.shared, let wid = parsedWindowID else { return .skipped }
        let t = target()
        // STALE-VERDICT GUARD: snapshot liveness BEFORE suspending. The spawn sites cancel
        // the outer task on teardown, but cancellation is cooperative and the discovery closure has no
        // checkpoint — so a close() (or re-pick/re-open) racing the await must be caught HERE, after the
        // query resumes, or the verdict below would act on a pane that no longer exists.
        let generation = closeGeneration
        let startedActive = active
        let windows = await query(t.host, t.mediaPort, t.cursorPort)
        // Torn down / re-targeted while the query was in flight ⇒ the verdict is stale. Acting on it
        // would silently REACTIVATE a closed pane (the `.rebind` arm re-open()s). Drop it as a no-op.
        guard !Task.isCancelled, generation == closeGeneration, active == startedActive else {
            return .skipped
        }
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

    /// TRUE from the instant this pane is resized until the host re-captures at the new size and the first
    /// SHARP frame renders — the video analogue of ``TerminalViewModel/awaitingResizeReflow``. The pane
    /// resize-scrim (``PaneContainer``) waits on it so the overlay BRIDGES the gap during which the Metal
    /// view shows the last frame STRETCHED/upscaled (blurry) before re-captured pixels arrive — instead of
    /// clearing on a fixed settle timer that uncovers the blur early. ``VideoWindowView`` drives it:
    /// ``noteResized()`` on a layout-size change (prompts the 1:1 host re-capture), ``noteRendered()`` on the
    /// first frame at the new native size. A safety timeout + ``close()`` clear it so it can never stick.
    /// (The live-video pane mount is deferred — see ``PaneContainer`` — so this seam is test-exercised today.)
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

    /// TERMINAL REFUSAL: the host REJECTED the live session (`helloAck(accepted: false)` — the window is
    /// gone on the host / version mismatch, incl. the mux mint-failure refusal). The video pipeline has
    /// already torn itself down WITHOUT the bye path's auto-rebuild (a rebuild would re-hello the same
    /// doomed request forever), so the pane must not keep a dead black surface: leave ``active`` and fall
    /// back to the picker with a ``loadError`` explaining why — the same fallback the stale-binding
    /// revalidation's `.unresolved` arm takes. No-op when nothing is active (a late/duplicate refusal
    /// after a user close must not stamp an error onto a fresh picker).
    public func noteSessionRejected() {
        guard active != nil else { return }
        let name = title.isEmpty ? "That window" : "“\(title)”"
        close()
        loadError = "\(name) is no longer available on the host — pick a window."
    }

    /// Closes the remote window (tears down the live view → its orchestrator `stop()`).
    public func close() {
        active = nil
        closeGeneration &+= 1 // invalidate any in-flight revalidateBinding() verdict (see its guard)
        pasteTask?.cancel() // a torn-down pane must not keep injecting a paste-in-flight into the host
        // Cancel any in-flight post-pick revalidation. Cancellation alone is COOPERATIVE (the discovery
        // await is not a reliable checkpoint), so the real teardown guarantee is `closeGeneration` above:
        // revalidateBinding() snapshots it before suspending and drops a verdict that lands after this
        // close — a stale query can never re-open a torn-down pane. Safe against self-cancel from the
        // `.rebound` path (which calls close() then re-open()s synchronously — its guard already passed
        // before that close, and there is no further suspension point).
        revalidationTask?.cancel()
        endAwaitingReflow() // a closed window will not re-capture — never leave the scrim hung
        isStreamStalled = false // a closed pane shows the picker, not a stale "Reconnecting…" scrim
    }
}
