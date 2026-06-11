# 26 — Aislopdesk Optimization Report (cross-product research synthesis)

Synthesis of 5 parallel research dossiers (terminal-mux UX, remote-desktop video tech,
host menu-bar GUI, connection resilience, dev-agent UX) into a single prioritized,
de-duplicated optimization backlog for Aislopdesk.

**Aislopdesk recap.** Swift 6 self-hosted remote workspace = remote TERMINAL multiplexer
(libghostty external backend, PTY on host, 1 TCP mux of logical channels) + GUI
SCREEN-SHARE / remote-desktop (host HEVC via VideoToolbox, client HW-decode, 1 UDP mux,
GUI path intentionally ~24–30 fps) over a NetBird/Tailscale 100.x overlay. Client =
SwiftUI macOS + iOS (vertical tabs + tmux-style split panes; pane ∈ {terminal,
claude-agent, remote-desktop-video}). Host = headless CLI daemons (`aislopdesk-hostd`,
`aislopdesk-videohostd`); a menu-bar host GUI is wanted.

Work-items: **(A)** GUI-video optimization · **(B)** modern client UX ·
**(C)** host menu-bar server GUI · **(D)** connection resilience / connect-once / reconnect.

### Two structural insights that shape everything below

1. **Most "modern feel" features ride the byte stream you already mux.** Blocks,
   cwd-inherit, per-pane status, notifications, quick-select all ride OSC 7 / 133 / 9 /
   99 / 777 escape sequences + client-side grid regex — libghostty already parses these.
   No new transport; only a **shell-integration bootstrap** (push terminfo + an rc
   snippet on first connect, kitty SSH-kitten style) + client UI rendering.
2. **cmux and muxy are the same SwiftUI + libghostty stack as Aislopdesk.** Treat their open
   source (AGPL — read, don't copy verbatim) as a parts bin: `SidebarStatusEntry`,
   `TerminalNotificationStore`, `SessionWorkspaceSnapshot`, `surfaceIdToPanelId` map near-
   directly onto Aislopdesk's `WorkspaceStore` / `ConnectionViewModel` / `reconcile`.

A recurring design principle for **A** and **D** from Parsec/WebRTC: resolve every
adaptive/recovery tie as **latency → frame-rate → quality**, and recover from loss with
**FEC first (no RTT) → LTR-P refresh (small) → IDR (last resort)**.

---

## (A) GUI-video optimization

| # | Idea | Source(s) | Concrete Aislopdesk change | Impact | Effort |
|---|------|-----------|-----------------------|--------|--------|
| A1 | Low-latency rate control + per-frame QP ceiling | Apple WWDC21 VideoToolbox | Create VT session with `EnableLowLatencyRateControl=true`; set `MaxAllowedFrameQP` so text never smears (drop frame instead) | H | S |
| A2 | Per-frame Reed-Solomon FEC (~20% parity, off on IDR) | Sunshine/Moonlight | Add FEC shards inside UDP video mux; reconstruct from any `dataPackets`; disable on large IDR | H | M |
| A3 | Client-side cursor overlay channel | Parsec/CRD/NX | Send cursor shape (on-change) + position (high-rate) on a tiny mux channel; composite over decoded video | H | S-M |
| A4 | LTR-based damage repair replacing on-demand IDR | Apple LTR + Moonlight RFI | `EnableLTR`; ACK received LTR tokens on control channel; on loss `ForceLTRRefresh` (small LTR-P) not IDR | H | M-L |
| A5 | Shrink/kill client jitter buffer (~1 frame, adaptive) | WebRTC / Multi.app | Audit render path; cap playout delay ~1 frame; grow only under measured jitter (~90 ms class win) | H | S |
| A6 | GCC-lite adaptive bitrate (delay-gradient + loss, take min) | WebRTC GCC / Parsec | Receive-reports on control channel; two estimators; feed `AverageBitRate`/`DataRateLimits` | H | M-L |
| A7 | Low-QP (near-lossless) idle IDR; optional 4:4:4 | TurboVNC lossless-refresh | On idle, emit existing static-IDR at *lower* QP so the frozen screen is crisp text | M-H | S |
| A8 | Bounded in-flight frame window + client ACK backpressure | RustDesk `VideoFrameController` | Host waits for client ACK before encoding next frame (1–2 frame window); kills stale-frame replay | H | S-M |
| A9 | Single-frame VBV (`DataRateLimits` ≈ bitrate/fps) | Sunshine | Cap each frame so no single frame spikes the network buffer | M-H | S |
| A10 | Mux scheduling: input+cursor > video | NoMachine NX | Prioritize input/control/cursor channels ahead of bulk video frames | M | S-M |
| A11 | Encoder-failure counter ⇒ reconfigure/fallback | RustDesk | Count consecutive bad encodes ⇒ reconfigure session / fall back (guards the `-12900` family) | M-H | S-M |
| A12 | UDP roaming-on-address-change | mosh + QUIC CID | Higher-seq authentic datagram from new addr ⇒ PATH_CHALLENGE ⇒ adopt addr | M-H | M |

### A — top 3 detail

**A1 — Low-latency rate control + `MaxAllowedFrameQP` (do first; ~1 day).**
Create the VideoToolbox session with encoder spec
`kVTVideoEncoderSpecification_EnableLowLatencyRateControl = kCFBooleanTrue`. This switches
to a one-in/one-out pipeline (no B-frames, no reordering, fast rate-control adaptation) —
Apple quotes up to ~100 ms saved at 720p30. Then set
`kVTCompressionPropertyKey_MaxAllowedFrameQP` (1–51). This is *the* text-legibility lever:
it caps worst-case QP so the encoder can never smear UI/text into mush during a bandwidth
dip — when the cap is hit and bits are exhausted it **drops the frame** instead of sending
a blurry one. For a 24–30 fps desktop a held-but-sharp frame reads far better than a
delivered-but-blurry one. Pure-win config change on the session you already create.

**A2 — Per-frame Reed-Solomon FEC (~1 week; biggest robustness win, zero RTT).**
Inside the UDP video mux, group each frame into `data + parity` shards (Sunshine default
`fec_percentage = 20%`); the client reconstructs from any `dataPackets` of the total via
`reed_solomon_new(data, parity)`. This eliminates most single-packet-loss freezes *without
a round trip* — ideal for one-way UDP. Guard like Sunshine: **disable FEC on very large
frames (IDRs)** where parity blows the budget. Adopt Moonlight's "unrecoverable ⇒ signal
loss now" rule (`if missingPackets > totalPackets − neededPackets` → `notifyFrameLost()`
immediately) so an LTR/IDR refresh is triggered fast rather than on a timeout.

**A3 — Client-side cursor overlay (~3–5 days; biggest *perceived* desktop-feel win).**
Every good remote desktop (Parsec, CRD, NX) renders the cursor client-side, decoupled from
video frame rate. Add a tiny dedicated mux channel: cursor **shape** (sprite, on change) +
**position** (cheap, high-rate). The client composites the cursor as a SwiftUI overlay on
top of the decoded HEVC. Result: pointer moves at native rate / zero added latency even
when video is 24–30 fps or momentarily frozen — the pointer "feels local," which is the
single biggest difference between a video player you control and a remote desktop.
Pairs with A10 (schedule input+cursor ahead of bulk video in the mux).

---

## (B) modern client UX

| # | Idea | Source(s) | Concrete Aislopdesk change | Impact | Effort |
|---|------|-----------|-----------------------|--------|--------|
| B1 | Per-pane sidebar status (branch/cwd/ports/PR/notif) + 4-state activity dot | cmux/muxy/agent-deck/Conductor | Add `branch/cwd/shellState/ports/lastNotif` to `ConnectionViewModel`; host pushes `report_*` frames on control mux; sidebar renders sorted | H | M |
| B2 | Command palette `Cmd+K` (host-switch, pane-jump, new-tab/split, workflows, reopen-tab; shows shortcuts) | wezterm/Warp/Raycast/Linear | New `CommandPaletteView` over `WorkspaceStore`; fuzzy + frecency; smart initial suggestions | H | M |
| B3 | OSC notifications: per-pane unread ring + jump-to-next-unread, gated on "unfocused", configurable N-sec threshold | cmux/Warp/kitty | Intercept OSC 9/99/777 + OSC 133-D in byte path → `NotificationStore` keyed by `PaneID`; `jumpToNextUnreadPane()` key | H | S-M |
| B4 | cwd + host inheritance for new tab/split (project model) | ghostty OSC 7 / muxy | New `PaneSpec` inherits active pane's host endpoint + last OSC-7 cwd (fixes 127.0.0.1 fallback wart) | H | S-M |
| B5 | Mode-aware bottom keybinding-hint bar | zellij | Thin SwiftUI status strip showing context shortcuts; doubles as iOS touch targets | H | S |
| B6 | Shell-integration bootstrap (terminfo + OSC 7/133/9 rc snippet) on connect | kitty SSH kitten | On first connect push terminfo + rc snippet; *enables* B1/B3/B4 + blocks | H (enabler) | M |
| B7 | Quick-select / hint mode (label + copy matches) | wezterm/kitty | Client-side regex over libghostty grid; overlay SwiftUI labels; copy on keypress | H | M |
| B8 | Diff pane type (read-only host `git diff`) | Conductor | New pane type fed over control channel; syntax-highlighted; makes the agent loop reviewable | H | M |
| B9 | Structured `claude` pane from `stream-json` (native chat/tool/diff vs raw PTY) | claudecodeui/OpenCode | Render agent pane as SwiftUI (bubbles + collapsible tool calls + diff + big approve/reject); phase later | H | L |
| B10 | Vim copy-mode + incremental scrollback search + block-select | wezterm | Modal keymap over libghostty selection; `/`+`?` jump-to-match; rectangular select | H | M-L |
| B11 | Broadcast input (synchronize-panes) | tmux | Fan-out keystroke events to all selected panes' mux channels | M-H | S |
| B12 | iOS responsive collapse (splits → swipeable full-screen pages + segmented switcher; big touch buttons) | claudecodeui | On iOS, split = swipeable pages; agent approvals = large touch buttons | H | M |
| B13 | Command blocks via OSC 133 marks (per-command copy/jump/exit-code) | Warp | Render block chrome over libghostty grid using marks host already emits | M-H | L |
| B14 | Workflows (host-stored parameterized command templates + param form) | Warp | Store on host; SwiftUI form; launch from palette | M | M |
| B15 | Welcome/empty-state host+session picker | zellij | Replace blank pane with picker of live hosts/sessions | H | S |
| B16 | Predictive local echo (client model + reconcile, RTT-gated) | mosh/sshx | Echo printable+backspace into client grid dim/underlined; reconcile on next host frame | H | L |

### B — top 3 detail

**B1 — Per-pane sidebar status + activity dot (~1 week; biggest "feels premium" win).**
A pane should never be a blank rectangle. Steal cmux's `SidebarStatusEntry`
(`{key, value, icon, color, url, priority, timestamp}`, sorted timestamp→priority→key) as
a `AislopdeskStatusEntry`. The host shell emits a tiny text protocol on the existing control mux
(wmux V1 verbatim is enough): `report_pwd`, `report_git_branch <branch> [dirty]`,
`report_shell_state idle|running|interrupted`, `notify <text>` — pushed from a
`PROMPT_COMMAND`/`precmd` hook (the rc snippet from B6). Because panes are *remote*, the
host knows the real cwd/branch/ports the client can't see. Render a 4-state activity dot
(agent-deck vocabulary: ● running green, ◐ waiting yellow, ○ idle gray, ✕ error red); for
`claude` panes add an agent-lifecycle status (thinking / running-tool / awaiting-approval /
done / errored), watched from the Claude transcript/hook output on the host.

**B2 — Command palette `Cmd+K` (~1–2 weeks; highest single-feature ROI for "modern feel").**
One palette is the single entry point that makes a bare app feel pro and subsumes host-
switching, pane-jumping, workflows, and reopen-tab. Actions = existing `WorkspaceStore`
mutations + transport verbs: *new tab, split, switch host, switch pane, connect host, run
workflow, jump to pane, change pane type, reopen closed tab*. Steal the design specifics:
**show each action's bound shortcut inline** (passive keymap teaching — wezterm/Warp),
**smart initial suggestions** (recent hosts + recently-used panes + "next unread agent",
not blank/alphabetical), **fuzzy + developer keywords + frecency** ranking (reuse the
existing local-persist pattern à la `skills-lock.json`), and **nested action-on-result**
("find host → connect / new terminal / new agent").

**B3 — OSC notifications + jump-to-unread, unfocused-gated (~3–5 days).**
libghostty already parses OSC 9 / 99 (kitty) / 777, and OSC 133-D gives command-end +
exit-code. Intercept these in the client byte path *before* handing to libghostty, route to
`UNUserNotificationCenter` (macOS) / local notification (iOS), and into a
`NotificationStore` keyed by `PaneID`. Copy Warp's exact firing rule: notify on command
completion past a **configurable N-second threshold** OR when input is needed, **and only
if the pane is not focused / app not foreground** — that unfocused gate is the whole trick
(no spam). Add the cmux affordances: a per-pane **unread ring** + tab badge, a
`jumpToNextUnreadPane()` key, and a panel of all pending requests across workspaces. This is
the core interaction for running many parallel agents — drain the queue by one key.

---

## (C) host menu-bar server GUI

**Structural insight:** Aislopdesk's daemon split already matches RustDesk's "Connection
Manager (separate process) talks to core over IPC" model. The menu-bar app is a **thin
authorization + observability shell** over the existing daemons, not a rewrite. The only
genuinely new engineering risk is macOS TCC permission onboarding.

| # | Idea | Source(s) | Concrete Aislopdesk change | Impact | Effort |
|---|------|-----------|-----------------------|--------|--------|
| C1 | TCC permission checklist (Screen Recording + Accessibility/Input Monitoring) with live dots, deep-links, quit&reopen | RustDesk/CRD/Screenpipe | Checklist rows: preflight `CG*ScreenCaptureAccess`/`AXIsProcessTrusted`; "Enable" deep-links to exact pane; relaunch-on-grant; red glyph when missing | Critical | M |
| C2 | Local-socket control protocol (events/approve/deny/permission/disconnect/list) | RustDesk CM IPC | Unix socket from `aislopdesk-hostd`/`aislopdesk-videohostd`; control plane stays local-only (never over overlay) | H | S-M |
| C3 | Incoming-connection approval: attended "Share now" (rotating code, TOFU allow-list, expiry+permission preset) + unattended (overlay-trusted / host password) | RustDesk/CRD/Sunshine/Parsec | Approve mode setting; prompt shows connType + peer name + overlay IP; TOFU device allow-list | H | M |
| C4 | MenuBarExtra `.window` shell: This-Host + Start/Stop + client count + status dot | Tailscale/Ollama | SwiftUI popover (not `.menu`): color dots, scrollable searchable client list | H | S-M |
| C5 | Live client list: per-client RTT/FPS, connType, per-session permission toggles (terminal r/o, video-only, kbd on/off) + disconnect | RustDesk CM | Per-session permission map (already aligns with per-pane model); revoke mid-session | M-H | M |
| C6 | SMAppService start-at-login / KeepAlive background agent | Ollama/SMAppService | Bundled plist + `register()`; surface `.requiresApproval` as a checklist row; `RunAtLoad`+`KeepAlive` | M | S-M |
| C7 | First-run security gate (set host password / confirm overlay-only) before accepting | Sunshine | Don't ship "open by default"; restrict control surface to localhost | M-H | S |
| C8 | Hotkey approve/kick + permission presets on share-code (view-only / terminal-only / full) | Parsec | Global hotkey to approve/kick; default guests to minimal permissions | M | S-M |

### C — top 3 detail

**C1 — TCC permission checklist (~3–5 days; critical — make-or-break).**
Every product in this category lives or dies on getting **Screen Recording**
(`aislopdesk-videohostd`) + **Accessibility** (host CGEvent keyboard/mouse injection) granted —
both require an app restart and cannot be auto-granted. Build the universal pattern: one row
per permission with a live status dot and an "Enable" button that deep-links to the exact
pane. Screen Recording: `CGPreflightScreenCaptureAccess()` /
`CGRequestScreenCaptureAccess()`, deep-link
`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
Accessibility: `AXIsProcessTrusted()` /
`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`, deep-link
`...?Privacy_Accessibility`. Gotchas to honor: **TCC is keyed by bundle ID** (Aislopdesk's
"build each product separately" + re-sign-for-lldb workflow will silently lose grants if the
bundle ID drifts — pin it); **Screen Recording needs Quit & Reopen** (detect the grant flip
and offer one-click relaunch); **re-preflight every launch** (grants go stale). Red menu-bar
glyph whenever any required perm is missing.

**C2 — Local-socket control protocol (~2–4 days; the enabling plumbing).**
Mirror RustDesk's CM-over-IPC. A local unix-domain socket carries a small control protocol:
`IncomingConnection{peerID, name, overlayIP, connType}`, `Approve/Deny`,
`SetPermission{sessionID, perm, bool}`, `Disconnect{sessionID}`, `ConnectionList[...]`,
plus per-client RTT/FPS telemetry (already measured). Prefer the socket over XPC because
Aislopdesk's daemons are already stream-shaped, it's headlessly testable like the existing E2E
suites (and avoids the HostServer-in-tests trap), and it keeps the **control plane local-
only** (Sunshine's localhost-only principle) — never expose host *control* over the overlay,
only the data planes. The only new daemon surface is a place in `aislopdesk-hostd` to gate
session start on `authorized`. Handle "daemon not up yet" gracefully (show "Starting…",
retry connect) — Login Items can launch before Launch Agents.

**C3 — Connection approval model (~1 week; the core feature).**
Frame it as Chrome Remote Desktop's two clear flows, not RustDesk's three-radio config:
**Unattended** ("this is my own machine; my phone/laptop always reaches it" → set once /
host password, legitimately default-on because Aislopdesk is overlay-only 100.x) vs **Share now**
(generate a short-lived rotating code a colleague enters once → TOFU device allow-list,
optional expiry + permission preset). The approval prompt must show the **connection type**
(terminal-mux channel vs video) + peer name + overlay IP so the user can't be surprised into
granting a shell when they meant to share a screen. Store permissions **per-session** (not
global) so two simultaneous clients can have different rights and keyboard can be revoked
mid-session without dropping video — a differentiator most consumer tools lack and which
aligns with Aislopdesk's per-pane model.

---

## (D) connection resilience / connect-once / reconnect

Aislopdesk today has connect-once endpoint inheritance but **no dead-host timeout, no auto-
reconnect, no session resumption after a drop**. sshx (`controller.rs`/`grpc.rs`) is the
closest ready-made template — its shape (one persistent stream multiplexing many shells,
each with a seqnum, plus reconnect) is ~1:1 with Aislopdesk's mux.

| # | Idea | Source(s) | Concrete Aislopdesk change | Impact | Effort |
|---|------|-----------|-----------------------|--------|--------|
| D1 | Heartbeat + dead-host timeout + stateless Ping/Pong RTT | mosh/sshx | Client heartbeat 3s; `Ping(ts)`→`Pong(ts)` RTT; declare dead ~10–15s no packet; host reaps assoc ~40s | H | S |
| D2 | Auto-reconnect loop, capped exponential backoff `2^min(retries,4)` (1→16s), reset if last fail >10s | sshx | Reconnect loop on the mux; never enter un-timed "connecting" (fixes the documented infinite-connecting wart) | H | S |
| D3 | Per-channel seq + bounded resend ring + resume handshake | Eternal Terminal / sshx / VS Code | Per-channel bytes-delivered seq; ~256 KB/channel host ring; `RESUME{session-id, lastRecvSeq[]}` → host replays delta | H | M-L |
| D4 | Periodic Sync map + duplicate-pane guard | sshx | Host sends `{paneID→bytesDelivered}` every 5s; client trims buffers + detects gaps; `contains_key` guard in `reconcile` | H | S |
| D5 | Host-side bounded scrollback restore on reattach | tmux/zellij | Per-pane scrollback ring on host; on RESUME ship it so client grid restores, not blank | H | M |
| D6 | "Is the session still alive?" probe before reconnect + status overlay | Coder/Kilo | Probe host session existence before reconnect (else create new); visible "Reconnecting…" overlay; multi-stage hydration | H | M |
| D7 | UDP video roaming (CID + PATH_CHALLENGE on highest-seq new addr) | mosh / QUIC RFC 9000 | Datagram carries session-CID + monotone seq; higher-seq from new addr ⇒ challenge ⇒ adopt | M-H | M |
| D8 | Host-side live-session persistence + re-attach (Aislopdesk's structural edge) | tmux/cmux/Warp gap | Host keeps PTYs/agents alive across client restart/roam/device-switch; client persists only intent tree | H | M |
| D9 | Page-diff streaming for scrollback resync on reconnect | ghostty native-SSH PoC | Stream only diffs of the terminal page model on reconnect, not full re-render | M-H | L |
| D10 | Connection-quality UX (latency badge + direct/relayed + reconnect state) | sshx/Tailscale | Surface Ping RTT + overlay path type + reconnect state as a badge/banner | M-H | S |
| D11 | Flow control / back-pressure on PTY producer | VS Code | Bound the per-channel buffer so `yes`-style floods can't unbounded-grow the mux | H | S-M |
| D12 | Keep mux warm briefly after last pane closes (ControlPersist) | SSH ControlMaster | Don't tear down the TCP mux immediately; instant re-open within a grace window | M | S |
| D13 | Predictive local echo (mosh adaptive, RTT-gated) | mosh/sshx | (= B16) speculative echo when RTT > ~30 ms; reconcile on host frame | H | L |

### D — top 3 detail

**D1 + D2 — Heartbeat/timeout + reconnect loop (~2–3 days; fixes a known bug immediately).**
These are the cheapest fixes for the documented "connect to dead host hangs in 'connecting'
forever" wart. Client→host heartbeat every **3s** on the control channel even when idle
(mosh); host→client `Ping(ts)` every ~3–5s echoed as `Pong(ts)` for stateless RTT (sshx, no
clock sync) — this single RTT feeds the dead-host timeout, the predictive-echo gate, and the
latency badge. Declare the host dead and trigger reconnect after ~10–15s with no authentic
packet; host reaps a client association after ~40s (mosh `SERVER_ASSOCIATION_TIMEOUT`). On
any transport error/timeout, run the sshx reconnect loop verbatim: `sleep = 2^min(retries,4)`
→ 1,2,4,8,16s cap, **reset retries if the last failure was >10s ago** (a brief blip doesn't
escalate). Never enter an un-timed "connecting" state — there is always a bounded path to
either `connected` or a terminal `unreachable`.

**D3 + D4 + D5 — Resumable mux: seq + resend ring + scrollback restore (~1–2 weeks; the core
missing capability).** This is "session resumption without losing scrollback," assembled from
Eternal Terminal + sshx + tmux. Give each mux channel a `seq` (bytes-delivered counter) and a
bounded per-channel resend ring on the host (~256 KB). On reconnect the client opens a fresh
TCP mux and sends `RESUME{session-id, perChannel lastRecvSeq[]}` on the control channel; the
host replies `RETURNING_CLIENT` (vs `NEW_CLIENT`) and **replays each channel's delta** from
its ring — the byte stream is continuous, the app above never sees a gap. **Generalize the
existing `MuxNWConnection` open-before-handler buffer** (already solved) into this seq-indexed
resend ring. Layer sshx's cheap **5s Sync map** (`{paneID→bytesDelivered}`) for buffer-
trimming + gap detection, and a `contains_key` duplicate-pane guard in
`WorkspaceStore.reconcile` to kill the duplicate-pane-on-reattach risk. Finally, keep a
bounded **host-side scrollback ring per pane** (tmux model — Aislopdesk ships bytes, so do NOT copy
mosh's drop-scrollback tradeoff) and ship it on RESUME so the client grid is restored, not
blank.

**D8 — Host-side live-session persistence + re-attach (~1 week; genuine differentiator).**
Every competitor hits the same wall — layout restores, live processes don't (cmux, Warp,
zellij-without-resurrection). Aislopdesk is architecturally positioned to *win* because PTYs (and
agent processes) run on the host daemon, not the client. Make the host **not tear down PTYs on
client disconnect**, persist only the **tree-of-intent** (tabs/panes/types/endpoints/cwd) on
the client, and re-attach over the existing mux on launch (D3 handshake). This delivers the
cmux/Warp "reopen where I left off" *including the running command/agent*, plus claudecodeui's
"resume on phone" (desktop→iPhone device-switch) — as one capability that falls out of the
architecture. It's mostly the same spirit as the open-before-handler buffer/replay fix already
shipped.

---

## DO NOT bother (anti-recommendations for Aislopdesk specifically)

- **120/60 fps game-stream assumptions.** Aislopdesk's GUI path is intentionally ~24–30 fps; do
  not import 60/120 fps targets, frame-pacing for sub-frame latency, or game-stream bitrate
  budgets. Optimize for **text sharpness + clean loss recovery + cursor feel**, not raw fps.
- **Reintroducing a separate input-bar / Warp-style real-editor input line.** Conflicts with
  shipping raw keystrokes to a remote PTY, and the input bar was explicitly *removed* to fix a
  focus/freeze bug (per MEMORY). Cherry-pick only block-scoped output copy via OSC 133.
- **mosh-style drop-scrollback state-diff for the terminal.** Aislopdesk ships *bytes* and renders
  via libghostty; copy tmux's bounded host-side scrollback (D5), not mosh's no-scrollback
  state-sync. (mosh's roaming and predictive-echo ideas *are* worth stealing — just not its
  state model for terminals.)
- **Building your own NAT traversal / rendezvous + relay (RustDesk/DERP).** NetBird/Tailscale
  already solve hole-punching and relay underneath Aislopdesk. Only *surface* the path/latency
  signal (D10); don't reimplement DERP. Revisit only if dropping the overlay dependency
  becomes an explicit goal.
- **Full QUIC transport rewrite (now).** Borrowing QUIC's Connection-ID + PATH_CHALLENGE
  pattern into the existing UDP mux (D7) is worth it; a from-scratch QUIC rewrite of both
  TCP+UDP mux is a strategic long-bet, not a near-term task — don't block the backlog on it.
- **A separate web UI for the host (Sunshine `localhost:47990` model).** The menu-bar app *is*
  the config surface; steal the pairing/allow-list/first-run-gate *patterns*, not the web UI.
- **Jellyfin-style transcode throughput tuning / WebSocket fallback transport (upterm).** Media
  throughput optimization tolerates seconds of buffer (wrong regime); NetBird already covers
  restrictive networks. Low novelty / low fit.
- **Infinite-canvas spatial pane layout (sshx) as the primary model.** Interesting but a large
  lift; the sidebar status model (B1) solves the "many agents at once" overview far more
  cheaply. Park as a future nice-to-have.

---

## Suggested cross-cutting sequencing

1. **Quick wins that close known gaps (days):** D1+D2 (heartbeat/timeout + reconnect loop),
   A1 (low-latency + MaxQP), A5 (jitter-buffer shrink), A9 (single-frame VBV), B5 (hint bar),
   B4 (cwd/host inheritance), C1 (TCC checklist).
2. **Enablers (1–2 weeks):** B6 (shell-integration bootstrap — unlocks B1/B3/B4/blocks),
   C2 (local-socket control protocol), A2 (FEC), A3 (cursor overlay).
3. **Core differentiated robustness (2–4 weeks):** D3+D4+D5 (resumable mux + scrollback),
   D8 (host-side session persistence), A4 (LTR repair), A6 (GCC-lite ABR), C3+C5 (approval +
   client list).
4. **Premium-feel UX (phased):** B1 (sidebar status), B2 (command palette), B3
   (notifications), B8 (diff pane), B12 (iOS responsive), then B9/B13/B16 (structured agent
   pane, blocks, predictive echo) as later phases.
