#if canImport(SwiftUI)
import SwiftUI

/// Holds the state for opening one remote GUI window (PATH 2 / Phase 4) and the resulting
/// ``RemoteWindowDescriptor`` once the user opens it. `@MainActor @Observable` so ``RemoteWindowPanel``
/// binds directly.
///
/// PATH 2 is the SECONDARY path (terminal-first). The host's shareable windows are discovered over the
/// wire (docs/31): ``refresh()`` queries them via ``RemoteWindowDiscovery`` and the panel shows a PICKER;
/// tapping a row ``pick(_:)``s it and opens. A manual window-id field stays as a fallback for when
/// discovery is unavailable (no host support / empty list / timeout).
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

    // MARK: Paste as Keystrokes (virtual-HID typing into secure fields)

    /// The live key-injection sink the gated ``VideoWindowView`` publishes (via
    /// ``RemotePaneContext/onKeyInjectorReady``) once its session exists, and clears (`nil`) on
    /// teardown. Each call drives the host's per-event input path, which routes to the virtual-HID
    /// keyboard under Secure Event Input — so this types into `sudo` / SecurityAgent password fields
    /// where the unicode `.text` path is OS-dropped. `(keyCode, down, shift)`.
    public var keyInjector: ((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?

    /// Whether a paste-as-keystrokes is possible right now: streaming AND a live key sink is wired.
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

    /// Closes the remote window (tears down the live view → its orchestrator `stop()`).
    public func close() {
        active = nil
    }
}

/// The PATH 2 panel: an endpoint-entry form, then the live remote-GUI-window view once opened.
///
/// When no window is active it shows the connect form; when active it shows
/// ``VideoWindowFactory/make(_:)`` (the app-injected `VideoWindowView`, or the gated
/// placeholder if no factory was registered) plus — when ``showCloseButton`` is `true` — a
/// Close row.
///
/// ### `showCloseButton` (WF5, docs/22 §7)
/// Inside the workspace a `.remoteGUI` leaf is wrapped in ``PaneChromeView``, whose header
/// already owns the per-pane close affordance, so the panel's own Close row is redundant and
/// `showCloseButton` defaults to `false`. Any standalone caller (a sheet, a preview) that wants
/// the inline Close passes `showCloseButton: true`. The SwiftUI dismantle →
/// ``VideoWindowPipeline`` `deactivate()` backstop is unaffected — it lives in the
/// `VideoWindowView` the factory makes, NOT in this Close row, so hiding the row never strands a
/// live decode pipeline.
public struct RemoteWindowPanel: View {
    @Bindable private var model: RemoteWindowModel
    /// The picker's live filter (view state — resets when the pane re-enters the form).
    @State private var filter: String = ""
    /// Whether the manual-window-id fallback is expanded. Auto-expands whenever discovery errors —
    /// the escape hatch must be VISIBLE exactly when it is needed, not folded behind a disclosure.
    @State private var manualExpanded = false
    /// Whether to draw the inline Close row beneath the live video (docs/22 §7). Default `false`:
    /// in the workspace the pane chrome owns close.
    private let showCloseButton: Bool
    /// Canvas behaviour for this pane (active state + activate/canvas-scroll callbacks), threaded to the
    /// gated video view. Defaults to `.standalone` so sheet/preview callers render normally.
    private let paneContext: RemotePaneContext

    public init(model: RemoteWindowModel, showCloseButton: Bool = false, paneContext: RemotePaneContext = .standalone) {
        _model = Bindable(model)
        self.showCloseButton = showCloseButton
        self.paneContext = paneContext
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let descriptor = model.active {
                VideoWindowFactory.make(descriptor, context: paneContext)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) { pasteFeedbackBanner }
                if showCloseButton {
                    HStack {
                        Text(descriptor.title)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button("Close", role: .destructive) { model.close() }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial)
                }
            } else {
                entryForm
            }
        }
    }

    /// Transient notice when a paste-as-keystrokes dropped unmappable characters (accents / emoji /
    /// non-Latin / over the length cap), so an incomplete paste is never silent. Tap to dismiss.
    @ViewBuilder
    private var pasteFeedbackBanner: some View {
        if let fb = model.pasteFeedback {
            Button {
                model.dismissPasteFeedback()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Typed \(fb.typed), skipped \(fb.skipped) unsupported character\(fb.skipped == 1 ? "" : "s")")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(Color.orange.opacity(0.92), in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .help("Some characters have no US-QWERTY keystroke and were skipped.")
        }
    }

    private var entryForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Pick a window to stream")
                    .font(.headline)
                if model.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Refresh the window list")
                .disabled(model.isLoading)
            }

            // Keep an already-loaded list VISIBLE during a reload (the spinner is in the header) so a
            // Refresh doesn't flash the list away; only show the inline spinner on the FIRST load.
            if !model.availableWindows.isEmpty {
                // Filter field: a busy host serves 10+ windows — scroll-blind without one. Token-AND
                // over title + app name (RemoteWindowModel.filtered, pure + tested).
                TextField("Filter by title or app", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
                windowList
            } else if model.isLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small)
                    Text("Loading windows…").foregroundStyle(.secondary)
                }
            }

            if let error = model.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Manual fallback — collapsed by default; the escape hatch when discovery is unavailable.
            // AUTO-EXPANDS on a discovery error (below): visible exactly when it's needed.
            DisclosureGroup("Enter a window id manually", isExpanded: $manualExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    field("window id", text: $model.windowID, kind: .number)
                    field("title (optional)", text: $model.title, kind: .plain)
                    Button("Open") { model.open() }
                        .disabled(!model.canOpen)
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Auto-discover on appear (manual Refresh re-runs it).
        .task { await model.refresh() }
        // Reveal the manual fallback the moment discovery reports a problem (it stays open — a user
        // who collapsed it mid-error can re-open it, but a NEW error re-reveals).
        .onChange(of: model.loadError) { _, error in
            if error != nil { manualExpanded = true }
        }
        .onAppear { if model.loadError != nil { manualExpanded = true } }
    }

    /// The tappable list of discovered host windows (filter applied). Choosing one fills the
    /// id+title and opens it.
    private var windowList: some View {
        let visible = RemoteWindowModel.filtered(model.availableWindows, query: filter)
        return ScrollView {
            VStack(spacing: 0) {
                if visible.isEmpty {
                    Text(RemoteWindowModel.windowFilterEmptyMessage(
                        filter: filter,
                        totalCount: model.availableWindows.count,
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                }
                ForEach(visible) { window in
                    Button {
                        model.pick(window)
                        model.open()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "macwindow")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(window.title.isEmpty ? window.appName : window.title)
                                    .lineLimit(1)
                                Text("\(window.appName) · \(window.width)×\(window.height)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 320)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private enum FieldKind { case url, number, plain }

    @ViewBuilder
    private func field(_ prompt: String, text: Binding<String>, kind: FieldKind) -> some View {
        let tf = TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        #if os(iOS)
        switch kind {
        case .url:
            tf.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        case .number:
            tf.keyboardType(.numberPad)
        case .plain:
            tf
        }
        #else
        tf
        #endif
    }
}
#endif
