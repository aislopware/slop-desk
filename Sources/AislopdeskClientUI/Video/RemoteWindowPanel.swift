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
@MainActor
@Observable
public final class RemoteWindowModel {
    // MARK: Entry fields (bound to the form)

    /// Which host-side window to mirror (set by the picker, or typed in the manual fallback). Host/ports
    /// come from the app target.
    public var windowID: String
    public var title: String

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

    public init(
        target: @escaping @MainActor () -> ConnectionTarget = { .default },
        windowID: String = "",
        title: String = "Remote window"
    ) {
        self.target = target
        self.windowID = windowID
        self.title = title
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

    /// Picks a window from the list: fills ``windowID`` + ``title`` (the caller then ``open()``s).
    public func pick(_ summary: RemoteWindowSummary) {
        windowID = String(summary.windowID)
        title = summary.title.isEmpty ? summary.appName : summary.title
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
            cursorPort: t.cursorPort
        )
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
                windowList
            } else if model.isLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading windows…").foregroundStyle(.secondary) }
            }

            if let error = model.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Manual fallback — collapsed by default; the escape hatch when discovery is unavailable.
            DisclosureGroup("Enter a window id manually") {
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
    }

    /// The tappable list of discovered host windows. Choosing one fills the id+title and opens it.
    private var windowList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(model.availableWindows) { window in
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
