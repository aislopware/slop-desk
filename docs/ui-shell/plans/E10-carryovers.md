# E10 carry-over directives (REQUIRED — fold into the E10 plan)

E10 (Path/link detection · Jump-To · status bar · hint mode) inherits **no behavioral fix from E17**
— E17 (Read-only + Vi-mode pill + secure input) closed all review findings (`d4d1696` → `be61d2b`,
`mediumsStillBroken:0`); its only residuals are Phase-3 HW GUI-fidelity checks, which don't constrain
E10. This file carries the **binding scope reductions** plus the **platform/wire/UX traps** that bite
path-detection + host-action + status-bar + hint-mode work.

## SCOPE REDUCTIONS (binding — do NOT build these)

- **Vertical-tabs-only.** slopdesk is vertical-tabs-only (encoded at E7-close in `docs/DECISIONS.md`;
  horizontal/top tab bar deliberately dropped per the user). E10's status bar is a **BOTTOM strip**
  (cwd / last-exit / pane-kind / host) — in scope. Do **NOT** add any top/horizontal tab-bar region.
  Put the status surface and full-path hover preview in the bottom strip.
- **No SSH-host filter.** Standing exclusion (primary impact E11). Not E10; noted so no cross-ref
  reintroduces it.
- **Agents = Claude Code only initially.** Standing exclusion (primary impact E13). Not E10; noted so
  nothing pulls in multi-agent UI.

## COEXISTENCE with E17 (no residual to fold, but don't collide)

- E17 added per-pane **top-overlay pills** (`🔒 READ ONLY`, Vi-mode, `SECURE INPUT`) and a ⌘/ hint
  bar. E10's **bottom status bar** must not collide with or duplicate those — they live at opposite
  pane edges; keep them there. The status bar's "pane kind" field is distinct from E17's mode pills;
  don't re-render the same state twice.

## TRAPS specific to E10 (respect these)

- **The host-side OPEN / REVEAL action is E10's ONE wire/RPC decision point (ES-E10-2, ES-E10-6,
  L6).** slopdesk is REMOTE — a detected path/file lives on the **HOST Mac** (or SSH host), not the
  client. So:
  - **`Copy Path`** → client-side pasteboard. No wire.
  - **`Change Directory Here`** → inject `cd <path>\n` into the PTY as **VERBATIM UTF-8 bytes** (NOT
    via SendKeysParser — see [[slopdesk-coding-workspace-redesign-2026-06-20]]: re-run/cd is verbatim
    UTF-8). Existing terminal input path; no new wire.
  - **`Open` / `Reveal in Finder` / `Open in…`** → execute **on the host** (the Mac that owns the
    file). PREFER extending the **existing E4 host-metadata control channel** with an *action* verb
    (e.g. `open-path` / `reveal-path`) over a new socket — but FIRST check whether E4's RPC service
    already exposes any action capability. A genuinely NEW verb is a **WIRE EXTENSION**: host accepts
    only version `1` (no negotiation) → host + client **redeploy together** (no-backcompat); manual
    **big-endian binary** (never JSON/Codable); **validate-then-drop** on the host action handler
    (path arrives over trusted WireGuard but still validate well-formed, never crash/force-unwrap on a
    malformed request); hand-edit `golden/golden_vectors.json` surgically so the 13 frozen keys
    survive + run `bash scripts/golden-check.sh`; update `docs/20-wire-protocol.md`; justify the verb
    in `docs/DECISIONS.md`. Default to extending E4's channel, not a new transport.
  - **iOS:** open/reveal ALWAYS route to the host (iOS has no local file); gesture fallback is
    tap-on-label (ES-E10-6).
- **Path/URL detection is CLIENT-side over the libghostty cell grid, a PURE detector.** Scan the
  rendered cell grid for abs / tilde (`~/…`) / relative / `:line:col` / url / `file://` forms (D1).
  Build as a pure, **unit-testable** function (ES-E10-2) with **revert-to-confirm-fail** tests,
  decoupled from GUI gesture wiring. **Validate-then-drop / bound the scan**: a pathological or very
  long line must not hang/crash the detector — cap scan width, never force-unwrap.
- **Status-bar fields are CLIENT-side derivable — reuse existing engines, no wire change.** cwd via
  **OSC 7**; last command's exit via **OSC-133 D** (the OSC-133 / `TerminalBlockModel` stack exists
  from E8/E9 — REUSE, don't rebuild); pane kind + host from `WorkspaceStore` / `ConnectionRegistry`.
  Honour the **`hideStatusBar`** config key (don't ship one that can't be hidden). ES-E10-3/-4 are
  partly unit-testable (cwd/exit derivation) + partly GUI.
- **⌘-hold link underline / 2-letter hint mode are NOT the reverted titlebar hint-chips.** Memory
  [[slopdesk-keyboard-hints-prefix-substitute-2026-06-25]]: the user found the ⌘-hold **keybinding
  hint keycaps in the titlebar** unattractive — **REVERTED**. E10's ⌘-hold **path/URL underline**
  (ES-E10-1) and **2-letter link-hint mode** (ES-E10-6, Vimium-style) are DIFFERENT, legitimate
  features over the terminal grid — build per `files-and-links.png` / `links-schemes.png` /
  `hint-mode.png`. Do **NOT** reintroduce or restyle the reverted titlebar keybinding-hint chips, and
  don't conflate the two surfaces.
- **Chord-collision check FIRST.** E10 binds `⌘J` (Jump-To), `⌘⇧J` (Hint Mode), `⌘⇧Y`/`⌘⇧R` (hint
  open/reveal variants), `⌃⌘O` (Command Navigator). Grep the default keymap /
  `WorkspaceBindingRegistry` to confirm no collisions before registering. NOTE: E13 (later) also
  wants `⌘⇧J` for Peek-and-Reply — **E10 comes first and OWNS `⌘⇧J` for Hint Mode**; leave a one-line
  note for the later epic to reconcile. **Never bind a bare key** (see
  [[slopdesk-orchestrator-rounds-2026-06-13]]).
- **iOS rots silently.** Status bar, Jump-To, and hint mode live in shared `SlopDeskClientUI` and
  must compile for iOS (⌘ gestures get a tap fallback; open/reveal route to host). **Run
  `bash scripts/check-ios.sh` in the gate** — `swift build` on macOS will NOT catch iOS rot.
- **Honesty discipline (E8/E12/E15/E17).** Never ship a status-bar field, Jump-To row, or hint
  affordance that silently does nothing. If a detected-link action can't actuate for a kind (e.g.
  "Open in…" unavailable), document the ceiling in `docs/DECISIONS.md` rather than present a dead
  control. Tests are revert-to-confirm-fail, non-tautological.

## Reference-screenshot fidelity standard

`spec/user-interface__files-and-links.md`, `spec/user-interface__status-bar.md`,
`spec/terminal-features__hint-mode.md`, `spec/user-interface__outline.md` + their reference
screenshots (`files-and-links.png`, `links-schemes.png`, `status-bar.png`, `hint-mode.png`,
`jump-to.png`) are the 1:1 visual standard (status-strip layout, link underline, hint-label
rendering, Jump-To panel). Match them.
