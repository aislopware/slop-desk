# Find

## Summary

In-pane search across the visible buffer and scrollback. The find bar opens inline
(top-right corner of the active pane), shows live highlights for every match in the
buffer, and displays an `N of M` counter. A separate Global Search (`⇧⌘F`) runs
across every open tab's scrollback and presents results in a dedicated results tab.

## Behaviors

- Pressing `⌘F` opens the find bar anchored to the top-right of the focused pane.
- Typing into the find bar shows live results immediately — every match is highlighted
  in the buffer as the user types; no explicit submit is required.
- An inline counter in the find bar shows `N of M` (e.g. `1 of 4`) indicating the
  current match position out of total matches.
- Pressing `↩` or `⌘G` advances to the next match; the buffer scrolls to keep the
  match visible.
- Pressing `⇧↩` or `⇧⌘G` moves to the previous match.
- Pressing `Esc` closes the find bar and removes all highlights.
- Find scope depends on the focused pane type:
  - Terminal pane: searches the visible viewport plus the full scrollback.
  - File pane: searches the full file contents.
  - Folder pane: searches file names only (not file contents).
- The find bar has two toggle buttons to the right of the input field:
  - `Aa` — toggles case sensitivity (off by default; default is case-insensitive).
  - `.*` — toggles regex mode; when active the pattern is interpreted as a regular expression.
- Default search mode: case-insensitive literal string.
- `⇧⌘F` opens Global Search, which runs across every open tab's scrollback and
  displays results in a dedicated results tab. Clicking a result jumps to that tab
  at the matched position.
- Global Search results are grouped by tab. Each group shows the tab name as a header
  and lists matching lines beneath it, with the matched term highlighted in the
  result row.
- Global Search also shows a summary line: `N results — M tabs`.
- The Global Search results tab is itself a dedicated pane in the left sidebar
  (labelled "Search: <query>"), so users can navigate back to results after jumping.

## Keybindings

| Action             | Keys              |
|--------------------|-------------------|
| Open find          | `⌘F`              |
| Next match         | `↩` or `⌘G`       |
| Previous match     | `⇧↩` or `⇧⌘G`    |
| Close              | `Esc`             |
| Global Search      | `⇧⌘F`            |

## Config keys

No dedicated config keys documented for Find on this page. The two toggles (`Aa` and
`.*`) are per-session UI state, not persisted config. Default is case-insensitive
literal.

## Visual spec

### find.png — In-pane find bar

Overall layout: standard app window — narrow left sidebar (tab list, dark background
~#1e1e1e) and large main content area (slightly lighter dark ~#232323). Window chrome:
macOS standard traffic-light controls top-left; title bar shows "OC | Reviewing todos".

Find bar position: top-right corner of the content pane, overlaid on the buffer. It
floats above the text content and does not reflow the buffer.

Find bar anatomy (left to right):
- Text input field: rounded-rect, medium-dark fill (~#2c2c2c), white caret, white input
  text. The field contains the query "doc" in white. Width approximately 120–140 pt.
- Toggle button `Aa` (case sensitive): small pill/button immediately to the right of the
  input, monospace label. Appears in a non-active (unselected) state — subtle, same
  fill as surrounding bar.
- Toggle button `.*` (regex): same style as `Aa`, placed to the right of `Aa`. Also
  in non-active state in the screenshot.
- Navigation chevron `∧` (previous match): small up-arrow icon button.
- Navigation chevron `∨` (next match): small down-arrow icon button.
- Close button `×`: rightmost, dismisses the bar.

All find-bar controls are packed into a compact horizontal strip with minimal padding.
The bar background is slightly darker than the pane content area, creating a subtle
floating card appearance. No border/stroke visible — contrast comes from the background
shade difference.

Match highlight in buffer: the word "doc" is highlighted in ALL its occurrences visible
in the buffer. The current (focused) match uses a distinct solid highlight color
(warm amber/orange ~#f0a040, the word "doc" inside "docs" on the first visible line is
shown with this highlight). Other matches also appear highlighted in the same color.
The highlight spans exactly the matched characters, inlined in the buffer text — the
text around the match remains in its normal terminal colors (light gray/white for
prose, green/red for tool output, etc.).

The `N of M` counter: not separately visible as standalone text in this screenshot
(it may be inside the input field as a suffix, or appear only once there is more
than one match visible in viewport). The query "doc" shows multiple highlighted
occurrences in the buffer.

Sidebar (left): "TABS" header at top. Tabs listed vertically:
- "project" (#1)
- "OC | Reviewing todos" (#2) — currently selected, highlighted with a lighter
  background (~#2d2d2d) and a left accent bar.
- "abner@MacBook-AB…" (#3)
- "Yazi: project" (#4)

Status bar (bottom): dark strip, shows token/cost info "20.7K (10%) · $0.08" and
"ctrl+p commands". Background ~#1a1a1a.

Typography: monospace throughout (appears to be a neutral mono font, likely similar
to JetBrains Mono or SF Mono). Find-bar labels (`Aa`, `.*`) are in a small
sans-serif. Sidebar tab labels are small sans-serif (~11–12pt). All on a fully dark
theme.

### global-search.png — Global Search results tab

Window title: "Search: doc". This replaces the normal tab title, confirming Global
Search opens as a dedicated results tab.

Left sidebar: "SEARCH" header replaces "TABS" header at top. A "Search: doc" item
appears at the top of the sidebar (selected, current). Below it the TABS section
header lists tabs that had results:
- "abner@MacBook-AB…:/…/Wo…" (#1)
- "OC | Reviewing todos:" (#2) — appears selected/active.
- "vi docs/code-review-todos…" (#3)

Main content area layout (the results tab):
Top section: a search input field spanning the full width of the content area. It
contains "doc" in white text. To the right of the field: the same `Aa` and `.*`
toggle buttons (same compact style, unselected). Below the search field: a summary
line "4 results — 3 tabs" in a muted/secondary color (lighter gray, ~#888).

Result groups: each matching tab is shown as a collapsible group. Groups use a
checkbox-style expand/collapse control to the left of the tab/file name header. The
header row shows the tab identity (hostname + path) in muted text.

Inside each group, matching lines are shown. Example from screenshot:
- Group "abner@MacBook-AB…: ~/Workspace/project:": shows a mini file-browser–style
  row with "build  CREDITS.md  resources  target" and "Cargo.lock  **docs**
  rust-toolchain.toml" and "~/Workspace/project ❯" — these are folder-pane search
  results showing file name matches.
- Group "OC | Reviewing todos:": shows multi-line terminal scrollback context. The
  matched segment ("doc") is highlighted with the same amber/orange color inline.
  Two result rows are shown; each row displays a line of scrollback text with the
  match highlighted.
- Group "vi docs/code-review-todos.md:": shows a file-pane result with the matched
  line, a line number column (1,1), and "Top" positional indicator — consistent
  with a vi-style file pane.

Result rows show enough context (the full line containing the match) to be legible.
Match highlights use the same amber/orange highlight as the in-pane find bar.

Scrollbar: thin vertical scrollbar on far right of results area, indicating the
list may be taller than the viewport.

No `N of M` counter per group; instead the global `N results — M tabs` summary
handles the count.

Overall visual density: compact, text-heavy, list-style — more like a search results
panel than a floating overlay. Feels integrated as a first-class tab rather than a
modal dialog.

## Screenshots

- `find.png` — in-pane find bar with "doc" query, multiple amber highlights in buffer
- `global-search.png` — Global Search results tab for "doc", 4 results across 3 tabs

## SlopDesk mapping notes

### What maps 1:1

- **In-pane find bar**: can be implemented entirely client-side. SlopDesk's
  `TerminalSurface` (backed by libghostty) maintains the scrollback; a find overlay
  can scan that buffer and draw highlights via the same render pass or an overlay
  view positioned top-right of the pane `NSView`. The `Aa` / `.*` toggle state is
  purely client-side UI state (`@State`/`Defaults`).
- **Keybindings** (`⌘F`, `⌘G`, `⇧⌘G`, `Esc`, `⇧⌘F`): all can be bound in
  `WorkspaceBindingRegistry` / the NSEvent monitor already used for the prefix key.
  No host involvement needed.
- **Match highlighting in viewport**: libghostty renders the buffer; slopdesk can
  request a re-render pass with highlight ranges injected, or draw a transparent
  overlay view with highlight rects computed from cell coordinates. The latter avoids
  patching libghostty's render path and is sufficient.
- **N of M counter**: purely client-side count derived from the find results array.
- **Regex mode**: use Swift's `NSRegularExpression` or the `Defaults`-stored regex
  flag; the `.*` toggle's regex syntax maps approximately to `NSRegularExpression`
  (POSIX-extended). Minor syntax differences (lookaheads, named groups) are
  acceptable — document the divergence.
- **Scope differences by pane type**: slopdesk has Terminal panes (scrollback from
  libghostty) and potentially file/folder panes. For the initial implementation, only
  Terminal panes are required; file/folder panes can be stubbed.

### What cannot map 1:1 / flags

- **Global Search across all tabs' scrollback**: slopdesk panes connect to a
  *remote* host. The scrollback buffer lives client-side (libghostty), so scanning
  it locally is fine. However panes that have never received data (not yet connected
  or reconnected) will have empty scrollback — the search results will be incomplete
  if any pane has dropped its buffer. This is an acceptable limitation; document it.
- **Folder pane "file names only" search**: slopdesk does not currently have a
  folder-browser pane. Skip for v1; note as future work.
- **File pane "full file contents" search**: same — file pane not yet present in
  slopdesk. Skip for v1.
- **Global Search "dedicated results tab"**: slopdesk uses `PaneKind` + the
  workspace reconciler. A read-only results pane would need a new `PaneKind.findResults`
  or reuse a `.systemDialog`-style ephemeral pane. The sidebar "SEARCH" header
  replacing "TABS" is a purely cosmetic state — implementable by toggling a view mode
  flag in `WorkspaceStore`.
- **iOS client**: the `⌘` key bindings (`⌘F`, `⌘G`, etc.) must be exposed via the
  iOS command palette or a toolbar button for hardware-keyboard-less use. The find
  bar overlay layout needs to be touch-friendly (larger hit targets) on iOS.
- **Regex syntax**: the `.* ` toggle's original design target was the Rust `regex`
  crate's syntax. On the Swift/Apple side, `NSRegularExpression` (ICU) is the
  natural choice. Differences include: ICU supports lookaheads (Rust's `regex`
  does not by default), but Rust `regex` supports `\b` word boundaries similarly.
  This divergence is minor and acceptable; we label the toggle `.*` and document
  ICU semantics in our help text.
- **Result click to jump**: in Global Search, clicking a result must scroll the
  target pane's buffer to the matched line. If the target pane is on a different tab,
  slopdesk must switch to that tab first. This maps onto `WorkspaceStore` tab
  switching + libghostty's scroll-to-row API. Feasible but requires coordinating
  two async operations (tab switch → scroll).
