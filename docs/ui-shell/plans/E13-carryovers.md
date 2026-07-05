# E13 carry-over directives (REQUIRED — fold into the E13 plan)

E13 (Agent integration UI — install card · behavior toggles · tab badges · Send-to-Chat · History ·
Resume/Fork · Peek-and-Reply) is **the most reuse-heavy epic**. Almost every engine exists; the gap is the
**view layer + a few host side-effect RPCs + wiring**. This file carries: (1) two **BINDING directives**
(Claude-only; NEVER an approval gate); (2) the **VERIFY-NOT-REBUILD** reuse-map; (3) the **genuine gaps**;
(4) the **wire** posture; (5) the **traps**.

## BINDING directive 1 — Claude Code ONLY (no other agents)

Per standing scope (goal 2026-06-25): support **Claude Code only** initially. `MetadataCodec.AgentKind`
has `claude = 0` AND `codex = 1` — **never surface `codex`** in any UI (install card, badges, history,
fork, send-to-chat picker). Codex is documented-dead (E4: "drop dead AgentKind.codex" — stays in the enum,
not deleted, never shown). Agents card, history, fork, etc. are all Claude-only.

## BINDING directive 2 — NEVER an approval gate (supervision is observe+notify+reply, never block)

Per [[slopdesk-night-supervision-roadmap-2026-06-21]] ("never add an approval gate") and the E17 read-only
disambiguation: slopdesk supervision is **observe + notify + reply-on-user-initiative**. The agent NEVER
blocks waiting for slopdesk to approve; Peek-and-Reply / Send-to-Chat / notifications let the USER reach the
agent when THEY choose. Do NOT build any flow where the agent pauses pending a slopdesk confirmation.
(E17 read-only mode is a per-pane INPUT gate the user toggles — legitimate and unrelated; do not turn it
into an agent-approval gate.)

## VERIFY-NOT-REBUILD (the headline — almost everything exists; read current state first)

Heaviest verify-first epic (E9/E11 lesson: the current-state map LIES toward "missing" — grep + read before
claiming a surface absent). Confirmed ALREADY BUILT:

**Host detection / control / install (`Sources/SlopDeskHost` + `Sources/SlopDeskAgentDetect`):**
- `AgentInstaller` — FULL pure API: `merge(into:command:)` / `remove(from:)` / `install(...)` /
  `uninstall(...)` / `hookScript()` / `hookCommand(scriptPath:)` / `defaultSettingsPath(...)` /
  `defaultScriptPath(...)`. Already writes the hook script + merges Claude Code `SessionStart`/`Stop`/
  `Notification`/… hooks into `~/.claude/settings.json` (docs/41 §2.6). **ES-E13-1 install/uninstall LOGIC
  is done host-side.** NOT wired to any client→host trigger yet (no metadata verb references it).
- `ClaudePaneDetector` / `ClaudeStatus` / `ClaudeStatusMachine` / `ClaudeSignal` / `ClaudeManifestMatcher`
  — full agent-state detection stack; `ForegroundProcessWatcher` emits `.claudeStatus(state,kind,label)`
  (already a wire message, `WireMessage.swift:168`). Detection is DONE — wire/render, don't rebuild.
- `AgentControlListener` (`AgentControlHandler` pure verb dispatcher + `AgentControlAcceptor` AF_UNIX shim),
  `AgentControlState`, `AgentHookListener` — the LOCAL agent-control path (agent drives it via
  `SLOPDESK_AGENT_CONTROL`/`SLOPDESK_CONTROL_SOCKET`). **NOT the client↔host RPC** — the client settings
  card cannot reach this socket (see WIRE).
- E4 metadata verbs **already include `listAgentSessions = 7` + `readAgentSession = 8`** — History backend
  EXISTS. (Also `openPath = 9` / `revealPath = 10` from E10.)

**Client side (`Sources/SlopDeskClientUI` + `Sources/SlopDeskWorkspaceCore`):**
- `Inspector/AgentSessionHistoryView` — History viewer EXISTS: fetches via `readAgentSession`, renders
  speaker turns + collapsed tool-call summaries + Markdown bodies (`AgentTranscriptEntry` +
  `AgentTranscriptProjection.entries(from:)` pure JSONL→turns). Its comment (line 9): "E4 LISTS + RENDERS
  only. Resume / Send to Chat / Fork in… are the later agent epics [E13 additions]." → ADD on top.
- `Markdown/MarkdownText` (Textual, large-doc-guarded) — the transcript/Markdown renderer. Reuse.
- `Footer/AgentInputFooterCoordinator` — agent input footer logic EXISTS but is **NOT mounted** (no
  references outside its own file). Gap = MOUNT it (ES-E13-4), per the E2 OverlayCoordinator lesson
  (built-but-unmounted = silent no-op).
- `Workspace/Domain/PeekReply` + binding `view.peekReply` (`.peekAndReply`, **⌘⌥J** — RE-POINTED off ⌘⇧J
  because E10 owns ⌘⇧J for Hint-to-Open; collision ALREADY RESOLVED, do not re-collide) — domain + chord
  exist; gap = the VIEW.
- `WorkspaceBindingRegistry`: `.sendToChat` action + `agent.sendToChat` binding (**⌘⌃↩**, "Send to Chat")
  EXIST but are an explicit **E13 STUB** (registry line 153) — gap = capture + dialog + routing impl.
- Composer/input (E12): `Input/ComposerModel` / `Input/InputBarModel` / `Pane/ComposerBar` / `Pane/InputBar`
  + `SlopDeskClaudeCode/PromptQueueModel` + `WorkspaceStore+Composer` (sendSink ordered-out) — the agent
  input/queue path. Send-to-Chat routes through THIS, not a new socket.
- `Workspace/Tabs/TabBadge` (E6) — agent tab badges incl. spinner/check/error/hand/caffeinate/sudo; the
  badge×3 toggles ride this. `Workspace/Domain/AttentionSupervision` — attention/needs-input domain.
- `SlopDeskInspector/*` (PATH 3 read-only inspector: `InspectorEngine`/`TranscriptLine`/`HookIngest`/
  `SubagentWatcher`/`EventBuilder`) — existing transcript/hook parsing; consult before writing new JSONL
  parsing for history/fork.

## Genuine GAPS (what E13 actually builds)

1. **Agents settings card** (ES-E13-1, O4): Settings view calling a client→host **install/uninstall
   trigger** (NEW — `AgentInstaller` is not wired to the wire) + a Status row ("✓ Installed" / "Not
   Installed") read from the host. Reuse `AgentInstaller`'s pure logic host-side; the card is view + RPC.
2. **7 behavior toggles** (ES-E13-2, O5/O12): badge×3, notify×2 (E14 built the notification policy — reuse
   `NotificationPolicy`), **prevent-sleep**, resume-on-recovery — with **per-pane overrides** + a
   **Clear-Badge** action. **Prevent-sleep is genuinely NEW host-side**: hold an `IOPMAssertion`
   (`kIOPMAssertionTypePreventUserIdleSystemSleep`) **only while the agent is processing** (driven by
   existing `claudeStatus` running state), released when idle — strictly balanced create/release pairing
   (per the `EnableSecureEventInput` balance lesson). The toggle state must reach the host (see WIRE).
3. **Send to Chat** (ES-E13-5, O9): implement the `.sendToChat` stub — capture the active pane's SELECTION
   (E8 selection) or LAST command output (OSC-133 `D` block, reuse `TerminalBlockModel` from E9/E10) → modal
   dialog (quoted preview, "Send to" session picker, comment field, Copy/Cancel/Send) → route composed text
   to the chosen agent pane via the EXISTING composer sendSink (VERBATIM literal UTF-8 if injected to a PTY —
   NEVER `SendKeysParser`) → auto-focus that pane.
4. **History additions** (ES-E13-6, O10): on top of `AgentSessionHistoryView` — a **raw-JSONL toggle**
   (rendered ⇄ raw) + a **Resume** button (`claude --resume <id>` injected VERBATIM into a new/here pane, OR
   jump-if-live to the existing tab for that session id). Backend verbs 7/8 already exist.
5. **Fork** (ES-E13-7, O11): detect a NEW Claude session id appearing on the PTY after `/branch` (reuse the
   detection stack / session-id signal), route it to a split or tab, add palette **"Fork in…"** entries.
6. **AgentInputFooter mount** (ES-E13-4): mount `AgentInputFooterCoordinator` with its notifications /
   rich-input / file-explorer chips (built-but-unmounted today).
7. **Peek-and-Reply view** (⌘⌥J): build the missing overlay view over the existing `PeekReply` domain +
   `view.peekReply` binding (targets the oldest pane needing attention) — observe + reply, NEVER a gate.

## WIRE posture — likely touchesWire:true (host side-effects), reuse E4's metadata channel

Host side-effects needing a **client→host trigger**: **install/uninstall agent hooks** and **the
prevent-sleep (and resume-on-recovery) host policy** (host holds the IOPMAssertion / re-arms on recovery,
but the toggles live in client Settings). RIGHT way (per E4/E10 precedent): **EXTEND E4's metadata channel
with new side-effecting verbs** (e.g. `installAgentHooks`, `uninstallAgentHooks`, `setAgentPolicy`) numbered
after `revealPath = 10`, following the `openPath`/`revealPath` discipline: status-byte-only + empty/short
payload responses (NOT an exfil vector), `init(rawValue:)`→nil→`unsupportedVerb` never traps
(validate-then-drop), accept+validate before acting. **Do NOT add a new socket or top-level wire message;
do NOT reuse the local `AgentControl` AF_UNIX socket for the client RPC** (that's the agent's own local
control path).

- **History** = existing verbs 7/8 (NO new wire).
- **Send-to-Chat / Resume / Fork inject** = client-side composer / VERBATIM PTY inject (NO new wire).
- So set **`touchesWire: true`** for the new metadata verbs, and apply FULL golden discipline:
  `golden-check.sh` must show the **13 frozen keys intact**; the **33 emitted keys** stay byte-identical
  UNLESS a vector round-trips a new verb (E10 added 9/10 and stayed effectively zero-diff — match that;
  hand-edit `golden/golden_vectors.json` surgically if needed, NEVER redirect the generator over it). Update
  `docs/20-wire-protocol.md` + `docs/DECISIONS.md`; host+client **redeploy together** (no backcompat — host
  accepts only version 1). If install/prevent-sleep can be driven WITHOUT a client trigger (host-local
  policy from detection + a settings value piggy-backed on an existing channel), prefer that and keep
  `touchesWire:false` — but be honest about how the toggle reaches the host.

## iOS — shared ClientUI, RUN check-ios.sh

- Agents card, behavior toggles, history viewer, Send-to-Chat dialog, footer, and Peek-and-Reply view are
  shared `SlopDeskClientUI` → **`touchesIOS: true`, the gate MUST run `bash scripts/check-ios.sh`.**
- Prevent-sleep `IOPMAssertion` is HOST-side (macOS host only) — no iOS concern; but any AppKit-only UI
  (e.g. a macOS modal sheet) must be `#if os(macOS)` with an iOS path or documented deferral (no dead iOS
  affordance). Most stories are "both" per USER-STORIES.

## TRAPS specific to E13 (respect these)

- **NEVER an approval gate** (directive 2) — the single most important constraint.
- **Claude only** — never render `AgentKind.codex` (directive 1).
- **⌘⇧J is E10's (Hint-to-Open); Peek-and-Reply is ⌘⌥J** — already resolved in the registry; do not
  re-collide or "restore" ⌘⇧J for peek-reply.
- **Built-but-unmounted = silent no-op** (E2/OverlayCoordinator lesson): `AgentInputFooterCoordinator` and
  the Peek-and-Reply view must be MOUNTED, not just defined. Verify the mount in the gate/review.
- **VERBATIM literal UTF-8 for any PTY inject** (Resume `claude --resume <id>`, Send-to-Chat-to-PTY, fork) —
  NEVER `SendKeysParser` (standing injection trap).
- **IOPMAssertion must be strictly balanced** (create⇄release paired around the agent-processing window; a
  leaked assertion keeps the Mac awake forever) — mirror the `EnableSecureEventInput` balance lesson.
- **Validate-then-drop** on any new metadata verb (untrusted client→host) — never trap on a bad verb/
  payload; status-byte-only responses.
- **Host hooks merge is idempotent** — `AgentInstaller.merge`/`remove` dedupe by `hookMarker`
  ("slopdesk-agent"); reuse, don't write a second merge path.
- **No app-layer crypto/auth/tokens** — the hook install writes a local script + settings.json on the
  trusted host; no pairing/token.
- **Test-first, headless:** the PURE parts (transcript projection, send-to-chat capture/compose model, fork
  session-id detection, prevent-sleep policy decision, install/uninstall merge already tested) are
  unit-testable — revert-to-confirm-fail, no tautological tests. NEVER instantiate a real
  NSWindow/WKWebView/SCStream in a test; the IOPMAssertion glue is host-app-target, code-reviewed.

## Design-spec fidelity standard

`spec/agents__{setup,supported-agents,agents-overview,send-to-chat,history,fork-branch-session,
parallel-tasks,composer,prompt-queue}.md` + `spec/getting-started__first-launch.md` are the prose standard;
match the agent screenshots under `screenshots/`. ES-E13-1…ES-E13-7 are the acceptance stories (all
Claude-only). GUI-only fidelity (install card, footer chips, Send-to-Chat dialog, history transcript,
Peek-and-Reply overlay rendering) that is headless-unprovable is a **Phase-3 HW-fidelity target** — flag it,
don't fake a pixel proof. Parallel-tasks/Workflows agent features are OUT of scope (Workflows globally
excluded; parallel-tasks only insofar as fork/multi-session already covers).
