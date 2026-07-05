# Files, Folder and Links

## Summary

Paths and URLs in terminal output are interactive: `⌘click` opens in the best handler (file pane for text, default app otherwise), `⌘⇧click` reveals in Finder or copies a URL. SlopDesk also embeds a text editor/previewer (syntect syntax highlighting), a directory browser (folder pane), and a native WKWebView browser pane. All panes can appear inline with the terminal — current pane, new tab, or split. Agent session logs (Claude Code, Codex, OpenCode) render as conversation transcripts, not raw JSON.

---

## Behaviors

### Path and Link Detection in Terminal Output

- Detected in live output and scrollback:
  - Absolute paths: `/usr/local/bin/foo`, `/Users/me/project`
  - Tilde paths: `~/project/file.swift`
  - Relative paths: `./src/lib.rs`, `../config/foo.toml`
  - Line/column suffixes: `src/lib.rs:42`, `src/lib.rs:42:5`
  - URLs with `http://`, `https://`, `file://` schemes
  - OSC 8 hyperlinks (always underlined, regardless of Link Schemes setting)
- Relative paths resolve against the pane's last-known working directory (OSC 7).
- Holding `⌘` underlines detected paths/URLs to signal they are clickable.
- `⌘`-hover shows the full resolved absolute path in the window's bottom-left status area.
- macOS Lookup (force-touch / three-finger tap) works on detected paths and URLs.

### Click Actions

| Target | Click | ⌘click | ⌘⇧click | Right-click |
|--------|-------|---------|----------|-------------|
| Path | nothing (prevents accidental opens) | Open in best handler — file pane for text, default app otherwise | Reveal in Finder | Context menu: Open With…, Copy Path, Reveal, Change Directory Here, Open in SlopDesk |
| URL | nothing | Open in URL pane (or system browser, per config) | Copy URL | Context menu: Copy, Open in Browser |

### Right-click Context Menu Items (paths)

- **Open Link / Open File / Open Folder** — default behavior (Settings → Controls → Open With).
- **Open with** — submenu of installed apps.
- **Copy Path / Copy URL** — copy the resolved absolute path.
- **Reveal in Finder**.
- **Change Directory Here** — cd the focused terminal to the path (or its parent folder).
- **Open in SlopDesk** — submenu: current pane, new tab, or split.

### Keyboard-only Path/Link Interaction

- **Jump To (⌘J)**: Open Quickly view scoped to the current pane, listing its detected paths, links, and commands. Type to filter; `⌘K` on the highlighted item opens the Actions popover (same actions as right-click).
- **Hint Mode**: Keyboard-only overlay for opening any detected link. See Hint Mode docs.

---

### File Pane / Editor

- Opens/previews common file types; embeds a text editor.
- Ways to open a file:
  - Drag from Finder onto the window's "New Tab" drag zone → file pane in a new tab.
  - Context menu → Open in SlopDesk → view pane.
  - `slopdesk view <file>` — preview/read-only mode.
  - `slopdesk edit <file>` — edit mode.
- Syntax highlighting via syntect (Sublime/TextMate grammars). Language detection by file extension, shebang fallback on the first line. For ambiguous extensions (`.m` → Objective-C, `.h` → C, `.v` → Verilog, `.pl` → Perl) a toolbar language dropdown overrides; "Auto-detect" undoes it.
- Syntax theme, editor font, and size all follow the terminal theme — no separate editor font setting.
- Save: `⌘S` (edit mode only). Reload from disk: `⌘R` (discards unsaved changes).
- Files modified outside SlopDesk trigger a banner: "Reload" / "Keep my changes".
- Designed for text up to a few MB; very large files fall back to a streamed view (no in-place edit). Binary files open as read-only hex.

#### Markup with Live Preview (Source ⇄ Preview)

These open with source and rendered preview, toggled via the pane toolbar Source/Preview control, `⌘E`, or right-click → Toggle Preview:

| Format | Extensions | Rendered as |
|--------|-----------|-------------|
| Markdown | `.md`, `.markdown` | GitHub-flavored HTML; fenced code blocks syntax-highlighted, follow terminal theme |
| reStructuredText | `.rst`, `.rest` | HTML |
| SVG | `.svg` | Live image with trackpad pinch-to-zoom |
| HTML | `.html`, `.htm` | Rendered locally (JavaScript off for safety) |

Preview mode by default. Source edits refresh the preview as you type; switching sides keeps cursor and unsaved changes.

#### Syntax-highlighted Languages (~120 bundled grammars)

- Systems/compiled: Rust, C, C++, Objective-C/Objective-C++, C#, Go, Zig, D, Pascal, Fortran, Ada, Swift, ARM & x86 Assembly, Verilog, WGSL
- JavaScript & web: JavaScript (+ Babel), TypeScript/TSX, CoffeeScript, LiveScript, Dart, Elm, Vue, HTML (+ Twig), CSS, Less, Stylus, QML, Slim, ActionScript
- JVM: Java, Kotlin, Scala, Groovy
- Functional: Haskell, OCaml, F#, Erlang, Elixir, Clojure, Lisp, Scheme, Racket, Standard ML, Lean
- Scripting & dynamic: Python, Ruby, PHP, Perl, Lua, R, Julia, Crystal, Nim, MATLAB, Tcl, AppleScript
- Shell & build: Shell (bash/zsh), Fish, PowerShell, Batch, Makefile, CMake, Ninja, Dockerfile, Terraform, Nix, Robot Framework, Gnuplot
- Data & config: JSON, JSON Lines, YAML, TOML, XML, INI, `.env`, Java Properties, Apache conf, Cabal, Protocol Buffers, GraphQL, Rego, SQL
- Markup & docs: Markdown, reStructuredText, AsciiDoc, Textile, Org Mode, LaTeX, BibTeX
- Other: Diff/patch, regular expressions

#### Other File Types

| Kind | Extensions | Behavior |
|------|-----------|---------|
| Images | `.png`, `.jpg`/`.jpeg`, `.gif`, `.webp`, `.heic`/`.heif`, `.bmp`, `.tiff`/`.tif`, `.ico` | Zoom (`⌘+` / `⌘-` / fit / 1:1), drag to pan, animated GIF/APNG play |
| PDF & rich docs | `.pdf`, video, office docs, fonts, … | Quick Look preview (read-only); PageUp/PageDown pages a PDF |
| Diff/patch | `.diff`, `.patch` | Unified diff with colored hunks (read-only) |
| Binary | any non-textual | Read-only hex view |

Plain-text files with no dedicated grammar still open in the editor (toolbar, shortcuts, terminal-matching theme) without highlighting.

#### Agent Session History

Coding-agent session logs render as a transcript instead of raw JSON. Three agents recognized by session file path:

| Agent | Session files |
|-------|--------------|
| Claude Code | `~/.claude/projects/<project>/*.jsonl` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` |
| OpenCode | `~/.local/share/opencode/storage/session/<project>/*.json` |

- Transcript lays out user/assistant turns with Markdown-rendered text, tool calls, reasoning, and attachments.
- Right-click → select and Copy or Send to Chat.
- **Resume** button continues the session: jumps to the live tab if still running, else spawns a fresh session with the agent's `--resume` flag.
- Open via Open Quickly (`⌘P`) — lists the current project's sessions across all three agents — or open the file directly.
- Toggle via right-click → View as → `<Agent> History ⇄ JSONL (Syntax Highlight)` for the raw log.
- Only files under a known agent's directory auto-open as a transcript; any other `.jsonl` stays plain text.

---

### Folder Pane

- Directory browser — click to open files, drag rows out into terminal or file panes.
- Open via `slopdesk view <dir>` or right-click a folder → "Open in SlopDesk".
- Shows a tree/list of the hierarchy. Folders expand inline; files open in a new pane.

---

### Web Browser Pane

- Built-in native WKWebView — opens a terminal link next to work in the current pane, new tab, or split.
- Default `http(s)` handler is the system browser; changeable to SlopDesk so `⌘click` opens links directly in the terminal.
- Non-persistent data store — cookies and local storage never cross panes or survive a restart.
- Audio/video do not autoplay until the user interacts with the page.
- A bare host in the address bar gets `https://` prepended; otherwise acts as a DuckDuckGo search.

---

## Keybindings

### Terminal — Path/Link interaction

| Action | Keys |
|--------|------|
| Show full resolved path in status bar (hover) | Hold `⌘` |
| Open path/URL in best handler | `⌘click` |
| Reveal path in Finder / Copy URL | `⌘⇧click` |
| Open context menu for path/URL | Right-click |
| Open Jump To panel (paths, links, commands in current pane) | `⌘J` |
| Open Actions popover for highlighted Jump To item | `⌘K` |
| Enter Hint Mode (keyboard-only link opening) | (see Hint Mode docs) |

### File Pane / Editor

| Action | Keys |
|--------|------|
| Save (edit mode) | `⌘S` |
| Reload from disk | `⌘R` |
| Toggle Source / Preview | `⌘E` |
| Toggle soft wrap (current pane only) | `⌘⌥W` |
| Zoom image in (image files) | `⌘+` |
| Zoom image out (image files) | `⌘-` |

### Web Browser Pane

| Action | Keys |
|--------|------|
| Back | `⌘[` |
| Forward | `⌘]` |
| Back / Forward (gesture) | Two-finger swipe |
| Reload | `⌘R` |
| Reload bypassing cache | `⌘⇧R` |
| Find in page | `⌘F` |

---

## Config Keys

Set in `~/.config/slopdesk/config.toml` under the relevant section. See the Configuration Reference doc for the full inventory.

| Key | Default | Effect |
|-----|---------|--------|
| `link-cmd-click` | `open` | `⌘click` on a link: `open` \| `copy` \| `nothing` |
| `link-cmd-shift-click` | `reveal-finder` | `⌘⇧click` on a link: `reveal-finder` \| `open-system-default` |
| `link-detection` | `on` | Link detection: `on` \| `off` (turn off if interfering with TUI mouse) |

### Settings UI (Settings → Controls → Open With)

| Setting | Default | Effect |
|---------|---------|--------|
| Open Links With | Browser | Where `⌘click` / right-click "Open Link" opens a URL. Options: Browser, SlopDesk. |
| Open Files With | SlopDesk | Where `⌘click` / right-click "Open File" opens a file path. |
| Open Folders With | Finder | Where `⌘click` / right-click "Open Folder" opens a folder path. Options: Finder, SlopDesk. |
| Default Git Client | Auto (first installed) | Git GUI used as primary "Open in <App>" target on the Details › Git toolbar. |
| Custom Open With Apps | — | Add third-party apps (e.g. Fork, Typora) to the folder/file "Open in…" submenus. |

### Settings UI (Settings → Controls → Link Schemes)

| Setting | Default | Effect |
|---------|---------|--------|
| Auto-Detect Link Schemes | All | Which URL schemes are underlined on `⌘`-hover and clickable. "All" detects any `scheme://`; "Custom" restricts to a user list. `http(s)`, `file`, `mailto` always detected. |
| Custom Link Schemes | — | URL schemes to additionally detect when Custom (e.g. `codex`, `ssh`, `vscode`). |
| Reset Security Warnings | — | Clears every "always allow" choice so confirmation dialogs return for non-standard schemes and executables. |

### Settings UI (Settings → Editor)

| Setting | Default | Effect |
|---------|---------|--------|
| Soft Wrap | On | Wrap long lines instead of scrolling horizontally |
| Show Line Numbers | On | Display the line-number gutter in text panes |
| Show Whitespace | Off | Render spaces, tabs, and newlines as visible glyphs |
| Tab Size | 4 | Visual width of a tab character in columns (1–16) |
| Scroll Past Last Line | On | Allow the file pane to scroll past its last line (terminal scroll-past-end is configured separately under Controls) |
| Default to Preview / Read-Only | On | Open Markdown/SVG/HTML in preview and start file panes read-only; off = source mode with editing |

---

## Visual Spec

### editor-pane.png — Text Editor (Source Mode)

Floating macOS window, translucent frosted rounded rect with shadow, traffic-light buttons top-left. Title bar: filename (`index.md`) centered in gray monospace.

**Toolbar (top):** Left — a two-segment toggle (leftmost active), a square icon button, a bookmark/flag icon button. Right — `✓ Saved` (muted gray) and `✗ Close` (plain text).

**Editor body:** White/light background. Left gutter: line numbers (1–21+), muted gray, right-aligned, ~3-char wide, separated by a subtle gap (no hard border). Monospace font ~13–14pt. Light scheme: near-black prose, blue markdown `#`/`##` markers, dimmed gray blank lines, blue/teal `[text](url)` links. No horizontal scrollbar in soft-wrap.

**State:** Read-only/saved (`✓ Saved`). File `index.md` — a project readme: top-level heading, paragraphs, `## Highlights`, `## Contents` with bullet lists.

### full-path-hover.png — Full Path Hover in Status Bar

Terminal window split into two vertical panes. Left sidebar TABS column: 4 entries (package.json, abner@MacBook-AB…, tmux, OC | Reviewing todos); the 4th is active (darker row, bold, "#4" gray on right).

Right main area: agent output — a table of tasks (Release pipeline, Theme/view, Link detection, IPC) with counts/descriptions; a "High-impact items to prioritize" section with numbered bullets (some red, one blue, one orange); a terminal block with a `give me more details...` prompt and `check missing content in CREDITS.md`.

**Status bar (bottom):** Thin dark full-width bar. Left (~30%, dark): resolved absolute path `/Users/abner/Workplace/project/CREDITS.md` in white monospace. Right (lighter): `files-and-links.md  20.7K (10%)  - $0.08  ctrl+p commands`. This is the `⌘`-hover full-path feature.

### markdown-pane.png — Markdown Preview Mode

Floating window, traffic-lights. Title bar: `index.md` centered. Toolbar: toggle (right/Preview segment active), two icon buttons, `✓ Saved` and `✗ Close`.

**Content:** Pure white background, web-page HTML rendering. Generous margins (~40px) and comfortable line height. Top heading ~24pt bold black, flush left. Body ~15–16pt near-black. Underlined link-blue hyperlinks. Standard disc bullets; `**` bold. Matches GitHub-flavored Markdown. No line numbers (rendered preview, not source).

### folder-pane.png — Folder Browser Pane

Window, traffic-lights. Title bar: `docs` centered. Top: search field (`Q Find`), icon buttons (back, forward, eye/view, speech bubble, share), `✗ Close`.

**Breadcrumb bar:** `abner > Workplace > project > docs`, `>` separators, each segment blue clickable.

**File tree:** Solid blue folder icons for directories, plain document icons for files. Roots `development`, `spec`, `user` (blue folders); expanded items `agents`, `customization`, `getting-started`, `public`, `reference`, `terminal-features`, `vt`, `workflows`, `workspace` (blue folders with `>` arrows). Under expanded `workspace`: `details-panel.md`, `drag-and-drop.md`, `files-and-links.md`, `find.md`, `open-quickly.md` (selected, light-blue full-width fill), `window-tab-split.md`; below: `index.md`, `code-review-todos.md`. No checkboxes/badges. Left TABS column: `project #1`, `OpenCode #2`, `docs #3`.

### web-broswer.png — Built-in Web Browser Pane

Window, traffic-lights. Title bar: `localhost` centered. **Browser toolbar:** `✗` (stop), `<` (back), `>` (forward), circular reload, URL bar `http://localhost:5173/` (rounded rect, light gray), share icon far right.

**Web content:** A documentation site — left nav sidebar (menu icon), home page (heading, paragraphs, "Highlights" bullets), rendered as native web (not the app's markdown renderer). App chrome is minimal; the content area is the WKWebView.

**Left TABS:** `npm run dev #1` (clock badge, abbreviated domain), `localhost #2` (active), `abner@MacBook-AB... #3` (clipped). Rows ~28px.

### agent-history.png — Agent Session Transcript

Full-size window (no floating chrome). Title bar: `Fill in the TODOs in the workspace files-and-links doc` (session title, gray). Top-right: `⟳ Resume` and `✗ Close`.

**Pane toolbar (left of title):** speech-bubble and share/export icon buttons; title centered.

**Transcript:**
- Metadata header: session ID hash (`b2d4f6a0-1c3e-4a5b-9d7f-2e4c0a80d11.json`), branch info (`~/Workspace/project · ⎇ main · v2.1.159`).
- Timestamp `● You · 19:30:21` with gray dot badge.
- Blue file path `/Users/abner/Workplace/project/docs/user/workspace/files-and-links.md`.
- User message `fill in the TODO`.
- Expandable tool-call block `> Claude · Agent, 5xBash, Edit, 6xRead · 553 chars` (`>` chevron, gray metadata).
- Assistant prose: "Filled in the **Web Browser** section of `docs/user/workspace/files-and-links.md` (it was previously `TODO`). Everything is verified against the source:"
- "Sources verified" list with blue file links: `link-open-with → browser | slopdesk — packages/config/src/lib.rs:924,3484,5801`, `slopdesk open <url> opens a URL pane — docs/...`, etc.
- Bullets with inline gray-background code, blue underlined file links.

**Left TABS:** `npm run dev #1`, `localhost #2` (green dot = active/running), `abner@MacBook-AB... #3` (orange dot), `Fill in the TODOs in the... #4` (active, no dot), `OC | Reviewing todos #5`.

White background, dark text, ~20px between turns. Code spans use light gray inline background; links bright-blue underlined; collapsed tool-call block is a single `>`-chevron line.

### editor-settings.png — Settings → Editor Panel

macOS settings window (light). Left sidebar: search field, then categories with icons — General, Shell, Controls, **Editor** (selected, bold, highlighted row), Agents, Appearance, Recipes, Key Bindings, Advanced.

**Right panel:** Header "EDITOR" (uppercase small-caps gray). Rows with bold title, gray subtitle, right-side control:

1. **Soft Wrap** — "Wrap long lines instead of scrolling horizontally" — green ON toggle
2. **Show Line Numbers** — "Display the line-number gutter in text panes" — green ON toggle
3. **Show Whitespace** — "Render spaces, tabs, and newlines as visible glyphs" — gray OFF toggle
4. **Tab Size** — "Visual width of a tab character, in columns" — stepper `[-]  4  [+]`
5. **Scroll Past Last Line** — scroll past last line; terminal scroll-past-end configured separately — green ON toggle
6. **Default to Preview / Read-Only** — "Open Markdown / SVG / HTML in preview mode and start file panes read-only — turn it off to open in source mode with editing enabled" — green ON toggle

Rows ~56px, separated by light-gray rules. White background, system font.

### links-schemes.png — Settings → Controls → Link Schemes Section

Same settings window; "Controls" selected.

**Right panel (partial scroll):** Continuation of OPEN WITH:
- **Open Folders With** — "Where Cmd+click and the right-click 'Open Folder' item open a folder path" — dropdown "Finder"
- **Default Git Client** — "The git GUI used as the primary 'Open in App>' target on the Details › Git toolbar." — dropdown "Auto (first installed)"
- **Custom Open With Apps** — "Add third-party apps (e.g. Fork, Typora) to the folder/file 'Open in…' submenus." — "Configure…" button

Then **LINK SCHEMES** (uppercase small-caps gray):
- **Auto-Detect Link Schemes** — "Which URL schemes get underlined on Cmd-hover and made clickable. 'All' detects any scheme://; 'Custom' adds only the schemes you list. http(s), file, and mailto are always detected." — dropdown "Custom"
- **Custom Link Schemes** — "URL schemes to additionally detect (e.g. codex, ssh, vscode)" — "Configure…" button
- **Reset Security Warnings** — "Forget every 'always allow' choice so the confirmation dialog returns when opening external links, custom schemes, or executables." — "Reset" button

### open-with-option.png — Settings → Controls → Open With Section

Same settings window; "Controls" selected.

**Right panel (OPEN WITH):**
- **Open Links With** — "Where Cmd+click and the right-click 'Open Link' item open a URL" — dropdown "Browser"
- **Open Files With** — "Where Cmd+click and the right-click 'Open File' item open a file path" — dropdown "SlopDesk"
- **Open Folders With** — "Where Cmd+click and the right-click 'Open Folder' item open a folder path" — dropdown "Finder" with popup open showing "Finder" / "SlopDesk"
- **Default Git Client** — "The git GUI used as the primary 'Open in App>' target on the Details › Git toolbar. Other installed clients and your custom Open With apps still appear in the dropdown." — dropdown partially obscured
- **Custom Open With Apps** — "Add third-party apps (e.g. Fork, Typora) to the folder/file 'Open in…' submenus." — "Configure…" button

Below: **KEYBOARD** section header, partially visible.

### hint-mode.png — Hint Mode Overlay in Terminal

Terminal pane running `npm run dev`. Title bar `npm run dev`. Top-right: **HINTS** badge and two buttons `Esc` and `✗ Exit`.

**Content:** Dark terminal output (`docs-web@0.1.0 predev`, `npm run sync-docs`, sync logs, vitepress v1.6.4). One line highlighted/underscored yellow: `Workspace/project/packages/docs-ms (main x)●` — the detected CWD path (clickable link).

**Hint labels:** Yellow rounded-square labels with white letters (fzf-style). A `h` label overlays the `h` in the `/scripts/dev.mjs` link; more `h` labels on `./scripts/sync-docs.mjs` and the `http://localhost:5173/` URL. **HINTS** top-right is a small rounded-rect uppercase badge; `Esc`/`Exit` are plain text buttons.

---

## Screenshots

- `editor-pane.png` — text editor / source mode for a Markdown file
- `full-path-hover.png` — status-bar path hover preview at window bottom
- `markdown-pane.png` — Markdown rendered preview mode
- `folder-pane.png` — folder/directory browser pane
- `web-broswer.png` — built-in WKWebView browser pane (note: "browser" misspelled as "broswer" in the original filename)
- `agent-history.png` — agent session transcript (Claude Code session)
- `editor-settings.png` — Settings → Editor panel
- `links-schemes.png` — Settings → Controls → Link Schemes section
- `open-with-option.png` — Settings → Controls → Open With section
- `hint-mode.png` — Hint Mode overlay with letter labels on detected links

---

## SlopDesk Mapping Notes

### What maps 1:1

- **⌘click / ⌘⇧click on paths/URLs:** Client UI. Already tracks the pane's last-known CWD via OSC 7 (slopdesk passes it through). Path detection regex (absolute, tilde, relative, `path:line:col`, `http(s)://`, `file://`) is a pure client-side scan on the rendered grid.
- **OSC 8 hyperlinks:** Already in libghostty's protocol surface — ghostty surfaces them as text-run metadata; the client reads them and underlines/makes clickable.
- **Right-click context menu:** Standard macOS `NSMenu` from the client view; all items (Open, Copy, Reveal, Change Directory Here) client-initiated. "Change Directory Here" sends `cd <path>\n` to the host PTY — no special protocol.
- **Jump To (⌘J):** Client-side scan of scrollback for detected paths/links/commands, fuzzy-searchable list. Open Quickly pattern already exists in slopdesk.
- **Hint Mode:** Client-side overlay; letter labels on detected links in the current viewport. No host involvement.
- **⌘-hold underline highlight:** Client-side render hint — re-render detected paths underlined while `⌘` held. No host round-trips.
- **Status bar path display on hover:** Bottom-left status region shows the resolved path. Adjacent to existing status-bar infrastructure.
- **Editor Settings (soft wrap, line numbers, whitespace, tab size, scroll-past, preview default):** Pure client-side file pane settings.
- **Web browser (WKWebView pane):** Client-side, fully local. New `PaneKind.web` hosting `WKWebView` (`.remoteGUI` reuse candidate, but a web pane is local).
- **Folder pane:** Client-side filesystem access — trivial for the LOCAL client filesystem. Remote (host-side) directories need a directory-listing protocol over the control channel.
- **Agent session history (Claude Code / Codex / OpenCode):** Client-side JSONL parsing and custom SwiftUI rendering. Session files are LOCAL for local sessions, on the HOST for remote (requires transfer). Parsing + transcript view are client-only UI.

### What does NOT map 1:1 (flag for design decision)

1. **"Reveal in Finder" for remote paths:** `⌘⇧click` → Reveal can't open Finder on the client for a host file. Options: show path in client status bar (copy to clipboard fallback); or send `open -R <path>` to the host PTY (reveals in the HOST's Finder — useful for a local Mac host, meaningless for a remote server). **Decision needed:** client Finder or host Finder? For a local macOS host, sending `open -R` to the host PTY is viable.

2. **File pane for remote files:** `slopdesk view`/`edit` open LOCAL files; in slopdesk the host session's filesystem is REMOTE. Opening a remote file in the client file pane needs an SFTP/SCP-style transfer channel (not in the wire protocol). **Cannot map 1:1 without a file-transfer sub-protocol.**

3. **"Open in best handler" for remote binary (non-text) files:** Opening a remote `.png`/`.pdf` via `⌘click` requires transferring the file first — no file-transfer mechanism exists.

4. **"Change Directory Here" for relative paths:** Trivial — send `cd <path>\n` to the host PTY. Relative→absolute resolution uses the host CWD (OSC 7), already tracked.

5. **Folder pane for HOST directories:** Needs a directory-listing protocol (not in the wire). Short-term: run `ls -la`/`find` in the host PTY and parse — fragile but viable. Proper solution: add a control-channel file-listing message.

6. **Agent session history for REMOTE sessions:** If the agent runs on the host with session files at `~/.claude/projects/...`, the client can't read them directly. Options: `tail -f` the `.jsonl` via PTY; add a file-read sub-protocol; for slopdesk's primary case (Mac Studio host + macOS/iOS client) the files are on the Mac Studio, so the client reads over the network or the host pushes session events over the control channel. **This is the agent-supervision feature already partially designed (ClaudeStatus/ClaudePaneDetector).**

7. **macOS Lookup (force-touch / three-finger tap):** Maps directly on macOS client. iOS: force touch or long-press triggers a preview popover (interaction model differs; 3D Touch peek on supported hardware).

8. **WKWebView browser pane:** WKWebView is cross-platform Apple — maps 1:1 on macOS and iOS. `link-open-with = browser | slopdesk` sets external vs. this pane.

9. **Non-persistent WKWebView data store (`.nonPersistent()`):** Maps 1:1 — available on macOS and iOS.

10. **Security confirmation for non-standard schemes / executables:** Client-side confirmation dialog before launching. Maps 1:1 on macOS; on iOS opening executables is impossible (sandboxed), but `codex://`, `vscode://`, `ssh://` etc. via `UIApplication.open()` is the equivalent.

### SlopDesk-specific notes

- `link-detection = off` matters for TUI apps using mouse reporting — slopdesk passes mouse events through, so this toggle should suppress the path-detection regex overlay when mouse reporting is active (or when configured off).
- "Open in SlopDesk" submenu (current pane / new tab / split) maps onto slopdesk's `PaneChooser` and `WorkspaceStore.reconcile()`.
- Syntax highlighting via syntect is a Rust/Swift library choice. In the all-Swift client: use `swift-syntax`, a bundled tree-sitter grammar set, or a `syntect`-equivalent (ship bundled `.tmLanguage` grammars with a Swift port / linked Swift package).
- The `⌘E` source/preview toggle and pane toolbar Source/Preview segmented control live in the slopdesk pane's toolbar (the strip above content in a non-terminal pane).
- The agent-session "Resume" button ties into slopdesk's agent-supervision design (ClaudeStatus/AgentControlListener); it sends `--resume <session-id>` to a new Claude Code PTY session.
