# Status Bar

## Summary

The status bar is a planned but **not yet implemented** feature of slopdesk's UI shell. No screenshots, configuration keys, keybindings, or full behavioral specification have been finalized yet.

Based on its intended placement in the sidebar (between the Details Panel and Files/Links), it is expected to occupy a persistent horizontal strip — most likely below the tab/title bar or at the bottom of the window — showing per-pane or per-window context, a standard terminal UX pattern.

## Behaviors

- **NONE SPECIFIED** — feature is unimplemented as of 2026-06-25.
- Anticipated (inferred from its planned placement and common terminal conventions):
  - Would display per-pane context: working directory, running process, git branch, or similar metadata surfaced from the Details Panel's Info tab.
  - Would provide a persistent, always-visible strip so the user does not need to open the Details Panel for quick context.
  - May mirror or summarize information from the Details Panel (Info tab: cwd, process list, listening ports).

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

No mockups or reference screenshots exist for this feature yet.

## Screenshots

- *(none — no status-bar screenshots exist yet)*

## Implementation notes

### Constraints from slopdesk's remote-host architecture

1. **Working directory (cwd)** — In slopdesk the terminal runs on the *remote macOS host*, not the client. The cwd would need to be forwarded over the wire (OSC 7 is already supported in the ghostty terminal and the shell-integration path; this should be the source of truth). The client can display the host-reported cwd, but it cannot resolve it locally (e.g. for Finder "reveal").

2. **Running process list** — Process introspection (what's running in the PTY) is host-side. The client would need the host to emit process metadata (process name, PID) over the control channel or a side-band. Currently `SlopDeskWorkspaceCore` has Claude auto-detect and OSC-133 shell integration; a status bar could consume those events.

3. **Listening ports** — Port enumeration is host-side only; it cannot be inferred client-side without an explicit host probe and wire protocol extension.

4. **Git status** — Repository state lives on the host filesystem. Showing it in a client status bar requires either the host to push git metadata (branch, dirty flag, ahead/behind count) over the control channel, or the client to run `git` remotely — neither is currently in the slopdesk wire protocol.

5. **macOS system integrations** — Any macOS-native status-bar affordances (menu-bar extras, NSStatusItem) are irrelevant on iOS; the iOS client would need an equivalent in-window strip.

### What's already available

- **Shell-integration marks (OSC 133)** — Already supported; a status bar could show the last command exit code and command text from the OSC-133 sequence stream without any new wire protocol work.
- **Session/pane identity** — PaneID, tab label, and connection state are all client-side and available directly from `WorkspaceStore`.
- **Theme integration** — The status bar strip would follow the existing client design-token system (flat, zero-radius, bg matches pane background).

### Implementation recommendation

Once the status-bar spec is finalized, implement it as a thin SwiftUI `HStack` strip pinned to the bottom of each `TerminalSurface` pane (or the window bottom). Consume:
- OSC 7 (cwd) → displayed path, truncated to the last 2 components.
- OSC 133 (shell integration) → last exit code badge (green/red).
- `WorkspaceStore` → pane kind, session state, active connection host.
- A future host-side metadata push for git branch / process name.

Keep the strip height ≤ 20 pt so it does not intrude on terminal real estate.
