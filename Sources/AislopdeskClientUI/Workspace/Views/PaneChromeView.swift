#if canImport(SwiftUI)
import SwiftUI

// MARK: - PaneChromeView (per-pane header + focus ring)

/// The per-pane chrome that wraps every leaf's content (docs/22 §3, §7): a thin header bar
/// (kind glyph + title + connection-status dot + split-H / split-V / zoom / close buttons) over the
/// content, plus a focus ring when the pane is focused.
///
/// All actions funnel through the store's pure mutations (`split`, `toggleZoom`, `closePane`), so the
/// chrome holds no state of its own — it is a thin, declarative skin. Buttons are monochrome SF
/// Symbols in the native toolbar idiom; the focus ring is a 1.5pt accent stroke that appears only on
/// the focused pane so the user always knows where keyboard input goes.
struct PaneChromeView<Content: View>: View {
    /// The leaf this chrome wraps.
    let id: PaneID
    /// The leaf's intent (kind + title) — drives the header glyph and label.
    let spec: PaneSpec
    /// The live session, for the header status dot (read-only).
    let handle: (any PaneSessionHandle)?
    /// Whether this pane is focused (shows the ring + a brighter header).
    let isFocused: Bool
    /// Whether the tab is currently maximized on THIS pane (flips the maximize button's glyph/intent).
    let isZoomed: Bool
    /// The store, for the chrome's mutations.
    let store: WorkspaceStore
    /// The wrapped content (the leaf view).
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            // The focus ring: an accent stroke on the focused pane only (docs/22 §3 affordance).
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isFocused ? 1.5 : 1,
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: PaneLeafView.icon(for: spec.kind))
                .font(.caption)
                .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                .accessibilityHidden(true) // decorative — the title Text carries the row's label

            let status = connectionStatus
            PaneStatusDot(status: status, running: isRunning)

            Text(displayTitle)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            // Reconnecting/unreachable detail beside the dot so "connecting forever" reads as a clear
            // "Reconnecting (n) — retrying in Ns" / "Unreachable" (surfacing the WF3 timeout + backoff).
            statusDetail(status)

            // Live RTT badge (docs/26 D10): the smoothed ping/pong RTT beside the title while
            // connected — typing lag finally has an attributable number (network vs host vs
            // render). Hidden until the first sample; amber past 100ms (the "this will feel
            // laggy" line for keystroke echo).
            if case .connected = status.phase, let ms = latencyMS {
                Text(ms < 1 ? "<1ms" : "\(Int(ms.rounded()))ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(ms > 100 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .accessibilityLabel(Text("latency \(Int(ms.rounded())) milliseconds"))
                    .help("Smoothed round-trip time to the host (3s ping)")
            }

            // A "running…" affordance while an OSC 133 command executes on this pane — the iconic
            // modern-terminal activity cue, beside the title. Hidden at the idle prompt.
            if isRunning {
                Text("running…")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .accessibilityLabel(Text("command running"))
            }

            Spacer(minLength: 8)

            controls
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        #if os(macOS)
            // BUG-2 ("ở cạnh trên/header vẫn bị"): the header bar is hit-OPAQUE (it carries the
            // tap-to-focus gesture over the whole bar), so a scroll over it was SWALLOWED instead of
            // panning — exactly like the resize-grip perimeter was before `gripBase`. Fix with the SAME
            // pattern: make the bar's hit layer a `ScrollPanForwarder` (a real NSView that forwards
            // scroll → `store.scrollPan`) that ALSO carries the tap. (The canvas drag-to-move moved to
            // the floating pill with the borderless canvas pane; this header now lives only on the
            // compact carousel, where panes don't move.)
            .background {
                ScrollPanForwarder(store: store)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { store.focus(id) })
            }
            .background(isFocused ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial))
        #else
            .background(isFocused ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial))
            .contentShape(Rectangle())
            // A plain TAP on the title bar focuses the pane (the natural way to select a window).
            .simultaneousGesture(TapGesture().onEnded { store.focus(id) })
        #endif
    }

    /// The add / maximize / close controls. Compact icon buttons in the native borderless toolbar
    /// idiom. The add affordance is a KIND-picker (docs/30 §6.7): a plain tap adds a terminal pane (the
    /// common case); the menu offers Claude Code / Remote so the user chooses the new pane's KIND —
    /// mirroring the sidebar / detail "New" idiom (the old split-direction buttons are gone with splits).
    private var controls: some View {
        HStack(spacing: 2) {
            addMenu
            chromeButton(
                isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: isZoomed ? "Restore" : "Maximize",
            ) {
                store.focus(id) // maximize acts on the focused pane — ensure it's this one first
                store.toggleZoom()
            }
            chromeButton("xmark", help: store.isOnlyLeaf(id) ? "Close last pane" : "Close pane", role: .destructive) {
                store.requestClosePane(id)
            }
        }
        .font(.caption)
    }

    /// The "add pane" KIND-picker: tap to add a terminal pane to the canvas, or open the menu to add a
    /// Claude Code / Remote pane. New panes cascade off the focused pane and are guaranteed in view.
    @ViewBuilder
    private var addMenu: some View {
        Menu {
            Button {
                store.addPane(kind: .terminal)
            } label: {
                Label("Terminal", systemImage: PaneLeafView.icon(for: .terminal))
            }
            Button {
                store.addPane(kind: .claudeCode)
            } label: {
                Label("Claude Code", systemImage: PaneLeafView.icon(for: .claudeCode))
            }
            Button {
                store.addPane(kind: .remoteGUI)
            } label: {
                Label("Remote Window", systemImage: PaneLeafView.icon(for: .remoteGUI))
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: 18, height: 18)
        } primaryAction: {
            store.addPane(kind: .terminal)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
            .menuStyle(.borderlessButton)
        #endif
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Add pane")
            .accessibilityLabel("Add pane")
    }

    private func chromeButton(
        _ systemImage: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void,
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Status dot

    /// The header status presentation (the shared ``PanePresentation`` derivation — the canvas
    /// floating handle and this header can never drift).
    private var connectionStatus: PaneConnectionStatus { PanePresentation.connectionStatus(handle) }

    /// Whether an OSC 133 command is currently executing in this pane's shell (drives the amber
    /// running ring on the dot + the "running…" header label).
    private var isRunning: Bool { PanePresentation.isRunning(handle) }

    /// The smoothed app-layer RTT for the latency badge (`nil` until the first ping/pong completes).
    /// Reading the `@Observable` connection's `latencyMS` re-renders the header on each ~3s sample.
    private var latencyMS: Double? { PanePresentation.latencyMS(handle) }

    /// The header label: the LIVE OSC 0/2 terminal title when set, else `spec.title` (shared
    /// ``PanePresentation`` rule). Reading the `@Observable` model's `title` here re-renders the
    /// header when the shell changes it.
    private var displayTitle: String { PanePresentation.displayTitle(handle, spec: spec) }

    /// The compact status detail shown beside the title for the in-flight / terminal states. For a
    /// reconnecting pane with a known next-retry instant it ticks a live "retrying in Ns" countdown via
    /// a `TimelineView` (refreshed once a second, no store mutation); otherwise it shows the static
    /// label. Hidden entirely for the steady connected/idle states so the header stays clean.
    @ViewBuilder
    private func statusDetail(_ status: PaneConnectionStatus) -> some View {
        switch status.phase {
        case .reconnecting:
            if let nextRetry = status.nextRetry {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(reconnectLabel(status, now: context.date, nextRetry: nextRetry))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            } else {
                Text(status.label)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        case .connecting:
            // An initial dial can block on the dead-host handshake/timeout (~10s); surface a
            // "Connecting…" cue beside the title — not just the pulsing dot — so the wait reads as
            // in-flight, not frozen. Neutral (secondary) since it is not yet an error.
            Text(status.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .unreachable,
             .failed:
            // Show the CONCRETE reason ("Failed: timed out") inline, not the bare word "Failed" —
            // the reason was previously reachable only via the 7pt status-dot hover tooltip. The
            // full text stays in `.help` for the truncated case. (`.unreachable` carries no message,
            // so `detailedLabel` is just "Unreachable" there — still correct.)
            Text(status.detailedLabel)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(status.detailedLabel)
        default:
            EmptyView()
        }
    }

    /// "Reconnecting (n) — retrying in Ns" once a countdown is known; clamps the remaining seconds at 0
    /// and collapses to "Reconnecting (n)…" when the deadline has passed (the attempt is firing now).
    private func reconnectLabel(_ status: PaneConnectionStatus, now: Date, nextRetry: Date) -> String {
        let remaining = Int(nextRetry.timeIntervalSince(now).rounded(.up))
        guard remaining > 0 else { return status.label }
        return "\(status.label) retrying in \(remaining)s"
    }
}

#endif
