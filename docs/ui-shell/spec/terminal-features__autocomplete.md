# Autocomplete / Inline Suggest

## Summary

Two surfaces — inline ghost-text and a candidate panel — driven by a Fig-compatible spec database (715+ CLI tools bundled) plus on-device learning from command history, `--help` probes, and project READMEs. Always-on and passive: no summon key. After a typing pause the most likely continuation shows as dim ghost text; when multiple completions are plausible, a candidate panel opens beneath the cursor. Fully offline — no keystrokes or history leave the machine.

## Behaviors

- Watches the prompt line continuously; no summon key — suggestions appear automatically after a typing pause.
- Single clear winner → **ghost text**: dim continuation rendered after the cursor on the same line. Accept with `Tab` (or `→` when `autocomplete-shortcut = tab+right-arrow`); keep typing to refine; `Backspace` to clear; `Esc` to dismiss without leaving the line.
- Multiple plausible completions → **candidate panel** (dropdown) beneath the cursor, up to 8 rows visible, with a side column showing the selected item's description. Navigate `↑`/`↓`; accept with `Return` or `Tab`; dismiss with `Esc`; or click a row.
- Every candidate row carries a **kind icon** for suggestion origin: subcommand, option/flag, argument, file, folder, alias, snippet, learned command, README command, or "did you mean…" fix.
- `autocomplete-show-candidates` controls when the panel opens. Default `escape` (press Esc to open). Other values: `disable`, `auto` (open whenever ≥ 2 matches), `option-escape` (Option+Esc / F5).
- **Source 1 — Fig-compatible spec database**: 715 commands bundled (`git`, `npm`, `kubectl`, `docker`, `aws`, …). Manually refreshed via Settings → Controls → Autocomplete → Update Now; no automatic background sync. Local specs are never overwritten by an update.
- **Source 2 — Recent used (frecency)**: each executed command is tokenized and recorded locally, ranked by frecency (frequency + recency, strong boost for current session). `git checkout ` surfaces most-used branches; a bare prompt offers commands used in that folder.
- Frecency secrets handling: values after `--password` / `--token` / `--api-key` flags are never stored; commands matching `autocomplete-history-ignore` globs are skipped; commands exiting 127 (not found) or with an obviously mistyped `--flag` are pruned out.
- **Source 3 — Auto correction**: on failure, reads the error output and offers the fix as ghost text on the next prompt line (thefuck-style). Recognizes correction output from `git`, `npm`, `cargo`, `pip`, `brew`, `rustup`, and the shell's command-not-found handler. Accept like any suggestion, or type to ignore.
- **Per-folder scripts via `slopdesk learn`**: `slopdesk learn 'npm run deploy:staging'` pins a command to the current directory; offered first on return, rank bumped on repeat. Does NOT auto-scan `package.json`, `Makefile`, or `justfile`.
- **README scanning**: reads fenced code blocks from a project's `README` and offers those commands in the same folder automatically, no setup.
- **Adding new binaries**: `slopdesk learn ripgrep` — for a bare binary on `$PATH`, `learn` runs `<binary> --help` (fallback: `-h` or a `help` subcommand), parses options and subcommands, writes a spec into the local completion DB. User-added specs are tagged separately and survive app updates.
- **Disabling options** (Settings → Controls → Autocomplete):
  - Hide ghost text: turn off Inline Suggestion.
  - Disable candidate panel: set Candidate Panel to Disabled (Esc/Option+Esc no longer opens the dropdown).
  - Disable accept key: set Accept Suggestion to Disabled.
  - Stop local learning: turn off On-device Learning (keeps bundled specs; stops history recording, --help probes, README reads).
  - Switching off BOTH Inline Suggestion AND Candidate Panel disables the feature entirely — spec database is never consulted.
  - Clear all learned data: "Clear my data" button.
- **Privacy**: fully offline. No keystrokes, command lines, or history sent anywhere. `--help` probes run inside a network-denied sandbox. Live data (branch names, Homebrew formulae) is read from local disk — `brew install …` never triggers `brew update`. Network is used only when the user presses "Update Now" for the completion database.
- `autocomplete-description-language` controls the language of candidate descriptions: `system`, `english`, or `chinese`.

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
| `autocomplete-history-ignore` | (none) | Glob patterns for commands never recorded, e.g. `ssh *`, `export *TOKEN*`. |
| `autocomplete-description-language` | `system` | Language of candidate descriptions: `system`, `english`, or `chinese`. |

## Visual spec

### autocomplete.png — Candidate panel (basic, no description column)

macOS terminal window (rounded corners, drop shadow, white/light background), traffic-light cluster (red/yellow/green) top-left, title bar "abner@MacBook-Pro: ~/Workplace/o…" centered in system font.

Prompt line: `~/Workplace/slopdesk (main ✓) ▷ git |` — directory in light cyan/teal, `(main ✓)` green, prompt `▷` green, `git` in default near-black, blinking block cursor after it.

Below and slightly right of the cursor, a **candidate panel**: floating rounded-rectangle, light gray background (~#E8E8E8), 8 rows of git subcommands in monospace (dark/black), left-aligned with consistent padding:
1. `archive`
2. `blame`
3. `commit`
4. `config`
5. `rebase`
6. `add`
7. `stage`
8. `status`

No row highlighted; no description side-column (minimal state, names only). No visible border/divider — background fill only. Font size matches terminal text. No kind icons visible here.

Window ~1366 × 768 at 2x (Retina). Panel anchored at the cursor, below-and-right of the `git ` token.

### autocomplete-config.png — Settings panel (Controls → Autocomplete section)

macOS settings window (white, rounded corners, traffic lights — red active, yellow/gray inactive), ~1280 × 800.

**Left sidebar** (~300px, light gray ~#F5F5F5): search field top ("Search", magnifier), then nav list of icon+label pairs (monochrome, ~16px):
- General (clock/info)
- Shell (>_)
- **Controls** (arrow/cursor) — selected, light blue/gray highlight row
- Editor (document)
- Agents (plug/power)
- Appearance (palette/circle)
- Recipes (book)
- Key Bindings (lightning bolt)
- Advanced (wrench)

**Right content area** (white): scrollable form. **AUTOCOMPLETE** section header (small caps, gray), then rows:

1. **Accept Suggestion** / "Key to accept suggestion when there is a single match or a selected candidate" — dropdown "Tab" + chevron-down, right-aligned (~200px).
2. **Candidate Panel** / "When to show the candidate panel" — dropdown "Escape Key" + chevron-down, right-aligned.
3. **Inline Suggestion** / "Show a faded inline preview when there's a single suggestion" — iOS toggle (green, ON), right-aligned.
4. **On-device Learning** / "Improve suggestions from your history, tools' --help output, and project README files. All data stays on this device — nothing is uploaded." (2 lines) — iOS toggle (green, ON), right-aligned.
5. **Completion Database** / "No data available yet" — button "Update Now" (rounded rect, light gray, right-aligned).
6. **Clear my data** / "Wipe what autocomplete has learned about you. Built-in CLI specs are kept." (2 lines) — button "Clear…" (rounded rect, light gray, right-aligned).

Below, partially visible: **SELECTION** header and "Shift+Arrow Select" row with a toggle (green, ON). Thin macOS scrollbar (dark indicator) on the far right.

Spacing: ~16px vertical gaps between rows; bold title ~14px, description ~12px gray; dropdowns/toggles right-aligned with ~24px right margin.

### autocomplete-fig.png — Candidate panel with description column (Fig spec source)

macOS terminal window (rounded corners, drop shadow, white/light background), traffic lights top-left, title bar "abner@MacBook-Pro: ~", small sidebar-toggle icon (square bracket / panel) left of the title.

Prompt: `~ ▷ make |` — tilde cyan/teal, `▷` green, `make` default text, blinking block cursor after it.

Below the cursor, a two-part floating **candidate panel**. LEFT part: rounded-rectangle, light gray (~#E8E8E8), 8 rows of `make` flags in monospace, left-aligned:
1. `--no-print-directory`
2. `-W`
3. `--what-if`
4. `--new-file`
5. `--assume-new`
6. **`--warn-undefined-vari…`** (truncated) — **selected**: text blue/teal (~#4DAADB), row background slightly darker (~#D8D8D8).
7. `-N`
8. `--Next-option`

RIGHT part: second rounded-rectangle, same light gray, directly right of the left panel with a gap. Contains header **"OPTION"** (small caps, gray ~#888888) and body "Warn when an undefined variable is referenced" (normal weight, dark gray, ~2 lines) — the selected item's description. Same vertical level as the left panel, ~480px wide vs ~300px for the candidates list.

Selected-row blue (~#4D9FDB) anchors the left selection to the right description. No distinct kind-icon glyphs visible (may be too small or absent for flag completions).

Window ~1366 × 768 at 2x. Panel below-and-slightly-right of the cursor; left panel's first row starts near the `make ` cursor's horizontal position.

## Screenshots

- `autocomplete.png` — candidate panel after typing `git `, 8 subcommands, no description column, no selection highlight.
- `autocomplete-config.png` — Settings → Controls → Autocomplete, all 5 controls (Accept Suggestion dropdown, Candidate Panel dropdown, Inline Suggestion toggle, On-device Learning toggle, Completion Database Update Now button, Clear my data button).
- `autocomplete-fig.png` — candidate panel for `make` with a selection (`--warn-undefined-vari…` in blue) and description side-column ("OPTION / Warn when an undefined variable is referenced").

Video (not downloaded, MP4):
- `autocomplete-correct.mp4` — Auto correction demo: command fails, ghost text appears with fix on next prompt line.
- `cli-learn.mp4` — `slopdesk learn` demo: per-folder command pinning workflow.

## Implementation notes

SlopDesk is a remote coding tool (macOS host + macOS/iOS clients) with the terminal rendered by libghostty behind a `TerminalSurface` seam. How each behavior fits:

**Straightforward (client-side rendering on top of libghostty):**

- **Ghost text rendering**: client-side overlay drawn after the cursor in `TerminalRenderingView`. Host PTY/shell sends raw bytes; the client intercepts the current command line (via shell integration / OSC sequences) and renders the ghost text as a SwiftUI/AppKit layer over libghostty's terminal. Entirely client-side.
- **Candidate panel UI**: client-side SwiftUI popover/overlay anchored to the cursor in screen coordinates. No host involvement.
- **Kind icons**: client-side decoration in panel rows.
- **Description side-column**: client-side panel layout.
- **Keyboard handling**: Tab accept, Esc dismiss, arrow navigation — intercepted client-side before forwarding to PTY; client must hold/suppress certain key events when the panel is visible.

**Requires host-side data (cwd, history) — partial:**

- **Frecency / recent command history**: history lives on the HOST (`~/.zsh_history` etc.). Client either (a) queries the host over the control channel, or (b) maintains a session-scoped local cache fed by the host as commands complete (OSC 133 / shell integration marks). Option (b) is more practical — slopdesk already has OSC-133 block detection. Flag: **requires host-side OSC-133 integration to feed per-command history to the client**.
- **Per-folder context (cwd)**: cwd is on the HOST. OSC 7 or shell integration provides it; already tracked in slopdesk's OSC integration. Flag: **cwd must be received from host via OSC 7 or equivalent**.
- **Fig spec database**: 715-command DB can be bundled LOCALLY as a static JSON/binary asset — no host dependency. "Update Now" needs a download source — slopdesk's own bundle or a compatible source (the open-source withfig/autocomplete GitHub repo).
- **`slopdesk learn` per-folder pinning**: a CLI tool that runs on the HOST. Base exists (`slopdesk-ctl` / AF_UNIX agent control). Flag: **requires a host-side CLI companion and a protocol message to sync learned commands to the client**.
- **README scanning**: on the HOST filesystem. Needs host-side scanning (daemon) with results sent to the client, or a file-protocol read over the existing channel. Flag: **host-side feature, needs protocol extension**.

**Harder constraints:**

- **`--help` probes in a network-denied sandbox**: the host daemon CAN run probes (no sandbox concern), but the client is UI-only and cannot run host binaries; the host must execute and return parsed results. Flag: **host-side probe execution needed; client cannot run host binaries directly**.
- **"Clear my data" and "On-device Learning" toggle**: learned data spans host (command history) and client (spec DB, frecency cache); settings UI is client-side, but clearing host history needs a control message. Flag: **dual-store: client-local spec/frecency vs host-side history**.
- **Auto-correction (thefuck-style)**: needs reading the failed command's stderr/stdout on the HOST and detecting correction patterns. OSC-133 marks capture exit status, but tool-specific correction output requires the host daemon to parse it and push a suggestion. Flag: **host-side pattern matching needed; not purely client-side**.
- **`autocomplete-description-language = chinese`**: needs localized description strings in the spec DB. Feasible if the bundle includes translations. No architecture barrier, just data.
- **Completion Database "Update Now"**: needs a hosted source. slopdesk needs its own update mechanism or points at the open-source withfig/autocomplete repo. Flag: **CDN dependency; slopdesk must host or mirror the spec bundle**.

**Difficulty tiers:**
- Easy (pure client): ghost text, candidate panel UI, kind icons, description column, keyboard interception, static Fig spec DB bundled in app.
- Medium (needs partly-present OSC integration): cwd-aware suggestions (OSC 7), session command history (OSC 133 marks), client-side frecency ranking.
- Hard (needs new protocol messages): `slopdesk learn` (host pinning + sync), README scanning (host reads files, pushes), `--help` probes (host executes, returns parsed spec), auto-correction (host parses tool error output, pushes correction).
