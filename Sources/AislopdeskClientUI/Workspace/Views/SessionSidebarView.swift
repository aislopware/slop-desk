// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
#if canImport(SwiftUI)
import AislopdeskAgentDetect
import SwiftUI

// MARK: - SessionSidebarView (the sessions sidebar — Muxy-styled)

/// The coding-IDE sessions sidebar, ported from Muxy's `Sidebar` (not a stock `List`/`.sidebar`): a solid
/// L3 `chrome` column of custom rows grouped by host. Each row is the wide "project" look — a rounded
/// session icon (the session's initial in a `surface` square) carrying a top-trailing rolled-up completion
/// badge, the session name, and a trailing rolled-up agent-status dot — laid on a `selectionWash`
/// (accent·0.18, active) / `hoverFill` (white·0.05, hovered) row plate, with a 3pt accent leading bar on
/// the active row. The footer is one full-width "New Session" Button. Drives the store's tree ops
/// (`selectSession` / `newSession` / `closeSession` / `renameSession`).
struct SessionSidebarView: View {
    @Bindable var store: WorkspaceStore

    /// The session whose inline rename field is open, or `nil`.
    @State private var renamingSession: SessionID?
    @State private var renameText: String = ""

    private var activeSessionID: SessionID? {
        store.tree.activeSessionID ?? store.tree.sessions.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionList

            // P3b: the chrome-meets-content hairline above the footer reads at `DSColor.borderComponent`
            // (white·0.11) so it's a visible separator, not the old near-invisible `border` (white·0.07).
            Rectangle().fill(DSColor.borderComponent).frame(height: 1)
            SidebarFooter(onNewSession: newSession)
        }
        // Elevation: the sidebar is the L3 chrome surface (DSColor.chrome == n3 == the legacy `bgRaised`,
        // byte-identical) so it reads a step above the `paneBg` pane cards.
        .background(DSColor.chrome)
    }

    // MARK: List (Muxy's `scrollableProjects`: a `ScrollView` of a `LazyVStack` grouped by host)

    private var sessionList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: UIMetrics.spacing3) {
                ForEach(groupedByHost, id: \.host) { group in
                    sectionHeader(group.host)
                    ForEach(group.sessions, id: \.id) { session in
                        sessionSlot(session)
                    }
                }
            }
            .padding(.horizontal, UIMetrics.spacing3)
            .padding(.top, UIMetrics.spacing2)
            .padding(.bottom, UIMetrics.spacing2)
        }
        .onChange(of: activeSessionID) { _, _ in renamingSession = nil }
    }

    // MARK: Section header (a small uppercase host label — not a `List` `Section`)

    /// The section-header type token (P3b): 10pt SEMIBOLD SF, lh14, +0.4 tracking — a dedicated stronger
    /// twin of ``DSFont/caption`` (which is `.medium`, +0.1). The spec wants section eyebrows SEMIBOLD with
    /// +0.4 tracking, ALL-CAPS, at `textTertiary` — readable as a label, not the old unreadable
    /// `fgFaint`·0.20. Applied via `.dsFont` so it lands tracking + leading + the live-scale repaint path.
    @MainActor static let sectionHeaderFont = DSFont(10, .semibold, .default, leading: 14, tracking: 0.4)

    private func sectionHeader(_ host: String) -> some View {
        Text(host.uppercased())
            // P3b: SEMIBOLD 10pt +0.4-tracking textTertiary (readable section eyebrow) — replaces the
            // unreadable `fgFaint`·0.20. ALL-CAPS already via `.uppercased()`.
            .dsFont(Self.sectionHeaderFont)
            .foregroundStyle(DSColor.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, UIMetrics.spacing3)
            .padding(.top, UIMetrics.spacing3)
            // P3b: 6pt bottom breathing room (DSSpace.s3) so the eyebrow doesn't touch the first row, vs the
            // old 2pt (spacing1). `.dsSpace` keeps it on the live-scale path.
            .dsSpace(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Row (or its inline rename field)

    @ViewBuilder
    private func sessionSlot(_ session: Session) -> some View {
        if renamingSession == session.id {
            HStack(spacing: UIMetrics.spacing4) {
                SessionIcon(
                    session: session,
                    isActive: session.id == activeSessionID,
                    completion: store.rollupPendingCompletion(forSession: session.id),
                )
                TextField("Session", text: $renameText)
                    .textFieldStyle(.plain)
                    // P3b: the inline rename field reads at the active-row weight (DSFont.emphasis) textPrimary.
                    .dsFont(.emphasis)
                    .foregroundStyle(DSColor.textPrimary)
                    .onSubmit { commitRename(session.id) }
                    .onEscapeKey { renamingSession = nil }
                #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                #endif
            }
            .padding(.horizontal, UIMetrics.spacing3)
            .padding(.vertical, UIMetrics.spacing2)
            .background(
                AislopdeskTheme.surface,
                in: RoundedRectangle(cornerRadius: UIMetrics.radiusLG, style: .continuous),
            )
        } else {
            SessionRow(
                session: session,
                isActive: session.id == activeSessionID,
                agentStatus: store.rollupStatus(forSession: session.id),
                completion: store.rollupPendingCompletion(forSession: session.id),
                summary: store.activitySummary(forSession: session.id),
                liveness: store.sessionLiveness(forSession: session.id),
                onSelect: { store.selectSession(session.id) },
                onRename: { beginRename(session) },
            )
            .contextMenu {
                Button("Rename…") { beginRename(session) }
                Button("Close Session", role: .destructive) { store.closeSession(session.id) }
            }
        }
    }

    // MARK: New session (the single source both the keyboard path and the footer use)

    private func newSession() {
        store.newSession(name: store.defaultSessionName, kind: SettingsKey.defaultPaneKind)
    }

    // MARK: Grouping (by host, first-appearance order within host)

    private struct HostGroup { let host: String
        let sessions: [Session]
    }

    /// Sessions grouped by their connection host (no-connection → "Local"), in first-appearance order.
    private var groupedByHost: [HostGroup] {
        var order: [String] = []
        var buckets: [String: [Session]] = [:]
        for session in store.tree.sessions {
            let host = session.connection?.host ?? "Local"
            if buckets[host] == nil { order.append(host) }
            buckets[host, default: []].append(session)
        }
        return order.map { HostGroup(host: $0, sessions: buckets[$0] ?? []) }
    }

    // MARK: Rename

    private func beginRename(_ session: Session) {
        renameText = session.name
        renamingSession = session.id
    }

    private func commitRename(_ id: SessionID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameSession(id, to: trimmed.isEmpty ? "Session" : trimmed)
        renamingSession = nil
    }
}

// MARK: - SessionRow (Muxy's `ExpandedProjectRow` projectHeader, mapped to a session)

/// A single sidebar session row: the session icon + name + a trailing agent-status dot, on a
/// `selectionWash` plate when active (accent·0.18 — clearly beating the `hoverFill` hover plate) and a 3pt
/// accent leading bar. Its own `hovered` state keeps the wash local.
///
/// NOTE: `internal` (not `private`) so the PURE row-state transforms (``Self/rowVisual(isActive:isHovered:)``,
/// ``Self/rowFill(_:)``) are reachable from the headless `P3bChromeTransformTests` via `@testable import` —
/// no SwiftUI layout is exercised there.
struct SessionRow: View {
    let session: Session
    let isActive: Bool
    let agentStatus: ClaudeStatus
    let completion: PaneCompletionBadge?
    /// P3 piece 5: the cheap one-line activity summary (the host blocking line / state label), or `nil`.
    let summary: String?
    /// P3 piece 5: the session's liveness (alive vs exited-resumable) for the leading glyph.
    let liveness: WorkspaceStore.SessionLiveness
    let onSelect: () -> Void
    let onRename: () -> Void

    @State private var hovered = false
    /// Reduce-Motion gate: the sidebar-selection spring falls to a near-instant crossfade under the system
    /// preference (via ``DSMotion/resolve(_:reduceMotion:)``).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayName: String {
        session.name.isEmpty ? "Session" : session.name
    }

    /// The liveness glyph, immediately before the agent dot in the trailing cluster. Both cases share ONE
    /// font size (`fontXS`) so the baseline/width is stable as a session flips alive↔detached. Alive uses a
    /// `bolt.fill` (live link) rather than a second filled circle so it never reads as a redundant double
    /// green dot beside the adjacent ``AgentStatusDot``; detached uses a muted `moon.zzz`.
    @ViewBuilder
    private var livenessGlyph: some View {
        switch liveness {
        case .alive:
            Image(systemName: "bolt.fill")
                .font(.system(size: UIMetrics.fontXS))
                .foregroundStyle(AislopdeskTheme.statusGreen)
                .help("Connected")
                .accessibilityLabel("connected")
        case .exitedResumable:
            Image(systemName: "moon.zzz")
                .font(.system(size: UIMetrics.fontXS))
                .foregroundStyle(AislopdeskTheme.fgMuted)
                .help("Detached — reattach on select")
                .accessibilityLabel("detached, resumable")
        }
    }

    // MARK: - Pure row-state → style transform (unit-tested headlessly — no SwiftUI layout)

    /// The three mutually-exclusive visual states of a sidebar row. Extracted so the load-bearing
    /// "selected clearly BEATS hovered" mapping is testable without driving SwiftUI layout. Selection wins
    /// over hover (a row can be both active and hovered — the active wash takes precedence).
    enum RowVisual: Equatable { case active, hovered, idle }

    /// The row's visual state, a PURE function of (isActive, isHovered). `active` takes precedence over
    /// `hovered` so the selected row never downgrades to the hover plate while the pointer is over it.
    static func rowVisual(isActive: Bool, isHovered: Bool) -> RowVisual {
        if isActive { return .active }
        if isHovered { return .hovered }
        return .idle
    }

    /// The row's fill colour, a PURE function of ``RowVisual`` (P3b — the core "selected beats hover" fix):
    /// `.active` ⇒ ``DSColor/selectionWash`` (accent·0.18) which CLEARLY beats `.hovered` ⇒
    /// ``DSColor/hoverFill`` (white·0.05); `.idle` ⇒ `.clear`. Selection is shown ADDITIVELY (this wash +
    /// the accent leading bar) — an idle row is `.clear`, NEVER dimmed.
    @MainActor
    static func rowFill(_ visual: RowVisual) -> Color {
        switch visual {
        case .active: DSColor.selectionWash
        case .hovered: DSColor.hoverFill
        case .idle: .clear
        }
    }

    /// The resolved fill for THIS row's live state.
    private var rowFill: Color {
        Self.rowFill(Self.rowVisual(isActive: isActive, isHovered: hovered))
    }

    var body: some View {
        HStack(spacing: UIMetrics.spacing4) {
            SessionIcon(session: session, isActive: isActive, completion: completion)

            VStack(alignment: .leading, spacing: UIMetrics.scaled(1)) {
                Text(displayName)
                    // P3b: active name = DSFont.emphasis (13pt semibold) textPrimary; inactive = DSFont.body
                    // (13pt regular) textSecondary. Hierarchy is weight + colour at a stable size — an idle
                    // row rests at textSecondary, NEVER dimmed.
                    .dsFont(isActive ? .emphasis : .body)
                    .foregroundStyle(isActive ? DSColor.textPrimary : DSColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // P3 piece 5: a cheap one-line activity summary under the name — the host blocking line /
                // last assistant message, else the agent state label. Hidden when no agent is present.
                if let summary, !summary.isEmpty {
                    Text(summary)
                        // P3b: the sub-line is subordinate telemetry — DSFont.caption (10pt) textTertiary.
                        .dsFont(.caption)
                        .foregroundStyle(DSColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: UIMetrics.spacing2)

            livenessGlyph
            // P5: pass the UNSCALED base (8) — AgentStatusDot applies the live scale via `.dsScaledFrame`.
            AgentStatusDot(status: agentStatus, size: 8)
        }
        // P3b: row padding migrates to the 4pt scale via the live-scale `.dsSpace` path — 6pt H / 4pt V.
        .dsSpace(.horizontal, 6)
        .dsSpace(.vertical, 4)
        // P3b: selected ⇒ selectionWash (accent·0.18) which CLEARLY beats hover ⇒ hoverFill (white·0.05);
        // idle ⇒ clear. The `.background(_, in:)` clip applies only to THIS fill shape — the accent bar below
        // is a sibling `.overlay`, so it is NOT clipped by the 8pt corner.
        .background(rowFill, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        // P3b SELECTION = fill + accent EDGE: a 3pt accent leading bar carries the primary "this is selected"
        // signal alongside the wash (the Linear/Raycast idiom). It is an `.overlay` (NOT a child of the
        // `.background(_, in:)` fill) so the 8pt corner radius never clips it; it spans the FULL row height
        // (no vertical inset) as a plain `Rectangle` — `DSColor.accentSolid`, 3pt wide, pinned `.leading`.
        // `.allowsHitTesting(false)` so the decorative bar NEVER steals the row tap (select / double-tap
        // rename still fire across the full row). Shown only on the active row — additive, never dims peers.
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(DSColor.accentSolid)
                    // P5: tracked scaled width (base 3) so the accent bar reflows with the row on a tier flip.
                    .dsScaledFrame(width: 3)
                    .allowsHitTesting(false)
            }
        }
        // P5 MOTION: sidebar SELECTION springs via DSMotion.select (the selectionWash plate + 3pt accent
        // leading bar move in on select), Reduce-Motion-gated to the near-instant crossfade. Keyed on
        // `isActive` so it fires exactly on a select; additive (wash + bar), it never dims a peer row.
        .animation(DSMotion.resolve(DSMotion.select, reduceMotion: reduceMotion), value: isActive)
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayName)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityAddTraits(.isButton)
        .highPriorityGesture(TapGesture(count: 2).onEnded { onRename() })
        .onTapGesture { onSelect() }
        #if os(macOS)
            .onHover { hovered = $0 }
        #endif
    }
}

// MARK: - SessionIcon (Muxy's `projectIcon`: the rounded badge + active ring + top-trailing completion)

/// The session's rounded icon: a continuous `surface`-filled rounded square holding the session's initial,
/// with the rolled-up completion badge overlaid top-trailing. The active row's selection signal is the 3pt
/// leading accent bar + `selectionWash` plate on `SessionRow` (the single accent cue); to avoid stacking
/// accent strokes on one row the icon keeps only a quiet neutral `border` frame (no accent ring), bumping
/// just its foreground/letter weight when active — monochrome glyph at `fgMuted`/`fg`.
private struct SessionIcon: View {
    let session: Session
    let isActive: Bool
    let completion: PaneCompletionBadge?

    private var initial: String {
        let trimmed = session.name.trimmingCharacters(in: .whitespaces)
        return String(trimmed.first.map(Character.init) ?? "S").uppercased()
    }

    private var letterForeground: Color {
        isActive ? AislopdeskTheme.fg : AislopdeskTheme.fgMuted
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: UIMetrics.radiusMD, style: .continuous)
                .fill(AislopdeskTheme.surface)
            Text(initial)
                .font(.system(size: UIMetrics.fontEmphasis, weight: .bold))
                .foregroundStyle(letterForeground)
        }
        // P5: the icon tile size routes through the tracked `.dsScaledFrame(square:)` (base 28 = iconXXL/mult)
        // so it reflows LIVE on a density-tier flip in lockstep with the row's `.dsFont`/`.dsSpace` text +
        // padding — instead of freezing (the static-var `UIMetrics.iconXXL` read SwiftUI can't observe).
        .dsScaledFrame(square: 28)
        .overlay {
            // Neutral hairline only — the row's leading accent bar (SessionRow) is the single "selected"
            // accent cue, so the icon never adds a second accent stroke.
            RoundedRectangle(cornerRadius: UIMetrics.radiusMD + UIMetrics.scaled(3), style: .continuous)
                .strokeBorder(AislopdeskTheme.border, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            CompletionBadge(badge: completion, size: UIMetrics.scaled(8))
                .offset(x: UIMetrics.spacing1, y: -UIMetrics.spacing1)
        }
    }
}

// MARK: - SidebarFooter (Muxy's `SidebarFooter`: an `IconButton` row pinned at the bottom)

/// The sidebar's bottom action bar — a row of `IconButton`s on the `bg` column. We keep just the
/// new-session action (Muxy's footer also carries notifications/extensions/theme, which we don't surface).
private struct SidebarFooter: View {
    let onNewSession: () -> Void

    @State private var hovered = false

    var body: some View {
        // P3b: ONE full-width Button wrapping icon+label so the WHOLE row is the hit target (the old layout
        // put the "New Session" Text OUTSIDE the IconButton, so the label beside the icon was non-tappable —
        // only the small plus glyph fired). `Label{}` weight-matches the SF Symbol (.medium) to the .body
        // text so icon + label read as one type system; `.contentShape(Rectangle())` makes the icon, label,
        // AND the trailing space all hittable.
        Button(action: onNewSession) {
            Label {
                Text("New Session")
                    .dsFont(.body)
            } icon: {
                Image(systemName: "plus")
                    .font(.system(size: UIMetrics.scaled(13), weight: .medium))
            }
            .foregroundStyle(DSColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, UIMetrics.spacing3)
            .padding(.vertical, UIMetrics.spacing2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Session")
        // Match the sidebar's L3 chrome elevation (base layer) so the footer doesn't read as a different
        // surface, then lay the translucent hover wash (white·0.05) ON TOP via a ZStack so it tints the
        // chrome rather than being painted over by it. P3b.
        .background {
            ZStack {
                DSColor.chrome
                if hovered { DSColor.hoverFill }
            }
        }
        #if os(macOS)
        .onHover { hovered = $0 }
        #endif
    }
}
#endif
