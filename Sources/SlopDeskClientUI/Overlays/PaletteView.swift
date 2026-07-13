// PaletteView — the floating command palette overlay. Renders the live state of the injected
// ``OverlayCoordinator`` as a VERBS-ONLY command palette: a pre-focused search field and a
// sectioned, fzf-highlighted result list with keycap chips, a ✓ toggled-state gutter, and a keyboard-selected
// fill row. (The per-domain filter chips live in the Open-Quickly picker — ⌘⇧P shows no chips here.)
//
// Faithful to `spec/user-interface__command-palette.md` (the centered floating panel, the magnifier +
// blue/accent caret, ALL-CAPS section headers with the WORKING-DIRECTORY badge, per-symbol keycap chips,
// the subtle selected-row fill) — mapped onto the DARK Monokai-default Slate token layer (`Slate.Surface.face`
// panel, `Slate.State.selected` row fill, `Slate.State.accent` caret/highlight, `Slate.State.header` section
// labels) rather than the light theme shown in the reference screenshot.
//
// SEAM discipline: the palette OWNS no state — every read/mutation goes through the coordinator (the single
// `@Observable` reducer) so the GUI and the headless model can't drift. Presented as a NATIVE `.sheet` by the
// `OverlayHostView` that mounts it (the system provides the window chrome — bg / rounded corners / shadow);
// this view carries only the search field + result rows. `Slate.*` tokens ONLY for that content (raw
// font/colour/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

struct PaletteView: View {
    /// The single overlay reducer — bound so the search field can two-way edit `paletteQuery` and `body`
    /// re-renders on `paletteSelection` / `rankedResults` changes.
    @Bindable var coordinator: OverlayCoordinator
    /// The live store — read-only here, for the WORKING-DIRECTORY badge (the focused pane's `lastKnownCwd`).
    let store: WorkspaceStore
    /// Whether a row currently shows its ✓ (toggled-on) gutter. Built by the host from the chrome
    /// state (e.g. `id == "action.toggleSidebar" ? !chrome.sidebarCollapsed : false`) so the pure coordinator
    /// never learns about chrome. `@MainActor` so the host's closure can read the `@MainActor`
    /// ``WorkspaceChromeState`` synchronously. Defaults to "nothing toggled" for standalone mounts / previews.
    var toggledState: @MainActor (PaletteItem) -> Bool = { _ in false }

    /// Pre-focuses the search field on appear so typing reaches it immediately (spec: pre-focused on open).
    @FocusState private var searchFocused: Bool

    // The fixed panel width (spec: a centered floating panel, ~720pt) + the results viewport cap (~7 rows).
    private let panelWidth: CGFloat = 720
    private let resultsMaxHeight: CGFloat = 336

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            resultsList
        }
        // Presented as a native `.sheet` by `OverlayHostView` — the system provides the window chrome (bg /
        // rounded corners / shadow), so this view carries only its content + a fixed macOS dialog width.
        #if os(macOS)
        .frame(width: panelWidth)
        #endif
        // Keyboard: the app NSEvent monitor passes bare arrows/Return through (it only swallows the prefix +
        // bound chords), so they reach this focused overlay. Plain ↩ is handled by the field's `.onSubmit`
        // (TextField-native, reliable); ⌘↩ is NOT a TextField submit, so it reaches THIS container handler —
        // guarding on `.command` (else `.ignored`) keeps the two from double-firing.
        .onKeyPress(.upArrow, phases: .down) { _ in
            coordinator.moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { _ in
            coordinator.moveSelection(1)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            coordinator.acceptSelectedKeepingOpen()
            return .handled
        }
        #if os(macOS)
        .onExitCommand { coordinator.closePalette() }
        #else
        .onKeyPress(.escape, phases: .down) { _ in
            coordinator.closePalette()
            return .handled
        }
        #endif
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemSymbol: .magnifyingglass)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.secondary)
            TextField("Search for commands…", text: $coordinator.paletteQuery)
                .textFieldStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.primary)
                .tint(Slate.State.accent) // the active caret is the accent colour (spec)
                .focused($searchFocused)
                .onSubmit { coordinator.acceptSelected() } // plain ↩ runs + closes
        }
        .padding(.horizontal, Slate.Metric.space4)
        .frame(height: Slate.Metric.heightInput)
        .onAppear {
            // A `@FocusState` set in the same tick the view appears (before its backing responder exists) is
            // dropped — defer one runloop hop (the same idiom InPaneChooserView uses).
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    // MARK: - Results list

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayRows) { entry in
                        row(entry.ranked, selectableIndex: entry.selectableIndex)
                    }
                }
                .padding(.vertical, Slate.Metric.space1)
            }
            .frame(maxHeight: resultsMaxHeight)
            .onChange(of: coordinator.paletteSelection) { _, _ in
                guard let id = selectedRowID else { return }
                withAnimation(Slate.Anim.smallFade) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func row(_ ranked: RankedRow, selectableIndex: Int?) -> some View {
        if ranked.item.isSeparator {
            sectionHeader(ranked.item)
        } else {
            actionRow(ranked, selectableIndex: selectableIndex ?? 0)
        }
    }

    // MARK: - Section header (+ WORKING DIRECTORY badge)

    private func sectionHeader(_ item: PaletteItem) -> some View {
        HStack(spacing: Slate.Metric.space2) {
            // Mirror the action-row's 20pt leading ✓/icon gutter so the uppercase header text
            // shares the row LABELS' left margin (command-palette.png: the headers are FLUSH with the row
            // labels, the ✓/icon gutter sitting to their LEFT). A section header carries no glyph, so this is an
            // empty placeholder — only its width matters.
            Color.clear.frame(width: 20)
            Text(item.title.uppercased())
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Slate.State.header)
                // The section label always wins the layout: a long cwd pill truncates its path, never the
                // "WORKING DIRECTORY" header it sits on.
                .layoutPriority(1)
            Spacer(minLength: Slate.Metric.space2)
            // The contextual cwd badge sits flush-right on the WORKING DIRECTORY header it OWNS — matched by
            // the category label, NOT "whichever separator sorts first" (which mislabelled a Recents/Actions
            // header before this section existed).
            if item.title == PaletteCategory.workingDirectory.label, let cwd = workingDirectory {
                // Home-abbreviate for display (`/Users/abner/Workplace/myproject` → `~/Workplace/myproject/`) to match
                // command-palette.png's `~/Workplace/myproject/` pill. `cwd` is the RAW remote-host path from the
                // `cwd()` RPC, so the abbreviation matches the home SHAPE (`/Users/<name>` · `/home/<name>`),
                // never the client's local home (see ``CwdDisplay``).
                cwdBadge(CwdDisplay.abbreviate(cwd))
            }
        }
        // `.padding(.horizontal, space3)` is the action-row's INNER padding; `.padding(.leading, space2)` adds
        // its OUTER inset. Together with the 20pt gutter + the `space2` HStack spacing the header text lands at
        // the EXACT x of a row label (space2 + space3 + 20 + space2), so headers + labels are flush (the row's
        // inset highlight + ✓-gutter are left untouched). The trailing `space2` mirrors the action
        // row's OUTER inset (space3 + space2 = 20pt) so the cwd pill's RIGHT edge lines up with the keycap-chip
        // column instead of jutting `space2` past it (command-palette.png: pill + keycaps share one right edge).
        .padding(.horizontal, Slate.Metric.space3)
        .padding(.leading, Slate.Metric.space2)
        .padding(.trailing, Slate.Metric.space2)
        .padding(.top, Slate.Metric.space3)
        .padding(.bottom, Slate.Metric.space1)
        .id(item.id)
    }

    private func cwdBadge(_ cwd: String) -> some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemSymbol: .folder)
                .font(.system(size: Slate.Typeface.small))
            Text(cwd)
                .font(.system(size: Slate.Typeface.small))
                .lineLimit(1)
                // Head-truncate so the leaf (the directory you're actually in) stays visible when the pill
                // shrinks — default `.tail` would drop the most meaningful part of the path.
                .truncationMode(.head)
        }
        .foregroundStyle(Slate.Text.secondary)
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .fill(Slate.Surface.raised),
        )
    }

    // MARK: - Action row

    private func actionRow(_ ranked: RankedRow, selectableIndex: Int) -> some View {
        let item = ranked.item
        let isSelected = selectableIndex == coordinator.paletteSelection
        return HStack(spacing: Slate.Metric.space2) {
            // Leading 24pt gutter: the ✓ toggled-state checkmark (Unicode check, dark accent), or empty.
            ZStack {
                if toggledState(item) {
                    Image(systemSymbol: .checkmark)
                        .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                        .foregroundStyle(Slate.State.accent)
                }
            }
            .frame(width: 20, alignment: .center)

            highlightedTitle(ranked)
                .font(.system(size: Slate.Typeface.body))
                .lineLimit(1)

            Spacer(minLength: Slate.Metric.space2)

            if let shortcut = item.shortcut, !shortcut.isEmpty {
                HStack(spacing: Slate.Metric.space1) {
                    ForEach(Array(keycaps(shortcut).enumerated()), id: \.offset) { _, key in
                        keycapChip(key)
                    }
                }
            }
        }
        .padding(.horizontal, Slate.Metric.space3)
        .frame(height: Slate.Metric.heightRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusItem)
                .fill(isSelected ? Slate.State.selected : Color.clear),
        )
        .padding(.horizontal, Slate.Metric.space2)
        .contentShape(Rectangle())
        // Hover moves the keyboard selection onto this row (spec: hover/tap → run).
        .onHover { hovering in
            if hovering { coordinator.paletteSelection = selectableIndex }
        }
        .onTapGesture { coordinator.run(item) }
        .id(item.id)
    }

    private func keycapChip(_ key: String) -> some View {
        Text(key)
            .font(.system(size: Slate.Typeface.small, weight: .medium))
            .foregroundStyle(Slate.Text.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, Slate.Metric.space1)
            .background(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusSmall)
                    .fill(Slate.Surface.raised),
            )
    }

    // MARK: - Title highlight (fzf ranges)

    /// The row title as a `Text`, with the fzf-matched code-point runs (``RankedRow/titleRanges``) tinted the
    /// accent colour + semibold. A range-less row (separator / zero-state / subtitle-only match) renders flat.
    private func highlightedTitle(_ ranked: RankedRow) -> Text {
        let title = ranked.item.title
        guard !ranked.titleRanges.isEmpty else {
            return Text(title).foregroundStyle(Slate.Text.primary)
        }
        // Accumulate `Text` segments then fold with `+` — `Text` has no `+=`, so a `result = result + …`
        // reassignment can't be a shorthand op; the array fold keeps it clean.
        var segments: [Text] = []
        var cursor = title.startIndex
        for range in ranked.titleRanges where range.lowerBound >= cursor {
            if cursor < range.lowerBound {
                segments.append(Text(title[cursor..<range.lowerBound]).foregroundStyle(Slate.Text.primary))
            }
            segments.append(Text(title[range]).foregroundStyle(Slate.State.accent).fontWeight(.semibold))
            cursor = range.upperBound
        }
        if cursor < title.endIndex {
            segments.append(Text(title[cursor...]).foregroundStyle(Slate.Text.primary))
        }
        return segments.reduce(Text(verbatim: "")) { $0 + $1 }
    }

    // MARK: - Derived data

    /// One result row paired with its selectable index (nil for separators). The keyboard selection indexes
    /// into the non-separator rows, so each action row knows whether it is the selected one. `Identifiable`
    /// (by the underlying row id) so `ForEach` diffs cleanly without a tuple key path.
    private struct DisplayRow: Identifiable {
        let ranked: RankedRow
        let selectableIndex: Int?
        var id: String { ranked.id }
    }

    /// The result rows paired with their selectable index — separators carry `nil`.
    private var displayRows: [DisplayRow] {
        var index = 0
        var out: [DisplayRow] = []
        for ranked in coordinator.rankedResults {
            if ranked.item.isSeparator {
                out.append(DisplayRow(ranked: ranked, selectableIndex: nil))
            } else {
                out.append(DisplayRow(ranked: ranked, selectableIndex: index))
                index += 1
            }
        }
        return out
    }

    /// The id of the currently keyboard-selected row (for `scrollTo`), or nil if nothing is selectable.
    private var selectedRowID: String? {
        var index = 0
        for ranked in coordinator.rankedResults where !ranked.item.isSeparator {
            if index == coordinator.paletteSelection { return ranked.id }
            index += 1
        }
        return nil
    }

    /// The focused pane's last-known working directory (cwd over the wire; stale-by-RTT is acceptable for
    /// display). nil ⇒ no badge. Reads the same active-pane chain the rest of the chrome uses.
    private var workingDirectory: String? {
        guard let session = store.tree.activeSession,
              let paneID = session.activeTab?.activePane else { return nil }
        let cwd = session.specs[paneID]?.lastKnownCwd
        guard let cwd, !cwd.isEmpty else { return nil }
        return cwd
    }

    /// Split a shortcut glyph string ("⇧⌘L", or a space-separated multi-chord sequence "⌃B D") into one chip
    /// per key symbol (the spec renders each key as its own rounded badge). Whitespace separators are dropped.
    private func keycaps(_ shortcut: String) -> [String] {
        shortcut.split(separator: " ").flatMap { chord in chord.map(String.init) }
    }
}

// MARK: - CwdDisplay (pure home-abbreviation for the cwd pill — no SwiftUI, so it is unit-pinned)

/// The pure display bridge that turns a RAW remote-host working directory into the abbreviated form the
/// command-palette WORKING DIRECTORY pill shows (`command-palette.png`: `~/Workplace/myproject/`).
///
/// Two transforms: a leading home prefix collapses to `~`, and a trailing `/` marks the directory. The cwd is
/// a **remote-host** path (from the `cwd()` metadata RPC), so the home is detected by SHAPE — `/Users/<name>`
/// (macOS) or `/home/<name>` (Linux) — NEVER `NSHomeDirectory()`, which is the CLIENT's own home and would be
/// wrong for a remote host. Pure + total + deterministic (no `FileManager`/`Date`, never traps); 100%
/// client-side display, so nothing here touches the wire / golden corpus. `CwdDisplayTests` pins the mapping
/// headlessly.
enum CwdDisplay {
    /// Home-style roots a remote cwd can carry, matched generically (the user name is the next path segment).
    private static let homeRoots = ["/Users/", "/home/"]

    /// Abbreviate a host cwd for the pill: `/Users/abner/Workplace/myproject` → `~/Workplace/myproject/`. An empty
    /// string stays empty; the filesystem root `/` stays `/`; an already-`~`-rooted path keeps its `~` and
    /// only gains the trailing slash; a non-home path (`/etc`) keeps its path and gains the trailing slash.
    static func abbreviate(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        return withTrailingSlash(tildeCollapsed(raw))
    }

    /// Replace a leading `/Users/<name>` or `/home/<name>` home prefix with `~`. A path already rooted at `~`,
    /// a path with no home prefix, or a bare home root WITHOUT a `<name>` segment is returned unchanged.
    private static func tildeCollapsed(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") { return path }
        for root in homeRoots where path.hasPrefix(root) {
            // The first path segment after the root is the user name; the home boundary is the END of that
            // segment (the next `/`, or the string end). A root with no name segment is NOT a home dir.
            let afterRoot = path.dropFirst(root.count)
            guard let first = afterRoot.first, first != "/" else { return path }
            if let slash = afterRoot.firstIndex(of: "/") {
                return "~" + afterRoot[slash...] // "~" + "/Workplace/myproject"
            }
            return "~" // the path IS exactly the home dir
        }
        return path
    }

    /// Append a single trailing `/` (the directory marker) unless one is already present.
    private static func withTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}
#endif
