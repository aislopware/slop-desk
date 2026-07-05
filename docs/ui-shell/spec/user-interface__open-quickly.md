# Open Quickly

## Summary

The Xcode-style `⌘⇧O` picker. One field — fuzzy across everything you might want to
jump to: open tabs, recent sessions, frequent folders, SSH hosts, agent sessions, the
focused pane's commands and links, and saved recipes.

## Behaviors

- Activated globally with `⌘⇧O` (opens the **All** filter) from any keyboard context:
  main window, settings surface, agent surface.
- Activated with `⌘J` (Jump-to) — opens directly to the **Current** filter, scoped to
  the focused pane.
- The picker is a floating panel that overlays the window (not a sheet, not a separate
  window); the terminal/sidebar behind it remains visible but dimmed/blurred.
- A single text field at the top accepts fuzzy query input; results update live.
- A filter bar with 8 named filter pills sits below the search field:
  **All**, **Opened**, **Recent**, **Folders**, **SSH**, **Agents**, **Current**,
  **Recipes**.
- The active filter pill is rendered with a filled/highlighted style; inactive pills
  are outlined/unfilled.
- Each filter is also a group heading in the **All** list — sections are labelled with
  ALL-CAPS group names (e.g. "WINDOWS", "TABS").
- Results are ranked; the **All** view merges all groups into one ranked list with
  section headers.
- Each result row shows: a leading icon (window icon or tab/pane icon), a primary
  label (window title or tab name), trailing metadata (tab count or CWD path), and a
  trailing type badge ("Window" or "Tab").
- The selected/highlighted row has a medium-grey filled background across the full
  width of the picker.
- The first result is auto-selected when the picker opens (or when the query changes).
- A bottom bar shows: left side "Quick Select ⌘" hint; right side "Switch to ↩" and
  "Actions ⌘K" buttons — these are static affordance labels, not interactive buttons.
- `↩` on a result runs the item's **default action**: open tab, switch to window,
  resume agent session, connect SSH, etc. (action label is context-sensitive: shown as
  "Switch to ↩" in the bottom bar for open tabs).
- `⌘K` opens an **Actions** popover for the highlighted item, fuzzy-searchable, with
  contextual actions per item type.
- `⌘1`–`⌘9` open the 1st–9th visible result directly without pressing `↩`.

### Filter: All (`⌘0`)
- Default when opened via `⌘⇧O`.
- Everything below, merged into a single ranked list with section group headers.

### Filter: Opened (`⌘W`)
- Every window, tab, and pane that is currently open. Allows mouse-free switching.

### Filter: Recent (`⌘R`)
- Recently-closed tabs and folders from this session plus ones restored from the
  previous session.

### Filter: Folders (`⌘Z`)
- Frequently-used folders ranked by SlopDesk's built-in frecency database.

### Filter: SSH (`⌘S`)
- Hosts parsed from `~/.ssh/config`.
- Default action (`↩`): connect in the focused pane.
- `⌘K` action: connect in a new tab or window.

### Filter: Agents (`⌘G`)
- Claude, Codex, and OpenCode sessions whose project contains the current directory.
- Actions: Resume session, View Session History, Copy Project Path, Copy Session ID.

### Filter: Current (`⌘J`)
- Focused pane only; `⌘J` opens the picker directly to this filter.
- Surfaces:
  - **Commands** from shell history — live commands plus commands restored from earlier
    session logs.
  - **URLs, files, and folders** detected in the terminal output (see Files and Links
    feature).
  - The **outline** of a focused file pane — Markdown/HTML headings, JSON/YAML/TOML
    keys, diff files (see Outline feature).
  - **Agent prompts** from the focused agent session.

### Filter: Recipes (`⌘E`)
- Workspace recipes the user has saved.

### Actions popover (`⌘K`) — per item type

| Item | Available actions |
|------|------------------|
| Tab | Close Tab · Move Tab to New Window · Reveal CWD in Finder · Copy CWD Path |
| Folder | Open in New Window · Split Right / Down · Change Directory Here · Reveal · Copy Path · Forget This Folder |
| SSH host | Connect · Connect in New Tab / New Window · Copy Command |
| Agent session | View Session History · Resume · Copy Project Path · Copy Session ID |
| Command | Re-Run in Current Pane · Re-Run in New Tab · Copy Command |
| File / URL | Preview · Open in Default App · Open in SlopDesk (current pane, new tab, split) · Change Directory Here · Reveal · Copy |

## Keybindings

| Action | Keys |
|--------|------|
| Open picker (All filter) | `⌘⇧O` |
| Open picker (Current filter / Jump-to) | `⌘J` |
| Move selection up / down | `↑` / `↓` |
| Jump through list | `PageUp` / `PageDown`, `Home` / `End` |
| Open 1st–9th result directly | `⌘1` – `⌘9` |
| Run default action on highlighted item | `↩` |
| Open Actions popover for highlighted item | `⌘K` |
| Cycle filters forward / backward | `Tab` / `⇧Tab` |
| Switch to All filter | `⌘0` |
| Switch to Opened filter | `⌘W` |
| Switch to Recent filter | `⌘R` |
| Switch to Folders filter | `⌘Z` |
| Switch to SSH filter | `⌘S` |
| Switch to Agents filter | `⌘G` |
| Switch to Current filter | `⌘J` |
| Switch to Recipes filter | `⌘E` |
| Close picker | `Esc` |

## Config keys

None documented on this page. The Open Quickly feature has no user-facing config keys;
behavior (frecency database, SSH config path, etc.) is not externally configurable per
this page.

## Visual spec

### Screenshot: open-quickly.png

**Overall layout:**
The picker is a floating rounded-rectangle panel (~700 px wide, ~680 px tall in the
screenshot) centered horizontally over the terminal window. It partially overlaps the
left sidebar (tabs list) and the main terminal area. The terminal content behind it is
still visible but is not visibly blurred in the screenshot — the panel has a solid
background.

**Panel background:**
Dark charcoal, approximately `#252525`–`#282828` (matches the terminal dark theme).
Rounded corners (~10 pt radius). A very subtle 1 px border or shadow separates it from
the background.

**Top section — Search field:**
- Full-width, no visible border box; blends with the panel.
- Left: magnifying-glass icon (⌕), medium-grey, ~16 pt.
- Text area: placeholder "Search tabs, windows..." in medium grey; the cursor is a
  blue text-input caret (macOS system blue, ~`#007AFF`).
- No visible inner shadow or border on the field itself — just flat dark area.
- Vertically padded ~12–14 pt top/bottom from panel edges.

**Filter bar:**
- Sits directly below the search field, full-width, with ~12 pt horizontal padding.
- 8 pill-shaped filter buttons: **All**, **Opened**, **Recent**, **Folders**, **SSH**,
  **Agents**, **Current**, **Recipes**.
- Active pill ("All"): filled background of medium-dark grey (`#3A3A3C` or similar),
  white label text, pill fully opaque. Slightly rounded rectangle (~full pill radius).
- Inactive pills: outlined with a ~1 px stroke in medium grey (`#48484A`), text in
  light grey (`#AEAEB2`), transparent fill. Same pill height.
- Pill height: ~28 pt. Font: ~13 pt, medium weight.
- Horizontal spacing between pills: ~6–8 pt.

**Results list:**
- Below the filter bar, separated by ~8–10 pt spacing.
- Section headers (e.g. "WINDOWS", "TABS"): all-caps, small (~11 pt), muted grey
  (`#636366` or similar), left-padded ~16 pt. No background differentiation.
- Result rows: full-width, ~52–56 pt tall, horizontally padded ~12–16 pt.
  - Leading icon: ~20 pt square. Window icon is a double-rectangle outline; Tab icon
    is a single rectangle outline. Both in medium grey.
  - Primary label: ~15 pt, white or near-white (`# FFFFFF` / `#F2F2F7`). Left of center.
  - Trailing path/metadata: right-aligned, ~12–13 pt, muted grey (`#8E8E93`). Shows
    CWD path or tab count.
  - Trailing type badge: rightmost, small pill with label "Window" or "Tab". Badge
    background is dark grey (`#3A3A3C`), text in light grey (`#AEAEB2`), ~11 pt, ~6 pt
    horizontal padding. Rounded corners.
  - Selected row: fills full width with a solid medium-grey highlight (`#3A3A3C`
    approximately), no border. ALL elements (icon, text, badge) remain on top of it.
  - Unselected rows: transparent background.
- First visible result (selected): "✱ Create Ghostty-compatible config system" with
  a ✱ (asterisk/star) prefix in the label, "23 tabs" trailing, "Window" badge.
- The ✱ prefix appears to denote an agent/active window context.
- Second result: "abner@MacBook-Pro: ~/Workplace/project" with "16 tabs" and "Window" badge.
- Then a "TABS" section header followed by individual tab rows, each with a tab icon,
  title (e.g. "OpenCode", "Yazi: project", "index.md"), trailing CWD path, and "Tab" badge.

**Bottom bar:**
- Fixed at bottom of the panel. Single-row, separated from results by a thin 1 px
  horizontal rule in dark grey (`#3A3A3C`).
- Left side: "Quick Select ⌘" — grey muted label, ~12 pt.
- Right side: "Switch to ↩" and "Actions ⌘K" — two small pill-like buttons or plain
  labels. Both in light grey, ~12 pt. "Actions ⌘K" has a slightly more prominent style
  (appears pill-wrapped with a subtle outline).
- Background: same dark charcoal as panel, no color difference.

**Typography summary:**
- All text: SF Pro (system font), dark-mode palette.
- Section headers: 11 pt, uppercase, `#636366`.
- Row primary labels: 15 pt regular, `#F2F2F7`.
- Row trailing metadata: 13 pt regular, `#8E8E93`.
- Badge labels: 11 pt, `#AEAEB2`.
- Search placeholder: 15 pt regular, `#636366`.
- Filter pills inactive: 13 pt medium, `#AEAEB2`.
- Filter pills active: 13 pt medium, `#FFFFFF`.

**Context visible behind the picker:**
- Left sidebar: vertical list of tab titles ("OpenCode", "Yazi: project", "index.md",
  "abner@MacB…", etc.) with "TABS" section header in all-caps; "abner@MacB…" row has
  a left-edge highlight indicating it is the active/selected tab.
- Titlebar: "abner@MacBook-Pro: ~/Workplace/project" centered. Traffic-light buttons top-left.
- Active pane header shows CWD breadcrumb with git branch "(main ✗)•★ ▶" in colored
  text (cyan path, purple git info).

## Screenshots

- `open-quickly.png`

## SlopDesk mapping notes

### Direct mappings (1:1 feasible)

- **Panel UI:** Implement as an `NSPanel` (or `NSWindow` with `.nonactivatingPanel`
  style) floated above the `WorkspaceView`. SwiftUI `searchable` or a custom
  `TextField` + `List` satisfies the search field + filtered list.
- **Filter bar:** A horizontal `HStack` of `Toggle`-style pill buttons; active state
  uses filled background, inactive uses stroked outline. Filter cycling via `Tab`/`⇧Tab`
  maps directly to key handler in the panel.
- **Opened filter:** `WorkspaceStore` already tracks all live panes/tabs; enumerate
  `PaneID`s and their titles/CWDs. 1:1 feasible.
- **Recent filter:** Persist recently-closed pane metadata (title + CWD) in
  `DetachedSessionStore` or a new `RecentStore`; straightforward.
- **Folders filter:** A frecency database (access-frequency × recency score) over
  visited CWDs; feasible in-process using SQLite or a lightweight in-memory store.
- **Recipes filter:** Maps to the Recipes feature (workspace recipes); 1:1 once
  Recipes are implemented.
- **Current filter — commands:** Shell history from the focused pane's `OSC 133`
  integration (already tracked in `SlopDeskWorkspaceCore`). 1:1 feasible.
- **Current filter — URLs/files/folders:** `Files and Links` detection from terminal
  output — already in scope (see the Files and Links spec). 1:1 feasible.
- **Current filter — outline:** Markdown/JSON/YAML/TOML outline from focused file pane.
  Feasible, scoped to the file-viewer pane type.
- **Actions popover (`⌘K`):** A secondary `NSPanel` or popover anchored to the
  selected row with a filtered action list. 1:1 feasible.
- **`⌘1`–`⌘9` quick-select:** Key handler in the panel maps index to result. 1:1.
- **Bottom bar hints:** Static `Text` labels in a fixed footer. 1:1.

### Partial or constrained mappings

- **SSH filter (`⌘S`):** Parsing `~/.ssh/config` is feasible on macOS. The "connect
  in focused pane" action sends an SSH command to the local PTY — 1:1 for the macOS
  client. On the **iOS client**, SSH config is not present on-device; this filter
  would need to be sourced from the host's `~/.ssh/config` over the remote control
  channel, not the local filesystem. Flag: **iOS — SSH config must come from host.**
- **Agents filter (`⌘G`):** "Sessions whose project contains the current directory"
  requires knowing the CWD of each agent session. CWDs are available via OSC 7
  (`SLOPDESK_*` shell integration), but only for local sessions. For remote-SSH panes,
  the CWD is the remote host's filesystem — the agent-session-to-CWD lookup must be
  done on the host side and relayed over the inspector/control channel.
  **Agent session history** (View Session History) requires access to the agent's
  transcript, which is local to the host machine. On iOS client, transcripts are not
  accessible directly — must proxy through the host.
- **Current filter — agent prompts:** The focused agent session's prompts must come
  from the host-side agent integration (`ClaudePaneDetector`, `AgentControlListener`).
  Already in scope for the agent supervision layer.

### Cannot map 1:1 (with reason)

- **"Reveal CWD in Finder" action (Tab items):** On the macOS CLIENT connecting to a
  remote host, the CWD is on the REMOTE host's filesystem, not the client's. Finder
  cannot reveal a remote path. Options: (a) disable this action for remote panes,
  (b) show the path in Finder only when the pane is local, (c) offer "Copy Remote Path"
  as a substitute. **Recommendation: disable for remote panes, always offer Copy Path.**
- **"Open in Default App" / "Reveal in Finder" for files (File/URL items in Current
  filter):** Same constraint — files detected in terminal output may be remote paths.
  For remote paths, offer "Copy Path" only; for `file://` URLs that resolve locally,
  standard macOS open is fine.
- **macOS Picture-in-Picture (PiP):** Not applicable to this feature page.
- **Remote SSH badge on the result row:** Not covered by the base spec above, but in
  slopdesk every pane is implicitly remote. A "remote" indicator (host badge or
  truncated hostname) on each row would be needed if/when multi-host sessions are
  supported (not in scope for v1).

### Implementation priority notes

- Implement **All + Opened** first — these require only `WorkspaceStore` and give
  immediate tab-switching value.
- **SSH** and **Agents** filters depend on host-side data channels; defer until the
  agent supervision and remote-control layers are wired.
- **Folders** (frecency DB) is self-contained and can be implemented independently.
- The `⌘K` Actions popover can be stubbed with a minimal action set (Close, Copy Path)
  and expanded incrementally.
