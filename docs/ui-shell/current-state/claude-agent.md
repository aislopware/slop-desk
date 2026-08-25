# Claude Code Agent Supervision — Current State

Assessed against the UI-shell spec pages (`docs/ui-shell/spec/agents__*.md`). Surveyed 2026-06-25;
every row re-verified against the tree 2026-08-22 (three waves had invalidated most of the original:
the 2026-07-03 agent-input prune `92472b0a`, the 2026-07-02 Details-panel removal `6de70aae`, and the
2026-08-17 client-UI split, `docs/56-client-ui-split.md`).

---

## Overview

Host-side detection is built and wired end-to-end and has since GROWN: `ClaudePaneDetector` (one per
pane, a handle over `rust/slopdesk-agent::detector`, fusing foreground-poll + hook + self-report +
screen tier + OSC title + user-input cancel edge) emits wire type 26 (`foregroundProcess`), type 27
(`claudeStatus`), type 36 (`agentSessionIntent`) and an empty type 21 (title RETIREMENT) over the
control channel. Client `LivePaneSession.feedAgentSignal` sinks these into
`WorkspaceStore.paneAgentStatus` / `paneAgentLabel` / `paneAgentIntent`, driving the sidebar row's
status mark, the iOS toolbar indicator, the tab-badge ladder and the attention/notification edge.

What the 2026-06 survey called absent is now largely present or deliberately gone:

- **Present now.** The sidebar status dot RENDERS on both platforms (`MacSidebarRow` /
  `NavigatorColumn`, both through `StatusPresentation.statusDot`). Peek & Reply has real views on
  both platforms and a live closure — and its chord moved to **⌘⌥J** (Hint Mode owns ⌘⇧J). The
  per-tab monitoring controls exist as `AgentBadgeGates` (three toggles, global in Settings ▸ Agents
  plus a per-pane override on the sidebar row context menu) and prevent-sleep is a real `IOPMAssertion`.
- **Deliberately gone.** The Composer, the Prompt Queue, Send-to-Chat, the three Fork-in-Split/Tab
  actions and the Claude bottom bar (`AgentInputFooter`) were deleted end-to-end by the 2026-07-03
  feature prune (`docs/DECISIONS.md` §"Agent input surfaces REMOVED", `92472b0a`). The
  Details/Inspector panel — and with it the agent status badge row and `AgentSessionHistoryView` —
  went in `6de70aae`. The per-pane status strip went by user ruling. None of these is a gap.
- **Still a genuine gap.** The JSONL history viewer. It is the ONE spec page with no implementation
  and no ruling striking it.

---

## Capability matrix

| Feature | Status | Evidence |
|---|---|---|
| **Agent detection (foreground process poll)** | done | `ClaudePaneDetector.sample(name:at:)` at `Sources/SlopDeskHost/ClaudePaneDetector.swift:154`; the ~1 Hz foreground basename poll task is created at `Sources/SlopDeskHost/MuxChannelSession.swift:1375` (`agentWatchTask`, declared `:280`, interval injected as `agentPollInterval`) |
| **Agent detection (hook events — SessionStart/PreToolUse/Stop/Notification/UserPromptSubmit)** | done | `AgentHookListener` at `Sources/SlopDeskHost/AgentHookListener.swift:97`; `ClaudePaneDetector.hook(bytes:at:)` at `Sources/SlopDeskHost/ClaudePaneDetector.swift:163`; hook socket wired in `HostServer.spawnFreshShell`. **`AgentHookHandler` no longer exists** — the fold moved down to `rust/slopdesk-agent::detector`; the name survives only in doc comments (`AgentHookListener.swift:19`) and the tests that recorded the move (`Tests/SlopDeskHostTests/AgentHookListenerTests.swift:11`) |
| **Agent detection (self-report via ctl verb)** | done | `AgentControlHandler.reportAgent` at `Sources/SlopDeskHost/AgentControlListener.swift:337` (the handler struct is `:59`); `ClaudePaneDetector.report(state:message:at:)` at `:177`; grace-window stickiness (`reportGraceWindow`, `wrapperSuppressionWindow`, both read from `slopdesk_agent_detector_constant`) prevents foreground-poll from wiping a self-reported state |
| **Agent detection (screen tier)** | live | the rule ladder is `rust/slopdesk-screend`'s `detect` verb (`rust/slopdesk-screend/src/detect.rs`, dispatched at `src/server.rs:286`), driven by `Sources/SlopDeskHost/PaneScreenScanner.swift` (`docs/50` §2, `docs/52` §4b). It reaches the machine as `screenDetection(_:at:)` at `ClaudePaneDetector.swift:202`. The process-name half of the old `ClaudeManifestMatcher` survives as `rust/slopdesk-agent/src/process.rs` predicates (`is_claude_running`, `is_likely_wrapper`, `is_sensitive`, `canonical_name`); its screen cues were deleted with the move, and the Swift `ClaudeProcessMatcher` wrapper went when the fusion moved to `rust/slopdesk-agent::detector` — neither name has a definition left in the tree |
| **awaiting-input / busy / done / idle status model** | done | `ClaudeStatus` enum (none/idle/working/done/needsPermission) at `Sources/SlopDeskAgentDetect/ClaudeStatus.swift:12`, with `urgency` (`:42`) and `rollup(_:)` (`:61`) both delegating to the Rust; `AgentStatusKind` qualifier (none/permission/waitingForInput/other/quiet) at `:80`; state machine with `done → idle` decay at `rust/slopdesk-agent/src/machine.rs`, constructed only by that crate's `PaneDetector` |
| **Status wire transport (types 26 / 27 / 36 / empty 21)** | done | `WireMessage.foregroundProcess` at `Sources/SlopDeskProtocol/WireMessage.swift:151`, `.claudeStatus` at `:168`, `.agentSessionIntent` at `:325` (type byte 36, `:405`). `ClaudePaneDetector.Emission` at `ClaudePaneDetector.swift:72` carries all four slots and orders them (`messages`, `:89`); `LivePaneSession.feedAgentSignal` sinks them at `Sources/SlopDeskWorkspaceCore/Workspace/Store/LivePaneSession.swift:474`. The intent + title-retirement slots are NEW since the 2026-06 survey — see `docs/20-wire-protocol.md` rows 21/36 |
| **Per-pane status stored client-side** | done | `WorkspaceStore.paneAgentStatus: [PaneID: ClaudeStatus]` at `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore.swift:2010` (pruned to the live leaf set at `:2696`); `setAgentStatus` at `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Attention.swift:44`; `paneAgentIntent` at `WorkspaceStore.swift:2024` / `setAgentIntent` at `+Attention.swift:122` |
| **Status rollup (tab / session)** | done | `rollupStatus(forSession:)` / `rollupStatus(forTab:)` at `WorkspaceStore+Attention.swift:279,285`; the Mac rail's rollup mark is `Sources/SlopDeskMacUI/Chrome/RailStatusRollup.swift` |
| **Status badge in the Details/Inspector panel** | deleted | The whole right sidebar went in `6de70aae` (2026-07-02, "remove the right sidebar (inspector / Details panel) — keyboard-centric"): `InspectorColumn.swift` (603 lines) and `AgentSessionHistoryView.swift` (577) were deleted with it, along with `DetailsPanelTab`/`DetailsPanelState` and ⌘⇧R. Zero definitions remain (`InspectorColumn` has no hits in `Sources`). Agent status is not homeless — it moved to the sidebar row mark and the toolbar indicator, below |
| **Status indicator in iOS toolbar** | done | `WorkspaceRootView` toolbar `.primaryAction` at `Sources/SlopDeskPhoneUI/WorkspaceRootView.swift:302-305` renders `StatusGlyph(reading: StatusPresentation.agentReading(...), tint: StatusPresentation.agentTint(...))`. **`StatusPresentation` lives in `Sources/SlopDeskSlate/StatusPresentation.swift`, not the phone target**, and **`agentSymbol` no longer exists** — the API is `agentReading(_:)` `:33` / `agentTint(_:)` `:48` / `agentLabel(_:)` `:53` |
| **Status dot in sidebar rows** | done | Was "partial — never rendered"; it renders now, on both platforms, from one resolver: `StatusPresentation.statusDot(working:badge:agentIdle:agentFinish:)` at `Sources/SlopDeskSlate/StatusPresentation.swift:145`, consumed by `Sources/SlopDeskMacUI/Columns/MacSidebarRow.swift:284` (AppKit) and `Sources/SlopDeskPhoneUI/Columns/NavigatorColumn.swift:399` (SwiftUI), plus `MacTabStrip.swift:413`. `RailRow.status` is populated at `Sources/SlopDeskClientCore/Rail/RailRowsBuilder.swift:229`. The shared `SlateTabRow` the old row lived in was **deleted** in the client-UI split (`docs/56-client-ui-split.md:390`) and is ratcheted dead by `scripts/check-supervisor.sh:5798-5802` |
| **Attention edge (needsPermission / done notification)** | done | `applyAttentionEdge` at `WorkspaceStore+Attention.swift:402`, `scheduleAgentAttention` `:432`, `fireAgentAttention` `:458`; the store slot is `WorkspaceStore.onAgentAttention` at `WorkspaceStore.swift:2132`, bound **once, cross-platform**, at `Sources/SlopDeskClientCore/App/ClientComposition.swift:364` (NOT in a per-platform app file). The Code-Agent notification sound rides the same edge (`Sources/SlopDeskWorkspaceCore/Connection/NotificationSound.swift:42`) |
| **Jump-to-oldest-attention (⌘⇧U)** | done | `WorkspaceStore.jumpToOldestAttentionPane()` at `WorkspaceStore+Attention.swift:484`; `unseenAttentionPanes` walk at `:316`; `.jumpToAttention` registered at `Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingRegistry.swift:183`, routed at `WorkspaceBindingRouting.swift:297` |
| **Peek & Reply overlay (⌘⌥J — NOT ⌘⇧J)** | done | Was "partial — SwiftUI overlay view not implemented"; both views exist now. Pure logic: `peekReplyTargetPane` `:515`, `peekContent` `:531`, `sendPeekReply` `:555` (`WorkspaceStore+Attention.swift`), `PeekReplyTarget`/`PeekReplyFormatter` at `Sources/SlopDeskWorkspaceCore/Workspace/Domain/PeekReply.swift`, copy at `Sources/SlopDeskWorkspaceModel/Reading/PeekReplyPresentation.swift`. Views: `Sources/SlopDeskMacUI/Overlays/MacPeekReply.swift` (AppKit) and `Sources/SlopDeskPhoneUI/Overlays/PeekReplyOverlay.swift` (SwiftUI, mounted from `Overlays/OverlayHostView.swift:237`). The routing fallback at `WorkspaceBindingRouting.swift:303` is no longer the live path — real closures are installed at `SlopDeskMacApp.swift:249,669` and `WorkspaceRootView.swift:248`. **Chord changed**: `.peekAndReply` binds ⌘⌥J because Hint Mode took ⌘⇧J (`WorkspaceBindingRegistry.swift:133,186,849`) |
| **Agent label / session intent in the sidebar** | done, reshaped | `agentLabel(for:)` at `WorkspaceStore+Attention.swift:27` / `setAgentLabel` `:111` (the type-27 label field; also the Peek & Reply "question" via `RailRowsBuilder.swift:250`). **`activitySummary(forSession:)` is GONE** — zero hits in `Sources`/`Tests`. What replaced it is richer: the type-36 AGENT-SESSION INTENT (`paneAgentIntent`), which titles an agent row (`RailRowsBuilder.swift:336`, `SidebarRowReading.swift:157`, `PaneSwitcherRows.swift:361`) so four idle `claude` rows stop reading identically |
| **AgentControlListener (ctl socket verbs)** | done, grown | `Sources/SlopDeskHost/AgentControlListener.swift`; the dispatch table at `:126-150` now carries **thirteen** verbs — list-panes, read, **screen**, **last-output**, write, run, wait, spawn, kill, resize, report (the two bolded are new since the survey), plus `subscribe` (per-pane, `serveSubscribe` `:999`) and its all-pane form (`serveSubscribeAll` `:1123`). Mutating verbs are gated by `IPCGuards` + `SensitiveSessionPolicy` at `:110-124` |
| **Composer (multi-line input bar, ⌘⇧E)** | deleted | Removed end-to-end by the 2026-07-03 feature prune (`92472b0a`, `docs/DECISIONS.md` §"Agent input surfaces REMOVED"): `ComposerModel`, `WorkspaceStore+Composer`, `ComposerBar`/`ComposerTextView`/`ComposerFloatPanel`/`ComposerSheet`/`PinnedComposerBar`, the pin persistence and `RichPasteMarkdown`. **⌘⇧E is unbound.** KEPT: `InputBarModel` at `Sources/SlopDeskWorkspaceCore/Input/InputBarModel.swift` and `InputBoxModel` at `Sources/SlopDeskClaudeCode/InputBoxModel.swift` — the per-pane ordered-OUT funnel Peek & Reply and every keystroke ride. Note the DECISIONS entry is itself now stale on one point: the `InputBar` **view** and `InputBarModel.richMode` have since gone too (no `struct InputBar` / `richMode` anywhere in `Sources`) |
| **AgentInputFooter bottom bar (WI-4)** | deleted | Same prune. `AgentInputFooterView`/`Coordinator`/`Action` + `FileExplorerModel` + the `TerminalLeafView` mount are gone; zero definitions remain. Only `docs/30-ui-architecture.md:39` still describes the bar as live — that doc is stale, not the code |
| **History viewer (JSONL transcript rendering)** | missing (genuine gap) | Spec at `docs/ui-shell/spec/agents__history.md`; still no implementation, and **no ruling strikes it** — this is the one row that is still an honest gap rather than a deletion. The surface that once rendered sessions (`AgentSessionHistoryView`) died with the Details panel in `6de70aae`. The nearest live affordance is Open Quickly's Agents pill, which `cd`s and injects `claude --resume <id>` (`Sources/SlopDeskClientCore/Overlays/OpenQuicklyPresentation.swift:375-383`) — a resume, not a transcript reader. `BlockHistoryView` is no longer available as a near-miss either: it was deleted in `6de70aae` |
| **Prompt queue (⌘⇧M, queue strip, chips)** | deleted | Was "missing (spec only)" in 2026-06; it has since been **explicitly ruled out**, not merely left unbuilt. `PromptQueueModel` + `PromptQueueStrip` + `PromptQueueHold` + the OSC-133;A `onPromptIdle` queue trigger were deleted by the 2026-07-03 prune; **⌘⇧M is unbound**. Spec page `docs/ui-shell/spec/agents__prompt-queue.md` survives as a historical spec only |
| **Send to Chat (⌘⌃↩, context capture dialog)** | deleted | Same prune, same distinction: ruled out, not pending. `SendToChatModel`/`Context`/`Session`, `SendToChatDialog`, the OverlayCoordinator state, the store capture/delivery and the context-menu row are gone; **⌘⌃↩ is unbound** |
| **Fork / Branch session (/branch, /fork)** | partly deleted, rest na-remote | The three slopdesk-side actions (`.forkInSplitRight`/`.forkInSplitDown`/`.forkInNewTab`), `ForkSessionDetector`, `LivePaneSession.forkSessionID` and the E13 WI-6 resume plumbing (`AgentResumeRouter`, `liveAgentSessionID`) were deleted by the 2026-07-03 prune — zero hits in `Sources`. What remains true of the residue: fork runs inside the Claude Code process via its own `/branch` slash command, and slopdesk is a pass-through terminal, so there is nothing left for slopdesk to route. Spec at `docs/ui-shell/spec/agents__fork-branch-session.md` |
| **Monitor Tasks / parallel-tasks (badge gates, prevent-sleep, per-pane toggles)** | done | Was "partial — per-tab toggle UI missing; no IOKit power assertion". Both landed. Three gates in `AgentBadgeGates` (`badgeWhileProcessing` default OFF, `badgeWhenComplete`, `badgeWhenAwaitingInput`) at `Sources/SlopDeskWorkspaceCore/Workspace/Domain/AgentBadgeGates.swift:29-77`, applied by masking `TabBadgeGating.resolve` inputs. **Global** toggles: Settings ▸ Agents ▸ Agent Behaviour (`Sources/SlopDeskPhoneUI/Settings/SettingsPages.swift:860-862`, keys at `SettingsKey.swift:182-186`). **Per-pane override**: the sidebar row context menu (`Sources/SlopDeskClientCore/Rail/SidebarRowReading.swift:383-394,412-418,453-455` → `WorkspaceStore.toggleAgentBadgeGate` at `+Attention.swift:165`). **Prevent sleep**: a real `IOPMAssertion` — `Sources/SlopDeskHost/PreventSleepAssertion.swift:19` + `PreventSleepDriver.swift` + `PreventSleepPolicy.swift`, gated by `SLOPDESK_AGENT_PREVENT_SLEEP` (`HostEnvironment.swift:278`) fed from `AgentPreferences.preventSleep`. Tab-level manual badge override: `setTabBadgeOverride` `:183` |
| **Per-connection agent preferences sidecar** | done, two fields only | `Sources/SlopDeskVideoProtocol/Settings/AgentPreferences.swift` carries exactly **`preventSleep`** and **`resumeOnRecovery`** (plus their `…Default` constants — `false` / `true`), riding the `video-prefs.json` sidecar with `.reconnect` timing. The old `agentHooks` gate is deliberately absent (the hook listener always binds). Surfaced at `SettingsPages.swift:864-867` through `hostFlag(_:_:)` (`:897-905`), which shows the DAEMON's answer while unset |
| **Claude-specific: TerminalMode / alt-screen detection (B1 compose mode)** | done, moved to Rust | `TerminalMode.swift` / `TerminalModeStream.swift` / `TerminalModeTracker.swift` / `InputBoxModel.swift` in `Sources/SlopDeskClaudeCode/`. `InputBoxModel` is now the Swift face of `rust/slopdesk-terminal`'s `inputbox` through `rust/slopdesk-ffi`'s `input_box` door and owns one thing, an opaque handle's lifetime (`InputBoxModel.swift:1-26`). **`InputDedupRing` is no longer a Swift type** — the hold-and-confirm ring is `rust/slopdesk-terminal/src/dedup.rs`, this model's interior; its name survives only in that file's comment at `:14` |
| **Claude-specific: OSC title detection** | done | `ClaudeStatusMachine::title_names_claude` at `rust/slopdesk-agent/src/machine.rs:627` (used by the ladder at `:601,639`); the `slopdesk_agent_detector_title` fold (`rust/slopdesk-ffi/src/agent.rs:1292`) lifts the presence floor, called from `ClaudePaneDetector.title(_:at:)` at `:211`. `ClaudePaneDetector.topicLine(fromTitle:)` `:257` extracts the type-36 intent from the same title |
| **Agent-generic: subscribe verb (output streaming over ctl socket)** | done | `serveSubscribe` (per-pane) at `AgentControlListener.swift:999` and `serveSubscribeAll` (supervision stream) at `:1123`, dispatched at `:958`; `agent_status_changed` NDJSON events on status change, fanned out by `HostServer.wireAgentStatusFanOut` (`HostServer.swift:1120,2207`, observer registry `:128-136`) |
| **Agent-generic: TERM + env seams** | done | `HostEnvironment.defaultTerm`/`fallbackTerm`, resolved by `resolveTerm` and injected via `HostEnvironment.curated` in `spawnFreshShell` |

---

## Key files

- `Sources/SlopDeskAgentDetect/ClaudeStatus.swift` — status enum, urgency, rollup (all three delegate to Rust)
- `rust/slopdesk-agent/src/machine.rs` — pure per-pane state machine (+ the OSC-title predicates)
- `rust/slopdesk-agent/src/process.rs` — process-name classifier (`claude` vs a wrapper runtime)
- `rust/slopdesk-agent/src/detector.rs` — the per-pane FUSION: the machine plus every dedupe anchor
- `rust/slopdesk-agent/src/badge.rs` — the badge gates' `Gates::ALL_ON` baseline (read, not restated, by `AgentBadgeGates.allOn`)
- `rust/slopdesk-screend/src/detect.rs` — the screen-tier rule ladder behind the `detect` verb
- `Sources/SlopDeskHost/ClaudePaneDetector.swift` — the handle over that fusion, plus the `WireMessage` shapes (P1)
- `Sources/SlopDeskHost/PaneScreenScanner.swift` — drives the screen tier into the detector
- `Sources/SlopDeskHost/AgentHookListener.swift` — hook socket server (the fold itself is Rust's now)
- `Sources/SlopDeskHost/AgentControlListener.swift` — ctl socket server, all verbs incl. subscribe
- `Sources/SlopDeskHost/AgentControlState.swift` — valid self-report states
- `Sources/SlopDeskHost/HostEnvironment.swift` — TERM + the curated env every pane spawns with
- `Sources/SlopDeskHost/PreventSleepAssertion.swift` / `PreventSleepDriver.swift` / `PreventSleepPolicy.swift` — the `IOPMAssertion` behind "Prevent Sleep While Processing"
- `Sources/SlopDeskHost/HostServer.swift` — `wireAgentStatusFanOut`, fan-out observer registry
- `Sources/SlopDeskHost/MuxChannelSession.swift` — `agentDetector`, `agentWatchTask`, `onAgentStatusChanged`
- `Sources/SlopDeskProtocol/WireMessage.swift` — types 21 / 26 / 27 / 36
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/LivePaneSession.swift` — `claudeStatus`, `feedAgentSignal`
- `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Attention.swift` — attention edge, rollup, peek & reply, agent label/intent, badge gates
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/AgentBadgeGates.swift` — the three agent gates (and the distinct `CommandBadgeGates`)
- `Sources/SlopDeskWorkspaceCore/Workspace/Domain/PeekReply.swift` — `PeekReplyTarget` / `PeekReplyFormatter`
- `Sources/SlopDeskWorkspaceModel/Reading/PeekReplyPresentation.swift` — the card's copy, shared by both platforms
- `Sources/SlopDeskSlate/StatusPresentation.swift` — the ONE view-layer resolver (`agentReading` / `agentTint` / `agentLabel` / `statusDot`)
- `Sources/SlopDeskClientCore/Rail/RailRowsBuilder.swift` — `RailRow.status` population + gate resolution
- `Sources/SlopDeskClientCore/Rail/SidebarRowReading.swift` — the row reading and its badge-gate context menu
- `Sources/SlopDeskClientCore/App/ClientComposition.swift` — `store.onAgentAttention` binding (cross-platform)
- `Sources/SlopDeskClientCore/Overlays/OpenQuicklyPresentation.swift` — the Agents pill's `claude --resume`
- `Sources/SlopDeskMacUI/Columns/MacSidebarRow.swift` — the AppKit sidebar row's status mark
- `Sources/SlopDeskMacUI/Chrome/RailStatusRollup.swift` — the rail's rolled-up mark
- `Sources/SlopDeskMacUI/Overlays/MacPeekReply.swift` — the ⌘⌥J card, AppKit
- `Sources/SlopDeskPhoneUI/Columns/NavigatorColumn.swift` — the SwiftUI sidebar row's status dot
- `Sources/SlopDeskPhoneUI/Overlays/PeekReplyOverlay.swift` — the ⌘⌥J card, SwiftUI
- `Sources/SlopDeskPhoneUI/WorkspaceRootView.swift` — iOS toolbar agent indicator (`:302`)
- `Sources/SlopDeskPhoneUI/Settings/SettingsPages.swift` — Settings ▸ Agents (badge gates + the two sidecar flags)
- `Sources/SlopDeskVideoProtocol/Settings/AgentPreferences.swift` — `preventSleep` + `resumeOnRecovery`, and nothing else
- `Sources/SlopDeskClaudeCode/InputBoxModel.swift` — affordance model (shell ↔ tuiCompose), a handle over Rust
- `Sources/SlopDeskClaudeCode/TerminalModeTracker.swift` — alt-screen detection
- `Sources/SlopDeskWorkspaceCore/Input/InputBarModel.swift` — the per-pane ordered-OUT funnel
- `Tests/SlopDeskHostTests/ClaudePaneDetectorTests.swift` (+ `…HookAuthorityTests` / `…SessionOwnershipTests` / `…TeardownTests`) — detector tests
- `Tests/SlopDeskHostTests/AgentSupervisionIntegrationTests.swift` — end-to-end supervision
- `Tests/SlopDeskHostTests/PreventSleepDriverTests.swift` / `PreventSleepPolicyTests.swift` — the sleep assertion
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/PeekReplyTests.swift` — peek & reply pure logic
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/AttentionTests.swift` / `UnseenAttentionQueueTests.swift` — attention edge + queue
- `Tests/SlopDeskWorkspaceCoreTests/Workspace/AgentBadgeGatesTests.swift` / `AgentBadgeStoreTests.swift` — gate policy + per-pane override

---

## Notes (wiring gaps, dead seams, traps)

### Closed since the 2026-06 survey (do not re-file these)
- **`RailRow.status` renders.** The 2026-06 note "populated but never rendered" is void: one resolver
  (`StatusPresentation.statusDot`), two platform rows (`MacSidebarRow.swift:284`,
  `NavigatorColumn.swift:399`). The row it was blocked on, `SlateTabRow`, was deleted outright.
- **Peek & Reply has views.** Both platforms, plus shared copy in `PeekReplyPresentation`. The
  `nil`-closure fallback at `WorkspaceBindingRouting.swift:303` is a defensive default, not the live
  path. Note the chord is **⌘⌥J**, not the ⌘⇧J the old doc named.
- **`manifestVerdict` is gone**, not merely unfed. `ClaudePaneDetector` has no such method and the
  string does not appear anywhere in `Sources`, `Tests` or the Rust crates. The screen tier reaches
  the machine as `screenDetection(_:at:)` carrying an `AgentScreenDetection`.
- **Per-tab monitoring controls exist**, at two levels (global Settings row + per-pane context-menu
  override), and prevent-sleep is a real `IOPMAssertion`.

### Deleted by ruling (a different state from "missing")
- **Composer, Prompt Queue, Send to Chat, Fork-in-Split/Tab, the Claude bottom bar** —
  `docs/DECISIONS.md` §"Agent input surfaces REMOVED (feature prune, 2026-07-03)", commit `92472b0a`.
  Rationale: they duplicated typing straight into the terminal. ⌘⇧E / ⌘⇧M / ⌘⌃↩ are UNBOUND and free
  for future core verbs; the registry `Category.agents` and palette `PaletteCategory.agents` went
  with them. **Supervision was explicitly kept**: badges, attention jump, Peek & Reply and its reply
  delivery. Their spec pages under `docs/ui-shell/spec/` survive as history — a spec page is NOT
  evidence of a pending feature.
- **The Details/Inspector panel** — `6de70aae` (2026-07-02). `InspectorColumn`,
  `AgentSessionHistoryView`, `BlockHistoryView`, `BlockOutputView`, `BlockRowView`,
  `ProcessPortsView`, `RemoteFileTreeView`, `DetailsPanelTab`/`DetailsPanelState` and ⌘⇧R all went.
  The Git details WINDOW survived as the panel's one keeper (chord-less `view.gitStatus`).
- **The per-pane status strip on a terminal pane** — a user ruling carried only in code, not in
  `docs/DECISIONS.md`: `Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift:98-102` ("NO per-pane
  status strip on a TERMINAL pane … the user judged the terminal pane footer low-value and asked to
  drop it"), mirrored at `Sources/SlopDeskMacUI/Pane/MacTerminalLeafView.swift:6`. Host + connection
  status now live ONCE in the connection island. A GUI/window pane keeps a bottom bar, but as a
  CONTROL bar (resize / lock / zoom), not a status strip.
- **`SlateTabRow` / `SlateTitlebar`** — deleted in the client-UI split
  (`docs/56-client-ui-split.md:390,434`) and ratcheted dead by `scripts/check-supervisor.sh:5798-5802,5869-5875`.

### Still missing (no implementation code, no ruling)
- **History viewer.** No JSONL transcript renderer, and nothing in `docs/DECISIONS.md` strikes it.
  Spec at `docs/ui-shell/spec/agents__history.md`. The one live neighbour is Open Quickly's Agents
  pill, which resumes a session rather than reading it. Building it needs a host RPC to list/read
  `~/.claude/projects/*.jsonl` plus a client renderer — neither exists.

### Platform parity (`docs/56-client-ui-split.md:99-102,144-145` — layout diverges, capability does not)
Every agent-supervision capability audited here is present on BOTH halves, with the arrangement
differing as the rule permits:

- **Status mark**: `MacSidebarRow` (AppKit) vs `NavigatorColumn` (SwiftUI), one shared resolver.
- **Peek & Reply**: `MacPeekReply` (AppKit card) vs `PeekReplyOverlay` (SwiftUI sheet), one shared
  target/formatter/presentation trio.
- **Badge-gate overrides**: one shared `SidebarRowReading` context-menu model, rendered per platform.
- **Attention notification**: bound once in `ClientComposition`, not per platform.
- **The toolbar agent indicator is iOS-only** (`WorkspaceRootView.swift:302`) — and that is a LAYOUT
  divergence, not a capability gap: macOS surfaces the same rollup in the rail
  (`MacUI/Chrome/RailStatusRollup.swift`) and the tab strip (`MacTabStrip.swift:413`), where a
  desktop window has room for it. No unexplained gap was found.

### Architecture notes (agent-generic vs Claude-specific)
- `ClaudeStatus` / `ClaudeStatusMachine` / `ClaudeSignal` are **Claude-specific** by name but the
  urgency/rollup model is generic — and all three now live in `rust/slopdesk-agent`, with the Swift
  enum delegating (`ClaudeStatus.swift:42,61`).
- `AgentControlListener` verbs are **agent-generic** — any agent can use the ctl socket.
- `InputBoxModel` / `TerminalModeTracker` in `SlopDeskClaudeCode` are **Claude Code-specific** (tuned
  to Claude's TUI compose UX), and are now thin handles over `rust/slopdesk-terminal`.
- Notifications via `onAgentAttention` fire on `needsPermission` and `done`, wired to the generic
  `ClaudeStatus` enum, and would generalise to any agent using the same wire types.
- Agent detection has **no env gate** (`HostEnvironment.swift:170-187`): `SLOPDESK_AGENT_DETECT` was
  retired, and `agentDetectEnabled` survives only as an INJECTED constructor parameter for tests.
