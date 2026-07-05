# Hint Mode

## Summary

Vimium-style keyboard navigation for the terminal. Press one shortcut and every
clickable target in the visible viewport (and scrollback, for copy) gets a
2-letter label overlay. Type the 2-letter label and the action runs immediately
— no mouse movement required. Complements Vi Mode (keyboard selection) and
`⌘click` (single-target click), and is faster when multiple targets are visible.

## Behaviors

- Activating "Hint to open" (`⌘⇧J`) overlays 2-letter labels on every
  hintable target in the **visible viewport**. Typing the full label triggers
  the open action (e.g. opens a file path in the OS, opens a URL in the
  browser, launches an app for the matched target).
- Activating "Hint to copy" (`⌘⇧Y`) overlays labels on every hintable target
  in the **visible viewport AND scrollback**. Typing the label copies the
  matched text to the clipboard.
- Activating "Hint to reveal in Finder" (`⌘⇧R`) overlays labels on every
  hintable target in the **visible viewport**. Typing the label reveals the
  matched path in Finder.
- Pressing `Esc` at any point while hint mode is active cancels the mode and
  removes all label overlays without taking any action.
- Labels are exactly **2 letters** long. Typing the first letter filters/dims
  unmatched labels; typing the second letter confirms the target and
  immediately runs the action (no Enter required).
- Hintable targets:
  - File paths (absolute paths, tilde-prefixed paths, relative paths — same
    recognition set as the "Files and Links" feature).
  - URLs (plain URLs and OSC 8 hyperlinks).
  - Git commit hashes matching `[0-9a-f]{7,}` adjacent to repo context.
  - IP addresses.
  - User-defined regex patterns (via `hint-pattern` config key).
- User-defined patterns support an action template via `hint-pattern-action`.
  The `{0}` placeholder in the action string is replaced with the matched text.
  Multiple patterns can be registered by repeating the `hint-pattern` /
  `hint-pattern-action` pair in the config.
- `⌘click` and hint mode are complementary: `⌘click` acts on the single
  target under the pointer; hint mode is faster when several targets are
  visible and avoiding mouse movement is desirable.

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
| `hint-pattern`       | (none)  | A regex string defining a custom hintable pattern. Repeat the key for multiple patterns.                |
| `hint-pattern-action`| (none)  | Shell command template to run when the associated `hint-pattern` label is activated. `{0}` is replaced with the matched text. Must follow the corresponding `hint-pattern` entry. |

Example config block:
```
hint-pattern = "TICKET-\\d+"
hint-pattern-action = "open https://linear.app/team/issue/{0}"
```

## Visual spec

No screenshots exist for this feature yet. The following is inferred from the
behavioral description:

### Inferred overlay appearance

The hint overlay must render 2-letter labels on top of each matched target in
the terminal viewport. Industry convention for Vimium-style hint UIs (and the
behavioral description) implies:

- Each label is a short badge (2 uppercase or lowercase letters) positioned at
  the start of the matched text region.
- Labels that do not match the first typed character are visually dimmed or
  hidden to narrow focus.
- The rest of the terminal content is typically dimmed or desaturated to make
  labels pop.
- Label badges are typically rendered in a high-contrast color (e.g. yellow
  background / black text, or accent-colored background / white text) so they
  are readable over any terminal background.
- No mouse interaction is required once hint mode is active — the entire flow
  is keyboard-driven.

The exact color scheme, font size, badge shape, and dimming treatment are NOT
yet pinned down and must be determined by cross-referencing slopdesk's
theme/design system when this feature is built.

## Screenshots

(none yet for this feature)

## Implementation notes

### Architecture context

SlopDesk renders the terminal via libghostty behind a `TerminalSurface`
seam (`SlopDeskTerminal`). The terminal content displayed to the user is a
remote session running on the macOS host, with the macOS and iOS clients
rendering locally via libghostty. Hint mode is a **client-side UX layer** —
it scans the visible terminal text and overlays labels — so it belongs in the
client UI, not the host.

### Straightforward

- **Label overlay rendering**: Implemented client-side by scanning the
  libghostty cell grid (or the visible `TerminalSurface` snapshot) for
  hintable patterns, then rendering label badges as a SwiftUI/UIKit overlay
  layer on top of `TerminalRenderingView`. No host involvement needed.
- **Hint-to-copy**: Copies matched text to the local clipboard — trivially
  client-side.
- **Hint-to-open (URL / IP)**: URLs and IP addresses can be opened locally
  with `NSWorkspace.open(_:)` / `UIApplication.open(_:)`. No host needed.
- **User-defined patterns**: Config keys (`hint-pattern`, `hint-pattern-action`)
  are stored in the client's `PreferencesStore` / config file. Pattern matching
  runs client-side against the visible cell grid text.
- **Esc to cancel**: Trivially handled by the client key event pipeline.

### Needs care

- **Hint-to-open (file paths)**: On macOS client, opening a file path with
  `NSWorkspace` would open it on the **local** machine, NOT on the remote
  host. For a remote session the semantically correct action is to open the
  file on the HOST (e.g. via a control-channel command that instructs the host
  to `open <path>` via `NSWorkspace` on macOS, or via the agent). This
  requires a host-side open command over the control channel.
  - Flag: **file paths must route through the control channel to the
    host** — URLs and IP addresses are host-agnostic and can be opened
    locally.
- **Hint-to-reveal in Finder**: "Reveal in Finder" is inherently a HOST-side
  macOS operation (the file lives on the host). This must be dispatched via
  the control channel to the host, which then calls
  `NSWorkspace.activateFileViewerSelecting([url])`. On iOS client this action
  has no equivalent (there is no Finder on iOS); the binding should be
  suppressed or remapped to "copy path" on iOS.
  - Flag: **no iOS equivalent** — suppress or remap on iOS client.
- **Git commit hash hinting ("adjacent to repo context")**: The heuristic that
  a hex string is a commit hash "adjacent to repo context" may require knowing
  the working directory / git state on the host. In practice this could be
  approximated purely by pattern-matching the cell text (any 7–40 hex chars
  in a terminal line that looks like git output). Repo-context validation would
  need a host query.
- **Scrollback scanning for hint-to-copy**: libghostty exposes a scrollback
  buffer accessible client-side; scanning it for patterns is feasible within
  the `TerminalSurface` seam. Verify that the full scrollback (not just the
  visible viewport) is accessible from the client cell grid API.
- **`hint-pattern-action` shell command execution**: The action template runs
  a shell command (e.g. `open https://...`). On macOS client this can be
  executed locally for URL-opening actions. For arbitrary shell commands the
  correct execution context is the HOST shell, requiring a control-channel
  command. Restrict local execution to known-safe URL-open patterns; route
  arbitrary shell strings to the host.
- **Label character set / collision avoidance**: With many targets the label
  assignment algorithm must avoid collisions. Standard Vimium-style uses a
  fixed alphabet (e.g. `asdfghjklqwertyuiop…`) ordered by distance from home
  row. This is purely client-side.
- **iOS keyboard**: On iOS the system keyboard intercepts most key input.
  The 2-letter label type-to-activate flow works fine with a hardware keyboard
  but on a soft keyboard the hint mode UI should present the labels as
  tappable targets (i.e. fall back from keyboard-type to tap-on-label) since
  typing 2 letters on a soft keyboard while the hint overlay is active is
  awkward.
  - Flag: **soft keyboard UX on iOS requires a tap-on-label fallback**.
