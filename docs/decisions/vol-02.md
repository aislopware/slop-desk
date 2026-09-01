# DECISIONS vol-02 — 2026-07-22 … 2026-07-24

> Volume 2 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## Clipboard sync = two MetadataVerbs on the E4 RPC, host pasteboard is the meeting point (2026-07-22)

- ✅ **Problem:** copy on the client did NOT reach the host pasteboard — Claude Code's Ctrl+V found
  "no image in clipboard", and pasting into a remote-desktop pane needed the manual paste-as-keystrokes
  action (text-only, CGEvents). Host-side copies never reached the client at all.
- ✅ **Transport = verbs `15` setClipboard / `16` readClipboard on the EXISTING E4 metadata RPC** (the
  E10/E13 pattern: new verb bytes, no new wire type, envelope byte-identical → golden zero-diff).
  Host-global like the agent-hooks verbs — routed through whichever pane carries a live channel
  (`firstConnectedMetadataClient`); a desktop-pane-only workspace with zero terminal channels does not
  sync (accepted residual — the workspace is terminal-first). Content kinds: UTF-8 text + PNG (image
  preferred; TIFF transcoded both ways so screenshots and app copies land everywhere, incl. Claude
  Code's `PNGf` read). Per-clip cap 12 MiB under the 16 MiB frame cap.
- ✅ **Pull is a POLL, not a push wire type.** The client's `ClipboardSyncEngine` ticks at 1 Hz (the
  `ClipboardMonitor` pattern) and polls `readClipboard` with the last-seen host `changeCount` — one
  tiny count-only RPC per tick when nothing changed. A host→client push type would have cost a new
  frozen wire type + golden churn for a 1 s latency win on a non-latency path.
- ✅ **Loop safety is DOUBLE-guarded, baseline-first.** Host: remembers the changeCount its last
  client push produced and answers "unchanged" for it (never echoes a push back). Client: remembers
  the last clip pushed OR applied and skips both re-push (its own apply) and re-apply by content
  compare. A ping-pong therefore needs both ends to fail. First pull after (re)connect is a baseline
  probe (`lastSeen = -1` → count-only), so connecting never overwrites the client clipboard with
  stale pre-connection host state; a pull failure resets the baseline.
- ✅ **Skips:** concealed clips (`org.nspasteboard.ConcealedType`, password managers) are never
  pushed; file-copy clips (`public.file-url`) are never synced either way (a path is meaningless on
  the other machine); over-cap clips silently stay local. Push failures stay PENDING and retry every
  tick until a newer local copy replaces them. Under automation the engine does not run (an E2E run
  must not mirror the developer's real pasteboard).
- ✅ **Paste-as-keystrokes (⌥⌘V) stays** — it is the fallback for a read-only-disabled sync future and
  the only path that types into a host field that blocks programmatic paste.

## Remote desktop is a DEDICATED OS WINDOW — remote-window mode is REMOVED (2026-07-22)

> User-directed re-scope: (1) per-window streaming (`.remoteGUI`) is removed outright — full-desktop
> is the only remote-viewing mode; (2) the desktop stream must NEVER be a pane or tab inside the
> workspace window — it always opens as its own OS window, with a setting for the default
> presentation (windowed vs fullscreen, the Parsec model); (3) research-backed UX additions.

- 🔁 **RE-SCOPE (reverses the 2026-07-14 "per-window streaming survives as a SECONDARY path"
  ruling): `PaneKind.remoteGUI` is DELETED.** Gone client-side: `newRemoteWindowTab` /
  `openRemoteWindow` / `streamedWindowPane` / `StreamedWindowRef` / `remoteWindowSpec`, the
  `RemoteWindowPickerModal`/`RemoteWindowPickerView` picker UI, the palette "New Remote Window Tab"
  row, Open Quickly's Host rows (their ONLY action was opening a window pane), and `WindowRebind`
  (CGWindowID-recycling rebind existed solely for persisted `.remoteGUI` panes). A persisted
  `"remoteGUI"` leaf folds to `.terminal` via the established legacy-raw-value decode bridge
  (`claudeCode`/`web`/`chooser` precedent — no-backcompat rule, stale stream identity is dropped).
- ✅ **The WIRE is untouched — window-shaped types go dormant, not deleted.** `hello` (1) stays
  LIVE (the `.systemDialog` pane still streams a host window by id); `resizeAck` (5), `listWindows`/
  `windowList` (7/8), `displayMax` (15), geometry datagrams (§9.5) lose their `.remoteGUI` caller and
  join types 19–21 in the dormant set (codec + golden vectors byte-identical, zero golden churn).
  `HostWindowFeed` + types 16–18 stay KEPT-SHARED for `AppLaunchMonitor`'s layout auto-switch. Host
  window-capture machinery (parking, geometry watcher) stays — systemDialog and any future window
  consumer ride it; deleting it buys nothing the dormant rule doesn't.
- ✅ **The desktop stream lives ONLY in a satellite window — never in the tree.** `.desktop` panes
  are minted DIRECTLY into `Session.detached` (⌥⌘N / palette; reveal-dedupe per display — a second
  ⌥⌘N on the same display raises the existing window; different displays mint siblings). The
  satellite close semantic branches by kind: a desktop satellite's close is a REAL close
  (`closeDetachedPane` — the session ends), never the reattach-fold; reattach affordances
  (`reattachAllPanes`, free-drag-into-tree) skip desktop panes. Launch restore DROPS persisted
  detached desktop panes instead of redocking them (satellites don't restore as windows — v1 rule —
  and a desktop pane must never redock into a tab).
- ✅ **Presentation setting: `desktopWindowPresentation` = windowed (default) | fullscreen** —
  a `SettingsKey` + macOS Settings row. Fullscreen v1 is NATIVE macOS fullscreen (Spaces): most-Mac
  behaviour, zero custom chrome. The known top-edge conflict (pointer at top reveals the LOCAL menu
  bar over the remote one — unsolved across Parsec/Screens/Jump/Apple; Parallels' dwell-delay gate
  on a borderless window is the researched best-in-class) is ACCEPTED for v1 and the dwell-gate
  borderless mode is the documented follow-up.
- ✅ **UX additions v1 (survey-backed, `docs/DECISIONS.md` is the research record):**
  (a) **fullscreen auto-arms immersive system-key capture** — the industry-converged pattern
  (Parsec Immersive / CRD "Send system keys" scoped to fullscreen / Moonlight's capture toggle):
  entering native fullscreen arms the existing `SystemKeyCaptureController` regardless of the
  latched per-target immersive mode; exiting returns to the latched value. The in-session escape
  hatch already exists (the immersive toggle chord) — the Moonlight lesson (capture with no
  in-stream off switch traps the user) is already satisfied.
  (b) **hostd keeps the host display awake while a display session is attached**
  (`IOPMAssertionCreateWithName` / PreventUserIdleDisplaySleep — released when the last display
  session detaches). No surveyed product does this declaratively; it closes the "host slept mid-
  session" failure mode for free.
- ✅ **UX backlog SHIPPED (2026-07-22, "làm hết tất cả những thứ hay đáng học hỏi"):**
  - **In-window display switcher** — already existed (the footer `GuiDisplaySwitcherMenu` +
    `RemoteWindowModel.switchDisplay(to:)` over the `listDisplays` 22/23 discovery). Verified in
    place; no new work.
  - **Parsec-grade stats HUD** — the in-pane readout gained a RTT / ENC / DEC latency row. New wire
    type 27 `hostStats` (host→client, ~2 Hz over the client's report clock) carries the host's
    smoothed RTT (only the host can compute it — every client-report field is relative, §9.8) + its
    now-always-measured encode-wall EWMA; the client times its own decode-wall EWMA around the VT
    submit. Zeros map to a dash (no fake 0.0). Additive golden splice.
  - **Dwell-gated borderless fullscreen** — a third `desktopWindow.presentation` (`borderless`): a
    `.borderless` cover of the current Space whose local menu bar/Dock hard-hide behind a
    `BorderlessDwellGate` (0.5 s dwell, 2 pt arm, 36 pt conceal hysteresis) — a bare top-edge touch
    reaches the REMOTE menu bar, a held one reveals the LOCAL. The Parallels answer to the top-edge
    conflict. The standard fullscreen verb (⌃⌘F) toggles it; engaging auto-arms immersive capture.
  - **Host-display privacy blank** — new wire type 28 `privacyMode` (client→host, display sessions
    only). `HostPrivacyBlank` blacks the streamed display with a zero `CGDisplayGammaTable` (client
    still sees the desktop; a bystander sees black). The RustDesk gamma technique ships live; the
    local-input `CGEventTap` swallow is behind a host seam (a HW-verified follow-up — a wrong tap
    would block the remote operator's injected input too). Desktop-pane footer shield toggle.
- 📌 **Deliberately NOT done** (rejected, not deferred): match-window dynamic resolution — the
  research verdict stands that it is the WRONG default for a real physical host display (scale-to-fit
  letterbox stays).
- ✅ **PATH 4 — drag-and-drop file transfer over a DEDICATED reliable channel (2026-07-23, "tạo 1
  connection mới, đừng dùng chung vào terminal tránh gây lỗi"):** dropping a file onto the desktop
  window uploads it to the host. Per the user's explicit constraint this rides its **own** TCP
  listener — NOT the terminal mux (a bulk file body sharing the PTY's data channel would stall
  keystrokes/resizes and risk framing errors), NOT the lossy UDP video path (FEC recovers *frames*,
  not files). A genuinely 4th path, modeled on the **inspector** precedent (the simplest existing
  self-contained TCP server), NOT the terminal's CONTROL/DATA mux dance.
  - **New module `SlopDeskFileTransfer`** (Foundation + Network leaf, shares nothing with the other
    three paths per the "do not merge" rule). Its own `[UInt32 BE length][UInt8 type][body]` frame
    shape (16 MiB cap) with a dedicated `FileTransferFrameDecoder` (mirrors `MuxFrameDecoder`'s
    streaming-splitter/lazy-compaction/poison-on-fault design — NOT a reuse of it). Version-pinned
    `hello`/`helloAck` (v1, no negotiation). Message table → `docs/20-wire-protocol.md §10`. This
    path is **outside** the golden corpus (golden = the PATH-2 video control codec only).
  - **Pure, headless-tested core:** `FileReceiveLogic` (offer→open→chunk→finish FSM, validate-then
    -drop: rejects a chunk-before-offer, a byte overrun past the offered size, an over-cap total, a
    bad name) + `FileNameSanitizer` (**path-traversal guard** — last component only, rejects
    `..`/absolute/empty, the untrusted-name attack an upload endpoint invites) + `FileTransferCodec`
    round-trip + collision-avoiding `DiskFileDropSink` (`name (1).ext`). The `NWListener` server +
    `NWConnection` client are compiled-not-tested (loopback `serve(channel:)` + fake-sink seam prove
    the logic, per hang-safety — no live socket in XCTest).
  - **Direction = client→host upload only** (the "into the desktop" gesture); host→client download is
    a future add. **Drop dir default `~/Downloads`** (the received-files convention; env
    `SLOPDESK_FILE_DROP_DIR`). Server gated `SLOPDESK_FILE_TRANSFER` (default-ON), stood up in
    `slopdesk-hostd` after the terminal + inspector servers on `terminalPort &+ 2`, **non-fatal** on
    bind failure. Client derives `ConnectionTarget.filePort = port &+ 2` (computed, mirrors the
    inspector's `+1` — no new persisted/golden field).
  - **UI:** the desktop pane registers an AppKit dragging destination for real file payloads (a file
    *drop* uploads bytes; the existing `PaneDropReceiver` path-inject stays for terminal panes) with
    a progress overlay + completion toast; `FileTransferModel` (pure `@Observable` in WorkspaceCore)
    holds active-upload progress behind a `FileUploading` seam the app fills with the real client.
- ✅ **2026-07-23 — Git status is PROJECT-scoped, rendered on the sidebar SECTION HEADER; the grouping key is bullet-proofed; freshness is project-scheduled + event-driven (wire 35).** Three decisions in one re-scope (user-directed):
  - **Grouping = git toplevel even from a subdir, ALWAYS.** The host resolver already walked up to the
    toplevel; the fix closes the windows where the raw subdir cwd leaked through as the section key:
    (a) new split/tab specs SEED the parent's host-pushed `projectKey` alongside the inherited cwd
    (subtree-coverage-guarded — never seeds across a policy-resolved foreign dir or a stale key);
    (b) the host seeds cwd+key truths AT SPAWN from the server-provided spawn cwd — a pane whose
    shell never emits OSC-133/OSC-7 (raw command, shim off) still resolves; (c) the resolver walks
    the `realpath`-canonicalized cwd, so logical OSC-7 paths and physical `proc_pidinfo` paths land
    on ONE key (a symlinked checkout no longer splits into two sections — or resolves the SYMLINK
    dir as its own bogus toplevel). Non-repo dirs keep grouping by plain cwd (unchanged, intended).
  - **One repo = one section = ONE git line, on the header.** `projectGitSummary` (keyed by the
    normalized section key — the `gitStatus` reply's `repoRoot`) replaces the per-pane mirror + the
    sibling fan-out; the header renders branch + non-zero oh-my-zsh sigils in the INSTRUMENT voice
    (`ProjectGitStatusLine` — branch recedes to the header gray, per-token status colours, branch
    pre-truncates so counts never do, conflict `=N` escalates to the header's ONE background
    treatment: a static err-tinted pill, hard cut per L3). The pane row's line 2 becomes the cwd
    RELATIVE to the project root, shown ONLY when the pane strayed from it (at-root rows collapse to
    single-line height); "Refresh Git Status" moved from the row menu to the header menu. iOS keeps
    plain system section headers (macOS-first refinement).
  - **Inactive projects stay fresh, cheaply.** The ~3s snapshot edge is re-scoped from
    "active PANE only" to per-PROJECT windows (active project 15s, background 60s) with a
    project-keyed in-flight de-dupe — N same-repo panes reconnecting/polling collapse to ONE RPC
    (`git status --porcelain` output is root-relative, so any pane answers for the project), cost
    bounded at O(projects)/window. On top, **wire type 35 `projectGitStatus`** (host → client,
    control): a per-repo FSEvents watcher (`RepoStatusWatcher`, refcounted across panes via the
    type-34 latch edges, 0.75s debounce, dirty-guarded, `SLOPDESK_GIT_WATCH` default-ON gate,
    probe-skipped when no client is attached) pushes the HOST-folded summary (shared
    `GitStatusPayload.foldedCounts` — the file list never rides the push) to every session
    sectioned under the repo; the client backs its poll off to 300s while pushes stay fresh, so an
    old host degrades gracefully to poll-only. The status probe gained `--no-optional-locks` (a
    read-only cadence probe must never contend the user's own git on `index.lock`). → [20 §type 35],
    `RepoStatusWatcher.swift`, `ProjectGitStatusLine.swift`, `WorkspaceStore.swift` (§Section git line)
- ✅ **2026-07-23 — Satellite windows take POINTER interaction while NOT key ("background interaction", user-directed).**
  The dedicated remote-desktop window (and any ⌥⌘P pop-out) went inert the moment another window had
  focus: hover/cursor tracking was `.activeInKeyWindow`-gated, AppKit consumed the first click purely
  to activate the window, and every pointer forward was gated on `isActive` (== window key for a
  satellite). Now a satellite surface forwards hover, clicks, drags and scroll to the host while the
  window stays INACTIVE — and a click deliberately does NOT activate it (`acceptsFirstMouse` +
  `shouldDelayWindowOrdering` + `preventWindowOrdering`, the drag-from-a-background-window mechanism):
  the pointer operates the remote desktop while the KEYBOARD stays wherever the user is typing — the
  scroll-follows-the-pointer philosophy extended to the whole satellite window. Focusing for typing
  stays explicit (title-bar click / ⌥⌘N / ⌘\`). Keyboard while not key is untouched (macOS routes keys
  to the key window; the immersive CGEvent tap already self-suspends on resign-key; the borderless
  dwell gate keeps its own key guard). Canvas panes keep click-to-activate unchanged — the flag rides
  the `RemotePaneContext` seam and `GuiLeafView` threads it ONLY for a detached pane. The pure gate
  decisions are `BackgroundPointerPolicy` (headless-pinned; the video view itself is never
  instantiated in tests). Setting: "Background Interaction" (Window section,
  `satelliteWindow.backgroundPointer`, default ON). Client-only — no wire change, no host redeploy.
- ✅ **2026-07-23 — System-dialog panes REMOVED; no video surface lives in the workspace window (user-directed).**
  The auto-spawned `.systemDialog` pane (the "show system popups in their own pane" feature: client
  polls `listSystemDialogs` → mints an ephemeral in-tree video pane per host SecurityAgent prompt) is
  retired. It was the LAST video surface inside the workspace window; with it gone, the remote desktop
  is fully separated: the ONLY video surface is the dedicated desktop OS window (detached `.desktop`
  pane, ⌥⌘N), and nothing video-shaped can enter the tree — the `reattachPane` family already refuses
  `.desktop` ("the desktop never joins a tab"), launch restore already drops every persisted `.desktop`
  leaf, and the retained-but-dead canvas fallback no longer mints a desktop pane. `PaneKind.systemDialog`
  is gone (persisted `"systemDialog"` decodes to `.terminal` via the legacy bridge, same discipline as
  `"remoteGUI"`); `SystemDialogMonitor`, the `SystemDialogDiscovery` seam, the
  `features.systemDialogPanes` setting, `SLOPDESK_SYSTEM_DIALOG_PANES`, the host's answer path and
  `scripts/check-system-dialog.sh` are deleted. **Wire stays DORMANT, golden zero-diff** (the
  remote-window precedent): `listSystemDialogs` (11) / `systemDialogList` (12) + `SystemDialogSummary`
  keep their codec + vectors, and the pure `SystemDialogDetector` classifier stays (its classify/detect
  golden vectors are pinned) — only the runtime plumbing is gone. The window-shaped `VideoEndpoint`
  survives as the AUTOMATION seam only: `check-video.sh`'s window-targeted autoconnect now boots a
  DETACHED `.desktop` pane (window endpoint, `RemoteWindowModel` window binding) instead of an in-tree
  pane 0, so the E2E runtime gate is preserved without re-admitting video into the tree.
- ✅ **2026-07-23 — Tab row = supervision instrument: ONE-SHAPE StatusRing + readout line + telemetry column + session-scoped height (user-directed).**
  With project identity + git on the SECTION HEADER, the per-tab dir/git lines were redundant; the row
  is redesigned around supervising many agents (research pass over Warp's agent tabs + T3 Code's
  indicator system — the latter is open source, `pingdotgg/t3code`, and its two load-bearing recipes
  are adopted: STEPPED motion (`steps(N)`-style discrete frames, never an eased breathing pulse) and
  a hard colour budget (colour only for act-now / in-motion / broken / unread-done; the resting state
  is the UNLABELED state)).
  - **One shape, many readings (`StatusRing`).** The badge vocabulary previously swapped silhouettes
    per state (dot+orbit ring / bare dots / SF-symbols) — a state edge read as an icon swap ("giống
    layout shift" even though the 16pt box never moved). Now every lifecycle state is a READING of the
    same Ø12 ring: working = dashed 8-segment ring, lead segment ticking one slot per 0.2s beat (a
    mechanical escapement, agent-only motion); awaiting = amber ring + centre dot + ONE stepped halo
    pulse per 2s (front-loaded, 8 discrete frames); done/unread = green ring + check (the `.completed`
    flash and `.finished` unread marker render identically — the enum split survives for the freshness
    machinery); error = red ring + cross; OSC 9;4 progress = muted ring + micro-dot, STATIC; sudo/
    caffeinate = glyph inside the muted ring. Only the plain busy shell stays a sub-ring 6pt micro-dot
    (concentric: an agent taking over reads as the dot growing a ring). Awaiting moved red→AMBER
    (act-now); red is reserved for broken. `SlateOrbitDot`/`SlateCometArc`/`SlatePingDot` deleted.
  - **The row grid: [2pt attention tick][content][4ch telemetry][16pt badge rail].** The tick
    (amber = a question waits, red = broken; hard cut, motionless, never fades under hover) gives a
    dedicated left-edge who-needs-me scan channel; the badge moved from its two per-line positions to
    ONE full-height vertically-centred rail slot (constant x AND constant anchor — a continuous scan
    column); the telemetry column (instrument small, right-aligned, `Slate.Metric.telemetryCol`) shows
    at most ONE value by badge precedence: blocked-age (AMBER — the sole coloured number, an ignored
    question must not look fresh), working turn-elapsed (from the `paneAttentionAt` `.working`-edge
    stamp; ≥10m escalates one luminance step — the stuck-agent answer), unread-age, command elapsed /
    determinate OSC 9;4 percent (`progressPercentLabel`'s first call site), or a non-agent error's
    bare exit code. Ages reveal at 60s; the duration grammar is clamped ≤4ch (`42s/12m/1h04/>9h`,
    `RailRowTelemetry`); the per-row clock is a `TimelineView` mounted ONLY while a value can show.
  - **Line 2 = the agent READOUT, by precedence (`RailRowReadout`):** blocked question > inspector
    todo scent (`3/5 · Editing …`, promoted from the tooltip; counter prefix leads so `.tail` can't
    eat it) > wire-27 last assistant line while working (~2s min-dwell against mid-turn churn) > the
    agent's FINAL line while done-unseen (the label already crossed the wire and was discarded) >
    `exit N · command` from the block model on error > the strayed relative cwd (demoted to the
    lowest rung, NOT deleted) > reserved blank. The process label became a COMMANDS-ONLY voice
    (suppressed on agent rows — the ring already says agent). Tooltip = full cwd + untruncated prose
    readout + `command · duration · exit N`.
  - **Height changes only at SESSION boundaries.** An agent row (any `ClaudeStatus` verdict, or a
    known agent CLI in the foreground — `RailRowsBuilder.isAgentSession`) HOLDS the 44pt two-line
    shell for the whole session (blank line 2 reserved when idle), with a 10s sticky decay on exit —
    so a question/done/error edge swaps text inside a fixed shell and NEVER moves layout (previously a
    subtitle-less row grew 32→44 the moment a question arrived). Non-agent rows keep 32pt (strayed-cwd
    rows keep their structural 44pt).
  - **Section header gains the act-now tally** (`●N`, amber, reserved slot, absent at zero): how many
    panes in the project are blocked/broken, counted through the SAME gated badge pipeline the rows
    render — "which PROJECT needs me" at a glance.
  Client-only; no wire change (every element binds to signals already crossing: wire 26/27/32, the
  attention/completion/command stamps, `TerminalBlockModel`, `PendingToolSummary.scent`). iOS keeps
  its system rows (ring badge inherited; readout/telemetry/tally deferred, macOS-first).

## Tab-row v2: Linear fill-fraction glyphs in a LEADING column, uniform two-line rows (2026-07-23)

- **Decision:** Rebuild the sidebar tab row around ONE leading status-glyph column speaking the
  Linear fill-fraction vocabulary, and make EVERY row the same two-line shape. Supersedes the
  same-day READOUT+RAIL trailing-rail design (its resolvers survive; its layout and its animated
  ring do not).
- **Why:** On hardware the trailing rail read as cramped and the escapement ring as generic
  "AI slop". Root causes, confirmed against the T3 Code source and the icon-family geometry it
  leans on: (1) a lead segment advancing around a circle is still a SPINNER — the crafted systems
  (T3, Linear, Octicons) never rotate anything; their only motion is a stepped opacity duty cycle
  (`steps(n)` ramps between two plateaus — discrete frames, e-ink cadence, on an already-simple
  shape); (2) our dash gaps (~6.5° vs ~38° dashes) collapsed into a "cracked circle" at Ø12 — the
  icon-family proportion is dash:gap 1:1 (8 × 22.5°); (3) semantics carried by 12pt micro-geometry
  plus a bare 4-char number is illegible — the crafted systems encode state as HOW MUCH of one
  fixed circle is drawn/filled (the `◌ ○ ◔ ◉ ●` terminal-glyph ladder), with terminal states
  earning the only solid fill; (4) a 46pt rail reserved on BOTH lines of a 220pt sidebar squeezed
  the title and left the number context-free.
- **The vocabulary (`StatusRing`, one Ø12 circle, 16pt box):** working = dashed `◌` (8 dashes, 1:1,
  one centred at 12 o'clock), whole-glyph flicker 1.0↔0.75 on T3's duty cycle (3.4s, hard 1/10
  steps, wall-clock phase from a fixed epoch — all working rings tick in unison, remounts land
  mid-cycle); awaiting = amber ring + centre dot `◉`, STATIC (halo deleted); done/error = the
  SOLID disc with a knocked-out ✓/✕ (ground-tone cutout); commandBusy = hollow muted `○`;
  commandRunning = muted ring + a centre pie wedge swept to the REAL OSC 9;4 fraction (r 3.5 —
  Linear's inner-fill proportion; indeterminate = bare ring); sudo/caffeinate glyphs unchanged.
  The only motion in the sidebar is the working flicker.
- **The layout:** `[16pt glyph column][title + readout][trailing telemetry text]`. The glyph column
  leads (a vertical scan line of readings, lazygit-style) and anchors on line 1; the attention
  tick is deleted (an amber/red glyph at a constant leading x IS the tick). The trailing rail and
  its reserved telemetry column are deleted — the telemetry value is right-aligned TEXT in the
  title line's timestamp slot (the T3 idiom), and line 2 runs the row's full width (minus the
  hover-`×` reserve). EVERY row is two-line (`reserveSubtitle` always): the height ladder and the
  session-scoped rung + 10s sticky decay are deleted outright — no state edge can EVER move
  layout because there is nothing left to move. Line 2 gains a RUNNING-COMMAND rung (open block's
  command text, fallback process label) between error and strayed-cwd; the line-1 process label is
  gone. A RESTING row (no badge, not active, not hovered) RECEDES to the secondary title tone —
  the T3 `shouldRecede`: the quiet state is dimness, colour + full ink are earned by live state.
- Client-only; no wire change; golden untouched. The readout/telemetry resolvers, hue budget,
  header tally and iOS system rows carry over unchanged.

### v2.1 — HW-review follow-ups (2026-07-23)

First hardware look at v2 surfaced three faults; all fixed the same day:

- **Glyph "slightly off" line 1** — the leading slot was centred over the whole two-line row and
  lifted by a hand-tuned `-7pt` offset. Replaced with a real custom vertical alignment
  (`VerticalAlignment.slateLineOne`): the line-1 HStack exposes its own centre as the guide and the
  shell's outer HStack aligns the accessory to it, so the glyph tracks the laid-out title line
  exactly and can never drift with font/metric changes.
- **Line 1 repeated the section header** — under By-Project grouping, a pane AT its project root
  titled itself with the same folder name the section header already carries (every at-root row in
  a section read identically). New `rowTitle` rung: at the project root the row titles by its
  foreground PROGRAM (`claude` / `vim` / `make` — the tmux idiom: header says WHERE, line 1 says
  WHO); an idle shell yields the kind-generic "Terminal". Strayed panes keep the folder name; an
  explicit rename still wins; the titlebar/window-title call sites omit the key and keep folder
  names. Consequences wired through: the worktree-collision disambiguation moved UP to the section
  header (`headerDisambiguated` — `feature-a/myapp` vs `feature-b/myapp` as HEADERS now), and
  `RailStructureKey.titledByProcess` is project-key-aware so an at-root pane's process change is
  structural (retitles) while a strayed pane's stays a volatile cache hit.
- **Section header layout** — the header hung into the gutter (8pt inset vs the rows' 12pt content
  inset) and the act-now tally kept a fixed 22pt reserve that read as a ragged hole against the
  right edge whenever it was empty. The header now sits at the rows' own content inset (flush over
  the glyph column), the tally renders only when non-zero, and each section gains breathing room
  above its header. New opt-in snapshot render (`sidebar-section.png`) locks header↔row alignment
  visually.

### v3 — flush-left rows, ASCII status glyphs, two-line header (2026-07-23)

Second hardware review: the leading glyph column — even perfectly aligned — indents every title off
the section header's left edge, and the drawn status rings still read as ornament. Direction: return
to the pre-v2 flush-left row anatomy, keep the uniform two-line shape, and speak status as TEXT.

- **The leading glyph column is GONE.** Rows are flush-left again (the old `SlateListRow` no-leading
  shell); status moved into the line-1 TRAILING cluster next to the telemetry number, where `✻ 4m`
  reads like an AI CLI's status line. `StatusRing`/`TabBadgeView` live on for the titlebar tab menu
  and iOS rows; the sidebar speaks `AsciiStatusBadge`.
- **Status is a text glyph in the instrument voice** (`AsciiStatusBadge`): agent working = the
  AI-CLI pulse `· ✢ ✳ ✶ ✻ ✽` (frame-stepped on the wall clock from a fixed epoch — hard swaps, rows
  in unison, re-render can't reset phase); command running/busy = the braille dot-walker, muted;
  static `?` amber (blocked), `✗` red, `✓` green/muted, `#` (sudo — the root prompt's sigil), `∞`
  (caffeinate). A fixed 13pt slot pins the cluster while frames/states swap. The determinate OSC
  9;4 pie is retired — the telemetry slot already carries the exact percent.
- **Line 2 is ALWAYS filled, never a duplicate.** New floor rungs under the readout ladder: the
  strayed cwd, then the LAST COMPLETED command line (`make check · 12s · ✓`), then the shell
  identity (`zsh` — suppressed when it would repeat the title, e.g. an at-root row titled
  `claude`), then the tab's `⌘N` shortcut hint. A resting row now reads as two useful lines instead
  of title + reserved blank.
- **The section header is TWO lines**: the caps project name + act-now `●N` tally over the
  project's git line (branch + dirt sigils); a non-repo project shows WHERE it lives instead (the
  `~`-abbreviated parent path). Both lines sit at the rows' own content inset, so the header and
  every title share one left edge — the misalignment complaint dies structurally.

### v3.1 — the de-dingbat pass: `!<code>`, `?N !N` tally, one-tone git, section rule (2026-07-23)

Hardware review of v3: the remaining round/nerd-font symbols (`✗ ✓ ●N`, the git arrows, the conflict
pill) still read as generated chrome. The pass replaces the residual symbol vocabulary with ASCII
text and spends the freed contrast on ONE animation idiom:

- **Error badge = `!<exit code>`** (`!137`, err-red) — the shell's own bang fused with the number a
  glance actually wants; a code-less error (agent / live OSC 9;4;2) reads the bare `!`. The
  telemetry slot drops its exit-code branch (the badge carries the number) and always answers "how
  long has it sat broken"; the line-2 error rung drops to the failing COMMAND alone — the pair
  `!137 12m` / `npm test` never repeats a digit. `✓ → ok` (green unread / muted decayed): a word in
  the instrument voice, not a dingbat.
- **Header tally speaks the rows' own dialect**: `●N` → `?N` (blocked questions, amber) + `!N`
  (failures, err) — the header total and the row badges are one vocabulary. The cluster BLINKS like
  a terminal cursor (soft opacity dip, hard swap, phase-locked to the shared wall-clock epoch so
  every project's tally dips together) — attention data is the one place the header earns motion.
- **Git line goes `__git_ps1` ASCII + one tone**: `↑↓` → `>`/`<`; every count reads the same
  secondary grey (the 10pt token rainbow read as noise); colour is rationed to the conflict `=N`
  (err-red text — the pill's background plate is gone, the one state that blocks work keeps the one
  hue).
- **The header earns its structure from a RULE, not a bead**: a hairline fills the width between
  the caps name and the tally (the lazygit `── title ──` idiom) — the section reads as drawn
  TUI chrome, and the tally hangs off the rule's right end.

### v3.2 — the readout earns line 2; the header goes still (2026-07-23)

Hardware review of v3.1: the section rule read as ornament, the tally blink as irritation, and the
row's "always-filled" second line as filler — a strayed-cwd echo of the title's own basename, a full
command under a command title, `claude` under an agent row. The verdict: line 2 must carry
information the row doesn't already state, or not exist.

- **The second line is EARNED, not reserved**: `RailRowReadout` keeps only the live rungs —
  question / todo scent / working label / final line / failing command / running command — and the
  structural fillers (strayed cwd, last-command history, shell identity, `⌘N` hint) are gone; a
  settled row COLLAPSES to the compact single-line shell (`SlateTabRow` no longer reserves the tall
  shape). A second line now always means "something is happening here"; history and the full cwd
  stay in the hover tooltip. Height changes only on real state edges.
- **The title-echo gate**: command-shaped rungs are dropped when they would only repeat the title
  (equal or word-bounded extension, `npm` ↔ `npm test`) — the case where a shell titles the pane by
  its own command. Prose rungs are exempt (a question quoting the title is still news).
- **Header: no rule, no blink.** The hairline between name and tally is deleted (the caps name +
  right-aligned tally is the whole structure) and the `?N !N` tally is static — its colour against
  the header grey is the signal; a permanent blink taxed attention instead of directing it.

### v3.3 — one line, one face: the rail reads like terminal text (2026-07-23)

Hardware review of v3.2: rows mixing one and two lines read as visual jitter, and the rail still
didn't look terminal-native — it wanted the terminal pane's own monospace face.

- **Every row is ONE fixed-height line.** `SlateListRow` loses the whole subtitle/reserve machinery
  (`heightRowTall` deleted from the ladder); the READOUT moves INLINE after the title in the dimmed
  secondary tone, truncating `.tail` before the title does (the tooltip keeps the whole line). State
  changes swap text, never row geometry — the list's rhythm is a constant beat, tmux-dense.
- **The rail speaks the instrument face end-to-end**: row titles, the inline readout, the rename
  field, the search field, the empty label and the drop slot join the header/git/telemetry lines in
  the mono voice — the sidebar reads like terminal text, in the same family libghostty embeds as the
  terminal default (JetBrains Mono).
- **The instrument voice can no longer silently fall back to proportional SF**: `Font.custom` with a
  missing family degrades to the plain system face, which on a machine without JetBrains Mono
  installed erased the entire mono register (the app does not bundle the font — the terminal's copy
  is embedded inside libghostty, invisible to AppKit). `Slate.Typeface.instrument` now checks the
  family once and falls back to SF Mono (`design: .monospaced`) — always a real mono.

### v4 — the otty reset: the sidebar returns to the source (2026-07-24)

Verdict after the v2→v3.3 saga: every visual added to the rail (git line, telemetry column, act-now
tally, inline readout, whole-rail mono) moved it FURTHER from the otty elegance the whole design
system was reverse-engineered from. The sidebar resets to otty's `TabsPanelRowView` 1:1
(`otty-reversed/Sources/UI/OttyReplica.swift` measurements + `docs/otty-clone/screenshots/`), with
ONE deliberate step past otty kept: always-on By-Project grouping.

- **The row is the otty row**: 34pt (`heightTabRow`, off the 4pt ladder — the replica measurement
  wins), 14pt inset, radius 7, title in the SYSTEM face 13 (medium when active, primary ink always —
  the T3 recede is gone), one trailing 28×18 slot carrying the resting SHELL LABEL (`zsh`, muted 11)
  or the status badge, swapping to the close `×` under hover. Active = raised card + hairline + the
  measured 4% cast shadow (returns with the reset; MERIDIAN L5's no-shadow rule yields to the
  measurement). `SlateTabRow` no longer rides `SlateListRow` — it IS the otty row, standalone.
- **Badges are the otty icon set** (`tab-badge.png`): ONE muted rays spinner for every busy tier
  (otty does not colour-grade motion), orange raised hand = awaiting input, red triangle = error,
  green check = task done, small green dot = unseen finish, `# ∞` stay small muted text.
  `AsciiStatusBadge` (text-glyph dialect) and `StatusRing` (one-shape fill-fraction vocabulary) are
  deleted; `TabBadgeView` is the one badge, shared by the sidebar, the title menu and iOS.
- **Deleted from the rendered rail**: the inline readout, the telemetry column (`RailRowTelemetry`
  gone), the header git line (`ProjectGitStatusLine` gone), the `?N !N` tally, the macOS search
  field (otty's sidebar is bare rows — Open Quickly is the finder; iOS keeps system `.searchable`),
  and the whole-rail mono register (the sidebar speaks the system face again; `instrument` remains
  for genuinely technical text elsewhere). The RICHNESS did not die — it moved where otty keeps it:
  the row tooltip (cwd + live agent line via `RailRowReadout` + last command) and the header tooltip
  (full path + git line), plus the context menus.
- **The project header speaks otty's own header grammar**: ONE caps line, system 11 semibold,
  `tracking(0.6)` (`capsTracking` — the measured "TABS" register), on the panel's 16pt label column,
  separated by AIR (16pt top), no rule, no counts. Hierarchy by luminance: "TABS" (panel chrome)
  keeps the lightest header grey; project names sit one ink step darker (`Text.secondary`) as
  content taxonomy — exactly how otty ranks the Details panel's "STAGED"/"CHANGES" against rows.

### v4.1 — the LIVE otty port: measured off the running app (2026-07-24)

The v4 reset was built from the historical replica + screenshots; the user then opened the CURRENT
otty (which has grown native By-Project grouping) and asked for a 1:1 port of what is actually on
screen. Every number below is pixel-sampled off the live window at 1× (`otty-cli tab new --cwd …`
probe tabs at controlled depths nailed the header dialect; `tab list --json` exposed the semantics).

- **The row re-measures**: height 34 → **36**, title inset 14 → **10** (title ink starts x18 against
  the card at x8), and the resting title drops to the SECONDARY ink — only the active card's title
  reads primary (+ medium). List inset 8, spacing 2, radius 7, card + hairline + shadow all held.
- **The group header is otty's real anatomy, not a caps line**: `chevron.down` (x≈10, muted) +
  dim `folder.fill` (x≈27) + the project PATH in the plain system face 11 at x≈46 — lowercase,
  trailing `/`, `~`-abbreviated (any `/Users/<name>` prefix — the key is a HOST path), and
  middle-elided past ~32 chars keeping FIRST + `…` + as many TRAILING components as fit
  (`/Volumes/…/oss/slop-desk/`; the live app renders its own quirky component order — ours keeps
  original order, same grammar). Header band = 24pt + the 2pt list gaps = the measured 28pt; the
  air IS the group separator (no rule, no counts, no caps). Tapping collapses the group
  (chevron.right; session-scoped `@State`). The v4 caps-line header is superseded.
- **The `✳` agent marker is title text**: `tab list --json` showed otty's agent integration
  literally prefixes the title string (`"✳ Claude Code"`). `SlateTabRow` grows `agentMarker:`
  (rendered `✳\u{FE0E}` — VS15 pins text presentation) driven by `isAgentSession`; the rename field
  still seeds from the bare title.
- **The TABS row gets otty's trailing panel-menu icon** (`line.3.horizontal.decrease`, header ink):
  theirs opens GROUP/ORDER/DIVIDER modes; ours is always-grouped-by-project, so the menu carries
  only honest actions (Collapse/Expand All Groups, Refresh Git Status).
- Badge COLOURS stay the v4 mapping (`tab-badge.png` — the live capture's grey hand is just the
  inactive-window render). The trailing pane-count otty shows does not map: our rows are per-PANE,
  not per-tab.

### v4.2 — the daily-driver header: name + live git line, animated collapse (2026-07-24)

Three adoptions after driving v4.1, one measured addition. The user's read: the full (elided) path
in every group header is noise once you know your projects — and the collapse snap felt raw.

- **The header names the FOLDER, not the path**: the title is `section.header` verbatim — the
  basename `TabOrderingEngine.projectSectionHeader` already derives (worktree collisions already
  parent-qualified by `headerDisambiguated`). `displayPath` and its elision dialect are deleted;
  the full path lives where the richness lives, the hover tooltip.
- **The git line moves INTO the header**: the muted trailing slot (right inset 10 — the rows'
  trailing-label x) carries `gitLine` (`main >2 !3`, header ink, footnote) while the group is open.
  Freshness is the existing project-scoped FSEvents push (wire 35). The name wins the truncation
  fight (`layoutPriority`), a long branch tail-truncates.
- **Collapsed shows the hidden-row COUNT** — measured off the live app: collapsing a group in otty
  swaps its trailing slot to the muted tab count at the row-label x. `trailingLabel(collapsed:count:summary:)`
  is the pinned pure swap (count while shut, git while open).
- **Collapse ANIMATES — a deliberate otty deviation**: a 60fps recording of the live app
  (background `screencapture -v` + a driven chevron click) proves otty snaps collapse in ONE frame.
  The user called the snap crude, so ours glides: every `collapsedSections` mutation (header tap +
  the TABS-menu Collapse/Expand All) wraps `Slate.Anim.standard`, and the disclosure is ONE
  `chevron.right` rotating 0°↔90° (not a symbol swap) so the glyph turns with the rows.
- The chevron drops semibold → **medium**: the live glyph is a 1px stroke; semibold at 10pt read a
  step chunkier than the reference.

### v4.3 — the header goes two-line (2026-07-24)

Driving v4.2, the user found one line too little area: the folder name and the git line share a
24pt row, so either can starve the other. The header becomes TWO lines while a git line exists:

- **Line 1 = the name, line 2 = the git line** — the git line moves from the trailing slot to a
  full-width small-face line under the name (header ink, indented to the name's x46), so branch +
  dirt and the name each get a whole line. `trailingLabel` splits into the pinned pair
  `detailLine(collapsed:summary:)` (second line while open) + `trailingCount(collapsed:count:)`
  (trailing slot while collapsed).
- **The band grows only when it must**: a bare (non-repo / unknown) header keeps the measured 24pt
  otty band (`minHeight`); a git-lined one takes its natural two-line height. Collapsed headers
  fold back to one line — count trailing, git folded away with the rows.
- The header HStack aligns `.firstTextBaseline` so the chevron + folder glyphs sit on the NAME
  line, not the two-line block's center.

### The idle row's "Terminal" becomes the last long-running command (2026-07-24)

The user: the kind-generic "Terminal" — what every at-root idle shell resolves to under By-Project
grouping (folder name suppressed by the header, bare shell suppressed as no better) — carries no
information; every resting pane in a section reads as identical twins. An idle shell has no CURRENT
identity, but it has a HISTORY one: the command it last ran is exactly what you scan the sidebar
for ("the shell I ran `make check` in").

- **Empty-title fallback = the pane's last long-running command** —
  `RailRowsBuilder.lastCommandTitle(blocks:)`, resolved in the LIVE row leaf (`SidebarLiveRow` +
  the iOS twin) since blocks are volatile; the memoized structural `RailRow.title` stays "" (search
  keys unchanged). "Terminal" now survives only for a genuinely blank shell that has run nothing —
  where it truthfully means "empty pane".
- **A sub-3 s command never takes (or clears) the title** — user-directed filter so quick commands
  don't churn the row: the resolver scans BACKWARDS for the newest block
  with `durationMS ≥ 3000` (`commandTitleMinDurationMS`, mirroring the busy-dot reveal default), so
  a quick `ls` after a long build leaves the build's title standing instead of flashing the row.
  A running block (no duration yet) never titles; an interrupted block with a stamped duration does.
- The tooltip's title-echo gate already covers the new title: a running command equal to the shown
  last-command title is dropped as a restatement.

### Row titles v4.5 — intent for agents, failure-only for shells, double-click rename (2026-07-24)

The last-command title above shipped and immediately under-delivered: echoing WHAT ran is mechanical
identity, and the research pass (tmux/WezTerm/kitty/iTerm2/Warp/VS Code/Ghostty + the agent-session
managers) shows the only label that stays meaningful AND differentiating once a pane idles is
SEMANTIC — why the pane exists, not what last executed in it. Three moves, one title chain
(`RailRowsBuilder.liveRowTitle`, shared by the macOS + iOS leaves): **rename → agent intent →
structural title → failed-command alarm → kind-generic**.

- **Agent rows title by their session INTENT (wire type 36, `agentSessionIntent`)** — the session's
  first titleable prompt, latched host-side by `ClaudePaneDetector` from the `UserPromptSubmit`
  hook's `prompt` field (no transcript reads, no LLM). Sticky per hook `session_id` (a new session /
  `/clear` re-derives; later turns never churn the row), cleared on `SessionEnd` AND on presence
  termination (a dead claude must not squat its task line on the pane), change-edge deduped with a
  silent-when-never-spoke anchor, re-asserted on reattach (the 33/34 sibling), pruned with the other
  per-pane mirrors. Slash-commands / harness-XML first prompts have no titling value — the latch
  stays open for the first REAL prompt. This is the Claude-Code/Conductor/VibeTunnel session-naming
  idiom: four `claude` rows in one project stop reading identically.
- **The idle shell's last-command title narrows to FAILURES only** — `lastCommandTitle` now lets the
  newest long-running (≥ 3 s) block DECIDE: non-zero exit surfaces its command in the status-error
  ink with a text-presentation `✗` (the `✳` precedent); a clean exit keeps the quiet generic row
  (success is the badge's story — echoing every finished command churned without informing, which
  is what sank v4.4). Sub-threshold blocks still neither title nor clear; an interrupted block
  (duration stamped, no exit code) decides quiet.
- **Double-click opens the inline rename** (`SlateTabRow`, the Finder idiom) — the third affordance
  sharing the context-menu / ⌘R pending-rename; the single-tap select rides `simultaneousGesture`
  so selection never waits out the double-click window. Rename stays the top of the chain and,
  once set, permanently beats the automatic titles (the tmux `rename-window` contract).

### Row titles v4.6 — the failure alarm retires; the title is simply the last EXECUTED command (2026-07-24)

The v4.5 fail-only title survived one day of hands-on: a red `✗` row reads as ugly alarm chrome,
and the quieter cost was worse — while a command RUNS the row showed only the spinner, answering
"something is happening" but never "what". User verdict: show the last executed command, and the
running command counts as last-executed.

- `lastCommandTitle` returns to exit-AGNOSTIC (the v4.4 rule), with the threshold LOWERED to 1 s
  (user-directed): the newest ≥ 1 s finished block titles the idle row; sub-second chatter still
  neither takes nor clears it. The title threshold now deliberately sits BELOW the busy-dot's 3 s
  reveal — standing text is cheap, the dot is an attention signal. Exit status lives where it
  always did — the badge and the tooltip's `cmd · duration · exit N` line. The `✗` glyph +
  status-error ink leave `SlateTabRow`.
- The chain gains a RUNNING rung above history: `liveRowTitle` = rename → agent intent →
  structural → **running command** → last executed → generic. The running text is the open
  block's command (foreground-process fallback), gated on the busy-badge reveal (`.commandRunning`
  / `.commandBusy`) — it appears WITH the spinner (the busy reveal), so a fast `ls` never flashes
  the title and the spinner is never anonymous again. The tooltip's running line drops as a title
  echo (the existing restatement gate).

### Row status v4.7 — the busy spinner retires; "working" is the TITLE's stepped shimmer (2026-07-24)

The rays spinner spent the trailing slot on motion and said nothing the title didn't already say
(the running rung has carried the full command since v4.6) — and it hid the shell label while a
command ran. New reading: any BUSY tier (`TabBadgeKind.isBusyTier` — working agent / OSC 9;4
progress / plain busy shell) renders as a working shimmer on the row TITLE itself (`WorkingShimmer`:
a low-contrast DARK band sweeping the title's own ink, quantized to 24 discrete steps over 1.4 s
with a 1.0 s rest beat — the coder/mux sidebar recipe, `steps()`-mechanical like T3 Code, never a
bright ChatGPT-gloss loop). The trailing slot keeps the shell label while running, so busy costs no
information. Glyphs are now reserved for the states that WAIT on the user (hand / triangle / check /
dot) plus the privilege markers (`#` / `∞`); the spinner mapping stays in `TabBadgeView` as the
vocabulary for non-sidebar mounts. The busy reveal threshold (1 s, `tabBadgeBusyDelaySeconds`) now
gates the shimmer + running title together; the terse busy reading ("Agent working" / "Running")
moves to the title's accessibility value. Both sidebars (macOS + iOS) split on `isBusyTier` at the
row leaf; phase math is pure wall-clock against a fixed epoch, so every working row ticks in unison
and re-renders can't reset a sweep.

### Row status v4.8 — hooks tell the truth: live intent, structured blocks, title-corroborated liveness; shimmer is the AGENT's alone (2026-07-24)

Three fidelity gaps closed after studying how the reference products supervise Claude Code
(t3code drives the Agent SDK's in-process `canUseTool` gate; herdr keeps ONE identity hook and
reads liveness off Claude Code's own OSC title — both refuse to let subagent events revive an
idle pane):

1. **The intent (wire 36) follows the session's LATEST titleable prompt.** The v4.5 latch kept
   the FIRST prompt for the session's whole life, so a multi-turn session's title never followed
   the work. `foldIntent` now re-derives on every real prompt; slash-commands / harness XML
   neither re-title nor wipe. The wire shape is unchanged (change-edge dedupe already handled
   re-pushes).
2. **Blocked/failed states arrive structurally.** The installer adds `PermissionRequest` (the
   structured permission dialog — kind 1, the gated tool names the label) and `StopFailure`
   (API-error termination → done with the error text, instead of a pane stuck `working`);
   `Notification` classification reads the structured `notification_type` field first
   (`permission_prompt`, `idle_prompt`, `agent_needs_input`, `elicitation_dialog` block;
   known informational types never false-block; unknown types still fall to the text
   heuristics). `PreToolUse` of `AskUserQuestion` maps to waiting-for-input with the question
   as the label — Claude ASKING is not Claude working (the t3code/herdr special case).
   SubagentStart/SubagentStop stay deliberately uninstalled (the herdr bug class: a subagent
   completing after the main turn stopped must never revive an idle pane).
3. **Claude Code's own OSC title corroborates liveness.** The title the CLI writes (a Braille
   spinner glyph while a turn runs, `✳ ` at rest) folds into the ONE detector on every sniffed
   title edge: the spinner promotes a DETECTED claude to working, the rest prefix demotes ONLY
   a live `.working` back to `.idle` — the missed-Stop stuck-shimmer corrector. A title never
   conjures presence, never clears a hook block, never touches `.done`'s decay window, and
   never opens the type-27 stream on an undetected pane.

Sidebar reading refined with the states now trustworthy: the working shimmer is reserved for
the AGENT tier (`.running`) — a running COMMAND's title (the command text, standing still) is
signal enough, so `commandRunning`/`commandBusy` mount neither shimmer nor glyph and the slot
keeps the shell label. The shimmer itself steps up: a thinking agent's title wears the PRIMARY
ink (the brighter base lifts the row) and the dark band deepens (0.55 → 0.35) — the field
verdict on v4.7 was "barely there". The header git line drops the ASCII-only constraint:
`↑2 ↓1 +3 !4 ?5 ~1 $2` (the prompt-theme dialect — `~` replaces the misleading `=` for
conflicts) behind an inline `arrow.trianglehead.branch` glyph.

**Amendment (same day, field bug):** the Claude Code NATIVE installer names its executable by
VERSION (`…/.local/share/claude/versions/2.1.218`) — the exact-basename `claude` classifier never
matched, so presence never held, the 30 s post-hook grace lapsed between turns, the intent was
wiped, and the slot read a meaningless `2.1.218`. `ForegroundProcessDetector.canonicalName(of:)`
resolves a version-shaped basename up past the layout components (`versions`/`bin`/`current`/
`libexec`) to the owning app directory; the probe and the detector fold both use it. Verified
end-to-end on the rig with the real binary (row reads `✳ <latest prompt>` + slot `claude`).
The git line's inline branch glyph was also dropped on review — symbols only where they carry
meaning, and the sigil dialect already says "git".

### Row title v4.9 — the row title is claude's OWN title; an untouched rename commit is a cancel (2026-07-24)

Field bug behind "title vẫn là Terminal" after v4.8.1: the pane's persisted spec carried
`userRenamed: true, title: "Terminal"` — the inline-rename field (double-click, new in v4.8.1)
committed its UNEDITED seed on blur, freezing the resting generic title as a sticky rename that
outranks every live rung forever. The host latched the intent correctly the whole time; the rig
never reproduced because a rig pane has no accidental rename. Two guards:

1. **An untouched draft resolves as CANCEL** in both inline-rename fields (macOS row + shared
   `InlineRenameField`): only an actual edit expresses a rename — double-click then click-away
   leaves the live title chain in charge.
2. **A "rename" equal to the kind-generic fallback never wins** in `liveRowTitle`: renaming a
   pane "Terminal" carries no identity, so the rung yields to the live chain — which heals the
   already-persisted accidental pins without a migration.

And the round's ask — "lấy title CHUẨN của claude code" (research: herdr corpus, happy/happier,
opcode/crystal/claude-squad/vibetunnel, official docs): Claude Code already titles its own
session — the OSC title's text behind the telltale glyph IS a background-model topic summary
(and `/rename` writes a custom name there); "✳ Claude Code" is only the startup static. The
transcript's `type:"summary"` record (what happy/happier read) is resume-time-stale and an
internal format — the OSC title is the LIVE self-title and the sniffer already latches it. So
wire 36 now carries: claude's own topic when the title has one (`topicLine` — telltale/VS/space
stripped, "Claude Code" rejected, detected-pane-only), superseding the prompt-derived intent;
the prompt remains the fallback while no topic exists (short sessions, title generation off).
This is exactly the tmux `set-titles-string "#T"` behaviour the pane titles came from — the
pane shows what the program running in it says it is doing.

Addendum (same day): the resting fallback of a bare pane is the cwd FOLDER NAME, not the
kind-generic "Terminal". The at-root idle shell used to fall all the way through (folder name
suppressed because it restates the section header; "zsh" suppressed as meaningless) and land on
"Terminal" — which says even less than the folder. `liveRowTitle` gained a `cwdTitle` rung
between the last-command history and the generic fallback: the basepath is still an identity,
even when it repeats the header. "Terminal" now appears only while the pane has no cwd at all.

## Notifications: one banner per agent event + visibility-honouring gates (2026-07-24)

- **Decision (host, type-25 gate):** while a pane's agent status is HOOK-established
  (`ClaudePaneDetector.suppressesChildNotifications` = the existing `hookAuthority`), the agent's
  OWN terminal notification (OSC 9 / 777 / 99) is DROPPED at the sniff point
  (`MuxChannelSession.ingestPTYChunk`'s FIFO filter — the same chokepoint that already strips the
  raw OSC-7 `.cwd`). A hook-free pane keeps the OSC path untouched.
- **Why:** Claude Code titles under `TERM=xterm-ghostty` resolve its notification channel to
  `ghostty` and it posts its own OSC terminal notification for the very edges the hooks already
  report (permission prompt, idle/waiting) — so a hooked pane raised TWO system banners per event:
  the type-27 agent edge (`agentAwaitInput`/`agentTaskComplete`, rich, host-truth) plus the blind
  OSC copy riding type 25 through the "Allow App Notifications" master. The OSC copy predates the
  hooks (it was the only signal then) and is pure duplication once hook truth exists. Host-side
  suppression (not client de-dupe) because the authority signal lives host-side and is
  race-free: `hookAuthority` is set from the FIRST hook fold (SessionStart), long before any
  mid-session OSC 9 arrives; a timing-window de-dupe on the client would have to guess. The gate
  dies with the authority (SessionEnd / absence termination), so whatever runs in the pane next
  gets its OSC notifications back.
- **Decision (client, visibility gate):** the `NotificationPolicy` foreground-gate input is now
  `sourcePaneVisible` — the user can SEE the source pane (any split of the active session's
  ACTIVE tab while the app is active, or its satellite window is key) — computed by
  `WorkspaceStore.isSourcePaneVisible`. `.tabUnfocused` therefore honours its own label ("Only
  when source tab is unfocused"): previously it read LEAF focus, so a visible split you were
  watching still bannered. The completion BADGE keeps the narrower leaf-focus gate (a badge on a
  visible-but-unfocused split is signal, not noise).
- **Decision (client, toast focus gate):** the in-app toasts (explicit OSC, agent attention,
  long-command) are suppressed when the SOURCE pane is the focused leaf — the user is watching
  the event happen in the pane itself; a toast on top of it is noise. Unfocused panes (other
  splits, other tabs, backgrounded app) keep their toasts — on iOS the toast is the only
  notification surface.
- The OS-banner defaults are unchanged: app frontmost + `Notify While Foreground = Off` still
  suppresses every banner; a backgrounded app still always delivers (that is what notifications
  are for).

## Agent liveness in the sidebar: shimmer keys on RAW status, done is CLIENT-owned unreadness, titles trust the program (2026-07-24)

Field report against a live claude session: no shimmer while the agent thinks, no done marker
after the turn ends (despite the OS notification firing), an idle shell wearing a meaningless
"zsh" trailing label, and `vi .` out-titling nvim's own title. Root-caused against the actual
sources of herdr (`ogulcancelik/herdr`) and t3code (`pingdotgg/t3code`) rather than guessed —
both converge on the same model, now adopted:

- **Decision (resolver): the AGENT finish outranks the busy tiers.** `TabBadgeResolver` checks
  `agent == .done` (and the new `unseenAgentDone` latch) BEFORE `progress`/`isBusy`. The `claude`
  process holds the shell's OSC-133 block open for its entire interactive lifetime, so `isBusy`
  is true for hours; with the old order the completed/finished branch was unreachable on a live
  agent pane — the green check could literally never show. A plain COMMAND's `.success` stays
  BELOW the busy tiers (there a newly-running command genuinely supersedes the previous exit).
  Consequence deliberately accepted: an agent finish now also outranks the passive privilege
  badges (cup/shield) — attention over rest.
- **Decision (store): "done" is UNREAD-COMPLETION, owned by the client.** The host's status
  machine decays `done → idle` after seconds — correct for "what is claude doing", useless for
  "has the user seen it". New `WorkspaceStore.paneUnseenDone` latches at the `.done` edge when
  the pane is NOT visible (`isSourcePaneVisible` — the same tab-level visibility the
  notification gate uses; a finish you watched happen is pre-seen and only flashes), survives
  the host's idle push, and clears ONLY on visiting (the existing `selectTab`/`clearAgentBadge`
  acknowledge paths) or on new agent activity (`.working`/`.needsPermission`). This is t3code's
  `hasUnseenCompletion` (`completedAt > lastVisitedAt`, cleared by opening the thread, Done shows
  indefinitely) and herdr's `Idle && !seen` (seen set by viewing the tab, no timers) — "done" is
  a bit ORTHOGONAL to status, not a fifth state to keep alive host-side.
- **Decision (render): the working shimmer keys on the RAW `.working` status,** not the gated
  badge. "Badge while processing" (default OFF) masks `.working` out of the badge resolver; the
  V4.8 shimmer gate read that gated badge, so every default-settings install rendered a thinking
  agent exactly like an idle shell — the report "no shimmer while claude thinks". The toggle
  governs the badge GLYPH; the shimmer is the title's own affordance (t3code ships working-state
  motion unconditionally). Bonus: the shimmer now starts the moment `UserPromptSubmit` folds
  (t3code flips to working on submit), with no busy-reveal delay.
- **Decision (trailing slot): bare login shells show NOTHING.** The slot now shares the title's
  `processDisplayName` suppression (`shellLabel` deleted) — an idle row labelled "zsh" says as
  little as "Terminal" did; herdr never shows a shell name anywhere. A real foreground program
  (`claude`, `vim`, `ping`) still labels the slot.
- **Decision (title): a FRESH program-set OSC title beats the raw command line.** New
  `liveRowTitle` input `programTitle`: the pane's OSC title, surfaced only where the RUNNING rung
  would title the row, and only when the title was stamped AT-OR-AFTER the current command's
  start (`paneTitleAt` vs `paneCommandStartedAt` — a title left behind by an exited program
  never resurfaces on the next command). One leading agent-activity glyph (braille frame /
  `·✢✳✶✻✽`, herdr's `stripped_terminal_title` rule) is stripped. A FOLDER structural title still
  never yields. nvim ships `notitle` by default — the host-side nvim config now sets
  `title`+`titlestring`, so `vi .` rows read "file (dir) - nvim".

Client-only (no wire change, no hostd redeploy, golden untouched). NOT adopted, recorded for
later: herdr's screen-region rule engine (blocked-form regex, transcript-viewer freeze rules) —
our hook+OSC-title chain covers those edges today; revisit if hook drift appears.

## Agent liveness round 2: elapsed turn clock, one quiet finish dot, the idle nudge is not a block (2026-07-24)

Same-day follow-up on user feedback against the shipped round above.

- **Decision (trailing slot): a WORKING agent row's slot shows the live ELAPSED turn time, not the
  process name.** While the title shimmers, "claude" in the slot repeats what the `✳` marker + the
  shimmer already say — the duration is the one thing the eye wants from a busy row. New
  `WorkspaceStore.paneWorkingSince` (stamped on the genuine `.working` edge in `setAgentStatus`,
  never reset by same-status re-pushes, retired on leaving `.working`, pruned on reconcile) feeds
  `SlateTabRow.workingSince`; the slot mounts a 1 Hz `TimelineView` rendering
  `RailRowsBuilder.workingElapsedLabel` (`42s` / `2m15s` / `1h02m`, monospaced digits, skew clamps
  to `0s`). The tick invalidates one small text leaf per second — never the sidebar body.
- **Decision (badge vocabulary): BOTH clean-finish tiers render the small green dot; the filled
  `checkmark.circle.fill` is retired.** The 16pt filled check-circle sat visually heavier than
  every other reading in the muted row (user: "lạc quẻ" — out of tune); "unread finish" needs a
  marker, not a trophy. `StatusPresentation.tabBadge` maps `.completed` and `.finished` to the
  same 7pt dot; the completed/finished SPLIT stays semantic (freshness machinery, control-backend
  badge tokens, attention ranking) — only the glyph unified.
- **Decision (host classify): Claude Code's `idle_prompt` Notification ("Claude is waiting for
  your input", fired ~60 s after a turn ends with the agent resting at its prompt) classifies
  `.other`, NEVER `.waitingForInput`.** It re-raised the act-now orange hand on every pane the
  user had already read — minutes after the done marker cleared ("xem rồi thì thôi chứ"). Idle
  is presence, not a block. The matcher/message-text idle promotions described exactly this nudge
  and demote with it. Genuine blocks keep the hand through their own signals: `PermissionRequest`
  / `permission_prompt` / permission message text, `AskUserQuestion` (W10 adapter),
  `agent_needs_input`, `elicitation_dialog`. Wire vocabulary unchanged (kind byte 2 still exists;
  hostd redeploy required for this one — the classifier is host-side).

## Agent liveness round 3: a keystroke into a blocked pane is the Esc-cancel unblock edge (2026-07-24)

Same-day follow-up: with the idle nudge demoted (round 2), a REAL block that the user resolves by
pressing Esc left the orange hand up forever — Claude Code fires NO Stop hook on a user interrupt,
and (per herdr's claude manifest priorities: blocked-screen rules 840–980 sit ABOVE the ✳/9;4;0
idle rules at 250) the ✳ rest title already shows WHILE the dialog is open, so neither hooks nor
the title carry an unblock edge for the cancel path.

- **Decision: the host folds client→PTY input into the ONE detector as the unblock signal.** New
  `ClaudeSignal.userInput`: a user keystroke while the machine sits at `.needsPermission` demotes
  to `.idle` — a modal being typed at is being HANDLED. The convergence is what makes it honest:
  an ANSWERED dialog re-promotes to `.working` via its own PreToolUse a beat later; an Esc-cancel
  leaves idle standing (the truth). Every other status ignores the signal (typing a prompt /
  queued message never touches the shimmer; input never conjures presence or cuts the done decay).
  Fed from both input paths — the data-channel relay and the agent-control raw injection (the
  supervision cockpit's routed answer).
- **Decision: only genuine KEYSTROKES count — `PaneInputClassifier` excludes the terminal's
  automatic replies.** The same input frames carry focus-in/out (`CSI I`/`CSI O` — sent by merely
  VISITING the pane), CPR/DA/DSR/DECRPM/kitty-flags reports, OSC/DCS string replies, and SGR
  mouse-wheel events; none is a human handling the dialog, so none may drop the hand. A bare
  trailing `ESC` is the Esc KEY (legacy encoding), not a truncated report; kitty-encoded keys
  (`CSI 27 u` et al.) count. Truncated/malformed sequences classify conservatively as
  not-a-keystroke. Accepted edge: navigating a dialog's options and leaving WITHOUT answering
  also drops the hand — the user demonstrably saw the block (t3code's seen-semantics).

## Agent liveness round 4: port herdr's manifest screen-rule engine (2026-07-24)

> The user's directive: herdr's detection is complete and battle-tested — study it thoroughly and
> port it to Swift at 100% parity or better. herdr is Apache-2.0 (`ogulcancelik/herdr`); the port
> is a reimplementation from its `src/detect/` + `src/pane/agent_detection.rs` semantics, and the
> 19 agent manifests are carried verbatim.

- **Decision: the detect engine is a pure manifest-driven rule engine in `SlopDeskAgentDetect`.**
  TOML manifests (herdr's exact files, embedded as raw-string literals — no SwiftPM resource
  bundle, so the headless daemon and every app target load them with zero deployment surface)
  are parsed by a minimal TOML-subset parser, validated with herdr's exact limits (≤128 rules,
  gate depth ≤8, ≤512 gates, ≤32 matchers/gate, ≤1024 matchers, ≤512 chars/matcher,
  `skip_state_update` ⇒ `state="unknown"` + no visible flags), compiled to NSRegularExpression
  (case-sensitive unless the pattern opts in via `(?i)`, `contains` always case-folded), and
  evaluated with herdr's exact reduction: every rule evaluated, highest priority wins,
  first-declared wins ties, known-agent fallback = plain `idle`. All 13 region resolvers are
  ported byte-faithfully, including the `\n`-only line/offset math. Deferred (documented deltas,
  not parity gaps we hide): remote manifest auto-update and local override files — bundled
  manifests only.
- **RE-SCOPE of "screen verb = on-demand, NOT a persistent grid": the grid becomes RESIDENT per
  pane — but never on the hot path.** P6's original objection (scanning per chunk on the
  latency-critical read-loop thread) still stands, so the read loop only APPENDS the chunk to a
  bounded pending buffer (one Data append, same cost class as the journal/sniffer taps it sits
  beside). A dedicated scan task — herdr's exact cadence: 300 ms, tightening to 100 ms while a
  working→idle hold is pending — owns the `TerminalScreenModel`, drains the buffer, feeds the
  grid + a ported OSC title/progress tracker, extracts herdr's detection text (visible rows from
  the bottom, per-row trailing trim, trailing blank rows dropped, `\n`-joined), and runs the
  engine. Pane resize or buffer overflow marks the model dirty; the scan task rebuilds it by
  replaying the scrollback ring (the same repaint property the `screen` verb relies on). The
  idle-scan skip (idle + no new bytes ⇒ no regex work) is ported as-is.
- **Decision: hooks stay — screen verdicts join the ladder as continuous ground truth.** herdr
  runs Claude with NO state hooks (screen+OSC is its sole authority); we keep our richer
  hook edges (instant working on UserPromptSubmit, `.done` on Stop) — that is the "better" half
  of parity-or-better. Reconciliation in the ONE machine: a screen `blocked` raises
  `.needsPermission` (manifest-sourced); screen `working`/visible-`idle` may clear even a
  HOOK-sourced block once the block is ≥1 s old (younger blocks win — covers the ≤300 ms
  stale-snapshot race right after a hook fires, before the dialog paints); a plain (non-visible)
  idle never clears a hook block; `.done` keeps its decay (screen has no done concept);
  `skip_state_update` (transcript viewer / model picker) freezes the previous status, exactly
  herdr. The working→idle hold (3 consecutive confirmations at 100 ms, 700 ms hard cap,
  bypassed when the idle is VISIBLE chrome) is ported into the fold.
- **Decision: process identity gains herdr's job-scan — but only when the cheap probe is blind.**
  The 1 Hz `tcgetpgrp`+basename probe stays primary. When it returns a generic runtime/shell
  (`node`, `python3`, `sh`, … — the npm-wrapped `claude` case), the host deep-scans the
  foreground process GROUP (proc_listpids + KERN_PROCARGS2 argv), unwraps runtime argv with
  herdr's exact rules (bail on `-c`/`-e`/`-m` eval flags — never trust positional args after
  them; basename → known-package sniff → symlink resolution), and scores candidates
  (unwrapped 3 > literal agent 2 > other 1, first wins ties). This closes the documented
  wrapper-staleness hole from the round-`461` fix. The pure identification/unwrap logic lives in
  `SlopDeskAgentDetect` (injected filesystem resolver); only the pgroup/argv probe is host OS
  code, compiled-only per the hang-safety rule.
- All 19 manifests ship (claude, codex, gemini, opencode, cursor, …), so any of herdr's
  screen-manifest agents in a pane gets live status — presence generalizes from exact-`claude`
  to the ported agent alias table. Parity checklist = herdr's `detect/manifest/tests.rs` +
  `agent_detection.rs` test suites, ported to XCTest.

## Herdr port addendum: parity proven by differential, not asserted (2026-07-24)

The round-4 port claimed 100% parity on the strength of ~90 ported fixture tests. That
standard is now mechanical, not manual:

- **Decision: the parity contract is a differential harness against the REAL herdr binary.**
  herdr ships its own offline oracle — `herdr agent explain --file … --agent … --json` runs
  the actual rule engine on an arbitrary screen file and dumps the full evaluation trace
  (winner, per-rule matched flags, per-rule region byte length + preview). A new dev-only
  `slopdesk-detect-explain` executable mirrors that trace over `AgentManifestCatalog`, and
  `scripts/herdr-differential.py` diffs the two field-by-field on a deterministic generated
  corpus (~3.5k screens built from each manifest's own vocabulary — fragment mutations, CRLF/CR
  endings, prompt boxes, codex markers, Unicode case-fold probes — × own agent + 2 others ≈
  10.6k cases). Any divergence in a region resolver, gate, priority tie-break, or fallback
  surfaces as a field mismatch. XDG dirs are sandboxed per run so the oracle can only load
  bundled manifests.
- **It caught two real bugs on its first run** (both invisible to the ported fixture suite,
  both `\r`-class): Swift's grapheme-based `split(separator: "\n")` treats `\r\n` as ONE
  `Character` and never splits CRLF text; and Rust's `str::lines()` strips a trailing `\r`
  only after stripping `\n` — a final unterminated line keeps its `\r` (plus Rust `trim()`
  counts `\r` as whitespace where Foundation's `.whitespaces` does not). `RegionText.rustLines`
  is now byte-level and pinned by `ManifestRegionLineSemanticsTests` (fixtures verified against
  the oracle). Dormant in production — VT grid rows never contain raw `\r` — but real for any
  future direct-text feed, and exactly the class of drift the harness exists to catch.
- **Decision: upstream sync is a script, not a ritual.** `scripts/herdr.pin` records the herdr
  commit the port is PROVEN equivalent to (advanced only after a green differential run).
  `scripts/herdr-sync.sh` = fetch → show `src/detect` delta since the pin → regenerate
  `BundledAgentManifests.swift` verbatim via `scripts/gen-bundled-manifests.py` (which fails
  loudly if the manifest SET changes, and byte-reproduces the checked-in file — proving the
  bundled TOMLs match the pin) → rebuild the oracle (vendored libghostty-vt builds with the
  repo's pinned Zig 0.15.2 + xcrun SDK shim from `ThirdParty/ghostty`) → differential →
  Swift test suite → `--update-pin`. Manifest-only upstream changes sync hands-free; engine
  `.rs` changes are flagged for a manual port, and an unread or botched port cannot pass —
  the differential gates the result against the new binary itself.
