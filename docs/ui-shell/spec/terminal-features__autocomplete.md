# Autocomplete / Inline Suggest

## Summary

SlopDesk's autocomplete feature provides two complementary surfaces — inline ghost-text and a candidate panel — driven by a Fig-compatible spec database (715+ CLI tools bundled) plus on-device learning from command history, `--help` probes, and project README files. It is always-on and passive: there is no summon key. After a brief pause in typing, the most likely continuation appears as dim ghost text; when multiple completions are plausible, a candidate panel opens beneath the cursor. All processing is fully offline — no keystrokes or history ever leave the machine.

## Behaviors

- SlopDesk watches the shell prompt line continuously; there is no key to summon autocomplete — it appears automatically after a pause in typing.
- A single clear winner is shown as **ghost text**: a dim (faded) continuation rendered after the cursor on the same line.
- Ghost text: accept with `Tab` (or `→` when `autocomplete-shortcut = tab+right-arrow`); keep typing to refine; `Backspace` to clear; `Esc` to dismiss without leaving the line.
- When multiple completions are plausible, a **candidate panel** (dropdown) opens beneath the cursor. Up to 8 rows are visible. A side column shows the selected item's description.
- Candidate panel: navigate with `↑`/`↓`; accept with `Return` or `Tab`; dismiss with `Esc`; or click a row directly.
- Every candidate row carries a **kind icon** indicating suggestion origin: subcommand, option/flag, argument, file, folder, alias, snippet, learned command, README command, or "did you mean…" fix.
- Whether the panel opens automatically or on-demand is controlled by `autocomplete-show-candidates`. Default is `escape` (press Esc to open the panel). Other values: `disable`, `auto` (open whenever ≥ 2 matches), `option-escape` (Option+Esc / F5).
- **Source 1 — Fig-compatible spec database**: 715 commands bundled (`git`, `npm`, `kubectl`, `docker`, `aws`, …). Manually refreshed via Settings → Controls → Autocomplete → Update Now. No automatic background sync. Local specs are never overwritten by an update.
- **Source 2 — Recent used (frecency)**: each executed command is tokenized and recorded locally, ranked by frecency (frequency + recency blend, strong boost for current session). `git checkout ` surfaces most-used branches; a bare prompt offers commands you reach for in that folder.
- Frecency secrets handling: values after `--password` / `--token` / `--api-key` flags are never stored; commands matching `autocomplete-history-ignore` globs are skipped; commands exiting 127 (not found) or obviously mistyped `--flag` are pruned back out.
- **Source 3 — Auto correction**: when a command fails, SlopDesk reads the error output and offers the fix as ghost text on the next prompt line (thefuck-style). Recognizes correction output from `git`, `npm`, `cargo`, `pip`, `brew`, `rustup`, and the shell's command-not-found handler. Accept like any suggestion, or type to ignore.
- **Per-folder scripts via `slopdesk learn`**: `slopdesk learn 'npm run deploy:staging'` pins a command to the current directory; it is offered first when returning to that folder. Repeating on the same command bumps its rank. SlopDesk does NOT auto-scan `package.json`, `Makefile`, or `justfile`.
- **README scanning**: SlopDesk reads fenced code blocks from a project's `README` and offers those commands in the same folder automatically with no setup.
- **Adding new binaries**: `slopdesk learn ripgrep` — for a bare binary on `$PATH`, `learn` runs `<binary> --help` (fallback: `-h` or a `help` subcommand), parses options and subcommands, writes a spec into the local completion DB. These user-added specs are tagged separately and survive app updates.
- **Disabling options** (Settings → Controls → Autocomplete):
  - Hide ghost text: turn off Inline Suggestion toggle.
  - Disable candidate panel: set Candidate Panel to Disabled (Esc/Option+Esc no longer opens dropdown).
  - Disable accept key: set Accept Suggestion to Disabled.
  - Stop local learning: turn off On-device Learning (keeps bundled specs, stops history recording, --help probes, README reads).
  - Switching off BOTH Inline Suggestion AND Candidate Panel disables the feature entirely — spec database is never consulted.
  - Clear all learned data: "Clear my data" button in Settings → Controls → Autocomplete.
- **Privacy**: fully offline. No keystrokes, command lines, or history sent anywhere. `--help` probes run inside a network-denied sandbox. Live data (branch names, Homebrew formulae) is read from local disk — `brew install …` never triggers `brew update`. Network only used when user explicitly presses "Update Now" for the completion database.
- `autocomplete-description-language` controls the language of descriptions shown next to candidates: `system`, `english`, or `chinese`.

## Keybindings

| Action | Keys |
|--------|------|
| Accept ghost text (default) | `Tab` |
| Accept ghost text (alternate) | `→` (when `autocomplete-shortcut = tab+right-arrow`) |
| Accept ghost text (alternate) | `Ctrl+Space` (when `autocomplete-shortcut = ctrl+space`) |
| Dismiss ghost text | `Esc` |
| Refine / clear ghost text | `Backspace` |
| Open candidate panel (default) | `Esc` |
| Open candidate panel (alternate) | `Option+Esc` or `F5` (when `autocomplete-show-candidates = option-escape`) |
| Navigate candidate panel | `↑` / `↓` |
| Accept candidate | `Return` or `Tab` |
| Dismiss candidate panel | `Esc` |
| Click to accept candidate | Mouse click on a row |

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| `autocomplete-shortcut` | `tab` | Key that accepts the current suggestion: `tab`, `tab+right-arrow`, `ctrl+space`, or `disable`. |
| `autocomplete-show-candidates` | `escape` | How the candidate panel opens: `disable`, `auto` (whenever ≥ 2 matches), `escape`, or `option-escape` (Option+Esc / F5). |
| `autocomplete-inline-suggestion` | `true` | Whether to draw the faded ghost text at all. |
| `autocomplete-on-device-learning` | `true` | Master privacy gate for local learning (history, `--help` probes, README scan). Everything stays on your machine. |
| `autocomplete-history-ignore` | (none) | Glob patterns for commands that are never recorded, e.g. `ssh *`, `export *TOKEN*`. |
| `autocomplete-description-language` | `system` | Language of the descriptions shown next to candidates: `system`, `english`, or `chinese`. |

## Visual spec

### autocomplete.png — Candidate panel (basic, no description column)

The screenshot shows a macOS terminal window (rounded corners, drop shadow, white/light background). The window has a standard macOS traffic-light close/minimize/maximize cluster (red/yellow/green) in the top-left. The title bar reads "abner@MacBook-Pro: ~/Workplace/o…" in system font, centered.

The terminal area shows a shell prompt line: `~/Workplace/slopdesk (main ✓) ▷ git |` — the directory is rendered in light cyan/teal, `(main ✓)` in green, the prompt symbol `▷` in green, `git` in default text color (near-black), and a blinking block cursor after it.

Directly below the cursor and slightly to the right, a **candidate panel** appears as a floating rounded-rectangle popup with a light gray background (approximately #E8E8E8). It contains 8 rows of git subcommand names in monospace font (dark/black text), left-aligned with consistent padding. The rows are:
1. `archive`
2. `blame`
3. `commit`
4. `config`
5. `rebase`
6. `add`
7. `stage`
8. `status`

No row is highlighted/selected (no highlight or accent color visible). No description side-column is visible — this is the minimal panel state with just the command names listed. The panel has no visible border or divider line, just the background fill distinguishing it from the terminal. The font size matches the terminal text. No kind icons are visually shown in this screenshot (they may not be shown for this case or are too small to distinguish).

The overall window is approximately 1366 × 768 pixels at 2x (Retina). The panel appears anchored at the cursor position, positioned below and to the right of the `git ` token.

### autocomplete-config.png — Settings panel (Controls → Autocomplete section)

A macOS settings/preferences window (white background, rounded corners, standard traffic lights — red active, yellow and gray inactive). The window is approximately 1280 × 800 pixels.

**Left sidebar** (approximately 300px wide, light gray background ~#F5F5F5): A search field at the top ("Search", magnifier icon). Below it, a navigation list with icon+label pairs (monochrome icons, ~16px):
- General (clock/info icon)
- Shell (>_ icon)
- **Controls** (arrow/cursor icon) — currently selected, shown with a light blue/gray highlight row
- Editor (document icon)
- Agents (plug/power icon)
- Appearance (palette/circle icon)
- Recipes (book icon)
- Key Bindings (lightning bolt icon)
- Advanced (wrench icon)

**Right content area** (white background): Scrollable form. Currently showing the **AUTOCOMPLETE** section header in small caps, gray, followed by these rows:

1. **Accept Suggestion** (bold title) / "Key to accept suggestion when there is a single match or a selected candidate" (gray description) — control: dropdown reading "Tab" with chevron-down, right-aligned (~200px wide).

2. **Candidate Panel** (bold title) / "When to show the candidate panel" (gray description) — control: dropdown reading "Escape Key" with chevron-down, right-aligned.

3. **Inline Suggestion** (bold title) / "Show a faded inline preview when there's a single suggestion" (gray description) — control: iOS-style toggle switch (green, ON state) right-aligned.

4. **On-device Learning** (bold title) / "Improve suggestions from your history, tools' --help output, and project README files. All data stays on this device — nothing is uploaded." (gray description, 2 lines) — control: iOS-style toggle switch (green, ON state) right-aligned.

5. **Completion Database** (bold title) / "No data available yet" (gray description) — control: button labeled "Update Now" (rounded rect, light gray background, system font, right-aligned).

6. **Clear my data** (bold title) / "Wipe what autocomplete has learned about you. Built-in CLI specs are kept." (gray description, 2 lines) — control: button labeled "Clear…" (rounded rect, light gray background, right-aligned).

Below that, partially visible: a **SELECTION** section header and "Shift+Arrow Select" row with a toggle (green, ON).

Vertical scrollbar visible on the far right edge of the content area (thin macOS-style scrollbar, dark indicator).

Spacing: rows are separated by ~16px vertical gaps. Bold title text ~14px, description ~12px gray. Dropdowns and toggles right-aligned at the content area edge with ~24px right margin.

### autocomplete-fig.png — Candidate panel with description column (Fig spec source)

A macOS terminal window (rounded corners, drop shadow, white/light background). Standard traffic lights (red/yellow/green) top-left. The title bar reads "abner@MacBook-Pro: ~". A small sidebar-toggle icon (square bracket / panel icon) is visible left of the title.

The shell prompt shows: `~ ▷ make |` — the tilde is cyan/teal, the `▷` prompt symbol is green, `make` is in default text, blinking block cursor after it.

Below the cursor, a **candidate panel** appears as a two-part floating panel. The LEFT part is a rounded-rectangle with light gray background (~#E8E8E8), containing 8 rows of `make` flags/options in monospace font, left-aligned:
1. `--no-print-directory`
2. `-W`
3. `--what-if`
4. `--new-file`
5. `--assume-new`
6. **`--warn-undefined-vari…`** (truncated with ellipsis) — this row is **highlighted/selected**: text is blue/teal (approximately #4DAADB or similar), and the row has a slightly darker background rectangle (~#D8D8D8) compared to the other rows.
7. `-N`
8. `--Next-option`

The RIGHT part of the panel is a second rounded-rectangle with the same light gray background, positioned directly to the right of the left panel with a gap. It contains:
- A header/label: **"OPTION"** in small caps, gray (#888888 approx), top of the box.
- Body text: "Warn when an undefined variable is referenced" in normal weight, dark gray, wrapping across ~2 lines.

The description box corresponds to the currently selected item (`--warn-undefined-vari…`). It appears at the same vertical level as the left panel, approximately 480px wide vs ~300px for the candidates list.

The selected row's blue color (`#4D9FDB` approx) creates a clear visual anchor between the left-panel selection and the right-panel description. No kind icons are clearly visible as distinct icon glyphs in this screenshot (may be too small or absent for flag completions).

Window is approximately 1366 × 768 at 2x. Panel is positioned below-and-slightly-right of the cursor. The left panel's first row starts at approximately the same horizontal position as the `make ` cursor.

## Screenshots

- `autocomplete.png` — candidate panel open after typing `git `, showing 8 subcommand completions, no description column, no selection highlight.
- `autocomplete-config.png` — Settings → Controls → Autocomplete panel showing all 5 controls (Accept Suggestion dropdown, Candidate Panel dropdown, Inline Suggestion toggle, On-device Learning toggle, Completion Database Update Now button, Clear my data button).
- `autocomplete-fig.png` — candidate panel for `make` with a selection (`--warn-undefined-vari…` highlighted in blue) and description side-column ("OPTION / Warn when an undefined variable is referenced").

Video (not downloaded, MP4):
- `autocomplete-correct.mp4` — Auto correction demo: command fails, ghost text appears with fix on next prompt line.
- `cli-learn.mp4` — `slopdesk learn` demo: per-folder command pinning workflow.

## Implementation notes

SlopDesk is a remote coding tool (macOS host + macOS/iOS clients) with the terminal rendered by libghostty behind a `TerminalSurface` seam. The following notes lay out how each autocomplete behavior fits this architecture:

**Straightforward (client-side rendering on top of libghostty):**

- **Ghost text rendering**: Implemented as a client-side overlay drawn after the cursor in the `TerminalRenderingView`. The host PTY/shell sends raw bytes; the client intercepts the current command line (via shell integration / OSC sequences) and renders the ghost text overlay. libghostty renders the underlying terminal; the ghost text is a SwiftUI/AppKit layer on top. This is a CLIENT-SIDE feature entirely.
- **Candidate panel UI**: The dropdown panel is a client-side SwiftUI popover/overlay anchored to the cursor position in screen coordinates. Fully implementable without host involvement.
- **Kind icons**: Client-side decoration in the candidate panel rows.
- **Description side-column**: Client-side panel layout.
- **Keyboard handling**: Tab accept, Esc dismiss, arrow navigation — intercepted client-side before forwarding to PTY. Requires the client to hold/suppress certain key events when the panel is visible.

**Requires host-side data (cwd, history) — partial:**

- **Frecency / recent command history**: The command history lives on the HOST machine (in `~/.zsh_history` or equivalent). The client must either (a) query the host via the slopdesk control channel to read history, or (b) maintain a session-scoped local history cache fed by the host as commands complete (OSC 133 / shell integration marks commands). Option (b) is more practical: slopdesk already has OSC-133 block output detection. Flag: **requires host-side OSC-133 integration to feed per-command history to the client**.
- **Per-folder context (cwd)**: The current working directory is on the HOST, not the client. OSC 7 (cwd notification) or shell integration provides cwd to the client. Already tracked in slopdesk's OSC integration. Flag: **cwd must be received from host via OSC 7 or equivalent**.
- **Fig spec database**: The 715-command spec database can be bundled LOCALLY in the slopdesk client app (it is a static JSON/binary asset). No host dependency. The "Update Now" button needs a download source — slopdesk would need its own spec bundle or a compatible source (the withfig/autocomplete GitHub repo is open source).
- **`slopdesk learn` per-folder pinning**: This is a CLI tool that runs on the HOST. SlopDesk already has `slopdesk-ctl` / AF_UNIX agent control as a base to build on. Flag: **requires a host-side CLI companion and a protocol message to sync learned commands to the client**.
- **README scanning**: Happens on the HOST filesystem. Requires either host-side scanning (daemon) with results sent to the client, or a file-protocol read over the existing slopdesk channel. Flag: **host-side feature, needs protocol extension**.

**Harder constraints:**

- **`--help` probes in a network-denied sandbox**: The host is a daemon running on the remote Mac — it CAN run `--help` probes (no sandbox concern), but the slopdesk client is the UI layer and cannot run host binaries. The host daemon would need to execute the probe and return parsed results. Flag: **host-side probe execution needed; client cannot run host binaries directly**.
- **"Clear my data" and "On-device Learning" toggle**: Learned data lives on the host (command history) and potentially also on the client (spec DB, frecency cache). The settings UI is on the client, but clearing host-side history may require a control message. Flag: **dual-store: client-local spec/frecency vs host-side history**.
- **Auto-correction (thefuck-style)**: Requires reading the stderr/stdout of the failed command on the HOST, detecting correction patterns. SlopDesk's OSC-133 block marks can capture command exit status, but reading tool-specific correction output requires the host daemon to parse it and push a correction suggestion to the client. Flag: **host-side pattern matching needed; not purely client-side**.
- **`autocomplete-description-language = chinese`**: Requires localized description strings in the spec DB. Feasible if the bundled spec DB includes translations. No architecture barrier, just data dependency.
- **Completion Database "Update Now"**: Needs a hosted source to contact. SlopDesk would need its own update mechanism or to point at the open-source withfig/autocomplete repo. Flag: **CDN dependency; slopdesk must host or mirror the spec bundle**.

**Summary of difficulty tiers:**
- Easy (pure client): ghost text rendering, candidate panel UI, kind icons, description column, keyboard interception, static Fig spec DB bundled in app.
- Medium (needs OSC integration already partially present): cwd-aware suggestions (OSC 7), session command history (OSC 133 marks), frecency ranking on client side.
- Hard (needs new protocol messages): `slopdesk learn` (host-side pinning + sync to client), README scanning (host reads files, pushes to client), `--help` probes (host executes, returns parsed spec), auto-correction (host parses tool error output, pushes correction).
