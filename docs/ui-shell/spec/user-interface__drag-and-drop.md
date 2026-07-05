# Drag and Drop

## Summary

SlopDesk accepts files, folders, and URLs from Finder, browsers, and any app that exports the standard pasteboard types. When content is dragged over a pane, a visual overlay appears with labelled drop zones offering different actions depending on the content type and the zone chosen. SlopDesk's own tabs and panes are also draggable and can be reordered, moved between windows, or torn off into new windows.

## Behaviors

- SlopDesk accepts drag sources that export standard pasteboard types: file/folder URLs, web URLs, and plain text.
- When dragging external content over a pane, the pane shows a full-screen overlay with multiple labelled circular/elliptical drop targets spread across the pane surface.
- The overlay zones for file drops (observed in `drop-overlay.mp4` frame 3) are:
  - **New Tab** (top-center, small circular zone): opens a new terminal tab with `cwd = <folder>`.
  - **Insert Path** (center of pane, medium circular zone): pastes the file path into the focused terminal.
  - **Open In-Place** (bottom-center, medium circular zone): opens the file/folder as a pane viewer in-place.
  - **Split Left** (left edge, large ellipse extending off-screen left): opens the content in a new pane split to the left.
  - **Split Right** (right edge, large ellipse extending off-screen right): opens the content in a new pane split to the right.
- The overlay zones are displayed as soft circular/elliptical blobs with a light semi-transparent fill. The hovered/active zone is rendered with a more saturated, darker fill (olive-green tones visible on the right "Split Right" target in the active frame). Non-active zones use a muted warm-grey or light-sage fill.
- Each zone carries a short text label rendered in a small dark sans-serif typeface at the zone center.
- While dragging, the file appears as a floating "ghost" thumbnail following the cursor (macOS system drag image). A green "+" badge appears on the drag image when hovering over a valid drop zone.
- Drop behaviour by content type:

  | Dragged thing | Green half / terminal action | Blue half / pane action |
  |---|---|---|
  | Folder | New terminal tab with `cwd = <folder>` | Folder pane (directory browser) |
  | File | (n/a — disabled) | File pane (viewer) |
  | URL | (n/a — disabled) | URL pane |
  | Text snippet | Pastes into the focused terminal | Same |

- The "green half" (terminal action) is disabled for files and URLs — there is no "open as terminal" semantic for those types.
- After a file drop resolves to "Insert Path", the file path is inserted as literal text into the terminal prompt and a command filter line appears at the bottom of the terminal (e.g. `No matching items` / the path string).
- **Dragging SlopDesk's own tabs**: drag a tab in the tab strip to reorder it (a thin insertion-line indicator shows the landing position between tabs), tear it off into a new window (drag off the strip and release over empty space), or move it into another window's tab strip. While dragging, the tab follows the cursor as a floating preview; the original dims to a ghost.
- Right-click a tab for menu alternatives: **Move Tab to New Window**, **Move Up**, **Move Down**.
- **Dragging SlopDesk's own panes**: each pane has a drag handle along its top edge; move the pointer near the top and a small capsule appears. Drag from there to pick the pane up. Drop zones light up as follows:

  | Drop zone | Highlight color | Result |
  |---|---|---|
  | A pane's edge (top / bottom / left / right) | blue | Split that pane and place the dragged pane on that side |
  | A divider between panes | blue | Insert the pane along that divider |
  | A pane's center (inner square) | green | Swap the two panes |
  | An existing tab (hover over it) | — | Merge the pane into that tab as a split |
  | The tab strip (empty gap) | — | Move the pane out into its own new tab |
  | Outside the window | — | Tear the pane off into a new window |

- Dropping a pane onto another window merges it into that window's layout.
- **Resizing splits**: drag the divider between panes to adjust space allocation. **Double-click** a divider to reset its neighbours to equal sizes.
- The blue/green zones used for pane-dragging are distinct from the green/blue edge-halves used for external file/URL drops. Dragging a file offers "terminal vs. pane"; dragging a pane offers "split vs. swap".

## Keybindings

No keyboard shortcuts are documented for drag-and-drop on this page. The operations are exclusively mouse/trackpad-driven.

| Action | Keys |
|---|---|
| (none documented) | — |

## Config keys

No configuration keys are documented for drag-and-drop on this page.

| Key | Default | Effect |
|---|---|---|
| (none documented) | — | — |

## Visual spec

### drop-file.mp4 — File drag from Finder into terminal pane

**Before drag (frame 01):** The app window is a macOS window with standard traffic-light buttons (red/yellow/green) in the top-left. A vertical sidebar on the left lists tabs: "npm run dev", "localhost", "abner@MacBook-AB…", "Fill in the TODOs in the…", and "OC | Reviewing todos" (currently active, with a badge showing commit count "2151"). The tab strip is dark-mode with the active tab highlighted. The main content area is a file-viewer pane in light background (#f8f7f5-ish warm off-white) showing a markdown table with columns "Terminal parsing", "External Apps", "Tab management", "Release pipeline", "Theme/view", "Link detection", "IPC". A status bar at the bottom reads "drag-and-drop.md  19.5K (10%)  $0.05  ctrl+p commands". To the top-right, a Finder file "CREDITS.md" (document icon) sits on the desktop.

**During drag (frame-action):** The user is dragging "CREDITS.md" over the pane. The drop overlay appears as large translucent circular zones. Visible labels: **New Tab** (top-center, small circle), **Insert Path** (center, medium circle), **Open In-Place** (bottom-center, medium circle), **Split Left** (left edge, partial ellipse), **Split Right** (right edge, partial ellipse — shown in a darker olive/sage green fill indicating it is the active hover target). The file thumbnail follows the cursor with a green "+" badge. The pane content behind the overlay is visible but dimmed.

**After drop (frame 04 / frame-result):** The overlay is dismissed. The terminal at the bottom of the content area now shows:
```
No matching items
/Users/abner/Desktop/CREDITS.md
```
indicating "Insert Path" was chosen and the file path was pasted into the terminal prompt. The file viewer content is still present above.

### drop-overlay.mp4 — Drop overlay detail: folder drop on a split-pane layout

**Before drag (frame 01):** A two-pane window: left pane = terminal with prompt `~/Workplace/project (main ✓) >|` on a near-white background. Right pane = a "Files" panel (triggered by the "Files" button in the toolbar at top-right) showing a directory tree: bin, build, docs, packages, resources, scripts, skills, target (expanded to reveal: AGENTS.md, Cargo.lock, Cargo.toml, CLAUDE.md, CREDITS.md, mise.toml, rust-toolchain.toml). The right panel has a search bar at top ("Find"), and toolbar icons (info circle, list, sort, Files button highlighted, sidebar-toggle). Both panes share the same window chrome; the right panel is light (#ffffff or near-white) with a sidebar-like nav structure. File icons are small monochrome folder/document glyphs.

**During drag (frame 03 / frame-action):** The drop overlay covers the left terminal pane. Five large soft circular/elliptical zones are shown: **New Tab** at top-center (small, muted warm-grey fill), **Insert Path** in the center-center (medium, muted warm-grey fill), **Open In-Place** at bottom-center (medium, muted pinkish-grey fill), **Split Left** at left edge (large partial ellipse, muted sage-grey), **Split Right** at right edge (large partial ellipse, saturated olive-green — active/hovered). CREDITS.md drag thumbnail with green "+" badge is visible at the right edge where "Split Right" is hovered. The file panel on the right remains visible and undimmed (the overlay only covers the pane being dragged onto). Each zone label is a small (~11pt), dark, readable sans-serif centered within the zone blob.

**After drop (frame 04):** A file viewer pane opened for CREDITS.md showing a rendered markdown page titled "Credits" with a subheading "Fonts" and a table listing JetBrains Mono. The pane is now inside the window alongside the terminal pane. Title bar reads "CREDITS.md", with toolbar: toggle (pill switch), comment bubble, share icon, "Saved ✓ × Close" controls.

### drop-view-cross-tab.mp4 — Cross-tab pane drag

**Frame 01:** A dark-sidebar window showing tab list: "abner@MacBook-AB…", "OpenCode", "vi CrEDITS.md" (active). The main content is a monospace text view of CrEDITS.md showing markdown source (theme list, direct inspirations). Status bar: "132,17-15  8ut". The tab strip is on the left as a vertical sidebar (not horizontal).

**Frame 02:** Same view but the "OpenCode" tab is now selected (highlighted with a pill/box highlight) and shows a drag interaction — the tab label has "⊕" or drag affordance indicator next to it. The "vi CrEDITS.md" file content is still visible as the background of the content area.

**Frame 03:** Cross-tab drag in progress. The window title reads "Yazi: project". Layout is 3-pane: left sidebar with tabs, a center area showing the OpenCode agent pane (large logo "opencode" in muted green text on a semi-transparent sage-green background card, with prompt "Ask anything…", build line, and "Tip Press tab to cycle between Build and Plan agents"), a floating preview thumbnail (translucent card) of the CrEDITS.md content being dragged — positioned at the right edge of the center pane to indicate a "split right" drop target. Bottom split shows a file manager view (~/Workplace/project directory tree with folders: Meld, Patetro, PenKit, Stirly, tascue, Typora; and build, docs, packages, resources, scripts, skills). The preview card has a blue circular cursor indicator at its right edge.

**Frame 04:** After the cross-tab pane merge. Now showing a 3-way split: left tab sidebar, bottom-left file manager, top-center OpenCode agent pane ("opencode" logo visible), right = CrEDITS.md content (markdown source in monospace, showing theme list). The merged layout confirms that dragging a pane from one tab into another tab's split layout works across tabs. Status bar shows "132,17-15  92%".

## Screenshots

The page uses MP4 video demos (not static PNGs). The following files were saved locally:

- `drop-file.mp4` — File drag from Finder desktop into a terminal/file-viewer pane
- `drop-overlay.mp4` — Drop overlay zones shown when dragging a file over a split-pane layout
- `drop-view-cross-tab.mp4` — Pane drag across tabs (merging a pane from one tab into another)

Extracted still frames (for reference):
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

- **External file/folder/URL drops onto a pane**: SlopDesk can accept NSDraggingDestination on the pane's NSView, inspect pasteboard types (NSFilenamesPboardType / NSURLPboardType / NSStringPboardType), and show a custom overlay. The overlay zones (New Tab, Insert Path, Open In-Place, Split Left, Split Right) are local client-side decisions that do not require host-side involvement for path insertion.
- **"Insert Path" action**: Once the local file path is known from the pasteboard, the client can send the path string as terminal input to the remote PTY via the existing data channel. This is a pure text injection — maps 1:1.
- **"New Tab" with cwd = folder**: This CANNOT be a 1:1 local action. The cwd must be set on the HOST, not the client. Implementation: send a `cd <path>` command to the terminal followed by Enter, or open a new session with a `--cwd` argument via the host daemon. The path must be a HOST-side path, not the drag-source Mac's path — this only makes sense when the drag source IS the host machine, or when the path is valid on the host.
- **Pane reordering (split/swap/tear-off into new tab or window)**: All pane layout operations in slopdesk are local client-side (WorkspaceStore + PaneKind layout). These map 1:1: drag handle on pane top edge, drop zones for split/swap, tab strip for move-to-new-tab, tear-off for new window.
- **Tab reordering**: Local tab strip reorder maps 1:1 via WorkspaceStore.
- **Double-click divider to equalize**: Local NSSplitView double-click gesture — maps 1:1.

### What cannot map 1:1

1. **"Open In-Place" / File pane / Folder pane for remote paths**: The design assumes the file is local and the pane opens a native file viewer. In slopdesk, the client's filesystem is the user's LOCAL machine; the host is remote. If the drag source is a file from the CLIENT machine, opening it "in-place" as a file pane can be done locally (the client renders it). If it represents a HOST-side file path, the client must request the file content over the wire — this needs a new wire message type (e.g., `FileContentRequest`/`FileContentResponse` on the inspector/control channel). Flag as PARTIAL MAP.

2. **"New terminal rooted at dragged path"**: Only meaningful if the dragged path exists on the HOST. From a client-side file drag, the host-side path equivalence is not guaranteed. Implementation must either (a) warn the user the path may not exist on the host, (b) only support this for paths that are already visible via the existing remote file tree, or (c) transmit the path as a `cd` command string and let the host shell error naturally. Flag as PARTIAL MAP — no automatic cwd negotiation protocol exists.

3. **URL pane**: The design calls for opening a URL pane natively. SlopDesk has no built-in browser pane. A URL could be opened in the host's default browser via `open <url>` sent as terminal input, but a dedicated "URL pane" renderer does not exist yet. Flag as OUT OF SCOPE (phase 1).

4. **Cross-window drag (tear-off into new window, or merge across windows)**: SlopDesk runs as a single-session client or multi-tab within one window group. Cross-window pane drag requires multiple NSWindow instances with a shared WorkspaceStore. This is architecturally possible but not currently implemented — the WorkspaceStore's reconcile() is window-scoped. Flag as DEFERRED.

5. **Text snippet paste as drop**: Accepting NSStringPboardType and pasting it into the terminal via the data channel maps 1:1 technically, but the "drop target" UI (showing the overlay) needs to detect that the pasteboard is plain text to route it to the terminal paste path. This is IMPLEMENTABLE but requires explicit pasteboard type inspection in the drag entry handler.

### Implementation approach summary

- Implement NSDraggingDestination on each pane's NSHostingView or an overlay NSView layer.
- On drag entry: inspect pasteboard types, show the circular zone overlay (SwiftUI sheet pinned to pane bounds).
- On drag move: highlight the hovered zone (animate fill color from muted grey → olive-green using withAnimation).
- On drag exit: dismiss the overlay.
- On drop: route by (zone, content type) to the appropriate local action or wire command.
- The drag handle for pane-dragging: add a hover-sensitive capsule at the top edge of each pane; implement NSDraggingSource + NSDraggingDestination for pane DnD, updating WorkspaceStore on successful drop.
- iOS client: UIKit drag-and-drop (UIDragInteraction / UIDropInteraction) — same logical zones, same wire commands, but iOS limits cross-app drag source types; "Split Right/Left" maps to iOS split-pane layout which may not exist on iPhone (only iPad multitasking). Flag iPhone split-pane as NOT APPLICABLE.
