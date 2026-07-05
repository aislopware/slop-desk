# Files, Folder and Links

## Summary

Paths and URLs in terminal output are interactive — `⌘click` opens them in the best handler (file pane for text files, default app otherwise), `⌘⇧click` reveals in Finder or copies a URL. SlopDesk also embeds a full text editor/file previewer (powered by syntect for syntax highlighting), a directory browser (folder pane), and a native WKWebView web browser pane. All these panes can appear inline in the same workspace as the terminal — in the current pane, a new tab, or a split. Agent session history files (Claude Code, Codex, OpenCode) render as readable conversation transcripts rather than raw JSON.

---

## Behaviors

### Path and Link Detection in Terminal Output

- SlopDesk detects the following in live terminal output and scrollback:
  - Absolute paths: `/usr/local/bin/foo`, `/Users/me/project`
  - Tilde paths: `~/project/file.swift`
  - Relative paths: `./src/lib.rs`, `../config/foo.toml`
  - Paths with line/column suffixes: `src/lib.rs:42`, `src/lib.rs:42:5`
  - URLs with `http://`, `https://`, `file://` schemes
  - OSC 8 hyperlinks emitted by programs (always underlined, regardless of Link Schemes setting)
- Relative paths resolve against the pane's last-known working directory (from OSC 7).
- Pressing the `⌘` key highlights detected paths/URLs with an underline to signal they are clickable.
- Hovering with `⌘` held shows the full resolved absolute path in the bottom-left status area of the window.
- macOS Lookup (force-touch / three-finger tap) works on detected paths and URLs for quick preview.

### Click Actions

| Target | Click | ⌘click | ⌘⇧click | Right-click |
|--------|-------|---------|----------|-------------|
| Path | nothing (prevents accidental opens) | Open in best handler — file pane for text, default app otherwise | Reveal in Finder | Context menu: Open With…, Copy Path, Reveal, Change Directory Here, Open in SlopDesk |
| URL | nothing | Open in URL pane (or system browser, per config) | Copy URL | Context menu: Copy, Open in Browser |

### Right-click Context Menu Items (paths)

- **Open Link / Open File / Open Folder** — open with default behavior (configured in Settings → Controls → Open With).
- **Open with** — submenu of installed apps.
- **Copy Path / Copy URL** — copy the resolved absolute path.
- **Reveal in Finder**.
- **Change Directory Here** — cd the focused terminal to the path (or its parent folder).
- **Open in SlopDesk** — submenu: open in current pane, new tab, or split.

### Keyboard-only Path/Link Interaction

- **Jump To (⌘J)**: Opens the jump-to panel — an Open Quickly view scoped to the current pane, listing its detected paths, links, and commands. Type to filter; press `⌘K` on the highlighted item to open the Actions popover (same actions as right-click menu).
- **Hint Mode**: Keyboard-only overlay for opening any detected link without the mouse. See Hint Mode docs for details.

---

### File Pane / Editor

- SlopDesk can open and preview common file types and embeds a text editor.
- Ways to open a file:
  - Drag a file from Finder onto the window's "New Tab" drag zone → new file pane in a new tab.
  - Context menu → Open in SlopDesk → opens view pane.
  - `slopdesk view <file>` — open in preview/read-only mode.
  - `slopdesk edit <file>` — open in edit mode.
- Syntax highlighting is powered by syntect (Sublime/TextMate grammars). Language detection is by file extension, with a shebang fallback for the first line. When an extension is ambiguous (`.m` → Objective-C, `.h` → C, `.v` → Verilog, `.pl` → Perl), a language dropdown in the toolbar lets the user override; "Auto-detect" undoes the override.
- The active syntax theme follows the terminal theme (see Themes).
- The editor font and size follow the terminal theme — there is no separate editor font setting.
- Save: `⌘S` (edit mode only).
- Reload from disk: `⌘R` — discards unsaved changes.
- Files modified outside SlopDesk trigger a banner with "Reload" / "Keep my changes" options.
- File panes are designed for text up to a few MB; very large files fall back to a streamed view (no in-place edit). Binary files open as hex (read-only).

#### Markup with Live Preview (Source ⇄ Preview)

These formats open with both a source view and a rendered preview, toggled with the Source/Preview control in the pane toolbar, `⌘E`, or right-click → Toggle Preview:

| Format | Extensions | Rendered as |
|--------|-----------|-------------|
| Markdown | `.md`, `.markdown` | GitHub-flavored HTML; fenced code blocks syntax-highlighted and follow terminal theme |
| reStructuredText | `.rst`, `.rest` | HTML |
| SVG | `.svg` | Live image with trackpad pinch-to-zoom |
| HTML | `.html`, `.htm` | Rendered locally (JavaScript off for safety) |

These open in preview mode by default. Edits on the source side refresh the preview as you type; switching sides keeps the cursor and unsaved changes.

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
| PDF & rich docs | `.pdf`, video, office docs, fonts, … | Quick Look preview (read-only); PageUp/PageDown to page a PDF |
| Diff/patch | `.diff`, `.patch` | Unified diff with colored hunks (read-only) |
| Binary | any non-textual | Read-only hex view |

Plain-text files with no dedicated grammar still open in the editor — you get the toolbar, shortcuts, and terminal-matching theme, without highlighting.

#### Agent Session History

Coding-agent session logs render as a readable transcript instead of raw JSON. Three agents are recognized by their session file paths:

| Agent | Session files |
|-------|--------------|
| Claude Code | `~/.claude/projects/<project>/*.jsonl` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` |
| OpenCode | `~/.local/share/opencode/storage/session/<project>/*.json` |

- The transcript lays out user and assistant turns with Markdown-rendered text, tool calls, reasoning, and attachments.
- Right-click → select and Copy or Send to Chat.
- A **Resume** button in the toolbar continues that session: jumps to the live tab if still running, otherwise spawns a fresh session with the agent's `--resume` flag.
- Open one via Open Quickly (`⌘P`) — it lists the current project's sessions across all three agents — or just open the file directly.
- Toggle the view with right-click → View as → `<Agent> History ⇄ JSONL (Syntax Highlight)` to drop back to the raw log.
- Only session files under a known agent's directory auto-open as a transcript; any other `.jsonl` stays plain text.

---

### Folder Pane

- A folder pane is a directory browser — click to open files, drag rows out to move them into terminal or file panes.
- Open via: `slopdesk view <dir>` or right-click a folder and select "Open in SlopDesk".
- The pane shows a tree/list of the directory hierarchy. Folders expand inline; files open in a new pane.

---

### Web Browser Pane

- SlopDesk includes a built-in web browser (native WKWebView), allowing a link from the terminal to open right next to work — in the current pane, a new tab, or a split.
- Default handler for `http(s)` links is the system browser; can be changed to SlopDesk so `⌘click` opens links directly in the terminal.
- URL panes use a non-persistent data store — cookies and local storage never bleed across panes or survive a restart.
- Audio and video do not autoplay until the user interacts with the page.
- A bare host in the address bar gets `https://` prepended; otherwise it acts as a DuckDuckGo search.

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

These are set in the SlopDesk config file (`~/.config/slopdesk/config.toml`) under the relevant section. See the Configuration Reference doc for the full key inventory.

| Key | Default | Effect |
|-----|---------|--------|
| `link-cmd-click` | `open` | Behavior for `⌘click` on a link: `open` \| `copy` \| `nothing` |
| `link-cmd-shift-click` | `reveal-finder` | Behavior for `⌘⇧click` on a link: `reveal-finder` \| `open-system-default` |
| `link-detection` | `on` | Toggle link detection: `on` \| `off` (turn off if interfering with TUI mouse) |

### Settings UI (Settings → Controls → Open With)

| Setting | Default | Effect |
|---------|---------|--------|
| Open Links With | Browser | Where `⌘click` and right-click "Open Link" item open a URL. Options include Browser, SlopDesk. |
| Open Files With | SlopDesk | Where `⌘click` and right-click "Open File" item open a file path. |
| Open Folders With | Finder | Where `⌘click` and right-click "Open Folder" item open a folder path. Options: Finder, SlopDesk. |
| Default Git Client | Auto (first installed) | The git GUI used as primary "Open in <App>" target on the Details › Git toolbar. |
| Custom Open With Apps | — | Add third-party apps (e.g. Fork, Typora) to the folder/file "Open in…" submenus. |

### Settings UI (Settings → Controls → Link Schemes)

| Setting | Default | Effect |
|---------|---------|--------|
| Auto-Detect Link Schemes | All | Which URL schemes are underlined on `⌘`-hover and made clickable. "All" detects any `scheme://`; "Custom" restricts to a user-defined list. `http(s)`, `file`, `mailto` are always detected. |
| Custom Link Schemes | — | URL schemes to additionally detect when set to Custom (e.g. `codex`, `ssh`, `vscode`). |
| Reset Security Warnings | — | Clears every "always allow" choice so confirmation dialogs return for non-standard schemes and executables. |

### Settings UI (Settings → Editor)

| Setting | Default | Effect |
|---------|---------|--------|
| Soft Wrap | On | Wrap long lines instead of scrolling horizontally |
| Show Line Numbers | On | Display the line-number gutter in text panes |
| Show Whitespace | Off | Render spaces, tabs, and newlines as visible glyphs |
| Tab Size | 4 | Visual width of a tab character in columns (1–16) |
| Scroll Past Last Line | On | Allow the file pane to scroll past its last line so it can sit at the top of the viewport (terminal's own scroll-past-end is configured separately under Controls) |
| Default to Preview / Read-Only | On | Open Markdown/SVG/HTML in preview mode and start file panes read-only; turn off to open in source mode with editing enabled |

---

## Visual Spec

### editor-pane.png — Text Editor (Source Mode)

The editor pane is a floating macOS window with a translucent/frosted rounded rectangle shadow, showing the standard traffic-light close/minimize/zoom buttons (red/yellow/green) in the top-left. The window title bar shows the filename (`index.md`) centered in a small gray monospace-like label.

**Toolbar (top):** A narrow strip below the title. Left side: a small segmented toggle control (two segments, leftmost appears selected/active), then two icon buttons — a square icon and a bookmark/flag icon. Right side: a `✓ Saved` label (muted gray) and an `✗ Close` button (plain text).

**Editor body:** Full-width content area with a white/light background. A left-side gutter shows line numbers (1–21+ visible) in muted gray, right-aligned, separated from code by a subtle vertical gap (no hard border). Line content begins immediately after. Font is monospace (appears to be a standard coding font, ~13–14pt). The color scheme is light: black/near-black text for prose, blue for markdown heading `#` and `##` markers, dimmed gray for blank lines, and blue/teal hyperlinks for Markdown `[text](url)` link syntax. No visible horizontal scrollbar in soft-wrap mode. Line numbers are aligned right in their column (~3-character wide gutter).

**State shown:** Read-only/saved state (toolbar shows `✓ Saved`). The file is `index.md` — a Markdown document showing a project readme with a top-level heading, paragraphs, `## Highlights`, and `## Contents` with bullet lists.

### full-path-hover.png — Full Path Hover in Status Bar

A terminal window split into two vertical panes. The left sidebar shows a tab list (TABS column) with 4 entries (package.json, abner@MacBook-AB…, tmux, OC | Reviewing todos). The fourth tab "OC | Reviewing todos" is selected/active (darker row, bold text, tab number "#4" shown in gray on right).

The right main area shows an agent output: a table listing tasks (Release pipeline, Theme/view, Link detection, IPC) with counts and descriptions. Below is a prose "High-impact items to prioritize" section with numbered bullets, some in red, one in blue, one in orange. Below that is a terminal block showing a `give me more details...` prompt and `check missing content in CREDITS.md`.

**Status bar at bottom:** A thin dark bar spanning the full window width. The left portion (dark background, ~30% width) shows the resolved absolute path `/Users/abner/Workplace/project/CREDITS.md` in small white monospace text. The right portion shows standard terminal status info in lighter text: `files-and-links.md  20.7K (10%)  - $0.08  ctrl+p commands`. This status bar path display is the "hover shows full path" feature — it appears when the user presses `⌘` and hovers over a detected path in terminal output.

### markdown-pane.png — Markdown Preview Mode

A floating window with traffic-light buttons. Title bar: `index.md` centered. Toolbar: toggle control on the left (the right segment appears active, indicating Preview mode), two icon buttons, then `✓ Saved` and `✗ Close` on the right.

**Content area:** Pure white background, rendered as a web-page-style HTML document. The layout uses generous margins (~40px each side) and comfortable line height. The top-level heading is large (~24pt), bold black, flush left. Body paragraphs are normal weight, 15–16pt, dark gray/near-black text. Hyperlinks are underlined in the link-blue color. Bullet lists use standard disc bullets; bold text uses `**` markdown. The rendered output matches GitHub-flavored Markdown. No line numbers visible (this is the rendered preview, not source).

### folder-pane.png — Folder Browser Pane

A window with traffic-light buttons. Title bar: `docs` centered. Top area has a search field (`Q Find`) and a row of icon buttons (back arrow, forward arrow, eye/view, speech bubble, share), plus `✗ Close` on the right.

**Breadcrumb bar:** Below the icon row, a breadcrumb path `abner > Workplace > project > docs` with `>` separators, each segment in blue clickable text.

**File tree (main body):** Dark/blue folder icons (filled solid blue) for directories, plain document icons for files. The tree shows: three root-level entries (`development`, `spec`, `user`) each with a blue folder icon, then expanded items under the root: `agents`, `customization`, `getting-started`, `public`, `reference`, `terminal-features`, `vt`, `workflows`, `workspace` (all blue folder icons with `>` expand arrows). Under `workspace` (which is expanded), indented file entries appear: `details-panel.md`, `drag-and-drop.md`, `files-and-links.md`, `find.md`, `open-quickly.md` (highlighted/selected in light blue), `window-tab-split.md`. Below that: `index.md`, `code-review-todos.md`.

The highlighted row (`open-quickly.md`) has a very light blue background fill spanning the full width. No checkboxes or badges on rows. The sidebar (TABS column at the left edge) is visible: `project #1`, `OpenCode #2`, `docs #3`.

### web-broswer.png — Built-in Web Browser Pane

A window with traffic-light buttons. Title bar: `localhost` centered. **Browser toolbar:** A single row containing: `✗` (stop/cancel, leftmost), `<` (back), `>` (forward), a circular reload icon, then a URL address bar displaying `http://localhost:5173/` in plain text (rounded rect input, light gray background). A share icon on the far right.

**Web content area:** Renders a documentation site. Left nav sidebar is visible showing menu icon. The main content area displays the home page content (a top-level heading, paragraphs, "Highlights" section with bullet points). The content is rendered as native web — standard browser rendering, not the app's own markdown renderer. The app's own chrome (traffic lights, title bar, browser toolbar) is very minimal — the entire content area is the WKWebView.

**Left sidebar (TABS):** Shows `npm run dev #1` (with a small clock-like badge and abbreviated domain text), `localhost #2` (active, selected row), `abner@MacBook-AB... #3` (partially clipped). Spacing is compact, rows ~28px tall.

### agent-history.png — Agent Session Transcript

A full-size window (no separate floating chrome visible). Title bar: `Fill in the TODOs in the workspace files-and-links doc` (the session title, in gray). Top-right: `⟳ Resume` button and `✗ Close`.

**Pane toolbar (left of title):** Two icon buttons (speech bubble and share/export icon). The title area is centered.

**Content area (transcript):**
- Session metadata header: a compact row showing the session ID hash (`b2d4f6a0-1c3e-4a5b-9d7f-2e4c0a80d11.json`), branch info (`~/Workspace/project · ⎇ main · v2.1.159`).
- A timestamp entry: `● You · 19:30:21` with a gray dot badge.
- A file path highlighted in blue: `/Users/abner/Workplace/project/docs/user/workspace/files-and-links.md`
- User message: `fill in the TODO` in plain text.
- An expandable tool-call block: `> Claude · Agent, 5xBash, Edit, 6xRead · 553 chars` (chevron `>` to expand, gray metadata).
- Assistant prose paragraph: "Filled in the **Web Browser** section of `docs/user/workspace/files-and-links.md` (it was previously `TODO`). Everything is verified against the source:"
- A list of "Sources verified" with blue hyperlinks: file paths like `link-open-with → browser | slopdesk — packages/config/src/lib.rs:924,3484,5801`, `slopdesk open <url> opens a URL pane — docs/...`, etc.
- Bullet items with inline code formatting in gray background, file links underlined in blue.

**Left sidebar (TABS):** `npm run dev #1`, `localhost #2` (with a green dot badge — indicating active/running session), `abner@MacBook-AB... #3` (with orange dot), `Fill in the TODOs in the... #4` (active, selected row, no dot), `OC | Reviewing todos #5`.

The transcript uses a white background, dark text, comfortable vertical spacing (~20px between turns). Code spans use a light gray inline background. Links are bright blue underlined. The expand/collapse tool call block is a single-line collapsed entry with a `>` chevron.

### editor-settings.png — Settings → Editor Panel

A macOS settings window (light theme). Left sidebar: search field at top, then a vertical list of categories with icons — General (⚠ circle), Shell (>_ prompt), Controls (cursor/arrow icon), **Editor** (document icon, currently selected — bold, highlighted row with light blue/gray background), Agents (plug icon), Appearance (palette icon), Recipes (book icon), Key Bindings (lightning bolt icon), Advanced (wrench icon).

**Right panel content area:** Section header "EDITOR" in uppercase small-caps gray label. Below, 5 settings rows, each with a bold title, subtitle description in smaller gray text, and a control on the right:

1. **Soft Wrap** — "Wrap long lines instead of scrolling horizontally" — green ON toggle (iOS-style pill toggle)
2. **Show Line Numbers** — "Display the line-number gutter in text panes" — green ON toggle
3. **Show Whitespace** — "Render spaces, tabs, and newlines as visible glyphs" — gray OFF toggle
4. **Tab Size** — "Visual width of a tab character, in columns" — a stepper control: `[-]  4  [+]` (minus button, value display, plus button), with a light border
5. **Scroll Past Last Line** — long description about scrolling past last line, terminal scroll-past-end configured separately — green ON toggle
6. **Default to Preview / Read-Only** — "Open Markdown / SVG / HTML in preview mode and start file panes read-only — turn it off to open in source mode with editing enabled" — green ON toggle

Row spacing is generous (~56px per row). Each row is separated by a subtle horizontal rule (very light gray). The window has a white background, standard macOS system font.

### links-schemes.png — Settings → Controls → Link Schemes Section

Same settings window structure as editor-settings.png but "Controls" is selected in the left sidebar.

**Right panel content area (partial scroll):** Shows two sections. Top section (continuation of OPEN WITH): 
- **Open Folders With** — "Where Cmd+click and the right-click 'Open Folder' item open a folder path" — dropdown showing "Finder"
- **Default Git Client** — "The git GUI used as the primary 'Open in App>' target on the Details › Git toolbar." — dropdown showing "Auto (first installed)"
- **Custom Open With Apps** — "Add third-party apps (e.g. Fork, Typora) to the folder/file 'Open in…' submenus." — "Configure…" button

Then a section header: **LINK SCHEMES** (uppercase small-caps gray).

- **Auto-Detect Link Schemes** — "Which URL schemes get underlined on Cmd-hover and made clickable. 'All' detects any scheme://; 'Custom' adds only the schemes you list. http(s), file, and mailto are always detected." — dropdown showing "Custom" (currently selected)
- **Custom Link Schemes** — "URL schemes to additionally detect (e.g. codex, ssh, vscode)" — "Configure…" button
- **Reset Security Warnings** — "Forget every 'always allow' choice so the confirmation dialog returns when opening external links, custom schemes, or executables." — "Reset" button

### open-with-option.png — Settings → Controls → Open With Section

Same settings window, "Controls" selected.

**Right panel content area (OPEN WITH section):**
- **Open Links With** — "Where Cmd+click and the right-click 'Open Link' item open a URL" — dropdown showing "Browser"
- **Open Files With** — "Where Cmd+click and the right-click 'Open File' item open a file path" — dropdown showing "SlopDesk"
- **Open Folders With** — "Where Cmd+click and the right-click 'Open Folder' item open a folder path" — dropdown showing "Finder" with a dropdown open below it showing two options: "Finder" (top) and "SlopDesk" (bottom), in a white popup menu with light shadow and rounded corners
- **Default Git Client** — "The git GUI used as the primary 'Open in App>' target on the Details › Git toolbar. Other installed clients and your custom Open With apps still appear in the dropdown." — dropdown partially obscured by the Finder/SlopDesk popup
- **Custom Open With Apps** — "Add third-party apps (e.g. Fork, Typora) to the folder/file 'Open in…' submenus." — "Configure…" button

Below: **KEYBOARD** section header, partially visible.

### hint-mode.png — Hint Mode Overlay in Terminal

A terminal pane showing a standard terminal session running `npm run dev`. The window title bar shows `npm run dev`. Top-right corner has a **HINTS** badge label and two buttons: `Esc` and `✗ Exit`.

**Terminal content:** Standard dark terminal output (dark background) showing commands like `docs-web@0.1.0 predev`, `npm run sync-docs`, sync log lines, vitepress v1.6.4 output, and sync lines. One line is highlighted/underscored in yellow: `Workspace/project/packages/docs-ms (main x)●` — this is the detected current-working-directory path that has been identified as a clickable link.

**Hint labels:** Yellow square label `h` appears overlaid on the highlighted `h` letter in `/scripts/dev.mjs` link (the link character that triggers the hint). The hint labels are small solid-colored rounded squares with white letters (fzf-style letter hints). Additional hint labels visible: `h` appears on the `./scripts/sync-docs.mjs` path and another on the `http://localhost:5173/` URL link.

The mode indicator **HINTS** in the top-right is a small rounded-rect badge with uppercase text. The `Esc` and `Exit` buttons are plain text buttons separated by a thin space.

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

- **⌘click / ⌘⇧click on paths/URLs:** Fully implementable in the client UI. The client already tracks the pane's last-known working directory via OSC 7 (which slopdesk passes through). Path detection regex (absolute, tilde, relative, `path:line:col`, `http(s)://`, `file://`) is a pure client-side text scan on the rendered terminal grid.
- **OSC 8 hyperlinks:** Already in libghostty's protocol surface — ghostty surfaces these as metadata on text runs. The client layer can read them and underline/make-clickable.
- **Right-click context menu:** Standard macOS `NSMenu` from the client view. All menu items (Open, Copy, Reveal, Change Directory Here) are client-initiated actions. "Change Directory Here" sends a `cd <path>\n` to the host PTY over the terminal channel — no special protocol needed.
- **Jump To (⌘J):** Client-side: scan the current scrollback buffer for detected paths/links/commands and show a fuzzy-searchable list. Open Quickly pattern already exists in slopdesk.
- **Hint Mode:** Client-side overlay; assigns letter labels to detected links in the current viewport. No host involvement.
- **⌘-hold underline highlight:** Client-side rendering hint — when `⌘` is held, re-render detected paths with underline decoration. Implementable in the terminal view without host round-trips.
- **Status bar path display on hover:** The bottom-left status region of the workspace window shows the resolved path. Already adjacent to the existing status bar infrastructure.
- **Editor Settings (soft wrap, line numbers, whitespace, tab size, scroll-past, preview default):** Pure client-side file pane settings. No host involvement.
- **Web browser (WKWebView pane):** Client-side. A new `PaneKind` (`.web`) hosting `WKWebView`. Already partially noted in slopdesk as `.remoteGUI` reuse candidate — but a web pane is fully local (no remote involvement). Can be a new `PaneKind.web`.
- **Folder pane:** Client-side file system access. Works for the LOCAL client filesystem trivially. For remote (host-side) directories, needs a directory-listing protocol over the control channel.
- **Agent session history (Claude Code / Codex / OpenCode transcript rendering):** Client-side JSON parsing and custom SwiftUI rendering. The session files live on the LOCAL client filesystem for local sessions, or on the HOST for remote sessions (requires file transfer). JSONL parsing and transcript view are client-only UI.

### What does NOT map 1:1 (flag for design decision)

1. **"Reveal in Finder" for remote paths:** When a path in the terminal output refers to a file on the remote macOS host, `⌘⇧click` → Reveal in Finder cannot directly open Finder on the client. Options:
   - Show the path in the client status bar only (copy to clipboard as fallback).
   - Use `open -R <path>` sent to the host as a PTY command, which reveals in the HOST's Finder (useful for a local Mac host; meaningless for a remote server).
   - **Decision needed:** Does "Reveal" mean client Finder or host Finder? For the local macOS host case, sending `open -R` to the host PTY is viable.

2. **File pane for remote files:** `slopdesk view`/`slopdesk edit` open files on the LOCAL filesystem. In slopdesk, the host terminal session's filesystem is REMOTE. To open a remote file in the client's file pane, slopdesk needs an SFTP/SCP-style file transfer channel (not currently in the wire protocol). **Cannot map 1:1 without adding a file-transfer sub-protocol.**

3. **"Open in best handler" for remote binary files (non-text):** Opening a remote `.png` or `.pdf` via `⌘click` requires transferring the file to the client first. The current protocol has no file-transfer mechanism.

4. **"Change Directory Here" for relative paths:** Works trivially — just send `cd <path>\n` to the host PTY. But path resolution (relative → absolute) must use the host's CWD (from OSC 7), which is already tracked.

5. **Folder pane for HOST directories:** Browsing the remote host's filesystem requires a directory-listing protocol (not in the current wire). The simplest approach: run `ls -la` or `find` in the host PTY and parse the output — fragile but viable short-term. A proper solution requires adding a control-channel file-listing message.

6. **Agent session history for REMOTE sessions:** If the agent runs on the host and the session files are at `~/.claude/projects/...` on the host, the client cannot read them directly. Options:
   - Stream/tail the `.jsonl` file via PTY (`tail -f`).
   - Add a file-read sub-protocol.
   - For slopdesk's primary use case (Mac Studio host + macOS/iOS client), the Claude Code session files are on the Mac Studio. The client must either read them over the network or the host can push session events over the control channel. **This is the agent supervision feature already partially designed (ClaudeStatus/ClaudePaneDetector).**

7. **macOS Lookup (force-touch / three-finger tap) for link preview:** iOS client supports 3D Touch peek on supported hardware, but the interaction model differs from macOS. On macOS client it maps directly. On iOS client, force touch or long-press can trigger a preview popover.

8. **WKWebView browser pane:** Available on both macOS and iOS (WKWebView is cross-platform Apple). Maps 1:1 for both clients. The `link-open-with = browser | slopdesk` config sets whether URLs open externally or in this pane.

9. **Non-persistent WKWebView data store (`.nonPersistent()`):** Maps 1:1 — WKWebView's `.nonPersistent()` data store is available on both macOS and iOS.

10. **Security confirmation for non-standard schemes / executables:** Client-side; show a confirmation dialog before launching. Maps 1:1 on macOS; on iOS, opening executables is not possible (sandboxed), but opening `codex://`, `vscode://`, `ssh://` etc. via `UIApplication.open()` is the equivalent.

### SlopDesk-specific notes

- The `link-detection = off` config key is important for TUI apps that use mouse reporting — slopdesk already passes mouse events through, so this toggle should suppress the path-detection regex overlay when mouse reporting is active (or when the user configures it off).
- The "Open in SlopDesk" context menu submenu (current pane / new tab / split) maps exactly onto slopdesk's `PaneChooser` and `WorkspaceStore.reconcile()` infrastructure.
- Syntax highlighting via syntect is a Rust/Swift library choice. In slopdesk's all-Swift client, use `swift-syntax` or a bundled tree-sitter grammar set, or embed a `syntect`-equivalent (e.g. ship bundled `.tmLanguage` grammar files and use a Swift port or link a Swift package).
- The `⌘E` source/preview toggle and the pane toolbar's Source/Preview segmented control should live in the slopdesk pane's toolbar area (the strip above the content in a non-terminal pane).
- The "Resume" button for agent sessions ties directly into slopdesk's agent supervision design (ClaudeStatus/AgentControlListener). It should send `--resume <session-id>` to a new Claude Code PTY session.
