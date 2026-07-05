# 44 — Agent Supervision + Workspace UX: Night Handoff (2026-06-21)

Follow-on round on branch **`feat/coding-workspace-redesign`** (continues [43](43-NIGHT-HANDOFF.md)).
The redesign landed the `Session → Tab → Pane` tiling shell and runtime Claude-Code detection;
this round turns that detection into a usable **supervision loop** for a human driving many
parallel agents, and fills the remaining mux-parity gaps (sync-input, floating panes, copy-mode).
Each feature committed green. **Nothing is pushed.** Decisions appended to
[`DECISIONS.md`](DECISIONS.md) (§Agent supervision + workspace UX, 2026-06-21).

## What landed

| Feature | Commit | Summary |
|---|---|---|
| Sync-input to all panes | `a51d444` | ⌘⇧I (zellij `ToggleActiveSyncTab`): fan keystrokes to sibling panes; per-tab arming, reentrancy-guarded. |
| Agent-supervision API (host / `slopdesk-ctl`) | `2262d3d` | `list-panes` `state`, a top-level `agent_status_changed` events stream, a `report_agent` self-report verb (30 s sticky), `read --unwrapped`, and `SLOPDESK_CTL*` env sentinels in spawned panes. |
| Premium dark-IDE UI polish | `1dde48b` | Pane focus ring, 3-step elevation ladder, semantic status accents, glass command palette, status-bar telemetry — a disciplined application of the existing `SlopDeskTheme` tokens, not a rewrite. |
| Supervision cockpit (client) | `53fb272` | Concentric attention ring, tab glow, edge-triggered OS notification, jump-to-unread (⌘⇧U), sidebar activity summary + liveness glyph. |
| Floating / scratch panes | `319085f` | Float ⌘⇧F / New Floating ⌃⌘F; movable+resizable card; `PaneSpec.floatingFrame` additive v11 persistence. |
| Keyboard copy-mode | `4b05501` | ⌘⇧C over the scrollback: `j/k`, `Ctrl-D/U`, `g/G`, `[`/`]`, `/` find reuse, `y` copy, `q` exit; COPY badge + hint bar. |

## The supervision model (the point of the round)

The host already ran ONE `ClaudePaneDetector` per pane (see [DECISIONS §C3](DECISIONS.md)); this
round wires it out two ways:

- **Headless** (`2262d3d`): `slopdesk-ctl` gains per-pane `state`, a **push** `agent_status_changed`
  NDJSON stream (no polling), and a `report_agent` verb so a non-`claude` agent can self-declare
  its state (sticky 30 s so the ~1 Hz foreground-absence poll doesn't wipe it). A spawned pane
  carries `SLOPDESK_CTL` / `SLOPDESK_CTL_BIN` / `SLOPDESK_CONTROL_SOCKET` (+ the existing
  `SLOPDESK_PANE_ID`) so an agent inside a pane self-orients with zero discovery.
- **GUI** (`53fb272`): the per-pane type-26/27 status drives a **"which agent needs me?" loop** —
  a blocked pane gets a red attention ring, a done pane a green one, drawn **concentrically with
  the P2 blue focus ring** and visible even on a background pane; tab glow + unread dot; an OS
  notification on a needsPermission/done **edge** (coalesced, click reveals the pane); ⌘⇧U focuses
  the oldest pane needing attention; the sidebar caption shows the agent's actual blocking question.

**No app-layer approval gate.** The client only renders the agent's own self-reported
`needsPermission` and routes the human's typed answer into the pane — it does not arbitrate
permission itself. The security boundary stays the trusted WireGuard mesh (no app-layer auth, see
[DECISIONS §Security](DECISIONS.md)).

## UI / mux-parity notes

- **UI polish is application, not rewrite.** The tokens were already sound; the round added
  elevation, a focus ring (which **never dims** the inactive pane — the documented invariant), and
  semantic accents. **Glass is on transient overlays only** (the ⌘K palette) — never on a content /
  terminal pane (the one-surface rule). Floating panes obey the same rule: glass only on the title
  strip, opaque raised terminal content.
- **Floating panes** revive the schema-reserved-but-deferred `Tab.floatingPanes` seam ([DECISIONS
  §redesign](DECISIONS.md)). `PaneSpec.floatingFrame` is **additive v11** (`decodeIfPresent` → an
  old workspace decodes nil = tiled). The no-teardown invariant holds: a float is just a leaf placed
  by its frame, still mounted.
- **Copy-mode is pragmatic.** No programmatic character-select — the pinned libghostty fork ABI has
  no set-selection action, so `y` copies the existing mouse-made selection / whole scrollback, never
  a client-guessed range. Navigation keys map to libghostty binding actions verified against the
  fork's `Binding.zig`.

## Verified

Per the commit bodies: `swift build` / `swift test` / `make lint` / `golden-check` / `check-ios`
green on each commit (golden corpus intact — these are client-UI + control-socket changes, no
hot-path wire encoding shifted). Each feature was **HW-verified** on macOS (focus ring across a
split, the agent dots lit via a `ctl report`, ⌘⇧U jumping to a blocked background pane, two floats
over the tiled layout, ⌘⇧C badge + `g` scroll-to-top with the key not leaking to the shell).

> A P4 "peek-and-reply" overlay (answer a blocked agent without leaving the current pane) is in
> progress separately and is **not** part of this round — not committed, not documented yet.
