# Hint Mode

## Summary

Vimium-style keyboard navigation for the terminal. One shortcut overlays a
2-letter label on every clickable target in the viewport (and scrollback, for
copy); typing the label runs the action immediately — no mouse. Complements Vi
Mode (keyboard selection) and `⌘click` (single-target), and is faster when
multiple targets are visible.

## Behaviors

- "Hint to open" (`⌘⇧J`): labels every hintable target in the **visible
  viewport**. Typing the label runs the open action (file path in OS, URL in
  browser, launch app for the target).
- "Hint to copy" (`⌘⇧Y`): labels targets in the **visible viewport AND
  scrollback**. Typing the label copies the matched text to the clipboard.
- "Hint to reveal in Finder" (`⌘⇧R`): labels targets in the **visible
  viewport**. Typing the label reveals the matched path in Finder.
- `Esc` cancels the mode and removes all overlays without taking any action.
- Labels are exactly **2 letters**. First letter filters/dims unmatched labels;
  second letter confirms and runs the action (no Enter).
- Hintable targets:
  - File paths (absolute, tilde-prefixed, relative — same recognition set as
    the "Files and Links" feature).
  - URLs (plain and OSC 8 hyperlinks).
  - Git commit hashes matching `[0-9a-f]{7,}` adjacent to repo context.
  - IP addresses.
  - User-defined regex patterns (via `hint-pattern` config key).
- User-defined patterns take an action template via `hint-pattern-action`; `{0}`
  is replaced with the matched text. Register multiple patterns by repeating the
  `hint-pattern` / `hint-pattern-action` pair.
- `⌘click` and hint mode are complementary: `⌘click` acts on the single target
  under the pointer; hint mode is faster for several targets / avoiding mouse
  movement.

## Keybindings

| Action                   | Keys   |
|--------------------------|--------|
| Hint to open             | `⌘⇧J` |
| Hint to copy             | `⌘⇧Y` |
| Hint to reveal in Finder | `⌘⇧R` |
| Cancel hint mode         | `Esc`  |

## Config keys

| Key                  | Default | Effect                                                                                                   |
|----------------------|---------|----------------------------------------------------------------------------------------------------------|
| `hint-pattern`       | (none)  | Regex string defining a custom hintable pattern. Repeat for multiple patterns.                          |
| `hint-pattern-action`| (none)  | Shell command template run when the associated `hint-pattern` label activates. `{0}` = matched text. Must follow the corresponding `hint-pattern` entry. |

Example config block:
```
hint-pattern = "TICKET-\\d+"
hint-pattern-action = "open https://linear.app/team/issue/{0}"
```

## Visual spec

No screenshots yet; the following is inferred from the behavioral description
plus Vimium-style convention.

### Inferred overlay appearance

- Each label is a short badge (2 letters) positioned at the start of the matched
  text region.
- Labels not matching the first typed character are dimmed or hidden.
- The rest of the terminal content is dimmed/desaturated to make labels pop.
- Badges render in a high-contrast color (e.g. yellow bg / black text, or
  accent bg / white text) to stay readable over any background.
- Entirely keyboard-driven once active; no mouse interaction.

Exact color scheme, font size, badge shape, and dimming are NOT yet pinned —
determine by cross-referencing slopdesk's theme/design system when built.

## Screenshots

(none yet for this feature)

## Implementation notes

### Architecture context

SlopDesk renders the terminal via libghostty behind a `TerminalSurface` seam
(`SlopDeskTerminal`). Content is a remote session on the macOS host, rendered
locally by the macOS/iOS clients. Hint mode is a **client-side UX layer** — it
scans visible terminal text and overlays labels — so it belongs in the client
UI, not the host.

### Straightforward

- **Label overlay rendering**: client-side — scan the libghostty cell grid (or
  the visible `TerminalSurface` snapshot) for hintable patterns, render badges
  as a SwiftUI/UIKit overlay on `TerminalRenderingView`. No host involvement.
- **Hint-to-copy**: copies to the local clipboard — client-side.
- **Hint-to-open (URL / IP)**: opened locally with `NSWorkspace.open(_:)` /
  `UIApplication.open(_:)`. No host needed.
- **User-defined patterns**: config keys stored in the client's
  `PreferencesStore` / config file; matching runs client-side against the
  visible cell grid text.
- **Esc to cancel**: handled by the client key event pipeline.

### Needs care

- **Hint-to-open (file paths)**: `NSWorkspace` on the macOS client would open on
  the **local** machine, not the remote host. Correct action is to open on the
  HOST via a control-channel command (`open <path>` via `NSWorkspace`, or the
  agent). Flag: **file paths must route through the control channel to the
  host** — URLs and IP addresses are host-agnostic and open locally.
- **Hint-to-reveal in Finder**: inherently HOST-side (the file lives on the
  host). Dispatch via control channel; host calls
  `NSWorkspace.activateFileViewerSelecting([url])`. iOS has no Finder equivalent.
  Flag: **no iOS equivalent** — suppress or remap to "copy path" on iOS.
- **Git commit hash hinting ("adjacent to repo context")**: the heuristic may
  need host working-dir / git state. Approximate purely by pattern-matching the
  cell text (7–40 hex chars in a git-looking line); repo-context validation
  needs a host query.
- **Scrollback scanning for hint-to-copy**: libghostty exposes a scrollback
  buffer accessible client-side; scanning within the `TerminalSurface` seam is
  feasible. Verify the full scrollback (not just viewport) is reachable from the
  client cell grid API.
- **`hint-pattern-action` shell command execution**: for URL-open actions,
  execute locally on macOS; arbitrary shell commands belong to the HOST shell
  (control-channel command). Restrict local execution to known-safe URL-open
  patterns; route arbitrary shell strings to the host.
- **Label character set / collision avoidance**: with many targets the label
  assignment must avoid collisions. Standard Vimium-style uses a fixed alphabet
  (e.g. `asdfghjklqwertyuiop…`) ordered by distance from home row. Client-side.
- **iOS keyboard**: the system keyboard intercepts most input. Type-to-activate
  works with a hardware keyboard, but on a soft keyboard present labels as
  tappable targets (fall back from type to tap-on-label) since typing 2 letters
  over the overlay is awkward. Flag: **soft keyboard UX on iOS requires a
  tap-on-label fallback**.
