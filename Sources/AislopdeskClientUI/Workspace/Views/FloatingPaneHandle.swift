#if canImport(SwiftUI)
import SwiftUI

// MARK: - PanePresentation (shared handle/header derivations)

/// The pane-presentation derivations shared by the floating pill, its menu, and the compact
/// carousel's ``PaneChromeView`` header — one source of truth so the surfaces can never drift
/// (the exact pattern ``PaneConnectionStatus`` set for the dot).
@MainActor
enum PanePresentation {
    /// The connection-status presentation (production handle only; a `.remoteGUI` / faked handle has
    /// no PATH-1 connection ⇒ `.none` ⇒ no dot).
    static func connectionStatus(_ handle: (any PaneSessionHandle)?) -> PaneConnectionStatus {
        PaneConnectionStatus.from((handle as? LivePaneSession)?.connection?.status)
    }

    /// Whether an OSC 133 command is currently executing in this pane's shell (the protocol-level
    /// ``PaneSessionHandle/isShellBusy`` — the same signal the store's busy-close guard consults).
    static func isRunning(_ handle: (any PaneSessionHandle)?) -> Bool {
        handle?.isShellBusy ?? false
    }

    /// The smoothed app-layer ping/pong RTT (`nil` until the first sample).
    static func latencyMS(_ handle: (any PaneSessionHandle)?) -> Double? {
        (handle as? LivePaneSession)?.connection?.latencyMS
    }

    /// A one-line summary of the most recently FINISHED command (OSC 133;D) on this pane — exit status
    /// + duration — or `nil` when none has run. `lastCommand` was captured but never surfaced; this is
    /// the formatter the pill tooltip uses so "did my last command pass, and how long?" is answerable.
    static func lastCommandSummary(_ handle: (any PaneSessionHandle)?) -> String? {
        guard let lc = (handle as? LivePaneSession)?.terminalModel?.lastCommand else { return nil }
        return formatCommandResult(exitCode: lc.exitCode, durationMS: lc.durationMS)
    }

    /// Pure formatter for an OSC-133 command result: a green-check / cross prefix by exit status, plus a
    /// human duration ("340ms" / "1.2s" / "2m 3s"). Exposed (and tested) independently of any handle.
    static func formatCommandResult(exitCode: Int32?, durationMS: UInt32) -> String {
        let ms = Int(durationMS)
        let duration: String
        if ms < 1000 {
            duration = "\(ms)ms"
        } else if ms < 60000 {
            duration = String(format: "%.1fs", Double(ms) / 1000)
        } else {
            let totalSeconds = ms / 1000
            duration = "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        guard let code = exitCode else { return duration } // host reported no exit code
        return code == 0 ? "✓ \(duration)" : "✗ exit \(code) · \(duration)"
    }

    /// The display title: the LIVE OSC 0/2 terminal title when the shell has set one, else the static
    /// `spec.title` (whitespace-only titles fall back so a pane is never blank).
    static func displayTitle(_ handle: (any PaneSessionHandle)?, spec: PaneSpec) -> String {
        let raw: String =
            if let live = (handle as? LivePaneSession)?.terminalModel?.title,
            !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                live
            } else {
                spec.title
            }
        // A remote shell controls the OSC title; mask any secret before it lands on the sidebar / pill /
        // bookmark name (the title flows to several persistent surfaces). Gated so it is an opt-out.
        return SettingsKey.redactSecretsEnabled ? SecretRedactor.redact(raw) : raw
    }
}

// MARK: - FloatingPaneHandle (the pane pill — the one borderless-pane affordance)

/// The single floating control of a borderless canvas pane: a small material capsule at the pane's
/// top-centre (the iPadOS-multitasking-pill idiom — top-centre avoids the shell prompt at top-left,
/// line starts, and all four corner resize grips) that replaces the whole header bar. It carries the
/// pane's kind glyph (accent-tinted when focused — a focus cue now that the ring border is gone) and
/// the shared ``PaneStatusDot``; the SAME pill expands to show — in priority order — trouble status
/// text with a live retry countdown, a latched RTT badge (>100ms with a 110/90 hysteresis band so the
/// width can't pop at the boundary), a "running…" cue, or a quiet truncated TITLE (always on iOS;
/// hover/focus on macOS) — so removing the header loses no information.
///
/// Interaction is attached by the OWNER (``CanvasItemView`` keeps the `@GestureState` move preview):
/// hold + drag MOVES the pane, a plain click focuses it and toggles ``menuShown`` (the
/// ``PaneMenuView`` popover). This view is purely visual + presentation (popover / help / hover /
/// scroll-forwarding / accessibility) so the gesture wiring stays where the canvas geometry lives.
struct FloatingPaneHandle: View {
    let id: PaneID
    let spec: PaneSpec
    /// The live session, for the status presentation + menu (read-only).
    let handle: (any PaneSessionHandle)?
    let isFocused: Bool
    /// Maximized pane: the pill cannot move it — the affordance copy + cursor say click-only (the
    /// owner's gesture already guards the drag out).
    var isMaximized: Bool = false
    let store: WorkspaceStore
    /// The menu popover toggle — owned by ``CanvasItemView`` (its drag gesture's click branch toggles it).
    @Binding var menuShown: Bool

    @State private var hovering = false
    /// Latched ">100ms" RTT badge with an engage/release band (110/90ms) so the pill width does not
    /// pop on every 3s sample when the RTT hovers at the boundary (the CanvasSnap hysteresis idea).
    @State private var laggyLatched = false

    /// Visual pill height (the hit target is taller — see the platform padding below).
    private static let pillHeight: CGFloat = 20

    var body: some View {
        let status = PanePresentation.connectionStatus(handle)
        let trouble = Self.isTrouble(status)
        let running = PanePresentation.isRunning(handle) && status.phase == .connected
        let latency = PanePresentation.latencyMS(handle)
        let laggy = laggyLatched && status.phase == .connected
        // The terminal rang while this pane was UNFOCUSED → an attention badge until you look at it
        // (focusing the pane clears it via store.focus → handle.clearBell).
        let bellRang = (handle?.bellPending ?? false) && !isFocused

        HStack(spacing: 5) {
            Image(systemName: PaneLeafView.icon(for: spec.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            PaneStatusDot(status: status, running: running)
            if bellRang {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("The terminal rang the bell")
                    .transition(.scale.combined(with: .opacity))
            }
            // ONE expansion slot, in salience order: trouble > laggy RTT > running > quiet title.
            if trouble {
                statusText(status)
            } else if laggy, let latency {
                Text("\(Int(latency.rounded()))ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
                    .help("Smoothed round-trip time to the host (3s ping)")
            } else if running {
                Text("running…")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                titleText
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.pillHeight)
        .frame(minWidth: 44)
        #if os(macOS)
            // Constraint 5 (the BUG-2 class): a scroll over the pill must PAN THE CANVAS, not be
            // swallowed — the proven gripBase/old-header pattern (a real NSView wins scroll hit-testing;
            // it overrides ONLY scrollWheel, so the SwiftUI drag/tap on top are untouched).
            .background { ScrollPanForwarder(store: store) }
        #endif
            .background(hovering ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
        // Taller hit target than the visual pill: 44×28 on macOS (pointer-precise); 44pt tall on iOS
        // (the HIG touch minimum — the extra reach over the top terminal row converts a near-miss
        // selection into a successful pill grab, and the 10pt dead zone absorbs tap jitter).
        #if os(iOS)
            .padding(.vertical, 12)
        #else
            .padding(.vertical, 4)
        #endif
            .contentShape(Rectangle())
            // Quiet when idle; fully opaque when it matters. A pane in trouble — or one actively running
            // a command — is NEVER 70%-transparent.
            .opacity(trouble || running || bellRang || hovering || menuShown || isFocused ? 1 : 0.7)
            .animation(.easeOut(duration: 0.12), value: bellRang)
            .animation(.easeOut(duration: 0.12), value: trouble)
            .animation(.easeOut(duration: 0.12), value: running)
            .animation(.easeOut(duration: 0.12), value: laggy)
            .animation(.easeOut(duration: 0.12), value: hovering)
            // The latch: engage past 110ms, release under 90ms; drop instantly when not connected.
            .onChange(of: latency ?? 0) { _, ms in
                if status.phase != .connected { laggyLatched = false } else if !laggyLatched,
                                                                               ms > 110 { laggyLatched = true }
                else if laggyLatched,
                        ms < 90 { laggyLatched = false }
            }
            .onHover { inside in
                hovering = inside
                #if os(macOS)
                if inside { (isMaximized ? NSCursor.arrow : NSCursor.openHand).push() } else { NSCursor.pop() }
                #endif
            }
            .popover(isPresented: $menuShown, arrowEdge: .bottom) {
                // NOTE: deliberately NO `.onDisappear { store.focus(id) }` here — the main window's
                // first responder survives the popover's key-window stint, and re-focusing would RAISE
                // this pane, stealing focus/z from whatever the user clicked to dismiss the popover.
                PaneMenuView(id: id, spec: spec, handle: handle, store: store, isPresented: $menuShown)
                #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                #endif
            }
            .help(helpText)
            // ONE accessibility element with the live state folded into the label (children are visual
            // duplicates), activatable: VoiceOver reads title + status + activity and can open the menu.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(axLabel(status: status, running: running, latency: latency)))
            .accessibilityHint(Text(isMaximized ? "Activate for pane actions"
                    : "Drag to move the pane; activate for pane actions"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                store.focus(id)
                menuShown = true
            }
    }

    /// The quiet at-a-glance pane title (the old header's job): always on iOS (no hover there);
    /// hover/focus-revealed on macOS so unfocused panes stay minimal.
    @ViewBuilder
    private var titleText: some View {
        #if os(iOS)
        titleLabel
        #else
        if hovering || isFocused { titleLabel }
        #endif
    }

    private var titleLabel: some View {
        Text(PanePresentation.displayTitle(handle, spec: spec))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 160)
    }

    private var helpText: String {
        let title = PanePresentation.displayTitle(handle, spec: spec)
        // Surface the last command's exit + duration (OSC 133;D) — captured but previously invisible.
        let lastCmd = PanePresentation.lastCommandSummary(handle).map { "\nLast command: \($0)" } ?? ""
        #if os(macOS)
        return (isMaximized
            ? "\(title) — click for actions"
            : "\(title) — drag to move (hold ⌘ for a free drag), click for actions") + lastCmd
        #else
        return title + lastCmd
        #endif
    }

    /// The composed VoiceOver label: title + connection state + activity + lag, in one element.
    /// Internal so it is unit-testable like ``reconnectLabel``.
    func axLabel(status: PaneConnectionStatus, running: Bool, latency: Double?) -> String {
        var parts = ["Pane handle: \(PanePresentation.displayTitle(handle, spec: spec))"]
        if status.showsDot {
            parts.append(status.detailedLabel)
            if running { parts.append("command running") }
            if status.phase == .connected, let latency, latency > 100 {
                parts.append("latency \(Int(latency.rounded())) milliseconds")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// The phases that expand the pill (the header used to carry these — a borderless pane must not
    /// look merely idle while its session is dying).
    static func isTrouble(_ status: PaneConnectionStatus) -> Bool {
        switch status.phase {
        case .connecting,
             .reconnecting,
             .unreachable,
             .failed: true
        case .connected,
             .idle,
             .none: false
        }
    }

    private func statusText(_ status: PaneConnectionStatus) -> some View {
        Group {
            if status.phase == .reconnecting, let nextRetry = status.nextRetry {
                // Live "retrying in Ns" countdown — same TimelineView discipline as the old header
                // (1 Hz refresh, no store mutation).
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.reconnectLabel(status, now: context.date, nextRetry: nextRetry))
                }
            } else {
                Text(status.detailedLabel)
            }
        }
        .font(.caption2)
        .foregroundStyle(statusColor(status))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 220)
        .help(status.detailedLabel)
    }

    private func statusColor(_ status: PaneConnectionStatus) -> Color {
        switch status.phase {
        case .connecting: .secondary
        case .reconnecting: .orange
        default: .red
        }
    }

    /// "Reconnecting (n) — retrying in Ns", clamping at 0 (the attempt is firing now). Ported
    /// verbatim from the header so the wording stays identical.
    static func reconnectLabel(_ status: PaneConnectionStatus, now: Date, nextRetry: Date) -> String {
        let remaining = Int(nextRetry.timeIntervalSince(now).rounded(.up))
        guard remaining > 0 else { return status.label }
        return "\(status.label) retrying in \(remaining)s"
    }
}

// MARK: - PaneDeadScrim (terminal failure states get a big, honest affordance)

/// A dimming scrim over a pane whose connection is terminally dead (`.unreachable` / `.failed`
/// ONLY — never the transient connecting/reconnecting states, so it cannot flicker): the body
/// content is stale anyway, so dim it and offer the whole pane as a "click to reconnect" target.
/// Scroll over the scrim still pans the canvas (the ``ScrollPanForwarder`` hit fill). The owner
/// suppresses the in-leaf failure banner while this is shown, so the reason is stated exactly once.
struct PaneDeadScrim: View {
    let status: PaneConnectionStatus
    let store: WorkspaceStore
    let onReconnect: () -> Void

    /// Shown for the terminal failure phases only.
    static func isShown(_ status: PaneConnectionStatus) -> Bool {
        status.phase == .unreachable || status.phase == .failed
    }

    var body: some View {
        ZStack {
            #if os(macOS)
            ScrollPanForwarder(store: store)
            #endif
            Color.black.opacity(0.35)
            VStack(spacing: 6) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                Text(status.detailedLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                #if os(iOS)
                Text("Tap to reconnect")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                #else
                Text("Click to reconnect")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                #endif
            }
            .padding(12)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onReconnect)
        .accessibilityLabel(Text("\(status.detailedLabel). Reconnect"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - PaneMenuView (the pill's click menu)

/// The action menu behind the floating pill: a popover with the pane's identity + live status at the
/// top (the information the header used to show) and the actions the header's buttons used to carry —
/// all funnelled through the store's pure mutations, so the menu holds (almost) no state of its own.
/// A custom popover (NEVER SwiftUI `Menu` on the pill itself — it opens its tracking on mouseDown and
/// the drag dies; NEVER `NSMenu` — its event-tracking runloop stalls the display-link video panes).
struct PaneMenuView: View {
    let id: PaneID
    let spec: PaneSpec
    let handle: (any PaneSessionHandle)?
    let store: WorkspaceStore
    @Binding var isPresented: Bool

    /// Interaction prefs (NOT document state): shared with ``CanvasItemView``'s solver config and
    /// ``CanvasView``'s grid — and the only snap-disable path on iOS (no ⌘ key there).
    @AppStorage(SettingsKey.snapPanes) private var snapPanes = true
    @AppStorage(SettingsKey.snapGrid) private var snapGrid = true
    @AppStorage(SettingsKey.showGrid) private var showGrid = true
    @AppStorage(SettingsKey.nonOverlap) private var nonOverlap = true

    @State private var groupSectionExpanded = false
    /// Inline rename, hosted HERE (the sidebar's inline-rename field is unreachable when the sidebar
    /// column is hidden — the menu must not silently no-op). Mirrors `PaneSidebarView`'s commit rule.
    @State private var renaming = false
    @State private var renameDraft = ""
    /// A paste the secret-aware guard flagged, parked behind a confirmation (nil = nothing pending).
    @State private var pendingPaste: PendingPaste?

    private struct PendingPaste: Identifiable {
        let id = UUID()
        let text: String
        let risk: PasteRisk
        let remote: RemoteWindowModel
    }

    private var isZoomed: Bool { store.workspace.maximizedPane == id }
    private var status: PaneConnectionStatus { PanePresentation.connectionStatus(handle) }
    private var groupID: PaneGroupID? { store.workspace.canvas.item(id)?.groupID }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Divider().padding(.vertical, 4)

            // Reconnect leads when a retry can help (terminal failures, a stuck retry loop, idle).
            if canReconnect {
                row("Reconnect", systemImage: "arrow.clockwise") {
                    store.reconnect(id)
                }
                Divider().padding(.vertical, 4)
            }

            row(
                isZoomed ? "Restore" : "Maximize",
                systemImage: isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            ) {
                store.focus(id) // maximize acts on the focused pane — ensure it's this one first
                store.toggleZoom()
            }
            row("Center in View", systemImage: "scope") {
                store.centerOnPane(id)
            }
            // A streaming remote-window pane can swap which host window it mirrors WITHOUT
            // close-and-recreate: `close()` re-enters the picker form (the SwiftUI dismantle of the
            // live view is the proven teardown path), which auto-refreshes the window list on appear.
            if let remote = (handle as? LivePaneSession)?.remoteWindow, remote.active != nil {
                row("Change Window…", systemImage: "macwindow.on.rectangle") {
                    remote.close()
                }
                // PASTE AS KEYSTROKES: type the clipboard into the remote window as HID key events —
                // works in sudo / SecurityAgent password fields where normal paste is OS-dropped.
                if remote.canPasteKeystrokes {
                    row("Paste as Keystrokes", systemImage: "keyboard") {
                        pasteAsKeystrokes(into: remote)
                    }
                    // PASTE RECENT: replay an older clip from the clipboard ring (not just the live board).
                    if !store.clipboardRing.isEmpty {
                        pasteRecentMenu(into: remote)
                    }
                }
                // RESIZE TO NATIVE: snap a manually-resized remote pane back to its crisp 1:1 stream size.
                if store.hasNativeSize(id) {
                    row("Resize to Native Stream Size", systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
                        store.resizeToNativeSize(id)
                    }
                }
            }
            renameRow

            Divider().padding(.vertical, 4)

            newPaneRow
            // Duplicate THIS pane (not the focused one): spec + endpoint + group + size come along.
            row("Duplicate Pane", systemImage: "plus.square.on.square") {
                store.duplicatePane(id)
            }
            groupSection

            Divider().padding(.vertical, 4)

            snapToggles

            Divider().padding(.vertical, 4)

            row(store.isOnlyLeaf(id) ? "Close Last Pane" : "Close Pane", systemImage: "xmark", role: .destructive) {
                // Through the busy-shell guard: a pane mid-command parks behind the root view's
                // confirmation dialog instead of killing the command outright.
                store.requestClosePane(id)
            }
        }
        .padding(10)
        .frame(minWidth: 240, alignment: .leading)
        .confirmationDialog(
            "Paste as Keystrokes?",
            isPresented: Binding(get: { pendingPaste != nil }, set: { if !$0 { pendingPaste = nil } }),
            presenting: pendingPaste,
        ) { pending in
            if pending.risk != .tooLarge {
                Button("Paste Anyway", role: .destructive) {
                    pending.remote.pasteAsKeystrokes(pending.text)
                    pendingPaste = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingPaste = nil }
        } message: { pending in
            Text(Self.pasteWarning(pending.risk))
        }
    }

    // MARK: Header (identity + live status — what the old header bar showed)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: PaneLeafView.icon(for: spec.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if renaming {
                    TextField("Pane name", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit { commitRename() }
                } else {
                    Text(PanePresentation.displayTitle(handle, spec: spec))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if status.showsDot {
                HStack(spacing: 6) {
                    PaneStatusDot(status: status, running: PanePresentation.isRunning(handle))
                    Text(status.detailedLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if case .connected = status.phase, let ms = PanePresentation.latencyMS(handle) {
                        Text(ms < 1 ? "<1ms" : "\(Int(ms.rounded()))ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(ms > 100 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                            .help("Smoothed round-trip time to the host (3s ping)")
                    }
                    if PanePresentation.isRunning(handle) {
                        Text("running…")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Rename (in-popover — self-contained, sidebar-independent)

    /// Swaps the header title for an editable field; commit on ⏎ writes `spec.title` through the
    /// store (the `PaneSidebarView.commitPaneRename` rule: trimmed, empty keeps the old name). The
    /// popover STAYS OPEN during the edit — this row is deliberately not a dismissing `row(...)`.
    private var renameRow: some View {
        Button {
            renameDraft = spec.title
            renaming = true
        } label: {
            Label("Rename…", systemImage: "pencil")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
    }

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.updateSpec(id) { $0.title = trimmed }
        }
        renaming = false
    }

    /// Reads the local clipboard and replays it into `remote` as HID keystrokes (the secure-field
    /// typing path). The payload is read here and handed straight to the model — it is NEVER logged
    /// or stored anywhere observable (it is frequently a password). Note: the LIVE board content is
    /// already in the clipboard ring via the monitor, so we don't re-record it here.
    private func pasteAsKeystrokes(into remote: RemoteWindowModel) {
        #if os(macOS)
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        deliverPaste(text, into: remote)
        #endif
    }

    /// Routes a paste through the secret-aware guard: an `.ok` payload types immediately; a risky one
    /// (a credential into an echoing field, a bulk blob into a password field, an over-long payload)
    /// parks behind a confirmation the user can still proceed through.
    private func deliverPaste(_ text: String, into remote: RemoteWindowModel) {
        let secure = (handle as? LivePaneSession)?.isSecureDialog ?? false
        let risk = remote.assessPaste(text, targetIsSecure: secure)
        if risk == .ok {
            remote.pasteAsKeystrokes(text)
        } else {
            pendingPaste = PendingPaste(text: text, risk: risk, remote: remote)
        }
    }

    private static func pasteWarning(_ risk: PasteRisk) -> String {
        switch risk {
        case .secretIntoInsecureField:
            "The clipboard looks like a secret, but this isn’t a password field — it may be typed "
                + "where it shows in plain text. Paste anyway?"
        case .bulkIntoSecureField:
            "You’re about to type many lines / a large blob into a password field. That’s usually a mis-paste. Paste anyway?"
        case .tooLarge:
            "The clipboard is too long to type as keystrokes safely."
        case .ok:
            ""
        }
    }

    /// A submenu listing the recent clips; choosing one replays it into `remote` as keystrokes. Each
    /// row shows a single-line preview (truncated) — never the full secret.
    private func pasteRecentMenu(into remote: RemoteWindowModel) -> some View {
        Menu {
            ForEach(Array(store.clipboardRing.enumerated()), id: \.offset) { _, clip in
                Button(Self.clipPreview(clip, redact: SettingsKey.redactSecretsEnabled)) {
                    isPresented = false
                    deliverPaste(clip, into: remote)
                }
            }
            Divider()
            Button("Clear History", role: .destructive) { store.clearClipboardRing() }
        } label: {
            Label("Paste Recent", systemImage: "list.clipboard")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
    }

    /// A one-line, length-capped preview of a clip for a menu row (whitespace collapsed; never the whole
    /// payload). When `redact`, likely secrets (access keys, bearer tokens, `PASSWORD=…`) are masked
    /// FIRST — so a copied credential isn't shown in plaintext in the "Paste Recent" menu (where it could
    /// be shoulder-surfed / screen-recorded) even though the stored clip stays usable for the paste.
    /// Internal (not private) so the redaction behaviour is unit-testable.
    static func clipPreview(_ clip: String, redact: Bool) -> String {
        let source = redact ? SecretRedactor.redact(clip) : clip
        let oneLine = source.split(whereSeparator: \.isNewline).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }

    // MARK: Sections

    /// The add-pane KIND picker as one inline row (popovers don't nest submenus well). The new pane
    /// cascades off THIS pane (focused first) and inherits its group.
    private var newPaneRow: some View {
        HStack(spacing: 8) {
            Label("New Pane", systemImage: "plus")
            Spacer(minLength: 12)
            kindButton(.terminal, help: "New Terminal")
            kindButton(.claudeCode, help: "New Claude Code")
            kindButton(.remoteGUI, help: "New Remote Window")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
    }

    private func kindButton(_ kind: PaneKind, help: String) -> some View {
        Button {
            isPresented = false
            let group = groupID
            Task { @MainActor in
                store.focus(id)
                store.addPane(kind: kind, inGroup: group)
            }
        } label: {
            Image(systemName: PaneLeafView.icon(for: kind))
                .frame(width: 22, height: 18)
        }
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Group membership: assign to an existing group (checkmark on the current one), create a new
    /// group with this pane in it, or remove from the current group.
    private var groupSection: some View {
        DisclosureGroup(isExpanded: $groupSectionExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.workspace.groups) { group in
                    row(group.name, systemImage: groupID == group.id ? "checkmark" : "rectangle.3.group") {
                        store.assignPane(id, toGroup: group.id)
                    }
                }
                row("New Group", systemImage: "plus.rectangle.on.rectangle") {
                    let gid = store.addGroup(name: "Group \(store.workspace.groups.count + 1)")
                    store.assignPane(id, toGroup: gid)
                }
                if groupID != nil {
                    row("Remove from Group", systemImage: "minus.circle") {
                        store.assignPane(id, toGroup: nil)
                    }
                }
            }
            .padding(.leading, 6)
        } label: {
            Label("Group", systemImage: "rectangle.3.group")
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
        }
    }

    /// The interaction prefs the canvas consumes live (also the iOS snap-disable path; the same
    /// toggles are surfaced app-globally in the View menu for discoverability).
    private var snapToggles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Snap to Panes", isOn: $snapPanes)
            #if os(macOS)
                .help("Magnetic alignment to other panes. Hold ⌘ while dragging to bypass.")
            #endif
            Toggle("Snap to Grid", isOn: $snapGrid)
            #if os(macOS)
                .help("Quantize free drags to the 16pt grid. Hold ⌘ while dragging to bypass.")
            #endif
            Toggle("Show Grid", isOn: $showGrid)
            Toggle("Keep From Overlapping", isOn: $nonOverlap)
            #if os(macOS)
                .help(
                    "Windows slide along each other and groups part to make room, instead of overlapping. Hold ⌘ while dragging to bypass.",
                )
            #endif
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
        .font(.callout)
        .padding(.horizontal, 2)
    }

    /// Reconnect is offered exactly when a retry can help: terminal failure states, a stuck
    /// reconnect loop (force a retry NOW), and deliberate idle.
    private var canReconnect: Bool {
        switch status.phase {
        case .idle,
             .reconnecting,
             .unreachable,
             .failed: true
        default: false
        }
    }

    // MARK: Row

    /// One menu row. Dismisses the popover FIRST, then mutates on the next runloop turn — a mutation
    /// like `closePane` removes the popover's anchor, and tearing the anchor down mid-dismissal is
    /// the kind of AppKit edge this sidesteps for free.
    private func row(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping @MainActor () -> Void,
    ) -> some View {
        Button(role: role) {
            isPresented = false
            Task { @MainActor in action() }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
    }
}
#endif
