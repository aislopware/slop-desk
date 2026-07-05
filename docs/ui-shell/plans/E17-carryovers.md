# E17 carry-over directives (REQUIRED — fold into the E17 plan)

E17 (Read-only mode + Vi-mode pill + secure input) inherits **no behavioral fix from E15** — E15
(Theming + fonts) closed all review findings (base `e87ae9d` → polish `3361360d` → finish
`80c2a1a`); its one open item, a Phase-3 HW GUI-fidelity check, does not constrain E17. This file
carries the **binding scope reductions** + the **platform/wire/balance traps** that bite
read-only-gate + secure-input work.

## SCOPE REDUCTIONS (binding — do NOT build these)

- **Vertical-tabs-only.** slopdesk is vertical-tabs-only (committed in `docs/DECISIONS.md` at
  E7-close; the horizontal/top tab bar was dropped per the user). E17's chrome is per-pane /
  title-region pills (`🔒 READ ONLY`, Vi-mode pill, `SECURE INPUT` title pill) + an overlay key-hint
  bar — all fine in the vertical-rail layout. Do **NOT** add any top/horizontal tab-bar region or a
  pill that only decorates one. Place pills in the pane title/overlay region and the sidebar rail
  row, never a horizontal strip.
- **No SSH-host filter.** Standing exclusion (primary impact E11). Noted so no settings
  cross-reference reintroduces it.
- **Agents = Claude Code only initially.** Standing exclusion (primary impact E13). Noted so nothing
  pulls multi-agent UI into E17's terminal gating.

## DO-NOT-CONFLATE (important — read-only mode IS the feature)

- The **"never add an approval gate"** directive is about *agent supervision* (E13) — never force the
  user to approve each agent action. E17's **read-only mode is a different, in-scope feature**: a
  *user-toggled* per-pane input gate the user turns on/off at will. NOT an agent approval gate. Build
  it fully (gate keys/paste/click-to-move/mouse-report/drop, beep-on-blocked, `🔒 READ ONLY ×` pill,
  Shell→Read-Only menu/palette terms per ES-E17-1). Do not water it down out of misplaced deference
  to the agent-gate rule.

## TRAPS specific to E17 (respect these)

- **Secure input is macOS-only; iOS rots silently.** `EnableSecureEventInput()` /
  `DisableSecureEventInput()` are **AppKit/Carbon, macOS-only** — no iOS equivalent. The secure-input
  feature (I22) must be `#if os(macOS)`-gated, and the shared `SlopDeskClientUI` Settings/title
  surfaces it touches MUST still compile for iOS (no-op or hidden). **Run `bash scripts/check-ios.sh`
  in the gate** — `swift build` on macOS will NOT catch iOS rot.
- **`EnableSecureEventInput` is PROCESS-GLOBAL and MUST be balanced.** Every `Enable` needs exactly
  one matching `Disable`; an unbalanced/leaked enable **locks every other app out of the keyboard**
  until the process exits (real, user-hostile bug). Reference-count or strictly pair it; disable on
  pane close / app background / window resign / no-echo-cleared. Add a test (or asserted invariant)
  that enable/disable balance. Do not enable unconditionally — only while the host signals canonical
  no-echo AND the Auto/Indicator setting allows it.
- **"Host signals canonical no-echo" may be a WIRE concern — treat carefully.** The PTY echo/no-echo
  (termios `ECHO`) state lives on the HOST. If E17 needs the host to *tell* the client "child
  disabled echo" (e.g. a password prompt), prefer deriving it CLIENT-side from libghostty's existing
  terminal-mode state if available (no wire change — like E8's `TerminalModeTracker`). **Only if it
  genuinely requires a new host→client message** do you touch the terminal control-channel wire — and
  then: it is a WIRE EXTENSION → host accepts only version `1` (no negotiation), so host+client
  **must redeploy together** (no-backcompat), update `docs/20-wire-protocol.md`, manual big-endian
  binary (never JSON/Codable), and hand-edit `golden/golden_vectors.json` surgically so the 13 frozen
  keys survive + run `bash scripts/golden-check.sh`. Default to no-wire client-side derivation;
  justify any wire touch explicitly in DECISIONS.md.
- **Read-only gate must be COMPLETE and at the right seam.** Gate ALL input paths named in ES-E17:
  keystrokes, paste, click-to-move-cursor, mouse reporting, AND drag-drop into the pane. Gate at the
  single input-ingress seam (where keys/mouse/paste enter the pane session), not scattered per call
  site, so a future input path can't bypass it. Beep-on-blocked (NSBeep / no-op on iOS).
- **Vi-mode rides the EXISTING copy-mode engine — reuse, don't rebuild.** The repo already has a
  copy/scrollback-selection stack; the Vi-mode pill + repeat-count + `⌘/` key-hint bar + `/`,`?`→find
  bar (reuse E5's `TerminalFindBar`) are the VIEW layer over it. char-granularity selection is a
  documented **libghostty ceiling** (line/block only) — document it, don't fake it.
- **Honesty (E8/E12/E15 discipline):** never ship a setting/pill that silently does nothing. If a
  control can't be actuated through libghostty/AppKit, document the ceiling in `docs/DECISIONS.md`
  rather than presenting a dead toggle. Tests are revert-to-confirm-fail, non-tautological.

## Visual fidelity standard

`spec/terminal-features__read-only-mode.md`, `spec/terminal-features__vi-mode.md`,
`spec/terminal-features__input.md` + their reference screenshots define the visual standard (pill
placement, hint-bar layout, secure-input title indicator). Match them.
