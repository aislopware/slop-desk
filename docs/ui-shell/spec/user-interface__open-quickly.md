# Open Quickly

## Summary

The Xcode-style `⌘⇧O` picker. One fuzzy field across everything you might jump to: open tabs, recent sessions, frequent folders, SSH hosts, agent sessions, the focused pane's commands and links, and saved recipes.

## Behaviors

- `⌘⇧O` (opens **All** filter) from any keyboard context: main window, settings, agent surface.
- `⌘J` (Jump-to) opens directly to **Current**, scoped to the focused pane.
- Floating panel overlaying the window (not a sheet, not a separate window); terminal/sidebar behind stays visible but dimmed/blurred.
- Single top text field: fuzzy query, live results.
- Filter bar below the field with 8 pills: **All**, **Opened**, **Recent**, **Folders**, **SSH**, **Agents**, **Current**, **Recipes**. Active pill is filled/highlighted; inactive pills outlined/unfilled.
- Each filter is also an ALL-CAPS group heading in the **All** list (e.g. "WINDOWS", "TABS"). Results are ranked; **All** merges all groups into one ranked list with section headers.
- Result row: leading icon (window or tab/pane), primary label (window title or tab name), trailing metadata (tab count or CWD path), trailing type badge ("Window" or "Tab").
- Selected row: medium-grey filled background across full picker width. First result auto-selects on open and on query change.
- Bottom bar (static labels, not interactive): left "Quick Select ⌘"; right "Switch to ↩" and "Actions ⌘K".
- `↩` runs the item's **default action** (open tab, switch to window, resume agent session, connect SSH, etc.); label is context-sensitive ("Switch to ↩" for open tabs).
- `⌘K` opens a fuzzy-searchable **Actions** popover with contextual actions per item type.
- `⌘1`–`⌘9` open the 1st–9th visible result directly, no `↩`.

### Filter: All (`⌘0`)
- Default when opened via `⌘⇧O`. Everything below merged into one ranked list with section group headers.

### Filter: Opened (`⌘W`)
- Every currently-open window, tab, and pane. Mouse-free switching.

### Filter: Recent (`⌘R`)
- Recently-closed tabs and folders from this session plus ones restored from the previous session.

### Filter: Folders (`⌘Z`)
- Frequently-used folders ranked by SlopDesk's built-in frecency database.

### Filter: SSH (`⌘S`)
- Hosts parsed from `~/.ssh/config`.
- `↩`: connect in the focused pane. `⌘K`: connect in a new tab or window.

### Filter: Agents (`⌘G`)
- Claude, Codex, and OpenCode sessions whose project contains the current directory.
- Actions: Resume session, View Session History, Copy Project Path, Copy Session ID.

### Filter: Current (`⌘J`)
- Focused pane only; `⌘J` opens the picker directly here. Surfaces:
  - **Commands** from shell history — live plus commands restored from earlier session logs.
  - **URLs, files, and folders** detected in terminal output (see Files and Links feature).
  - The **outline** of a focused file pane — Markdown/HTML headings, JSON/YAML/TOML keys, diff files (see Outline feature).
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

None. Open Quickly has no user-facing config keys; behavior (frecency database, SSH config path, etc.) is not externally configurable per this page.

## Visual spec

### Screenshot: open-quickly.png

**Overall layout:** Floating rounded-rectangle panel (~700 px wide, ~680 px tall) centered horizontally over the terminal window, partially overlapping the left sidebar (tabs list) and main terminal area. Terminal content behind stays visible but is not visibly blurred — the panel has a solid background.

**Panel background:** Dark charcoal, ~`#252525`–`#282828` (matches terminal dark theme). Rounded corners (~10 pt radius). Very subtle 1 px border or shadow.

**Top section — Search field:**
- Full-width, no border box; blends with panel.
- Left: magnifying-glass icon (⌕), medium-grey, ~16 pt.
- Placeholder "Search tabs, windows..." in medium grey; cursor is a blue text-input caret (macOS system blue, ~`#007AFF`).
- No inner shadow/border — flat dark area. Vertically padded ~12–14 pt top/bottom.

**Filter bar:**
- Directly below search field, full-width, ~12 pt horizontal padding.
- 8 pill buttons: **All**, **Opened**, **Recent**, **Folders**, **SSH**, **Agents**, **Current**, **Recipes**.
- Active pill ("All"): filled medium-dark grey (`#3A3A3C`), white label, fully opaque, ~full pill radius.
- Inactive pills: ~1 px stroke medium grey (`#48484A`), light-grey text (`#AEAEB2`), transparent fill, same height.
- Pill height ~28 pt. Font ~13 pt medium. Spacing between pills ~6–8 pt.

**Results list:**
- Below filter bar, ~8–10 pt spacing.
- Section headers ("WINDOWS", "TABS"): all-caps, ~11 pt, muted grey (`#636366`), left-padded ~16 pt, no background differentiation.
- Result rows: full-width, ~52–56 pt tall, ~12–16 pt horizontal padding.
  - Leading icon ~20 pt square: Window = double-rectangle outline, Tab = single-rectangle outline, both medium grey.
  - Primary label: ~15 pt, white/near-white (`#FFFFFF` / `#F2F2F7`), left of center.
  - Trailing metadata: right-aligned, ~12–13 pt, muted grey (`#8E8E93`); CWD path or tab count.
  - Trailing type badge: rightmost small pill "Window"/"Tab", dark-grey background (`#3A3A3C`), light-grey text (`#AEAEB2`), ~11 pt, ~6 pt horizontal padding, rounded.
  - Selected row: full-width solid medium-grey highlight (~`#3A3A3C`), no border; all elements stay on top. Unselected: transparent.
- First result (selected): "✱ Create Ghostty-compatible config system", ✱ (asterisk/star) prefix, "23 tabs" trailing, "Window" badge. ✱ appears to denote an agent/active window context.
- Second result: "abner@MacBook-Pro: ~/Workplace/project", "16 tabs", "Window" badge.
- Then a "TABS" section header with tab rows, each with tab icon, title (e.g. "OpenCode", "Yazi: project", "index.md"), trailing CWD path, "Tab" badge.

**Bottom bar:**
- Fixed, single-row, separated from results by a thin 1 px rule in dark grey (`#3A3A3C`).
- Left: "Quick Select ⌘" — grey muted label, ~12 pt.
- Right: "Switch to ↩" and "Actions ⌘K" — small pill-like buttons or plain labels, light grey, ~12 pt; "Actions ⌘K" slightly more prominent (pill-wrapped with subtle outline).
- Background: same dark charcoal as panel.

**Typography summary:** SF Pro, dark-mode palette.
- Section headers: 11 pt uppercase, `#636366`.
- Row primary labels: 15 pt regular, `#F2F2F7`.
- Row trailing metadata: 13 pt regular, `#8E8E93`.
- Badge labels: 11 pt, `#AEAEB2`.
- Search placeholder: 15 pt regular, `#636366`.
- Filter pills inactive: 13 pt medium, `#AEAEB2`. Active: 13 pt medium, `#FFFFFF`.

**Context behind the picker:**
- Left sidebar: vertical tab-title list ("OpenCode", "Yazi: project", "index.md", "abner@MacB…", etc.) with "TABS" all-caps header; "abner@MacB…" row has a left-edge highlight (active/selected tab).
- Titlebar: "abner@MacBook-Pro: ~/Workplace/project" centered; traffic-light buttons top-left.
- Active pane header: CWD breadcrumb with git branch "(main ✗)•★ ▶" (cyan path, purple git info).

## Screenshots

- `open-quickly.png`

## SlopDesk mapping notes

### Direct mappings (1:1 feasible)

- **Panel UI:** An `NSPanel` (or `NSWindow` with `.nonactivatingPanel` style) floated above `WorkspaceView`. SwiftUI `searchable` or a custom `TextField` + `List` covers search field + filtered list.
- **Filter bar:** `HStack` of `Toggle`-style pill buttons (filled active / stroked inactive); `Tab`/`⇧Tab` cycling maps to a panel key handler.
- **Opened filter:** `WorkspaceStore` already tracks all live panes/tabs; enumerate `PaneID`s + titles/CWDs.
- **Recent filter:** Persist recently-closed pane metadata (title + CWD) in `DetachedSessionStore` or a new `RecentStore`.
- **Folders filter:** Frecency database (access-frequency × recency) over visited CWDs; in-process SQLite or lightweight in-memory store.
- **Recipes filter:** Maps to the Recipes feature; 1:1 once Recipes exist.
- **Current — commands:** Shell history from the focused pane's `OSC 133` integration (tracked in `SlopDeskWorkspaceCore`).
- **Current — URLs/files/folders:** `Files and Links` detection from terminal output (see that spec).
- **Current — outline:** Markdown/JSON/YAML/TOML outline from focused file pane; scoped to the file-viewer pane type.
- **Actions popover (`⌘K`):** Secondary `NSPanel`/popover anchored to the selected row with a filtered action list.
- **`⌘1`–`⌘9` quick-select:** Panel key handler maps index to result.
- **Bottom bar hints:** Static `Text` labels in a fixed footer.

### Partial or constrained mappings

- **SSH filter (`⌘S`):** Parsing `~/.ssh/config` is feasible on macOS; "connect in focused pane" sends an SSH command to the local PTY (1:1 macOS client). On the **iOS client**, SSH config is not on-device — it must be sourced from the host's `~/.ssh/config` over the remote control channel. Flag: **iOS — SSH config must come from host.**
- **Agents filter (`⌘G`):** "Sessions whose project contains the current directory" needs each agent session's CWD. CWDs come from OSC 7 (`SLOPDESK_*` shell integration) but only for local sessions; for remote-SSH panes the CWD is the remote host's filesystem, so the session-to-CWD lookup must be done host-side and relayed over the inspector/control channel. **View Session History** needs the agent transcript, local to the host; on iOS transcripts are not directly accessible — proxy through the host.
- **Current — agent prompts:** Must come from host-side agent integration (`ClaudePaneDetector`, `AgentControlListener`). Already in scope for the agent supervision layer.

### Cannot map 1:1 (with reason)

- **"Reveal CWD in Finder" (Tab items):** On a macOS CLIENT connected to a remote host, the CWD is on the REMOTE filesystem — Finder can't reveal a remote path. Options: (a) disable for remote panes, (b) reveal only when the pane is local, (c) offer "Copy Remote Path". **Recommendation: disable for remote panes, always offer Copy Path.**
- **"Open in Default App" / "Reveal in Finder" for files (File/URL, Current filter):** Same constraint — detected files may be remote paths. For remote paths offer "Copy Path" only; for `file://` URLs that resolve locally, standard macOS open is fine.
- **macOS Picture-in-Picture (PiP):** Not applicable to this feature page.
- **Remote SSH badge on the result row:** Not in the base spec; in slopdesk every pane is implicitly remote. A "remote" indicator (host badge or truncated hostname) per row is needed only if/when multi-host sessions are supported (not in scope for v1).

### Implementation priority notes

- Implement **All + Opened** first — require only `WorkspaceStore`, give immediate tab-switching value.
- **SSH** and **Agents** depend on host-side data channels; defer until agent supervision and remote-control layers are wired.
- **Folders** (frecency DB) is self-contained; implement independently.
- The `⌘K` Actions popover can be stubbed minimally (Close, Copy Path) and expanded incrementally.
