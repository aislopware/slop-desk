# Find

## Summary

In-pane search across the visible buffer and scrollback. The find bar opens inline
at the top-right of the active pane, live-highlights every match, and shows an
`N of M` counter. Global Search (`⇧⌘F`) runs across every open tab's scrollback and
presents results in a dedicated results tab.

## Behaviors

- `⌘F` opens the find bar anchored top-right of the focused pane.
- Typing shows live results immediately — every match highlighted as you type; no submit.
- Inline counter shows `N of M` (e.g. `1 of 4`) — current match position out of total.
- `↩` or `⌘G` advances to next match; buffer scrolls to keep it visible. `⇧↩` or `⇧⌘G`
  moves to previous.
- `Esc` closes the find bar and removes all highlights.
- Find scope by focused pane type:
  - Terminal pane: visible viewport plus full scrollback.
  - File pane: full file contents.
  - Folder pane: file names only (not contents).
- Two toggle buttons right of the input:
  - `Aa` — case sensitivity (off by default; default case-insensitive).
  - `.*` — regex mode; pattern interpreted as a regular expression.
- Default search mode: case-insensitive literal string.
- `⇧⌘F` opens Global Search across every open tab's scrollback, in a dedicated results
  tab. Clicking a result jumps to that tab at the matched position.
- Global Search results grouped by tab: tab name as header, matching lines beneath with
  the matched term highlighted. Summary line: `N results — M tabs`.
- The Global Search results tab is a dedicated pane in the left sidebar (labelled
  "Search: <query>"), so users can navigate back after jumping.

## Keybindings

| Action             | Keys              |
|--------------------|-------------------|
| Open find          | `⌘F`              |
| Next match         | `↩` or `⌘G`       |
| Previous match     | `⇧↩` or `⇧⌘G`    |
| Close              | `Esc`             |
| Global Search      | `⇧⌘F`            |

## Config keys

No dedicated config keys. The `Aa` and `.*` toggles are per-session UI state, not
persisted. Default is case-insensitive literal.

## Visual spec

### find.png — In-pane find bar

Layout: standard app window — narrow left sidebar (tab list, dark ~#1e1e1e) and larger
main content (~#232323). macOS traffic-light controls top-left; title bar "OC | Reviewing todos".

Find bar: top-right of the content pane, overlaid on the buffer — floats above text, does
not reflow it.

Anatomy (left to right):
- Text input: rounded-rect, ~#2c2c2c fill, white caret/text, query "doc". Width ~120–140 pt.
- `Aa` toggle (case): small pill, monospace label, unselected state (same fill as bar).
- `.*` toggle (regex): same style, right of `Aa`, also unselected.
- `∧` previous-match chevron (up-arrow icon button).
- `∨` next-match chevron (down-arrow icon button).
- `×` close button (rightmost).

Controls packed into a compact horizontal strip, minimal padding. Bar background slightly
darker than pane content → subtle floating-card look; no border/stroke, contrast from
background shade.

Match highlight: "doc" highlighted in all visible occurrences. Current/focused match uses
a distinct solid warm amber/orange (~#f0a040) — e.g. "doc" inside "docs" on the first line;
other matches use the same color. Highlight spans exactly the matched characters, inlined;
surrounding text keeps normal terminal colors (gray/white prose, green/red tool output).

`N of M` counter: not separately visible in this screenshot (may be an input-field suffix,
or appears only with >1 match in viewport). "doc" shows multiple highlighted occurrences.

Sidebar: "TABS" header; tabs listed vertically:
- "project" (#1)
- "OC | Reviewing todos" (#2) — selected, lighter background (~#2d2d2d) + left accent bar.
- "abner@MacBook-AB…" (#3)
- "Yazi: project" (#4)

Status bar (bottom, ~#1a1a1a): "20.7K (10%) · $0.08" and "ctrl+p commands".

Typography: monospace throughout (neutral mono, e.g. JetBrains Mono / SF Mono). Find-bar
labels (`Aa`, `.*`) and sidebar tab labels (~11–12pt) in small sans-serif. Fully dark theme.

### global-search.png — Global Search results tab

Window title "Search: doc" replaces the normal tab title — Global Search opens as a
dedicated results tab.

Sidebar: "SEARCH" header replaces "TABS". A "Search: doc" item at top (selected). Below,
the TABS section lists tabs with results:
- "abner@MacBook-AB…:/…/Wo…" (#1)
- "OC | Reviewing todos:" (#2) — selected/active.
- "vi docs/code-review-todos…" (#3)

Main content (results tab):
- Top: search input spanning full width, contains "doc". Right of it: same `Aa`/`.*`
  toggles (compact, unselected). Below: summary line "4 results — 3 tabs" in muted gray (~#888).
- Result groups: each matching tab is a collapsible group with a checkbox-style
  expand/collapse control left of the tab/file name header. Header shows tab identity
  (hostname + path) in muted text.

Group examples from screenshot:
- "abner@MacBook-AB…: ~/Workspace/project:" — mini file-browser rows ("build  CREDITS.md
  resources  target", "Cargo.lock  **docs**  rust-toolchain.toml", "~/Workspace/project ❯")
  = folder-pane file-name matches.
- "OC | Reviewing todos:" — multi-line terminal scrollback; matched "doc" highlighted
  amber/orange inline; two result rows.
- "vi docs/code-review-todos.md:" — file-pane result with matched line, line-number column
  (1,1), and "Top" indicator — vi-style file pane.

Result rows show the full line containing the match for legibility. Highlights use the same
amber/orange as the in-pane bar. Thin vertical scrollbar far right (list may exceed viewport).

No per-group `N of M`; the global `N results — M tabs` summary handles the count. Overall:
compact, text-heavy, list-style — a first-class tab, not a modal overlay.

## Screenshots

- `find.png` — in-pane find bar with "doc" query, multiple amber highlights in buffer
- `global-search.png` — Global Search results tab for "doc", 4 results across 3 tabs

## SlopDesk mapping notes

### What maps 1:1

- **In-pane find bar**: entirely client-side. SlopDesk's `TerminalSurface` (libghostty)
  holds the scrollback; a find overlay scans it and draws highlights via the render pass
  or an overlay view top-right of the pane `NSView`. `Aa`/`.*` state is client-side
  (`@State`/`Defaults`).
- **Keybindings** (`⌘F`, `⌘G`, `⇧⌘G`, `Esc`, `⇧⌘F`): bind in `WorkspaceBindingRegistry` /
  the existing NSEvent prefix-key monitor. No host involvement.
- **Match highlighting in viewport**: request a libghostty re-render with highlight ranges,
  or draw a transparent overlay with highlight rects from cell coordinates. The overlay
  avoids patching libghostty's render path and is sufficient.
- **N of M counter**: client-side count from the find results array.
- **Regex mode**: `NSRegularExpression` (or the `Defaults` regex flag). The `.*` toggle's
  syntax maps approximately to `NSRegularExpression`; minor divergences (lookaheads, named
  groups) are acceptable — document them.
- **Scope by pane type**: SlopDesk has Terminal panes (libghostty scrollback) and possibly
  file/folder panes. Only Terminal panes required initially; file/folder panes stubbed.

### What cannot map 1:1 / flags

- **Global Search across all tabs' scrollback**: panes connect to a *remote* host, but the
  scrollback lives client-side (libghostty), so local scanning is fine. Panes that never
  received data (not yet connected/reconnected) have empty scrollback → incomplete results
  if any pane dropped its buffer. Acceptable limitation; document it.
- **Folder pane "file names only"**: no folder-browser pane yet. Skip v1; future work.
- **File pane "full file contents"**: no file pane yet. Skip v1.
- **Global Search "dedicated results tab"**: uses `PaneKind` + the workspace reconciler.
  A read-only results pane needs a new `PaneKind.findResults` or a `.systemDialog`-style
  ephemeral pane. The sidebar "SEARCH"-replaces-"TABS" header is cosmetic — a view-mode
  flag in `WorkspaceStore`.
- **iOS client**: `⌘` bindings (`⌘F`, `⌘G`, …) must be exposed via the iOS command palette
  or a toolbar button for keyboard-less use. Find-bar overlay needs touch-friendly (larger)
  hit targets on iOS.
- **Regex syntax**: original target was the Rust `regex` crate. On Swift/Apple,
  `NSRegularExpression` (ICU) is natural. ICU supports lookaheads (Rust `regex` does not by
  default); Rust `regex` supports `\b` word boundaries similarly. Divergence is minor and
  acceptable; label the toggle `.*` and document ICU semantics in help text.
- **Result click to jump**: clicking a Global Search result must scroll the target pane's
  buffer to the matched line, switching tabs first if needed. Maps onto `WorkspaceStore` tab
  switching + libghostty's scroll-to-row API — feasible but coordinates two async ops
  (tab switch → scroll).
