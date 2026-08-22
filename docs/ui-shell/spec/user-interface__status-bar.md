# Status Bar

> ⛔ **RULED OUT — this is no longer "not yet", it is "not going to be".** The per-pane status strip was
> judged low-value by the user and dropped; the ruling is carried in code rather than in
> `docs/DECISIONS.md`, at `Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift:98-102` and mirrored at
> `Sources/SlopDeskMacUI/Pane/MacTerminalLeafView.swift:6`: "NO per-pane status strip on a TERMINAL pane
> … The cwd / exit / progress cues are low-value; host + connection status now live ONCE in the
> connection island." The `hideStatusBar` settings key that used to gate it has zero occurrences left in
> the tree. Do not build a bottom status bar.

## Summary

**Not implemented, and ruled out** (see the banner above; the original note read "not yet implemented as
of 2026-06-25"). No screenshots, config keys, keybindings, or behavioral spec finalized.

Planned placement in the sidebar (between Details Panel and Files/Links) implies a persistent horizontal strip — likely below the tab/title bar or at the window bottom — showing per-pane/per-window context (standard terminal UX pattern).

## Behaviors

- **NONE SPECIFIED** — unimplemented as of 2026-06-25.
- Anticipated (inferred from planned placement + terminal conventions):
  - Per-pane context: cwd, running process, git branch, or similar metadata from the Details Panel's Info tab.
  - Persistent always-visible strip so the user avoids opening the Details Panel for quick context.
  - May mirror/summarize the Details Panel Info tab (cwd, process list, listening ports).

## Keybindings

| Action | Keys |
|--------|------|
| *(none — feature not implemented)* | — |

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| *(none — feature not implemented)* | — | — |

## Visual spec

### No screenshots available

No mockups or reference screenshots exist yet.

## Screenshots

- *(none — no status-bar screenshots exist yet)*

## Implementation notes

### Constraints from slopdesk's remote-host architecture

1. **cwd** — Terminal runs on the *remote macOS host*, not the client, so cwd must be forwarded over the wire (OSC 7 is already supported in ghostty + the shell-integration path — use as source of truth). Client displays host-reported cwd but cannot resolve it locally (e.g. Finder "reveal").

2. **Running process list** — Host-side. Host must emit process metadata (name, PID) over the control channel or side-band. `SlopDeskWorkspaceCore` already has Claude auto-detect + OSC-133 shell integration a status bar could consume.

3. **Listening ports** — Host-side only; not inferable client-side without an explicit host probe + wire protocol extension.

4. **Git status** — Repo state lives on the host filesystem. Requires either the host pushing git metadata (branch, dirty flag, ahead/behind) over the control channel, or the client running `git` remotely — neither is in the wire protocol today.

5. **macOS system integrations** — Menu-bar extras / NSStatusItem are irrelevant on iOS; the iOS client needs an equivalent in-window strip.

### What's already available

- **OSC 133 (shell-integration marks)** — Supported; a status bar could show last command exit code + command text from the OSC-133 stream with no new wire work.
- **Session/pane identity** — PaneID, tab label, connection state are client-side, available directly from `WorkspaceStore`.
- **Theme integration** — Strip follows the existing client design-token system (flat, zero-radius, bg matches pane background).

### Implementation recommendation

Once the spec is finalized, implement as a thin SwiftUI `HStack` strip pinned to the bottom of each `TerminalSurface` pane (or the window bottom). Consume:
- OSC 7 (cwd) → displayed path, truncated to last 2 components.
- OSC 133 (shell integration) → last exit code badge (green/red).
- `WorkspaceStore` → pane kind, session state, active connection host.
- A future host-side metadata push for git branch / process name.

Keep strip height ≤ 20 pt so it does not intrude on terminal real estate.
