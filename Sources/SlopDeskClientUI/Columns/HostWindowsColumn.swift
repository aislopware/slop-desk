// HostWindowsColumn — the RIGHT sidebar listing the HOST machine's windows (docs/45), the left
// rail's mirror twin: same ground surface, 40pt strip, instrument-voice header, search plate, 32pt
// rows at radius 7. A supervision instrument, not a picker: every row is one click from becoming a
// pane, and every already-streamed window points back at its pane (trailing accent tab ordinal).
//
// STABILITY IS THE UX (docs/45 §1): sections are alphabetical by app, rows keep first-seen order —
// nothing reorders on host focus flips / title churn / refresh ticks; state restyles in place
// (weight, dimming, ordinal), never by motion or position.
//
// PERF DISCIPLINE (docs/45 §7, the ca429f90 3-part rule): section membership is memoized in
// ``HostWindowRowsMemo`` keyed ONLY on structural identity + the filter; title / metrics / state /
// frontmost / streamed-ref are VOLATILE — live-read inside ``HostWindowLiveRow`` leaves keyed
// `.id(leafIdentity)`, never passed as init params (lazy containers freeze first-render params).

#if os(macOS)
import AppKit
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

struct HostWindowsColumn: View {
    let store: WorkspaceStore
    /// The ONE feed store (app-owned; its renewal loop gates on the rail's collapse + connection).
    let feed: HostWindowFeed
    let chrome: WorkspaceChromeState

    /// The transient filter query (token-AND over appName + title, the picker's policy).
    @State private var query = ""
    /// The section/rows memo — a plain class in @State so body re-runs hit the cache unless the
    /// STRUCTURAL fingerprint (identity sequence + filter) changed.
    @State private var memo = HostWindowRowsMemo()
    /// The keyboard cursor (↑/↓ + ⏎), or `nil` when the panel isn't being keyboard-driven. The
    /// raised card renders ONLY for this cursor — selection vocabulary, not streamed-state.
    @State private var cursor: HostWindowIdentity?
    /// The live PEEK (docs/45 Phase 4): set ONLY once the JPEG fully arrives (no spinner, no
    /// skeleton — if it never arrives, nothing appears), presented as a popover on its row.
    @State private var peek: PeekPresentation?
    /// Windows with a peek fetch in flight (single-flight; a second Space is a no-op).
    @State private var peekFetching: Set<UInt32> = []
    @FocusState private var listFocused: Bool
    /// Pointer-in-strip — the collapse toggle's hover-reveal gate (the otty behavior, 2026-07-11).
    @State private var stripHover = false

    /// One fully-formed peek: the row it anchors to, the image, and its instrument caption.
    struct PeekPresentation: Identifiable {
        let identity: HostWindowIdentity
        let image: NSImage
        let caption: String
        var id: String { identity.leafIdentity }
    }

    var body: some View {
        // Filter reads `feed.titles` ONLY while a query is active (registering the body's dependency
        // on titles is the price of live-filtering; at rest an empty query keeps the body
        // structural-only, so title ticks re-render just the ≤64 leaves).
        let sections = memo.sections(
            structure: feed.structure,
            titles: query.isEmpty ? [:] : feed.titles,
            query: query,
        )
        return VStack(alignment: .leading, spacing: 0) {
            strip
            header
            searchField
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            list(sections)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Slate.theme.ground)
    }

    // MARK: - Chrome (strip + header + search — the left rail's anatomy, mirrored)

    /// Traffic-light-row strip: ONLY the rail-collapse toggle, top-LEADING (the mirror of the left
    /// rail's top-trailing toggle — each toggle hugs its column's inner edge). Same settled-state
    /// choreography: hide instantly on collapse, fade back after the slide settles — plus the
    /// hover-reveal gate (2026-07-11, the otty behavior): at rest the strip is empty. The glyph is
    /// the WINDOW one (`macwindow.on.rectangle`), matching the titlebar reopen button — this toggle
    /// is about the host's windows, deliberately distinct from the left `sidebar.left`.
    private var strip: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            PlateIconButton(symbol: .macwindowOnRectangle) { chrome.toggleHostWindows() }
                .opacity(!chrome.hostRailCollapsed && stripHover ? 1 : 0)
                .allowsHitTesting(!chrome.hostRailCollapsed && stripHover)
                .animation(
                    chrome.hostRailCollapsed ? nil : Slate.Anim.standard.delay(0.25),
                    value: chrome.hostRailCollapsed,
                )
                .animation(Slate.Anim.smallFade, value: stripHover)
                .padding(.top, 3)
                .padding(.leading, 8)
        }
        .frame(height: Slate.Metric.titlebarHeight)
        .background(HoverSensor { stripHover = $0 })
    }

    /// The panel label — instrument voice, same register as the left rail's "TABS". No hostname, no
    /// counts (the left rail's footer owns connection truth; filler earns no pixels).
    private var header: some View {
        HStack(spacing: 0) {
            Text("HOST")
                .font(Slate.Typeface.instrument(Slate.Typeface.footnote, weight: .semibold))
                .tracking(Slate.Typeface.instrumentTracking)
                .foregroundStyle(Slate.State.header)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    /// Byte-identical anatomy to the left rail's search plate (`NavigatorColumn.searchField`).
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemSymbol: .magnifyingglass)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.icon)
            TextField("Search windows", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.primary)
                .tint(Slate.State.accent)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemSymbol: .xmarkCircleFill)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.icon)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Slate.Surface.face, in: RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
        )
    }

    // MARK: - List

    @ViewBuilder
    private func list(_ sections: [(appName: String, rows: [HostWindowIdentity])]) -> some View {
        if HostWindowFeedQuery.openLink == nil {
            emptyLabel("Window discovery unavailable")
        } else if !feed.hasEverLoaded {
            // Never loaded: connected ⇒ the first snapshot is in flight (rows appear fully formed —
            // no spinner, no skeleton); disconnected ⇒ say what unlocks the rail.
            emptyLabel(feed.isLive ? " " : "Connect to a host to see its windows")
        } else if sections.isEmpty {
            emptyLabel(query.isEmpty
                ? "No windows on the host"
                : windowFilterEmptyMessage())
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.appName) { section in
                        SlateSectionHeader(section.appName.uppercased()) {
                            if section.rows.count > 1 {
                                Text("\(section.rows.count)")
                                    .font(Slate.Typeface.instrument(Slate.Typeface.small))
                                    .foregroundStyle(Slate.Text.tertiary)
                            }
                        }
                        ForEach(section.rows) { identity in
                            HostWindowLiveRow(
                                identity: identity,
                                feed: feed,
                                store: store,
                                isCursor: cursor == identity && listFocused,
                                onAct: { duplicate in act(on: identity, duplicate: duplicate) },
                                onPeek: HostWindowPreviewQuery.shared == nil
                                    ? nil : { requestPeek(identity) },
                            )
                            .id(identity.leafIdentity)
                            // The peek popover anchors to ITS row (a real NSPopover window — floats
                            // above the AppKit split, dismisses on Esc/outside-click natively).
                            .popover(item: peekBinding(for: identity), arrowEdge: .leading) { peek in
                                PeekCard(presentation: peek)
                            }
                            // New rows fade in (opacity only — no layout animation, no slide);
                            // removals and field updates apply instantly (docs/45 §3 Motion).
                            .transition(.opacity.animation(Slate.Anim.reveal))
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            // Stale feed (gates closed / unanswered renewals): cached rows dim in place and stop
            // accepting clicks — the calm outage treatment; the left rail's footer tells the story.
            .opacity(feed.isLive ? 1 : 0.4)
            .allowsHitTesting(feed.isLive)
            .focusable()
            .focused($listFocused)
            // Focusable for ↑/↓/⏎ ONLY — never the system focus ring (user report 2026-07-12:
            // clicking the rail drew a blue border around the whole list).
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { moveCursor(1, in: sections) }
            .onKeyPress(.upArrow) { moveCursor(-1, in: sections) }
            .onKeyPress(.return) {
                guard let cursor else { return .ignored }
                act(on: cursor, duplicate: NSEvent.modifierFlags.contains(.command))
                return .handled
            }
            .onKeyPress(.escape) {
                if !query.isEmpty { query = ""
                    return .handled
                }
                listFocused = false
                return .handled
            }
            .onKeyPress(.space) {
                guard let cursor, HostWindowPreviewQuery.shared != nil else { return .ignored }
                requestPeek(cursor)
                return .handled
            }
        }
    }

    // MARK: - Peek (docs/45 Phase 4 — Space / context menu; fully-formed-only)

    /// The per-row popover binding: presents ONLY when the live peek belongs to `identity`.
    private func peekBinding(for identity: HostWindowIdentity) -> Binding<PeekPresentation?> {
        Binding(
            get: { peek?.identity == identity ? peek : nil },
            set: { if $0 == nil, peek?.identity == identity { peek = nil } },
        )
    }

    /// Fetches one preview and presents it fully formed. Single-flight per window; a timeout /
    /// host throttle means nothing appears (never a spinner). The caption carries the dimensions +
    /// display — the row itself stays clean.
    private func requestPeek(_ identity: HostWindowIdentity) {
        guard let query = HostWindowPreviewQuery.shared,
              !peekFetching.contains(identity.windowID), feed.isLive else { return }
        peekFetching.insert(identity.windowID)
        let target = feed.connectionTarget
        Task { @MainActor in
            defer { peekFetching.remove(identity.windowID) }
            guard let result = await query(
                target.host, target.mediaPort, target.cursorPort, identity.windowID, 640,
            ), let image = NSImage(data: result.jpeg) else { return }
            // The row may have died while fetching — a peek for a gone window never appears.
            guard feed.structure.contains(identity) else { return }
            var parts = [identity.appName.uppercased()]
            if let m = feed.metrics[identity.windowID] {
                parts.append("\(m.widthPt) × \(m.heightPt)")
                if m.displayIndex > 0 { parts.append("DISPLAY \(m.displayIndex + 1)") }
            }
            peek = PeekPresentation(
                identity: identity, image: image, caption: parts.joined(separator: " · "),
            )
        }
    }

    /// The rail's quiet empty label — the left rail's `emptyLabel` register (no icon, no card).
    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Slate.Typeface.base))
            .foregroundStyle(Slate.Text.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The filter-miss message — names the filter AND the fix (the picker's pinned copy shape).
    private func windowFilterEmptyMessage() -> String {
        RemoteWindowModel.windowFilterEmptyMessage(filter: query, totalCount: feed.structure.count)
    }

    // MARK: - Acting (the ONE verb, state-aware — docs/45 §4)

    /// Single-click / ⏎: focus the streaming pane when the window is already in the workspace, else
    /// open a new pane. `duplicate` (⌘-click / ⌘⏎) deliberately opens ANOTHER pane of the same window.
    private func act(on identity: HostWindowIdentity, duplicate: Bool) {
        cursor = identity
        if !duplicate, let ref = Self.streamedRef(for: identity.windowID, in: store) {
            store.focusPaneTree(ref.paneID)
            return
        }
        openPane(for: identity)
    }

    private func openPane(for identity: HostWindowIdentity) {
        let title = feed.titles[identity.windowID] ?? ""
        store.newRemoteWindowTab(
            windowID: identity.windowID, title: title, appName: identity.appName,
        )
        store.recordRecentCommand(.newPane(.remoteGUI))
    }

    private func moveCursor(
        _ delta: Int, in sections: [(appName: String, rows: [HostWindowIdentity])],
    ) -> KeyPress.Result {
        let flat = sections.flatMap(\.rows)
        guard !flat.isEmpty else { return .ignored }
        let current = cursor.flatMap { c in flat.firstIndex(where: { $0 == c }) }
        let next = ((current ?? (delta > 0 ? -1 : flat.count)) + delta + flat.count) % flat.count
        cursor = flat[next]
        return .handled
    }

    // MARK: - Streamed derivation (client-side, live-read by leaves)

    /// Where a host window is already streaming: the pane + its 1-based tab ordinal in the ACTIVE
    /// session. The earliest tab wins for a window streamed twice (⌘-click duplicates are
    /// secondary). Reads `PaneSpec.video` — the binding `RemoteWindowModel` persists on every
    /// open/rebind, so markers self-correct through `WindowRebind` after a host restart.
    static func streamedRef(for windowID: UInt32, in store: WorkspaceStore) -> StreamedRef? {
        guard let session = store.tree.activeSession else { return nil }
        for (index, tab) in session.tabs.enumerated() {
            for paneID in tab.allPaneIDs() {
                guard let spec = session.specs[paneID], spec.kind == .remoteGUI,
                      spec.video?.windowID == windowID else { continue }
                return StreamedRef(paneID: paneID, tabOrdinal: index + 1)
            }
        }
        return nil
    }

    struct StreamedRef: Equatable {
        let paneID: PaneID
        let tabOrdinal: Int
    }
}

// MARK: - Leaf row (volatile fields live-read — the ca429f90 rule)

/// One host-window row. Init params are STRUCTURAL only (identity + stable references + the cursor
/// flag); title / metrics / state / frontmost / streamed-ref are read from the live stores inside
/// `body`, so a lazy container can never freeze them at first render.
private struct HostWindowLiveRow: View {
    let identity: HostWindowIdentity
    let feed: HostWindowFeed
    let store: WorkspaceStore
    let isCursor: Bool
    /// Fires the row's verb; `duplicate` = ⌘-click (open another pane of an already-streamed window).
    let onAct: (_ duplicate: Bool) -> Void
    /// Requests the row's peek (docs/45 Phase 4). `nil` (no preview seam) hides the verb.
    let onPeek: (() -> Void)?

    /// Hover, sensed by the DRAG-SOURCE overlay's tracking area (the overlay owns the row's mouse
    /// events, so SwiftUI `.onHover` inside `SlateListRow` never fires here) and piped back through
    /// `hoverOverride`. Also drives the row's own hover choreography below.
    @State private var hovered = false

    var body: some View {
        let title = feed.titles[identity.windowID] ?? ""
        let state = feed.states[identity.windowID]
        let dimmed = state?.isDimmed ?? false
        let isFrontmost = feed.frontmostWindowID == identity.windowID
        let streamed = HostWindowsColumn.streamedRef(for: identity.windowID, in: store)
        SlateListRow(
            active: isCursor,
            onTap: { onAct(NSEvent.modifierFlags.contains(.command)) },
            leading: { icon(dimmed: dimmed) },
            title: {
                // A DIMMED row (minimized / other Space / hidden app) wakes up under the pointer —
                // the hover preview of what opening it restores. Colour-only, restyle-in-place.
                Text(title.isEmpty ? identity.appName : title)
                    .font(.system(size: Slate.Typeface.body, weight: isFrontmost ? .medium : .regular))
                    .foregroundStyle(dimmed && !hovered ? Slate.Text.secondary : Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            },
            titleTrailing: { _ in
                // Streamed marker: the pane's tab ordinal in the accent — quiet, positional.
                // (A hover verb hint — "OPEN" / "FOCUS · n" — lived here and was removed on user
                // ruling 2026-07-12: it said nothing the click doesn't; the tooltip carries the
                // long-form meaning.)
                if let streamed {
                    Text("\(streamed.tabOrdinal)")
                        .font(Slate.Typeface.instrument(Slate.Typeface.small))
                        .foregroundStyle(Slate.State.accent)
                }
            },
            subtitleTrailing: { _ in },
            trailingOverlay: { _ in },
            hoverOverride: hovered,
        )
        .help(tooltip(title: title, state: state))
        .contextMenu { contextMenu(streamed: streamed) }
        // DRAG SOURCE (docs/45 round 3): drag the row onto the canvas to place the window — the
        // canvas previews split/dock/new-tab zones (`HostWindowDropAffordance`). An AppKit overlay,
        // NOT `.onDrag` (the row's tap gesture eats the mouse-down — see `HostWindowRowDragSource`);
        // it also owns the row's left-click (`onAct`, not `SlateListRow.onTap`) AND its hover
        // (`hovered`, not `.onHover` — the overlay swallows those events too).
        .overlay {
            HostWindowRowDragSource(
                payload: HostWindowDragPayload(
                    windowID: identity.windowID,
                    title: feed.titles[identity.windowID] ?? "",
                    appName: identity.appName,
                    bundleID: identity.bundleID,
                ),
                onAct: onAct,
                onHover: { hovered = $0 },
            )
        }
    }

    /// The 16pt app icon — resolved LOCALLY by bundleID (the client is a Mac too; most apps match).
    /// Unresolved ⇒ the static `macwindow` glyph — no monogram, no loading animation (docs/45 §2).
    /// On hover the icon perks up: a small scale bump (the pane-move pill's treatment) + a dimmed
    /// row's icon returns to full strength — colour/scale only, the frame never moves.
    private func icon(dimmed: Bool) -> some View {
        Group {
            if let icon = HostAppIconCache.shared.icon(forBundleID: identity.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemSymbol: .macwindow)
                    .font(.system(size: Slate.Typeface.iconSizeFallback))
                    .foregroundStyle(Slate.Text.icon)
                    .frame(width: 16, height: 16)
            }
        }
        .opacity(dimmed && !hovered ? 0.5 : 1)
        .scaleEffect(hovered ? 1.12 : 1)
        .animation(Slate.Anim.smallFade, value: hovered)
    }

    /// Open-in-Split (docs/45 Phase 5): the split-with-spec op beside the active pane — same
    /// endpoint persistence + cap gating as the tab path.
    private func openSplit(_ axis: SplitAxis) {
        let title = feed.titles[identity.windowID] ?? ""
        store.newRemoteWindowSplit(
            windowID: identity.windowID, title: title, appName: identity.appName, axis: axis,
        )
        store.recordRecentCommand(.newPane(.remoteGUI))
    }

    /// Dimensions / display / visibility live in the tooltip ONLY — never row filler (docs/45 §2).
    private func tooltip(title: String, state: HostWindowState?) -> String {
        var parts = [title.isEmpty ? identity.appName : "\(identity.appName) — \(title)"]
        if let m = feed.metrics[identity.windowID] {
            parts.append("\(m.widthPt) × \(m.heightPt)")
            if m.displayIndex > 0 { parts.append("Display \(m.displayIndex + 1)") }
        }
        if let state, !state.isOnScreen {
            parts.append(state.isAppHidden ? "App hidden" : state.isMinimized ? "Minimized" : "On another Space")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func contextMenu(streamed: HostWindowsColumn.StreamedRef?) -> some View {
        if streamed != nil {
            Button("Focus Pane") { onAct(false) }
            Button("Open Another Pane") { onAct(true) }
        } else {
            Button("Open in New Tab") { onAct(false) }
        }
        // Open in Split (docs/45 Phase 5): pull the window in BESIDE the active pane — the
        // split-with-spec op; works for streamed windows too (a deliberate second pane).
        Button("Open in Split Right") { openSplit(.horizontal) }
        Button("Open in Split Down") { openSplit(.vertical) }
        if let onPeek {
            Button("Peek") { onPeek() }
        }
        Divider()
        Button("Copy Window Title") {
            let title = feed.titles[identity.windowID] ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(title.isEmpty ? identity.appName : title, forType: .string)
        }
    }
}

// MARK: - Peek card (the ONLY window-content imagery anywhere — docs/45 Phase 4)

/// The fully-formed peek: the JPEG at a LEGIBLE 320 pt width (true aspect, letterboxed past
/// 220 pt tall) over `Surface.face`, captioned in the instrument voice. Appears ONLY complete —
/// there is no loading state to render by design.
private struct PeekCard: View {
    let presentation: HostWindowsColumn.PeekPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space2) {
            Image(nsImage: presentation.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 320, maxHeight: 220)
                .background(Slate.Surface.face)
                .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall))
            Text(presentation.caption)
                .font(Slate.Typeface.instrument(Slate.Typeface.small))
                .tracking(Slate.Typeface.instrumentTracking)
                .foregroundStyle(Slate.Text.secondary)
        }
        .padding(Slate.Metric.space3)
        .frame(width: 320 + Slate.Metric.space3 * 2)
    }
}

// MARK: - Section/rows memo (structural fingerprint ONLY)

/// Memoizes the rail's sectioned rows: rebuilt ONLY when the structural fingerprint — the ordered
/// identity sequence + the filter query — changes. Title / metrics / state are EXCLUDED (volatile at
/// this feature's cadences; leaves live-read them), so a title tick can never re-run sectioning.
/// Plain non-@Observable class held in `@State` (the `RailRowsMemo` shape).
@MainActor
final class HostWindowRowsMemo {
    private var fingerprint = ""
    private var cached: [(appName: String, rows: [HostWindowIdentity])] = []
    /// Test pin: how many times the sections were actually rebuilt (RailRowsMemoTests shape).
    private(set) var buildCount = 0

    func sections(
        structure: [HostWindowIdentity],
        titles: [UInt32: String],
        query: String,
    ) -> [(appName: String, rows: [HostWindowIdentity])] {
        let next = Self.fingerprint(structure: structure, query: query)
        if next == fingerprint { return cached }
        fingerprint = next
        buildCount += 1
        let filtered = HostWindowFeed.filtered(structure, titles: titles, query: query)
        cached = HostWindowFeed.sectioned(filtered)
        return cached
    }

    /// Ordered leaf identities + section keys + the query — nothing volatile.
    static func fingerprint(structure: [HostWindowIdentity], query: String) -> String {
        var out = query
        out.reserveCapacity(query.count + structure.count * 24)
        for identity in structure {
            out += "\u{1F}"
            out += identity.leafIdentity
            out += "\u{1E}"
            out += identity.appName
        }
        return out
    }
}

// MARK: - App-icon cache (local resolve → disk cache → wire fetch)

/// bundleID → 16pt-ready NSImage. Resolution ladder (docs/45 Phase 3): (1) the LOCAL Mac's Launch
/// Services — the client is a Mac too, so most apps match; (2) the DISK cache of previously wire-
/// fetched icons (LRU 5 MB); (3) ONE wire fetch per bundleID via the ``HostAppIconQuery`` seam
/// (single-flight; a magic-validated PNG lands in both caches and bumps ``version`` so rows
/// re-render). Misses cache negatively — a host-only app with no icon costs one fetch ever.
/// `@Observable` ONLY for `version`; the row leaves read `icon(forBundleID:)` (which touches it) so
/// an async icon arrival repaints exactly the rows.
@MainActor
@Observable
final class HostAppIconCache {
    static let shared = HostAppIconCache()

    /// Bumped when a wire-fetched icon lands — the leaves' re-render signal.
    private(set) var version = 0
    @ObservationIgnored private var memory: [String: NSImage?] = [:]
    @ObservationIgnored private var fetching: Set<String> = []
    /// The wire-fetch target (set by the app once the connection exists; returns `nil` while
    /// disconnected so no fetch round is wasted). Unset ⇒ local-only.
    @ObservationIgnored var remoteTarget: (@MainActor () -> ConnectionTarget?)?

    /// The wire-fetch pixel edge (64 px covers 16 pt @2x–@4x rendering).
    private static let fetchPx: UInt16 = 64

    func icon(forBundleID bundleID: String) -> NSImage? {
        _ = version // register the arrival signal even on the miss path
        if let hit = memory[bundleID] { return hit }
        guard !bundleID.isEmpty else {
            memory[bundleID] = NSImage?.none
            return nil
        }
        // (1) Local Launch Services.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            memory[bundleID] = icon
            return icon
        }
        // (2) Disk cache of prior wire fetches.
        if let data = HostAppIconDiskCache.read(bundleID: bundleID, px: Self.fetchPx),
           let icon = Self.rowImage(from: data)
        {
            memory[bundleID] = icon
            return icon
        }
        // (3) Wire fetch (single-flight, negative-cached).
        scheduleFetch(bundleID)
        memory[bundleID] = NSImage?.none
        return nil
    }

    private func scheduleFetch(_ bundleID: String) {
        guard !fetching.contains(bundleID),
              let query = HostAppIconQuery.shared,
              let targetProvider = remoteTarget,
              let target = targetProvider()
        else { return }
        fetching.insert(bundleID)
        Task { @MainActor [weak self] in
            let data = await query(target.host, target.mediaPort, target.cursorPort, bundleID, Self.fetchPx)
            guard let self else { return }
            fetching.remove(bundleID)
            guard let data, let icon = Self.rowImage(from: data) else { return } // negative entry stands
            HostAppIconDiskCache.write(data, bundleID: bundleID, px: Self.fetchPx)
            memory[bundleID] = icon
            version += 1 // repaint the rows waiting on this icon
        }
    }

    private static func rowImage(from data: Data) -> NSImage? {
        guard let icon = NSImage(data: data) else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// The wire-fetched icon disk cache: `Caches/host-app-icons/<fnv64(bundleID)>-<px>.png`, pruned
/// LRU-by-mtime to 5 MB on write. Contents are magic-validated PNGs (the fetch validates before
/// this layer sees bytes), keyed content-addressably so a hostile bundleID string never becomes a
/// path component.
enum HostAppIconDiskCache {
    static let maxBytes = 5 * 1024 * 1024

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("SlopDesk/host-app-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(bundleID: String, px: UInt16) -> URL? {
        // FNV-1a64 of the bundleID — content-addressable, path-safe (matches the wire blobID).
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bundleID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return directory?.appendingPathComponent(String(format: "%016llx-%d.png", hash, px))
    }

    static func read(bundleID: String, px: UInt16) -> Data? {
        guard let url = fileURL(bundleID: bundleID, px: px),
              let data = try? Data(contentsOf: url) else { return nil }
        // Refresh mtime so the LRU prune keeps hot icons.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    static func write(_ data: Data, bundleID: String, px: UInt16) {
        guard let url = fileURL(bundleID: bundleID, px: px) else { return }
        try? data.write(to: url, options: .atomic)
        prune()
    }

    /// Drops oldest-mtime files until the cache fits `maxBytes`.
    private static func prune() {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
              )
        else { return }
        var entries: [(url: URL, size: Int, mtime: Date)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        entries.sort { $0.mtime < $1.mtime }
        for entry in entries {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

private extension Slate.Typeface {
    /// The fallback glyph size inside the 16pt icon slot.
    static let iconSizeFallback: CGFloat = 12
}
#endif
