# E10 carry-over directives (REQUIRED — fold into the E10 plan)

E10 (Path/link detection · Jump-To · status bar · hint mode) inherits **no behavioral fix from
E17** — E17 (Read-only + Vi-mode pill + secure input) closed ALL of its review findings (base
`d4d1696` → polish `be61d2b`, `mediumsStillBroken:0`); its only residuals are Phase-3 HW
GUI-fidelity checks, which do not constrain E10. This file carries the **binding scope reductions**
plus the **platform/wire/UX traps** that specifically bite path-detection + host-action + status-bar
+ hint-mode work.

## SCOPE REDUCTIONS (binding — do NOT build these)

- **Vertical-tabs-only.** slopdesk is vertical-tabs-only (product decision encoded at E7-close in
  `docs/DECISIONS.md`; the horizontal/top tab bar was deliberately dropped per the user). E10's
  **status bar is a BOTTOM strip** (cwd / last-exit / pane-kind / host) — that is legitimate and in
  scope. Do **NOT** introduce any top/horizontal tab-bar region. Place the status surface as a
  bottom strip and the full-path hover preview within it.
- **No SSH-host filter.** Standing exclusion (primary impact E11). Not relevant to E10; noted so no
  link/jump cross-reference reintroduces it.
- **Agents = Claude Code only initially.** Standing exclusion (primary impact E13). Not relevant to
  E10; noted so nothing pulls in multi-agent UI.

## COEXISTENCE with E17 (no residual to fold, but don't collide)

- E17 added per-pane **top-overlay pills** (`🔒 READ ONLY`, Vi-mode pill, `SECURE INPUT`) and a ⌘/
  hint bar. E10's new **bottom status bar** must not visually collide with or duplicate those — they
  live at opposite pane edges, keep them there. The status bar's "pane kind" field is distinct from
  E17's mode pills; don't re-render the same state twice.

## TRAPS specific to E10 (respect these)

- **The host-side OPEN / REVEAL action is E10's ONE wire/RPC decision point (ES-E10-2, ES-E10-6,
  L6).** slopdesk is REMOTE — a detected path/file lives on the **HOST Mac** (or the SSH host),
  NOT on the client. So:
  - **`Copy Path`** → client-side pasteboard. No wire.
  - **`Change Directory Here`** → inject `cd <path>\n` into the PTY as **VERBATIM UTF-8 bytes**
    (NOT via SendKeysParser — see [[slopdesk-coding-workspace-redesign-2026-06-20]]: re-run/cd is
    verbatim UTF-8). This is the existing terminal input path; no new wire.
  - **`Open` / `Reveal in Finder` / `Open in…`** → must execute **on the host** (the Mac that owns
    the file). PREFER extending the **existing E4 host-metadata control channel** with an *action*
    verb (e.g. `open-path` / `reveal-path`) over adding a new socket — but FIRST read whether E4's
    RPC service already exposes any action capability. If a NEW verb is genuinely required it is a
    **WIRE EXTENSION**: the host accepts only version `1` (no negotiation) → host + client **redeploy
    together** (no-backcompat); manual **big-endian binary** (never JSON/Codable); **validate-then-
    drop** on the host action handler (the path arrives over the trusted WireGuard mesh but still
    validate it is well-formed and never crash/force-unwrap on a malformed request); hand-edit
    `golden/golden_vectors.json` surgically so the 13 frozen keys survive + run
    `bash scripts/golden-check.sh`; update `docs/20-wire-protocol.md`; justify the verb in
    `docs/DECISIONS.md`. Default to extending E4's channel, not a new transport.
  - **iOS:** open/reveal ALWAYS route to the host (iOS has no local file); the gesture fallback is
    tap-on-label (ES-E10-6).
- **Path/URL detection is CLIENT-side over the libghostty cell grid, and is a PURE detector.** Scan
  the rendered cell grid for abs / tilde (`~/…`) / relative / `:line:col` / url / `file://` forms
  (D1). Build it as a pure, **unit-testable** function (ES-E10-2 notes the detector is
  unit-testable) with **revert-to-confirm-fail** tests, decoupled from the GUI gesture wiring.
  **Validate-then-drop / bound the scan**: a pathological or very long line must not hang or crash
  the detector — cap the scan width, never force-unwrap.
- **Status-bar fields are CLIENT-side derivable — reuse existing engines, no wire change.** cwd via
  **OSC 7**, last command's exit via **OSC-133 D** (the OSC-133 / `TerminalBlockModel` stack already
  exists from E8/E9 — REUSE it, don't rebuild), pane kind + host from `WorkspaceStore` /
  `ConnectionRegistry`. Honour the **`hideStatusBar`** config key (don't ship a status bar that
  can't be hidden). ES-E10-3/-4 are partly unit-testable (cwd/exit derivation) + partly GUI.
- **⌘-hold link underline / 2-letter hint mode are NOT the reverted titlebar hint-chips.** Memory
  [[slopdesk-keyboard-hints-prefix-substitute-2026-06-25]]: the user disliked ⌘-hold **keybinding
  hint keycaps in the titlebar** ("không đẹp") and they were **REVERTED**. E10's ⌘-hold **path/URL
  underline** (ES-E10-1) and **2-letter link-hint mode** (ES-E10-6, Vimium-style) are DIFFERENT,
  legitimate, distinct features over the terminal grid — build them faithfully per `files-and-links.png`
  / `links-schemes.png` / `hint-mode.png`. Do **NOT** reintroduce or restyle the reverted titlebar
  keybinding-hint chips, and do not conflate the two surfaces.
- **Chord-collision check FIRST.** E10 binds `⌘J` (Jump-To), `⌘⇧J` (Hint Mode), `⌘⇧Y`/`⌘⇧R` (hint
  open/reveal variants), `⌃⌘O` (Command Navigator). Grep the default keymap / `WorkspaceBindingRegistry`
  to confirm none collide with an existing binding before registering. NOTE: E13 (later) also wants
  `⌘⇧J` for Peek-and-Reply — **E10 comes first and OWNS `⌘⇧J` for Hint Mode**; the later epic will
  reconcile, so use `⌘⇧J` for hint mode here and leave a one-line note. **Never bind a bare key**
  (see [[slopdesk-orchestrator-rounds-2026-06-13]]).
- **iOS rots silently.** Status bar, Jump-To, and hint mode live in shared `SlopDeskClientUI` and
  must compile for iOS (⌘ gestures get a tap fallback; open/reveal route to host). **Run
  `bash scripts/check-ios.sh` in the gate** — `swift build` on macOS will NOT catch iOS rot.
- **Honesty discipline (E8/E12/E15/E17).** Never ship a status-bar field, Jump-To row, or hint
  affordance that silently does nothing. If a detected-link action can't actuate for a given kind
  (e.g. "Open in…" unavailable), document the ceiling in `docs/DECISIONS.md` rather than presenting a
  dead control. Tests are revert-to-confirm-fail, non-tautological.

## Reference-screenshot fidelity standard

`spec/user-interface__files-and-links.md`, `spec/user-interface__status-bar.md`,
`spec/terminal-features__hint-mode.md`, `spec/user-interface__outline.md` + their reference
screenshots (`files-and-links.png`, `links-schemes.png`, `status-bar.png`, `hint-mode.png`,
`jump-to.png`) are the 1:1 visual standard (status-strip layout, link underline, hint-label
rendering, Jump-To panel). Match them.
