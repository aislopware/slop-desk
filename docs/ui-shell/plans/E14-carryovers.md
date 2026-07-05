# E14 carry-over directives (REQUIRED — fold into the E14 plan)

E14 (Progress state + notifications + privilege parity) inherits **no behavioral fix from E11** —
E11 (Open Quickly) closed all of its review findings (base `82fce21` → polish `4176578`,
`broken:[]`). This file carries the things that make E14 a **reuse-first, wire-touching** epic done
right: (1) the **K1 wire extension** (OSC-9;4 progress → a structured host→client message), to be
built on the **type-31 `inputEcho` precedent** with full golden discipline; (2) the rich **reuse-map**
(most of E14 is wiring + ONE new wire message — much of the badge/notification/privilege plumbing
already exists); (3) the standing **scope exclusions** that touch E14; (4) the **traps** that bite a
progress/notification/dock surface.

## This is a WIRE-TOUCHING epic — K1 done right (THE headline)

**K1 = "Replace the OSC-9;4 filter with a wire message + client spinner/progress badge."** The host
already SEES OSC 9;4 — `Sources/SlopDeskHost/HostOutputSniffer.swift` parses it (grep `9;4`/
`progress`), and `Sources/SlopDeskWorkspaceCore/Workspace/Tabs/TabBadge.swift` already documents
the badge taxonomy mapping `OSC 9;4;1/3` → Running spinner and `OSC 9;4;2` → Error (built in E6).
What is MISSING is the **transport**: the host must forward the extracted progress *state + value*
to the client as a structured app-level message (the terminal renders client-side via libghostty, but
the **progress badge is app chrome on the tab/pane**, not terminal content — so it cannot ride the raw
VT stream; it needs its own control-channel message). Build it EXACTLY like E17's secure-input signal:

- **Follow the type-31 `inputEcho` precedent verbatim.** Host: a pure detector folds sniffer output
  (see `EchoModeWatcher.swift` / `EchoModeDetector` and `MuxChannelSession.swift:~601` for the
  enqueue-on-CONTROL-channel pattern) → enqueues a NEW `WireMessage` case → client handles it in the
  `case .inputEcho:`-style switch (`Sources/slopdesk-client/main.swift:383`,
  `Sources/SlopDeskClient/SlopDeskClient.swift:113` define the case + decode). Add the progress
  case next to `inputEcho`. **Find the next free wire type byte** in the encode/decode switch (type-31
  is taken; the type bytes are assigned in the codec switch, not as enum raw values — read the actual
  assignment site, do not guess a number).
- **Manual big-endian binary, validate-then-drop.** No JSON/Codable on the wire. The client decoder
  must **drop** a malformed/short progress datagram (never crash), **validate declared lengths/counts
  before allocating**, **never force-unwrap** attacker-controlled bytes, read any interop bool as
  `byte != 0`, and **clamp the progress value to 0–100** (an out-of-range value is dropped/clamped,
  not trusted). The state enum must `init(rawValue:)`→nil→drop on an unknown discriminant (the
  `MetadataVerb` validate-then-drop idiom).
- **No version negotiation; redeploy together.** Host accepts only version `1`; host+client ship as a
  pair (no-backcompat, single-user — `[[rwork-no-backcompat]]`).
- **Golden discipline (the gate MUST run `golden-check.sh` this epic).** Hand-edit
  `golden/golden_vectors.json` surgically so the **13 XCTest-pinned frozen keys survive**
  (`captureRetarget, captureUnion, hostOutputSniffer, inputMotionCoalesce, naluJoin, naluSplit,
  terminalModeTracker, vdChipPixelLimit, vdOriginToRight, vdRefreshRates, virtualDisplayGeometry,
  windowFits, windowPlacement`). Match how type-31 `inputEcho` was frozen (pin the new message the
  same way — XCTest round-trip + golden entry as applicable). Update `docs/20-wire-protocol.md` (the
  wire contract) and justify the new type in `docs/DECISIONS.md`. Set `touchesWire:true` in the design
  so the gate enforces golden.

**Any OTHER new wire (e.g. K6 OSC-99 if it needs host→client transport) follows the same discipline.**
Default: only K1 (and possibly K6) touch the wire; everything else is client-side or reuses an
existing channel.

## REUSE-FIRST seam map — E14 is mostly WIRING; do NOT rebuild

Grep these and BUILD ON them:

- **K1/K3 badges** → `TabBadge.swift` (the E6 badge taxonomy already references the OSC-9;4 states),
  `TabOrdering.swift`, `WorkspaceStore+Completion.swift` (the `completionFlashTick` re-render seam that
  E6 used to make `.finished` actually paint — drive the progress badge through the SAME re-render
  path), `Sources/SlopDeskClientUI/Rail/RailRowsBuilder.swift` (renders rail-row badges, vertical
  rail only). OSC-133-D exit status is already tracked by `CommandBlockTracker.swift` /
  `CommandBlockSegmenter.swift`. K3 is mostly already-built — wire progress through it, don't add a
  second badge model. Client-side progress presentation: `SlopDeskClientUI/App/StatusPresentation.swift`.
- **K9/K10 notifications** → `Sources/SlopDeskWorkspaceCore/Connection/CommandCompletionNotifier.swift`,
  `Workspace/Domain/AttentionSupervision.swift`, `Workspace/Store/WorkspaceStore+Completion.swift`,
  `Workspace/Store/WorkspaceStore+Attention.swift`. The completion/attention DETECTION already exists —
  E14 adds the **delivery + policy** (banner/beep/bounce) and the Notify-on-Finish/Error/Watch +
  Notify-While-Foreground POLICY layer on top. Reuse `[[rwork-night-supervision-roadmap]]` infra; do
  not rebuild completion detection or add an approval gate.
- **K11/K12 privilege** → **OSC-52 read/write Ask/Allow/Deny was already built in E8** (clipboard-write
  ask actuation, `right-click-action`/clipboard confirm — grep E8's OSC-52 plumbing). E14 **reuses/
  extends** it (add the READ side + the Ask/Allow/Deny tri-state surface in Settings if missing) — do
  NOT reimplement clipboard confirm. Title-report toggle + the **system-permission status row** are
  Settings/Details surfaces atop the E7 settings taxonomy (Shell/General sections) — reuse the E7
  navigator, no new settings framework.
- **K13 IPC guards** → the EXISTING host control socket: `slopdesk-ctl` / `AgentControlListener.swift`
  / `SlopDeskCtlCore`. Map IPC guards onto it. **No new socket. No tokens/crypto.**

## SCOPE EXCLUSIONS that touch E14 (binding)

- **Agent notifications = Claude Code ONLY.** Standing exclusion. Any "agent needs attention / agent
  finished" notification path is Claude-session-scoped (`AttentionSupervision` is already Claude-aware);
  do not reintroduce Codex/OpenCode kinds.
- **Vertical-tabs-only / no horizontal tab bar.** Standing product decision (`docs/DECISIONS.md`,
  E7-close). K3 progress/exit badges attach to **vertical-rail** rows (`RailRowsBuilder`) — do not
  introduce any horizontal tab-bar badge surface.
- **NO app-layer crypto/auth/tokens** (K13). The security boundary is the trusted WireGuard mesh; the
  ctl-socket carries raw NDJSON. Do not add pairing/tokens/permission-prompts to IPC.

## TRAPS specific to E14 (respect these)

- **Dock progress / bounce / red-tint are macOS-ONLY; iOS no-ops them.** `NSApp.dockTile` /
  `requestUserAttention(.informationalRequest)` / dock-tile badge are AppKit — gate them `#if os(macOS)`.
  iOS has no Dock: the iOS path no-ops K5/K8 (banners via `UNUserNotificationCenter` still work, but the
  foreground policy differs). **The picker/badge/notification code lives in shared `SlopDeskClientUI`
  / `SlopDeskWorkspaceCore` → run `bash scripts/check-ios.sh` in the gate** — `swift build` on macOS
  will NOT catch iOS rot.
- **Notify-While-Foreground policy must actually gate.** Don't banner-spam when the app/pane is focused
  unless the policy says to; honour focus + the per-event Finish/Error/Watch toggles. The policy
  DECISION (given focus state + event type + settings) is a **pure function — test it headlessly**
  (revert-to-confirm-fail). Same for the OSC-9;4 parse, the 0–100 clamp, the auto-progress prefix-list
  matcher (K2), and the OSC-99 parse (K6) — all PURE, all testable; test them.
- **K2 auto-progress prefix-list — honest, bounded.** A small list of known-slow command prefixes that
  show an indeterminate spinner even without OSC-9;4. Keep it a simple bounded list; an unmatched
  command shows no phantom progress. Do not fabricate progress values.
- **Honesty discipline (E8/E10/E11/E15/E17).** Never ship a toggle/badge/notification path that
  silently does nothing. If a privilege toggle or notification mode can't actuate (a macOS/libghostty
  ceiling), **document the ceiling in `docs/DECISIONS.md`** rather than presenting a dead control. No
  half-wired dock animation.
- **`EnableSecureEventInput`-style global state balance** does NOT apply here, but the dock-tile
  progress indicator IS process-global mutable state — ensure it is CLEARED when the last
  progress/error session ends (no stuck red dock tint after the failing pane closes).

## Design-spec fidelity standard

`spec/terminal-features__progress-state.md` + `spec/terminal-features__notifications.md` are the prose
standard; `screenshots/notification.png` + `screenshots/notification-setting.png` are the 1:1 visual
standard for the banner + the Notifications settings surface. The progress-badge visual standard is
`TabBadge.swift`'s already-distilled taxonomy (Running spinner / Error triangle / etc., from
`progress-state.md` "The full badge set"). Match these. ES-E14-1…ES-E14-4 are the acceptance stories;
ES-E14-3 (dock animate + red tint) is **GUI-verifiable only → Phase-3 HW-fidelity target**.
