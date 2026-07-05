# Drag and Drop

## Summary

SlopDesk accepts files, folders, and URLs from Finder, browsers, and any app exporting standard pasteboard types. Dragging content over a pane shows an overlay with labelled drop zones whose actions depend on content type and zone. SlopDesk's own tabs and panes are also draggable — reorder, move between windows, or tear off into new windows.

## Behaviors

- Accepts drag sources exporting standard pasteboard types: file/folder URLs, web URLs, plain text.
- Dragging external content over a pane shows a full-screen overlay with multiple labelled circular/elliptical drop targets across the pane.
- Overlay zones for file drops (`drop-overlay.mp4` frame 3):
  - **New Tab** (top-center, small circle): new terminal tab with `cwd = <folder>`.
  - **Insert Path** (center, medium circle): pastes the file path into the focused terminal.
  - **Open In-Place** (bottom-center, medium circle): opens the file/folder as an in-place pane viewer.
  - **Split Left** (left edge, large ellipse off-screen left): opens content in a new pane split left.
  - **Split Right** (right edge, large ellipse off-screen right): opens content in a new pane split right.
- Zones are soft blobs with light semi-transparent fill. The active/hovered zone is more saturated and darker (olive-green on the active "Split Right"); non-active zones use muted warm-grey or light-sage. Each carries a short text label in a small dark sans-serif at the zone center.
- While dragging, the file follows the cursor as a floating "ghost" thumbnail (macOS system drag image); a green "+" badge appears over a valid drop zone.
- Drop behaviour by content type:

  | Dragged thing | Green half / terminal action | Blue half / pane action |
  |---|---|---|
  | Folder | New terminal tab with `cwd = <folder>` | Folder pane (directory browser) |
  | File | (n/a — disabled) | File pane (viewer) |
  | URL | (n/a — disabled) | URL pane |
  | Text snippet | Pastes into the focused terminal | Same |

- The "green half" (terminal action) is disabled for files and URLs — no "open as terminal" semantic exists for those types.
- After a file drop resolves to "Insert Path", the path is inserted as literal text into the terminal prompt and a command filter line appears at the terminal bottom (e.g. `No matching items` / the path string).
- **Dragging own tabs**: drag a tab to reorder (thin insertion-line indicator shows landing position), tear off into a new window (drag off strip, release over empty space), or move into another window's tab strip. The tab follows the cursor as a floating preview; the original dims to a ghost.
- Right-click a tab for menu alternatives: **Move Tab to New Window**, **Move Up**, **Move Down**.
- **Dragging own panes**: each pane has a top-edge drag handle — a small capsule appears near the top; drag from there to pick the pane up. Drop zones:

  | Drop zone | Highlight color | Result |
  |---|---|---|
  | A pane's edge (top / bottom / left / right) | blue | Split that pane, place dragged pane on that side |
  | A divider between panes | blue | Insert the pane along that divider |
  | A pane's center (inner square) | green | Swap the two panes |
  | An existing tab (hover over it) | — | Merge the pane into that tab as a split |
  | The tab strip (empty gap) | — | Move the pane out into its own new tab |
  | Outside the window | — | Tear the pane off into a new window |

- Dropping a pane onto another window merges it into that window's layout.
- **Resizing splits**: drag the divider to adjust space allocation. **Double-click** a divider to reset neighbours to equal sizes.
- Pane-drag blue/green zones are distinct from the external-drop green/blue edge-halves: file drag offers "terminal vs. pane"; pane drag offers "split vs. swap".

## Keybindings

No keyboard shortcuts documented; drag-and-drop is exclusively mouse/trackpad-driven.

| Action | Keys |
|---|---|
| (none documented) | — |

## Config keys

No configuration keys documented for drag-and-drop.

| Key | Default | Effect |
|---|---|---|
| (none documented) | — | — |

## Visual spec

### drop-file.mp4 — File drag from Finder into terminal pane

**Before drag (frame 01):** macOS window with traffic-light buttons top-left. Left vertical sidebar lists tabs: "npm run dev", "localhost", "abner@MacBook-AB…", "Fill in the TODOs in the…", "OC | Reviewing todos" (active, badge "2151"). Dark-mode tab strip, active tab highlighted. Main area is a file-viewer pane on light warm off-white (#f8f7f5-ish) showing a markdown table with columns "Terminal parsing", "External Apps", "Tab management", "Release pipeline", "Theme/view", "Link detection", "IPC". Status bar: "drag-and-drop.md  19.5K (10%)  $0.05  ctrl+p commands". Top-right: Finder file "CREDITS.md" on the desktop.

**During drag (frame-action):** Dragging "CREDITS.md" over the pane. Overlay shows large translucent circular zones. Labels: **New Tab** (top-center, small), **Insert Path** (center, medium), **Open In-Place** (bottom-center, medium), **Split Left** (left edge, partial ellipse), **Split Right** (right edge, partial ellipse — darker olive/sage green = active hover target). File thumbnail follows cursor with green "+" badge. Pane content behind the overlay is visible but dimmed.

**After drop (frame 04 / frame-result):** Overlay dismissed. Terminal at content bottom now shows:
```
No matching items
/Users/abner/Desktop/CREDITS.md
```
indicating "Insert Path" was chosen and the path pasted into the prompt. File viewer content remains above.

### drop-overlay.mp4 — Drop overlay detail: folder drop on a split-pane layout

**Before drag (frame 01):** Two-pane window. Left = terminal, prompt `~/Workplace/project (main ✓) >|` on near-white. Right = "Files" panel (triggered by the toolbar "Files" button top-right) showing a directory tree: bin, build, docs, packages, resources, scripts, skills, target (expanded: AGENTS.md, Cargo.lock, Cargo.toml, CLAUDE.md, CREDITS.md, mise.toml, rust-toolchain.toml). Right panel has a "Find" search bar and toolbar icons (info circle, list, sort, Files highlighted, sidebar-toggle); light (#ffffff or near-white) with sidebar-like nav. File icons are small monochrome folder/document glyphs.

**During drag (frame 03 / frame-action):** Overlay covers the left terminal pane. Five soft zones: **New Tab** top-center (small, muted warm-grey), **Insert Path** center (medium, muted warm-grey), **Open In-Place** bottom-center (medium, muted pinkish-grey), **Split Left** left edge (large partial ellipse, muted sage-grey), **Split Right** right edge (large partial ellipse, saturated olive-green — active/hovered). CREDITS.md drag thumbnail with green "+" badge at the right edge where "Split Right" is hovered. Right file panel stays visible and undimmed (overlay covers only the target pane). Each label is small (~11pt), dark, readable sans-serif centered in the zone blob.

**After drop (frame 04):** A file viewer pane opened for CREDITS.md — rendered markdown page titled "Credits" with subheading "Fonts" and a table listing JetBrains Mono. The pane sits inside the window alongside the terminal pane. Title bar "CREDITS.md"; toolbar: toggle (pill switch), comment bubble, share icon, "Saved ✓ × Close" controls.

### drop-view-cross-tab.mp4 — Cross-tab pane drag

**Frame 01:** Dark-sidebar window; tab list "abner@MacBook-AB…", "OpenCode", "vi CrEDITS.md" (active). Main content = monospace text view of CrEDITS.md markdown source (theme list, direct inspirations). Status bar: "132,17-15  8ut". Tab strip is a vertical left sidebar (not horizontal).

**Frame 02:** Same view; "OpenCode" tab now selected (pill/box highlight) and shows a drag interaction — tab label has a "⊕"/drag affordance indicator. "vi CrEDITS.md" content still visible as the background.

**Frame 03:** Cross-tab drag in progress. Window title "Yazi: project". 3-pane layout: left tab sidebar; center = OpenCode agent pane (large muted-green "opencode" logo on semi-transparent sage-green card, prompt "Ask anything…", build line, "Tip Press tab to cycle between Build and Plan agents"); a floating translucent preview thumbnail of CrEDITS.md being dragged at the center pane's right edge (indicates a "split right" target). Bottom split = file manager (~/Workplace/project tree: folders Meld, Patetro, PenKit, Stirly, tascue, Typora; and build, docs, packages, resources, scripts, skills). Preview card has a blue circular cursor indicator at its right edge.

**Frame 04:** After the cross-tab merge — 3-way split: left tab sidebar, bottom-left file manager, top-center OpenCode agent pane ("opencode" logo), right = CrEDITS.md content (markdown source in monospace, theme list). Confirms dragging a pane from one tab into another tab's split layout works across tabs. Status bar: "132,17-15  92%".

## Screenshots

The page uses MP4 video demos (not static PNGs). Saved locally:

- `drop-file.mp4` — File drag from Finder desktop into a terminal/file-viewer pane
- `drop-overlay.mp4` — Drop overlay zones when dragging a file over a split-pane layout
- `drop-view-cross-tab.mp4` — Pane drag across tabs (merging a pane from one tab into another)

Extracted still frames (reference):
- `drop-file-frame01.png` — Before drag
- `drop-file-frame02.png` — Drag in progress (two files visible)
- `drop-file-frame03.png` — Drop overlay visible with zone labels
- `drop-file-frame04.png` — After drop: path inserted in terminal
- `drop-file-frame-action.png` — Mid-drag with overlay and active "Split Right" zone
- `drop-file-frame-result.png` — Post-drop result
- `drop-overlay-frame01.png` — Split pane before drag
- `drop-overlay-frame02.png` — Split pane with file selected in file panel
- `drop-overlay-frame03.png` / `drop-overlay-frame-action.png` — Overlay zones displayed (key reference frame)
- `drop-overlay-frame04.png` — File viewer pane opened after drop
- `drop-view-cross-tab-frame01.png` — Tab with CrEDITS.md file content
- `drop-view-cross-tab-frame02.png` — Tab being selected/dragged
- `drop-view-cross-tab-frame03.png` — Mid cross-tab drag showing preview card
- `drop-view-cross-tab-frame04.png` — Post-merge 3-way split layout

## SlopDesk mapping notes

### What maps cleanly

- **External file/folder/URL drops onto a pane**: accept NSDraggingDestination on the pane's NSView, inspect pasteboard types (NSFilenamesPboardType / NSURLPboardType / NSStringPboardType), show a custom overlay. Zones (New Tab, Insert Path, Open In-Place, Split Left, Split Right) are local client-side decisions; path insertion needs no host involvement.
- **"Insert Path"**: once the local path is known from the pasteboard, send it as terminal input to the remote PTY via the existing data channel — pure text injection, 1:1.
- **Pane reordering (split/swap/tear-off into new tab or window)**: all pane layout ops are local client-side (WorkspaceStore + PaneKind layout) — map 1:1: top-edge drag handle, split/swap drop zones, tab strip for move-to-new-tab, tear-off for new window.
- **Tab reordering**: local tab-strip reorder maps 1:1 via WorkspaceStore.
- **Double-click divider to equalize**: local NSSplitView double-click gesture — 1:1.

### What cannot map 1:1

1. **"New Tab" with cwd = folder**: NOT a 1:1 local action — cwd must be set on the HOST, not the client. Implementation: send `cd <path>` + Enter, or open a new session with a `--cwd` argument via the host daemon. The path must be HOST-side, not the drag-source Mac's — only meaningful when the drag source IS the host, or the path is valid on the host.

2. **"Open In-Place" / File pane / Folder pane for remote paths**: design assumes a local file opening a native viewer. In SlopDesk the client's filesystem is the user's LOCAL machine; the host is remote. A CLIENT-machine file can open in-place locally (client renders it). A HOST-side path requires fetching content over the wire — needs a new wire message type (e.g. `FileContentRequest`/`FileContentResponse` on the inspector/control channel). PARTIAL MAP.

3. **"New terminal rooted at dragged path"**: only meaningful if the dragged path exists on the HOST; from a client-side drag, host-side path equivalence is not guaranteed. Options: (a) warn the path may not exist on the host, (b) support only paths already visible via the existing remote file tree, or (c) transmit as a `cd` command and let the host shell error naturally. PARTIAL MAP — no automatic cwd negotiation protocol exists.

4. **URL pane**: design opens a URL pane natively, but SlopDesk has no built-in browser pane. A URL could open in the host's default browser via `open <url>` sent as terminal input, but a dedicated "URL pane" renderer does not exist. OUT OF SCOPE (phase 1).

5. **Cross-window drag (tear-off into new window, or merge across windows)**: SlopDesk runs as a single-session client or multi-tab within one window group. Cross-window pane drag needs multiple NSWindow instances with a shared WorkspaceStore — architecturally possible but not implemented (WorkspaceStore's reconcile() is window-scoped). DEFERRED.

6. **Text snippet paste as drop**: accepting NSStringPboardType and pasting into the terminal via the data channel maps 1:1 technically, but the overlay UI must detect the pasteboard is plain text to route it to the terminal paste path. IMPLEMENTABLE — requires explicit pasteboard type inspection in the drag entry handler.

### Implementation approach summary

- Implement NSDraggingDestination on each pane's NSHostingView or an overlay NSView layer.
- On drag entry: inspect pasteboard types, show the circular zone overlay (SwiftUI sheet pinned to pane bounds).
- On drag move: highlight the hovered zone (animate fill muted grey → olive-green via withAnimation).
- On drag exit: dismiss the overlay.
- On drop: route by (zone, content type) to the local action or wire command.
- Pane-drag handle: hover-sensitive capsule at each pane's top edge; implement NSDraggingSource + NSDraggingDestination for pane DnD, updating WorkspaceStore on successful drop.
- iOS client: UIKit drag-and-drop (UIDragInteraction / UIDropInteraction) — same logical zones and wire commands, but iOS limits cross-app drag source types; "Split Left/Right" maps to iOS split-pane layout, which may not exist on iPhone (only iPad multitasking). iPhone split-pane: NOT APPLICABLE.
