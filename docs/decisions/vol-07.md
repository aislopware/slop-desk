# DECISIONS vol-07 — 2026-08-11 … 2026-08-13

> Volume 7 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## The escape hatch has to be reachable, and a guard has to re-arm (2026-08-11, review)

✅ **Decided.** A max-effort review of the two rounds above found fifteen defects, all fixed here.
Four are worth recording because each is a CLASS of mistake the rest of this log can be read
against.

**1. A unit test that bypasses the pipeline proves nothing.** The sustained-dissent watchdog — the
only way a pane recovers when the hook feed dies — could never mature in production. It advanced on
folded detections, but `AgentDetectionHold.shouldPublish` only publishes a CHANGED verdict and its
one heartbeat requires `visibleBlocker` on both sides, so a steady dissent is folded EXACTLY ONCE.
Its test passed because it drove `reduce(.screen(…))` directly. The stopwatch is now anchored on the
first dissenting fold and re-checked from `reduce`, on every tick and every signal. Two related
edges: `apply()` used to clear the dissent on EVERY hook (so the watchdog could never mature while a
turn was still emitting hooks — precisely when a stale ledger entry pins a pane), and the watchdog
revoked coverage BEFORE checking whether the matured verdict could land (so a plain idle against a
hook block left the pane stale AND unclaimed, free for the next nested run to take).

**2. A level is not an edge.** `syncFrameHoldCap` bounds how long an open synchronized frame may
suppress publishing — but it was anchored on the first scan that saw ANY frame open, and
`isFrameOpen` is a level. A pane repainting continuously opens a NEW well-formed frame every few
milliseconds, so one second of ordinary Tab-holding retired the tear guard permanently and every
scan after it read a torn grid: the exact bug the tracker was written to prevent, reintroduced by
its own safety valve. The tracker now exposes `frameGeneration` and the cap re-arms per frame.
(Same file, same class of miss: ESC inside a CSI dropped to ground and ate the ESC, so the sequence
after a re-sync was parsed as text. ESC is an anywhere-transition.)

**3. A modal inference is still an inference.** `resolveLedger` dropped every `.permission` entry on
any `PreToolUse`, reasoning that a permission dialog is modal. A batch breaks it: `[Read(a),
Bash(gated)]` raises the prompt on `Bash`, and `Read`'s own `PreToolUse` then lowers the hand while
the human is still looking at the dialog. That is the failure the ledger EXISTS to fix, left open in
one direction because the fix arrived one direction at a time. Every kind resolves by identity now;
the denial the sweep stood in for is announced by `PermissionDenied`, which round 2 installed.

**4. An interrupt is not a failed call.** `PostToolUseFailure` carries `is_interrupt`, and Claude
Code emits no `Stop` for a user interrupt. Read as an ordinary failure it left the pane `working`
with the spinner up until the watchdog corrected it — ten seconds later, into a "turn finished"
banner for a turn the human had just cancelled. It is a QUIET idle.

**Two guards were widened rather than patched.** `AgentInstaller.isInstalled` now means ALL of
`installedEvents`, not any — a settings file from an older build would otherwise report green
forever while the events added since went unregistered. And `scripts/herdr-differential.py` scopes
divergence to the RULE (`DIVERGED_RULES`) rather than the agent: excluding the whole `claude` label
had silently dropped the guard on five rules nothing else pins. Back under test at 10 663 cases,
PARITY OK. A gate `region` also became an engine-3 key, since an engine that ignores it drops a
VETO — the quietest way for a rule to fire on the screen it was written to skip. → [50 §4, §5, §5b, §7]

## The band gets an aggregate agent reading — three fixed slots, flush right, on the system palette (2026-08-11, user-directed)

The sidebar's traffic-light strip carried nothing but the lights. It now carries `RailStatusRollup`
— *is anything at all waiting / working / finished right now*, with no counts, no names, no ranking.
It exists for the rows the column CANNOT show: scrolled past the fold, or hidden behind a live
search query. It is deliberately NOT filtered by that query, because a filter hiding a waiting agent
is exactly when it earns its place. Tapping it is a second door onto ⌘⇧U's own walk, never a second
implementation, and it is hit-testable only while something actually waits — a control that
sometimes does nothing is worse than no control.

**⚠️ This is not Round 11's titlebar pip returning.** That pip stood on the CONTENT side and
restated, in a second vocabulary, what the visible rail was already naming pane by pane. This stands
on the navigator's own ground, in the rail's own marks, for the rows the rail is not showing.

**⚠️ It must stay a LEAF.** Resolving each row's chrome touches the store's volatile per-pane dicts;
doing it inside `NavigatorColumn`'s body would register every one as a dependency of the sidebar body
and bring back the re-render storm `RailRowsMemo` exists to kill — the same rule
`ConnectionStatusMount` carries. Rows arrive as a STRUCTURAL parameter.

Three things were then corrected on hardware, in the order they were seen:

**1. ALL THREE MARKS ARE ALWAYS DRAWN.** It shipped as a cluster that appeared and collapsed with
the news, on the argument that a strip bare by design must stay bare. What that produced was a
widget whose WIDTH and CONTENTS both moved, so the reader had to re-identify the marks on every
arrival — and a mark's POSITION said nothing, because which mark sat where depended on what else was
lit. Three fixed slots make the cluster a LEGEND that is sometimes lit: the hand is always in the
same place and the eye learns it once. An unlit slot keeps its silhouette and gives up both things
that carry state — the hue goes neutral (`Text.tertiary` at `Opacity.dim`, the "ruled-out hint
letter" pairing) and the one mark that moves is FROZEN. Deliberately neutral, not the state's own
hue faded: a dimmed amber is still amber, and three washed-out hues read as three states
half-happening rather than one legend with one entry lit. Freezing goes through `AgentSpinner`'s
`pinnedPhase: 0` — the same still Reduce Motion asks for, through the same one parameter, so a
disabled slot and an accessibility freeze can never become two drawings of "not moving".

**2. IT ENDS ON THE COLUMN'S GUTTER.** It stood 18pt further in, on the rows' MARK COLUMN
(`space2 + projectIslandInset + islandRail`), on the argument that it read as the head of that
column. On hardware it read as a cluster that had failed to reach the edge — the search plate
directly under it is the nearer and far stronger line. `trailingInset` is `space2` now, and the
search plate reads THAT constant rather than spelling `8` again.

**3. THE MARK COLUMN WAS MOVED TO THE SYSTEM PALETTE AND MOVED BACK, THE SAME DAY.** The proposal
(`StatusPresentation.markInk`, systemOrange / systemYellow / systemGreen for the three marks, with
the row TITLE and the git line keeping `StatusInk`) reversed, for the marks only, the argument
`StatusInk` was written on — "a ring mark 10pt across is the thinnest thing in the rail that carries
state". The reasoning was that the ink tier is solved on the DEEPEST PROJECT BED, the worst ground a
git line ever stands on, while the mark column stands on ONE determined ground; and that the tier is
a six-hue ramp built to keep seven git runs apart AT ISO-LIGHTNESS, while the mark column has three
readings that need to RANK. It also bought the collision the thinking mark has carried a written
warning about since it took herdr's yellow: working and awaiting were ONE ink, held apart by
silhouette and motion alone.

**It lost on the measurement the ink tier exists for.** On the cream, systemOrange measures 2.23:1,
systemGreen 2.14, and systemYellow — the thinking cell, the one mark on this rail that has to be
seen across a room — **1.46**. The unlit slots this same round introduced measure 1.60, so the
FROZEN GREY spinner came out louder than the running yellow one. The counter-argument (hue ranks
them, not luminance: one saturated mark among two achromatic ones wins the eye at equal contrast)
is true and was not enough. Reverted on hardware, user-directed, hours later.

⚠️ The ground under the marks is what would have to change for this to come back — not the argument.
`markInk` and `Slate.Status.working` are gone; there is no second tier to keep in sync, and
`attentionInk` is the one answer again. The working/awaiting hue collision stands, separated by
silhouette and motion as before.

**4. EACH MARK IS ITS OWN BUTTON, AND THE GAP DOUBLED.** *"bấm vào cái giữa (running) lại nhảy sang
cái blocked, bấm vào cái done cũng thế"* — the cluster shipped as ONE tap target over the whole
`HStack`, calling the attention walk, which ranks needs-permission above everything else. So the
spinner and the check were live, took the click, and silently landed on the blocked pane. Three
marks that all do one thing are one button wearing three faces, and the face the pointer chose was
the one part of the gesture that carried no meaning.

Each slot is now its own hit box, and each jumps into the state it is LIT FOR — derived from
`matches(_:_:)`, the same predicate that decides whether the slot is lit, so a lit mark always has
somewhere to go and an unlit one is inert by construction rather than by a second rule that could
drift. Repeated clicks WALK that state's panes (`nextPane(in:focused:)`, wrapping, restarting at the
head when focus is elsewhere) instead of pinning its first one — the rollup answers "another one"
the way ⌘⇧U does, but scoped to the mark that was clicked. Clearing the badge stays scoped too: a
waiting or finished jump clears, a WORKING jump does not, because arriving at a thinking agent has
not resolved anything.

The same report named the cause the pointer had to fight: `markGap` was `space1`, 4pt, and at 4pt
the three read as one object. It is `space2` now. The gap is dead space by construction — a mark's
hit box is its own `StatusDot.footprint` and never the half-gap beside it — so widening it buys
separation for the EYE without making a near-miss land on a neighbour.

**5. WHEN THE COLUMN GOES, THE CLUSTER FOLLOWS THE TOGGLE.** *"để khi collapse, thì 3 cái nút trôi
về cạnh nút collapse sidebar"* — the rollup was mounted inside `NavigatorColumn`, so collapsing the
navigator took the agent reading away with it, which is precisely when a reading of panes you cannot
see is worth most. It now hangs off the WINDOW ROOT beside `WindowSidebarToggle`, for the same
reason that button does (`WindowSidebarToggle`'s header): a view parked inside either column RIDES
the split's slide.

`RailStatusRollupMount` owns the geometry and the travel. Expanded it parks so its TRAILING edge
lands on the navigator's gutter; collapsed it parks one `space2` right of the toggle's plate, and
the two are the same number when the column is narrower than the toggle's own row (`max` clamp) so
it can never slide under the traffic lights.

**⚠️ Follow-up, same day — the collapsed band already had a tenant.** The parking spot was correct
and empty-looking, and it was neither: `SlateTitlebar`'s horizontal tab strip starts on that exact
line, because it was reserving *the sidebar toggle's slot and nothing more*. Collapsed, the three
marks were drawn straight over the first tab's title (user-reported, screenshot). The strip's inset
is now `RailStatusRollupMount.collapsedTrailingEdge` — the cluster's own trailing edge plus one gap
— so the band's leading side is ONE sum owned by the mount rather than two views independently
deriving "where the toggle ends". The next control added there inherits the same clearance instead
of re-colliding.

⚠️ **The parked lead cannot be a constant** — the navigator item is RESIZABLE (220…360), so `220` is
right only at the default. The split controller publishes the live width through
`WorkspaceChromeState.navigatorWidth` from the resize notification it already answers, and the mount
— itself a LEAF, for its own volatile source this time — reads it. And the travel animates on
`sidebarCollapsed` ONLY, never on `navigatorWidth`: animating a continuous drag would make the
cluster lag the edge it is glued to, by exactly the animation's duration, on every frame.

## The terminal notices go to PAPER — the on-glass band cannot hold a chip (2026-08-11, user-reported)

Reported as "the notification popup of the terminal pane — characters copied, restore closed pane — is
ugly and sunken". Measured against the shipping profile, three of the chip's four layers failed: the
plate stood at **1.63 : 1** against the glass face, its rim at **1.49 : 1** against its own plate, and
the LABEL — the word saying what happened — at **2.19 : 1**, under even the 3.0 floor for non-text.
Only the detail run (9.16) worked. The 2026-08-10 `Terminal.rim` fix had only ever touched the border;
nobody had measured the ink.

⚠️ **It could not be fixed where it stood, and that is arithmetic rather than taste.** The whole
on-glass band — face `#22212C` to comment ink `#7970A9` — is **3.56 : 1 wide in total**, and a chip
needs three separable steps inside it. Every arrangement spends one to buy another: lifting the plate
to 2.95 drops the ink on it to 5.06 and leaves the rim at 1.22. There is no fourth rung to mint.

**This is the same wall ONE ISLAND already hit once, at the whole-app scale** — "any darker frame is
arithmetically stuck: `#22212C` against pure black is 1.32 : 1, so the whole dark half of the axis
cannot separate at all" (`DESIGN.md`), which is why the ground is Alucard's cream. The notice met it one
level down and takes the same way out. On paper every step passes with room to spare: plate **15.32**
against the glass, rim **9.57**, label **6.99**, detail **20.25**.

- ✅ **`SlatePaperCapsule`** — the floating family's one-line member: `Surface.field` cream, a capsule,
  `Line.overlayRim` (the family's rim VERBATIM — a second light-side rim solved for this shape is the
  drift the `Opacity` ladder exists to prevent), the `.chip` shadow. Bought for the case that needs it:
  where the capsule crosses BRIGHT output the cream itself falls to ~1.03 and the rim (1.32–1.86 there)
  plus the cast are the only things carrying the boundary.
- ✅ **Taking the paper means taking the family's VOICE — one decision, not two.** The floating family's
  ink is the system's neutral semantics in sentence case, and its caps-mono eyebrow was rejected
  wholesale the same week the form cards shed theirs. So `COPIED · 1,204 CHARS` → `Copied · 1,204
  characters`. "CHARS" was an abbreviation the caps register needed to stay narrow; a proportional face
  at reading size does not. The instrument register is the GLASS's voice and this no longer stands there.
- ✅ **Hierarchy is size and weight in ONE voice, never ink alone.** The old chip set both halves at the
  same size, face and weight and asked COLOUR to carry the entire distinction — which is how a label at
  2.19 could read as designed rather than as broken. `NoticeCapsule` is the one rendered form behind both
  chips, so they cannot drift; the DETAIL is the dominant half in every notice this family carries (the
  count answers "did I get all of it?", the chord answers "how do I undo that?").
- 🔁 **RE-SCOPE (user-directed): ONE mount. The copy receipt no longer confirms itself inside its pane.**
  Pane-scoped copies drew bottom-trailing IN the pane on a "feedback lives at its trigger" rationale
  while pane-less ones drew at the island's foot — one event, two homes, both to be learned. The pane
  still OWNS the receipt (it is the pane's state); only the mount moved, reached through the new
  `WorkspaceStore.activePaneCopyReceipt()`. ⚠️ The chip's dwell is therefore keyed on the WHOLE
  `CopyReceipt`, not on `epoch`: one mount is now fed by two independent counters, so two copies can
  carry the same epoch number and the chip would inherit the dead one's nearly-elapsed timer — the exact
  bug epoch exists to prevent, arriving by a new route.
- ✅ **ONE SILHOUETTE, TWO MATERIALS — the line is DURATION.** A notice ARRIVES and leaves, so it is
  paper; `ConnectionAlertChip` LIVES at the foot for as long as a pane is down, and a cream plate glowing
  over the terminal for minutes is the glare a 1.5 s capsule is too brief to cause. It keeps the glass
  palette but takes the capsule's shape, padding and type size, so the material difference reads as a
  ROLE rather than as two unrelated chips stacked by accident. ⚠️ It carried the **2.19 : 1** label
  bug too, unnoticed, while announcing that a connection was DOWN — its label is `Terminal.ink` (9.16)
  now, the only rung on the glass that clears the plate.
- ✅ **`InstrumentChipShell` survives with ONE mount: the divider's live ratio readout.** It did not
  follow, because it is not a notification — it is an instrument readout under the pointer DURING a drag,
  gone when the gesture ends, and it never had the legibility bug (its numbers are `Text.primary`, white
  on the plate). A cream capsule blooming under the cursor mid-drag is exactly the glare the notices are
  short-lived enough to avoid.
- ⚠️ **`Slate.chromeColorScheme` — the ink has to climb back OUT of the glass, and the first build shipped
  white on cream.** The capsule is mounted on the pane canvas, INSIDE the subtree `glassColorScheme` has
  forced dark, so `SlateOverlayInk` (semantic, polarity-following) resolved for the dark well and drew an
  unreadable capsule with a perfect surface. Caught by the `testRenderIslandChips` snapshot before it
  ever ran. The fix is the SELECTED TAB's move in the other direction — a compact island flips its row to
  the glass polarity "so every ink on it resolves against the plate it stands on". One rule, both ways:
  **the scheme follows the PLATE, not the ancestor.** Not a third appearance — the app still has two
  polarities and one `NSApp` pin; this is that pin, restored for an object that stepped off the glass.
- ✅ **The chord is a KEY, not two words in bold** (`ChipNotice.keycap` + `NoticeKeycap`). `Tab closed ·
  ⇧⌘T reopens` set the whole answer as one semibold run, which made the chord read as emphasis rather
  than as something to press; the family already had the opposite rule ("a key you can press right now is
  drawn as a KEYCAP", `DESIGN.md`) and this was the one notice that ignored it. Five treatments were
  rendered side by side and the winner puts the CAP on the hero rung with both text runs quiet — the
  label frames it, the trailing verb only says what pressing does, and there is exactly one hero. Two
  consequences fall out of that: a notice carrying a cap **drops the `·`** (a keycap is already a
  boundary object, so the dot would be a second separator doing the first one's job — the dot earns its
  place only where there is no cap, as in `Copied · 100 lines`), and the cap is **not** `SlateKeycap`,
  which is built ``Metric/heightControl`` tall for a palette LIST ROW and inflates the capsule to ~40pt.
  The face and the plate are shared deliberately (a key is a key everywhere, and never mono); the height
  follows the text line and the ink goes up a rung. VoiceOver has no keycap, so `accessibilityText`
  rejoins it as plain text in the drawn reading order: `Tab closed · ⇧⌘T reopens`.
- 🐞 **`strokeBorder` whiskers a shape whose corner radius reaches half its height — clip, or it ships.**
  The rim left a stray vertical TICK a point or so outside each horizontal extreme, where the two arcs
  meet. Isolated by rendering the chip four ways at NATIVE scale (the 3× snapshot is an interpolation, so
  an artefact seen only there proves nothing): with the border and without, inside a `Button` and bare.
  The ticks tracked the BORDER alone — `Button` was innocent, and a plate at a radius small enough to fit
  inside its own height never had them. `.clipShape` to the same shape is the fix and keeps a true
  capsule; an inset `.stroke()` was tried and still ticks. ⚠️ It belongs to the SILHOUETTE, so both
  members carry it: on the cream the same defect is there and merely too faint to see, and it was only
  ever CAUGHT on `ConnectionAlertChip` because that is the member whose rim has real contrast.

## A running agent stops dying because we edited the host (2026-08-11, user-directed)

✅ **Decided — and it reverses a written non-goal.** `docs/45` §8 listed "live-process survival
across a hostd restart" as out of scope, and the disk-journal decision above said "explicitly NOT a
sessiond" on the reasoning that the TRANSCRIPT can survive the daemon while the process cannot.
That reasoning was sound for the problem it was solving (history loss) and wrong as a general
ruling. The user reported the real cost: any host-side edit means killing every running agent, so
host changes get batched, delayed, and made in bigger and riskier lumps than they should be. The
tooling was shaping the work.

**What changes.** A new `slopdesk-superd` LaunchAgent forks the pane shells and keeps each PTY master
fd open for the pane's life, handing hostd a duplicate over `SCM_RIGHTS`. hostd's byte path is
untouched — it reads, resizes and `tcgetpgrp`s the same kind of fd it always did, with no extra hop
and no relay. hostd's exit closes only its duplicate, so the fd refcount stays above zero and the
shell never sees the `SIGHUP`. → [51]

**Two things were verified by running code before any of this was designed**, because both could
have killed it:

1. A PTY master survives `SCM_RIGHTS` with every power intact — `read`, `TIOCSWINSZ`, and
   `tcgetpgrp`, which is the primary agent-detection signal. The `CMSG_*` macros are invisible to
   Swift but their arithmetic is hand-rollable, so **no second C target** is needed and the "only C
   is `CSlopDeskSIMD`" invariant survives.
2. The pane survives its fd-holder's death **only if someone else still holds the fd**. A
   supervisor that hands off and closes is worse than useless: it hangs up the shell at exactly the
   moment it was supposed to save it. superd holds its copy and never reads it. Across the gap the
   kernel PTY buffer backpressures the writer rather than dropping — the same mechanism
   `PTYReadLoop`'s pause gate already leans on, which is why superd needs no ring buffer.

**The non-obvious half was the sockets, not the fd.** `SLOPDESK_SOCKET_PATH` and
`SLOPDESK_CONTROL_SOCKET` are keyed by hostd's pid and baked into the child env at spawn. A
restarted hostd binds a *different* path while the running `claude` still holds the old one, and
the hook relay's failure mode is `ConnectFailed` → exit 0, silently. So the agent's authoritative
feed would have been lost permanently, not just during the gap — a pane that survives with tier 1
dead is a worse outcome than an honest restart. Both sockets therefore move to superd at stable
paths. Same for `SLOPDESK_PANE_ID`: it is derived from `(connectionID, channelID)`, so it must be
**recovered from superd on adopt, never re-derived**, or hook POSTs route nowhere.

The general rule this leaves behind, which is the part worth keeping: **hostd's pid may not appear
in anything a live child remembers.** That single test decides what belongs in superd, and it is why
the split is one small boundary rather than the subsystem-by-subsystem carve-up the request could
have been read as. Splitting detection or the workspace into their own daemons buys nothing once
restarting hostd is free.

**Rejected alternatives.** *Relay the bytes through superd* — no unsafe code, but it puts an AF_UNIX
hop on every keystroke and every output byte, needs the `SO_SNDBUF` fix (2026-08-10), and turns
`tcgetpgrp` into a polled IPC verb; fd-passing leaves all of it alone. *`execve` in place* — keeps
the pid, needs no new daemon, but cannot survive a new binary that fails to boot, and during host
development that is not a rare event; it also does nothing for a hostd that crashed.

**The cost, stated plainly.** superd's own crash still takes every pane with it — fd custody dies with
the custodian and launchd cannot inherit it. That is inherent, and the mitigation is that superd is
small, dependency-free, and does nothing per byte. And because superd outlives hostd's *build*, the
superd↔hostd protocol is the one place in this codebase that must tolerate version skew: append-only,
version in `hello`, unknown verbs answered `unsupported` rather than dropped. The three wire paths
are frozen because both ends ship together; this one negotiates because they do not. → [51 §3]

## superd reads the master; only `read` moves (2026-08-11, user-directed)

✅ **Decided — and it reverses one sentence of the entry above, written the same day.** That entry
rejected relaying bytes through superd for two named reasons, and both were right: an `AF_UNIX` hop
on every keystroke, and `tcgetpgrp` — the zero-config half of agent detection — becoming polled IPC.
It then said superd "holds its copy and never reads it", and justified that with "across the gap the
kernel PTY buffer backpressures the writer rather than dropping".

That last clause is true and was the wrong thing to be satisfied by. **A PTY buffer is a few KB.**
Between hostd's exit and the next hostd's `adopt` nobody is reading the master, so the child's next
`write` blocks there, and the `claude` superd had just saved from `SIGHUP` spends the entire restart
frozen at whatever line it had reached. The pane survived; the agent stopped. The user asked for the
agent to keep working, and "does not die" was only most of that.

**What changes.** Every pane gets a reader thread in superd (`pump.rs`) that drains it for the
pane's whole life, attached or not, into an offset-addressed ring (`ring.rs`). hostd `subscribe`s
and receives binary output frames. `Sources/SlopDeskHost/PTYReadLoop.swift` is deleted. → [51 §6.5]

**Both original objections survive intact, because only `read` moved.** hostd keeps its `SCM_RIGHTS`
duplicate and still uses it for `write`, `TIOCSWINSZ` and `tcgetpgrp`. Keystrokes go hostd → kernel
with no hop; the foreground process group is a syscall, not a verb. The rejected design was
*relaying*, which is bidirectional; this is one direction, and the direction that was already
one-way to a queue.

**The four rules that fell out, none of which were obvious in advance:**

1. **Losing the last subscriber clears the pause.** hostd asserts backpressure when a channel's
   output queue fills, and superd is now what stops reading. But a hostd that dies mid-flood leaves
   that pause behind, and a pause nobody is left to lift would freeze the very pane this daemon
   exists to carry through a restart — the same failure, arrived at from the other side.
2. **Eviction is announced, never silent.** `subscribe` answers with the offset the stream *actually*
   resumed at, not the one that was asked for. A terminal stream spliced across an unannounced hole
   renders a screen that is *wrong* rather than merely short, and nothing downstream can tell.
3. **The reaper drains the pump before broadcasting `exited`.** Two independent threads would
   otherwise race, and a shell's farewell output would arrive after the session meant to show it had
   been torn down — about half the time.
4. **`waitUntilExitedDrainingMaster` had to stop draining.** It existed because nobody read the
   master between `hangup()` and the `SIGKILL` escalation, which wedges a zsh blocked in
   `tcsetattr(TCSADRAIN)`. The pump makes that premise false, and keeping the drain would make it a
   *second* reader stealing bytes on a file description `SCM_RIGHTS` makes shared — and one that
   sets `O_NONBLOCK` on superd's reads as a side effect.

**Rejected while doing it.** *Move the on-disk scrollback journal too* — it is the obvious next
brick and it would drag `AltScreenCutScanner` into two languages, because `ReplayBuffer`'s eviction
is its other caller and lives in the transport module the client links. One implementation or
neither; the journal moves when the ring does. *Base64 the output inside the JSON reply* — a third
more wire and two more copies on the hottest path this socket has, to avoid one tag byte.

**The cost, stated plainly.** Output now crosses an `AF_UNIX` socket on its way to the transport,
where before it went kernel → hostd directly. It is one hop on a path that already had a queue, a
FIFO and a drain task on it, and `SO_SNDBUF` is the thing to watch if it ever shows up in a
measurement (2026-08-10). The keystroke path — the one latency actually lives on — is untouched.

## superd binds the child-facing sockets and hands hostd the accepted connection (2026-08-11, user-directed)

✅ **Decided.** The two sockets a spawned child is told about — the Claude-hook socket
(`SLOPDESK_SOCKET_PATH`) and the agent-ctl socket (`SLOPDESK_CONTROL_SOCKET`) — are now bound by
superd for its whole life. hostd sends `listen` naming the kinds it will serve, and superd passes
each **accepted connection** over `SCM_RIGHTS` as a `connection` event. → [51 §6.6]

**Why the path fix was not enough.** The entry above dropped the `-<pid>` suffix so a child's
`execve` snapshot would still name a real address after a restart. But an address is only a promise
to be *listening* at it, and the listener was hostd. The name was stable and nothing was behind it,
which is the same bug one layer down and just as silent — a hook POST to a dead socket costs a
`claude`'s authoritative feed and nothing logs an error.

**Only the `bind` moved, deliberately.** superd reads no byte of either protocol. The hook record
parser, the Claude state machine, the `tool_use_id` ledger and the dissent watchdog stay in hostd,
which is the process that has the state they need. The alternative — moving the protocols too —
either duplicates them in Rust (against the one-implementation rule) or makes superd a relay, which
is the thing §8 says it is not.

**Unclaimed is not unbound.** Both sockets are bound always; whether a hostd is behind one is
separate state, and it gates exactly one thing: whether the path is advertised into a child's
environment. Advertising an address is a promise to be listening at it. This is also how the
default-off `SLOPDESK_AGENT_CTL` flag survived without leaking into superd — off means hostd does
not *claim* `control`, and superd never learns the flag exists.

**Rejected: queue the record until a hostd attaches.** The peer is Claude Code's hook binary and it
**blocks its agent** until its write completes, so a fast `EPIPE` beats a wait. The lost record is
self-healing — `lastAuthoritativeAt` goes stale, coverage is revoked, the screen engine takes over
(`docs/50`). A hung `claude` is not.

**Scoped out, with a reason rather than by omission: `CodeBridgeServer` and `InspectorServer` stay
in Swift.** Both are TCP, neither is addressed into a child's environment, and neither holds a
long-lived child process — so the rule that produced this whole boundary ("hostd's pid may not
appear in anything a live child remembers") does not reach them. Moving them would be a rewrite with
real risk and no benefit; a restart already costs them nothing but a reconnect.

## An exited pane keeps its output long enough to be read (2026-08-11)

✅ **Decided — a defect the entry above exposed, not a design choice made freely.** Once `read` was
superd's, a pane's bytes lived in that pane's ring, and the pane died the instant its child was
reaped. hostd subscribes only *after* the `spawn` reply travels back to it, and
`slopdesk-ctl spawn --cmd ls` finishes well inside that window: the `subscribe` found no pane, and
the pane rendered **empty**. Not slowly, not partially — nothing at all, reliably, for every command
fast enough to win the race.

**The fix is two halves.** superd's reaper moves the ring (never an fd) into a bounded 16-entry
graveyard before it broadcasts `exited`, and `subscribe` falls back to it; `release` evicts. And
`StreamPosition.ended` tells a late subscriber the stream is finished, because the `exited` notice
that normally ends it was broadcast before that subscriber existed — without the flag hostd renders
the backlog and then waits forever for an end that already happened. → [51 §6.5]

**Rejected.** *Auto-subscribe the holder inside `spawn`* — hostd's handler is not wired at that
point, so the frames would be dropped by the client instead of by superd. *Buffer unhandled frames
in `SupervisorClient`* — unbounded, on the hottest path this socket has. *Keep exited panes in the
main pane table until `release`* — every pane lifetime edge would grow a "but is it dead" branch,
and a hostd that never released would leak them forever.

## The panel backends are supervised panes too (2026-08-12)

✅ **Decided — reversing `docs/51` §8, which had listed this as a non-goal.** The old reasoning
asked how a new hostd would *find* code-server again (it is addressed by port, not by fd — read it
from a state file) and never asked why it had to. The answer was `HostServer.stop()`, which
**terminated** both backends: every host edit bought the user a Node reboot in the code panel and a
dead simulator server, on the surface they look at most, for the entire life of this project.

The fix is `SupervisedServiceProcess`, ~190 lines, because the output ring had already done the hard
part. Spawn-or-adopt under the stable pane id `service:<name>`; on adopt, **re-learn the port from
the child's own announce line** by replaying the ring from offset 0 — no state file, no port
handshake, nothing to go stale. `stop()` calls `relinquish()`; only a deliberate stop calls
`terminate()`. → [51 §6.7]

**Held on a PTY on purpose.** Both backends were checked on a real terminal first: neither
colourises, neither moves its announce line, and the only difference is `\r\n`, which
`LineAssembler` strips. A second, pipe-flavoured spawn primitive would mean a second pre-exec window
beside the disassembly-pinned one (`fork_window_contract`) — to buy a carriage return.

**Found on the way:** `CodeServerManager.bridgeSocketPath` carried `getpid()`. Harmless while hostd
killed its own backend on every restart; fatal the moment one survives, since a child cannot be told
a new environment. Now stable, and `check-supervisor.sh` §7 ratchets every socket path in `Sources/`
rather than superd's three.

**Rejected.** *Porting the managers to Rust* — 5,337 lines of settings seeding, extension install,
port parsing and readiness probing, none of which is supervision; the injected `Spawner` seam meant
only the fork/hold/reap had to move. *A state file recording the port* — the child already says it,
every time, and the ring already keeps what it said. *Supervising the Android bridge* — nothing
there is a held child: the bridge is an in-process listener, `adb` calls are sub-second, scrcpy is
tied to sockets hostd holds anyway, and the emulator was already deliberately orphaned.

## The restart is one command, and the reload is the restart (2026-08-12)

✅ **Decided — the last piece of `docs/51`, and the one about the person rather than the process.**
Everything before this made a hostd restart *cheap*: panes, both child-facing sockets and the panel
backends all live in superd now. What was still expensive was the ritual — find the process (`pkill`
matching too much is a written-down trap), wait, remember the flags, notice that `--port 0` bound
something else. A restart that is technically free but takes four steps still gets postponed, which
was the original complaint.

So hostd states its own launch — `HostLaunchRecord` → `hostd-launch.json`, written once the listener
is up, removed on the orderly stop — and `scripts/restart-hostd.sh` (`make host-restart`) reads it.
Two fields exist because only the process can know them: the **bound** port, and the physical path
of the running executable (`_NSGetExecutablePath`, symlinks resolved, so it matches the `lsof -d txt`
the script confirms the pid with — `argv[0]` is the relative `.build/release/…` and would not).
Measured downtime **0.2 s**, superd's child count unchanged across it. → [51 §9]

❌ **Live config reload — rejected, and not narrowly.** It was the obvious companion: SIGHUP, re-read
the flags, no restart at all. `EnvConfig.overlay` is a deliberately lock-free write-once global, set
at `main()` before any `static let` is forced and read on the video pipeline's hot path by the
golden-pinned controllers; making it mutable means a lock *there*, to save a restart that now costs
0.2 s and kills nothing. The hostd toggles argue the same way from both sides: `ipcAllowSendKeys` and
`ipcAllowSensitiveSessions` are already re-read per request, while `blocksEnabled`,
`agentControlEnabled` and `preventSleepEnabled` thread into construction, so a live flip would
half-apply and leave sessions disagreeing about the rules.

**Rejected.** *`pkill` in a Makefile target* — the trap this replaces. *Reconstructing the launch
from `ps`* — `-o comm=` is argv[0] as typed, `-o command=` loses argument boundaries, and neither
knows the environment. *A `--port` flag on the script* — the record already holds the bound port,
and a second source of that answer is how they drift.

## What is left in Swift stays in Swift — measured, not assumed (2026-08-12, user-directed; the inspectord half REVERSED the same day, see below)

✅ **Decided.** After superd, screend, dropd and androidd, the standing instruction was to keep going:
move whatever is better in Rust, and split whatever can be dialled directly. This entry is the audit
that answers "what is left", and its conclusion is mostly **stop** — which is a result, not a
retreat, because every part of it is a number rather than a taste.

**The rule in `CLAUDE.md` was gating on the wrong thing.** It justifies Swift by "a macOS framework
with no usable C ABI: AppKit/SwiftUI, ScreenCaptureKit, VideoToolbox, Network.framework". Three of
those four are wrong on the facts: Network.framework IS a C API (`nw_connection_t`), VideoToolbox IS
a C API (`VTCompressionSessionCreate`), and ScreenCaptureKit is Objective-C, which `objc2` reaches.
Read literally the rule permits almost everything to move. The honest floor is much smaller:
**SwiftUI/AppKit in the client** (49k lines of `SlopDeskClientUI` + 36k of `SlopDeskWorkspaceCore`),
and in hostd exactly **four files** — `PreventSleepAssertion`, `InspectorServer`,
`HostPathActionPerformer`, `HostClipboardPerformer` are the only ones importing AppKit/Network/IOKit.
(Later the same day: `InspectorServer` is gone — see the reversal below — but `RepoStatusWatcher`
belongs on the list too, on CoreServices/FSEvents. So the count is unchanged at four:
`PreventSleepAssertion` (IOKit), `HostPathActionPerformer` + `HostClipboardPerformer` (AppKit),
`RepoStatusWatcher` (CoreServices). Re-verified 2026-08-12 after the ctl port.)
Everything else is Foundation, and could move. The question is therefore never "can it" but "does
the number say to".

**The hot path was measured, and it is not a ceiling.** `MuxChannelSession.ingestPTYChunk` is the
last per-byte Swift on a hot thread: every byte a pane produces crosses `HostOutputSniffer.observe`
(OSC title/bell, OSC 133, OSC 7, OSC 9;4) and `CommandBlockSegmenter.ingest` on the read loop.
`slopdesk-sniffbench` times both over the same corpus `slopdesk-replay-bench` uses, in production
32 KiB reads (`PaneOutputStream.readChunkSize` = superd's `pump::READ_CHUNK_BYTES`):

| stage | throughput (64 MiB, median of 3) |
| --- | --- |
| `HostOutputSniffer.observe` | **614 MiB/s** |
| `CommandBlockSegmenter.ingest` | **118 MiB/s** |
| both, as the read loop runs them | **99 MiB/s** |

A pane's real output peaks in the single-digit MiB/s. 99 MiB/s is one to two orders of magnitude of
headroom, so a Rust port buys nothing measurable — and the standing instruction is explicit that a
move which does not improve performance should not happen. Contrast the case that DID justify a
move: `TerminalScreenModel` ran at **17.9 MiB/s** and a cold reattach composed the whole retained
ring through it, so a 64 MiB ring was 3.5 s of hostd's main work before the phone saw a byte
(`docs/52` §1). That is a ceiling; this is not. The bench stays in the tree so the next person can
re-ask instead of re-guessing.

⚠️ **The segmenter's 118 was an ITERATION defect, not a language one — 2026-08-12, later the same
day.** The bench did exactly what it was left in the tree to do: the next person re-asked, and the
5× gap between two state machines of the same shape on the same thread turned out to be the
`some Sequence<UInt8>` signature. A `Data` chunk iterated through a non-specialized indexing path
into a byte-at-a-time `append`; the sibling sniffer took `Data`, called `withUnsafeBytes` once, and
`memchr`d its way between escapes. Giving the segmenter the same shape — plus a bulk `appendContent`
whose cap arithmetic reproduces the per-byte rule rather than approximating it — moved it to **375
MiB/s** and the read loop to **232 MiB/s**, pinned by a differential test that runs the same stream
through both overloads at five caps × five chunk sizes. The verdict above is unchanged and now rests
on a bigger margin, but the reasoning it models needs one clause added: **before a slow Swift number
is allowed to argue for Rust, read the Swift.** The gap here was not in the grammar, the allocator
or the language — it was one generic parameter, and a port would have carried the defect across and
credited the win to Rust.

🔁 **Both halves moved anyway — 2026-08-13, and NOT on throughput.** The numbers above are still
right and still not a ceiling; what they measured stopped being the question once superd's pump
became the first reader of every byte, which made these a SECOND pass over the same stream in a
second language. See "The sniffer belongs to the reader that already has the bytes" below.

🔁 **`slopdesk-inspectord` — dropped on a throughput argument, then BUILT once the rule changed
(same day).** The original verdict is preserved above the line because the facts in it are still
true: the inspector is off by default (`--inspector` / `--transcript`), the hook feed was never
connected to it (`main.swift` never called `InspectorEngine.ingest(hook:)` — hooks go to detection
only), the subagent watcher was passed `nil`, and per-pane transcript discovery was still deferred.
What changed is the RULE those facts were weighed against. The user's directive — *"nếu ngang perf
thì cũng có thể chuyển sang rust được, vì rust safety hơn, nhẹ hơn, và là ngôn ngữ hiện đại hơn"* —
makes parity sufficient and only a measured REGRESSION disqualifying. Under that rule "it would not
be faster" stops being an argument, and what remains is an argument the throughput framing had
hidden entirely: **the inspector's state died with every `make host-restart`.** The tail, the fold
and the whole 50 000-event replay window lived in hostd's address space, so a client reconnecting
after a 0.2 s rebuild asked for `subscribe(fromSeq: 0)` and got an empty history for a session that
was still running. That is the same argument dropd won on — blast radius, not benchmarks — and it
applies whether or not the flag is on today. Built as `rust/slopdesk-inspectord` (`docs/54`), with
the ten Swift files it replaces deleted and ratcheted in `check-supervisor.sh` §12.

Two things the port did NOT carry over, both deliberate. `EventBuilder.ingest(hook:)` was deleted
rather than translated — nothing in production called it, and a separate daemon cannot receive a
hook record at all, so porting it would have invented a capability to keep a dead one alive. And the
Swift `InspectorSource` went with the rest: it was the host END of the wire, and keeping it "just
for the tests" is exactly the cross-language mirror the one-implementation rule forbids. The tests
that used it now hand-build the wire bytes, which is the stronger pin anyway — a round trip through
one codebase's own encoder and decoder passes just as happily when both have drifted.

Related correction to an earlier claim in the same session, unaffected by the reversal:
`readAgentSession` (verb 8) can return 15 MiB on the same TCP connection as keystrokes, but it has
**no caller in the client** — so it is a latent capability, not live traffic, and it does not justify
a daemon on its own.

**Crates, if a framework port ever happens.** ObjC surfaces: BUY. `objc2` is 36.7M downloads/90d,
pushed daily, and `objc2-screen-capture-kit` 0.3.2 covers the SCK types — hand-rolling `objc_msgSend`
for ScreenCaptureKit would be its own project. C surfaces: WRITE OUR OWN. The third-party
`videotoolbox` crate has **2,709 downloads in 90 days, one contributor, zero PRs, eighteen releases
in three weeks**; VideoToolbox is a C API and we would use ~15 entry points, so `extern "C"` is ten
lines and no dependency. Same verdict for `axuielement` (982 downloads/90d) — Accessibility is C too.
`screencapturekit` (doom-fish) is rejected on churn: v6 → v7 → v8 in seven weeks. `cc-rs` turns out
to have no job here at all: the only C in the tree is `Sources/CSlopDeskSIMD`, and that must NOT move
(`SlopDeskVideoProtocol` is a leaf shared by host AND client, so a Rust GF(2⁸) would be the
two-language mirror the one-implementation rule forbids).

**Toolchain moved to 1.97.1 / nightly 1.99, and it broke a pin honestly.** rustc 1.97 switched the
default symbol mangling to `v0`, so `fork_window_contract`'s `nm` lookup for `spawn9spawn_pty17` —
where `17h<hash>` is *legacy* mangling — matched nothing and failed the pin with no code changed.
Fixed by matching the FUNCTION rather than a substring (`contains` finds thirteen symbols once
closures spell the same path): the tail after the path must be empty (`v0`) or exactly `17h`+16
hex+`E` (legacy). Both accepted, because the scheme is the compiler's choice and a pin must fail
when the window breaks, never when the name changes spelling. `nix` 0.30 → 0.31.3 in the same pass;
`libc` deliberately held at 0.2 (its `max_version` is `1.0.0-alpha.4`, and "latest" is not "alpha"
for the crate standing under every syscall superd makes).

## The screen tier of detection is screend's, and the clock stays hostd's (2026-08-12, user-directed)

✅ **Decided.** The manifest schema, its TOML parser, the region resolver, the rule engine, the
nineteen bundled manifests, the explain trace, the OSC tracker and the synchronized-frame tracker
moved into `slopdesk-screend` behind one new verb, `detect` (9), and were DELETED from Swift in the
same change — along with `slopdesk-detect-explain` (now `slopdesk-screend explain`) and
`ClaudeManifestMatcher`'s three tables of literal Claude cues, which were a SECOND screen matcher
living beside a nineteen-agent rule ladder. Its process-name half survives as `ClaudeProcessMatcher`.

**The roundabout it removes.** hostd walked every PTY chunk FOUR times for this: once across the
screend socket for the grid, then again in `AgentOscTracker`, again in `AgentSyncFrameTracker`, and
once more for ~20 `NSRegularExpression`s over the grid — which came back as JSON, ≈10 KB at 50×200,
per pane, every ~300 ms. Now one request carries the bytes, three walks happen on the far side, and
~150 bytes of verdict come back. The regexes stopped being a hazard on the way: the manifests match
against text a foreign program drew into a PTY, and `NSRegularExpression` is ICU BACKTRACKING, where
the `regex` crate is a finite automaton with a documented linear-time guarantee. The bundled rules
were authored FOR that crate upstream (`\x{2800}`, `\p{Alphabetic}`, `(?i)`, `(?s)`, no lookaround),
so the move improves fidelity with herdr rather than risking it.

**Where the line is, and why it is not "hot code".** *screend owns everything that reads the BYTES;
hostd owns everything that reads the CLOCK.* So the ladder, the regions and both trackers moved, and
`AgentDetectionHold` / `PaneScreenScanner` did not — the startup grace, the working→idle hold, the
blocked→idle confirmation count, the cap on an open synchronized frame and the scan cadence are all
decisions about time, and they belong next to the timer that measures them. `Verdict` therefore
reports `frameOpen` and `frameGeneration` as FACTS and lets hostd draw the deadline. Tier 1 (hooks,
ctl `report`) never touched this path and still does not (`docs/50`).

**Two things got better on the way, neither of them the point.** hostd now CACHES the verdict: it is
a pure function of (grid, OSC evidence, agent), so a tick that folds no bytes asks nothing at all —
where the Swift engine re-ran the whole ladder every tick against a snapshot it had already cached,
for any pane whose last verdict was not idle. And a failed exchange now publishes NOTHING. It used
to publish IDLE: `feedGrid`'s catch set `lastSnapshot = nil`, the evaluation read
`lastSnapshot?.detectionText ?? ""`, an empty screen matched no rule, and the known-agent fallback is
idle — so a dropped socket announced a finished turn, in a function whose doc comment said it
"publishes nothing".

**Proven before anything was deleted.** `scripts/herdr-differential.py`'s own corpus generator, run
through the Swift oracle and the Rust one across all 19 manifest agents plus `omp`, `mastracode` and
an unknown label, diffing state, winner, every `visible*` flag, skip/fallback reasons and — per
evaluated rule — `matched`, `region_bytes` and `region_preview`: **3656 screens, 0 mismatched.** The
harness now drives `slopdesk-screend explain` as the ported side.

**One behaviour delta, recorded rather than hidden.** The OSC and frame trackers live in screend's
bounded registry now, so a pane EVICTED at the 256-pane cap loses its retained title, where the
Swift trackers (in hostd, never evicted) kept it. It self-heals on the agent's next title emission,
and at that cap it is theoretical.

The manifests went back to being the TOML files they already are (`rust/slopdesk-screend/manifests`,
`include_str!`d), so `scripts/gen-bundled-manifests.py` is a copy rather than a Swift-source
generator — and it now REFUSES to overwrite a manifest carrying the `DIVERGES FROM herdr` marker.
That was a live hazard: `herdr-sync.sh` runs the writer unattended, so an upstream sync would have
silently deleted the two deliberate `claude` divergences, after which the differential would have
reported perfect parity because both engines were again running upstream's rule.

## uniffi-rs — evaluated on request, rejected on structure and then on a measurement (2026-08-12, user-directed)

> **The reopen clause below is VOID as of 2026-08-13** — see "The FFI ban was never the user's rule"
> at the end of this file. The structural table stays true (a daemon that must outlive hostd cannot
> be a library); the three-part reopen test does not, because it was written to guard a ban the user
> had not made.

The standing instruction was to look at [uniffi-rs](https://github.com/mozilla/uniffi-rs) and ask
which ported, in-flight or planned component could adopt it — *"review lại những phần đã port, đang
port hoặc sắp port xem phần nào có thể adopt uniffi-rs được"*. It was evaluated properly, and the
answer is none of them. Not because `CLAUDE.md` forbids FFI — that would be citing the rule as its
own justification — but because of what each component is.

**The tool is real.** uniffi 0.32.0 (2026-06-30), 10.6M downloads, Mozilla ships it in Firefox on
both mobile platforms, Swift is a first-class target. Pre-1.0 with ~266 open issues and an explicit
"advanced things might break as you upgrade", but nobody would be taking a risk on maturity. The
integration is the friction: it emits a C header, a modulemap and a Swift source, and the crate must
be built as a cdylib/staticlib and linked. There is no SwiftPM story — you either add a build plugin
that shells out to cargo, or you commit a prebuilt `.xcframework` as a `binaryTarget`.

**uniffi buys exactly one thing: removing an IPC hop from in-process, lifetime-coupled compute.**
That is the filter every candidate has to pass, and the ported services fail it on their own terms:

| component | why a linked library cannot be it |
| --- | --- |
| `slopdesk-hook` | Claude Code `execve`s it. It has to BE a program. |
| `slopdesk-superd` | Its entire purpose is outliving hostd — that is what stops a `claude` freezing across a restart. A library dies with its host. |
| `slopdesk-screend` | Two unrelated processes share one (`SlopDeskHost` + `SlopDeskCLICore`), the client starts one when none is listening, and a linked copy would put an unbounded VT parser inside the process that owns every keystroke. It also already answers a cold reattach at 186 MiB/s. |
| `slopdesk-dropd` | The client dials it directly, and a 4 GiB upload has to survive `make host-restart`. |
| `slopdesk-inspectord` | Same — the client dials it, and a session's replay window survives a host restart only because hostd does not hold it. |
| `slopdesk-androidd` | Same — the client dials the bridge port it learned from metadata verb 22. |
| `slopdesk-ctl` | A CLI. Its cost IS process startup; that is the thing being fixed. Shipped the same day — see the entry below. |
| the scrollback journal (planned) | Moves BECAUSE superd outlives hostd. Linking it back into hostd is the bug being removed. |

Every one of them was chosen for **lifetime independence** or **process identity**. Those are
properties a shared library cannot have, so the answer is structural rather than stylistic — and it
would be the same answer for `swift-bridge`, a hand-written `@_cdecl` layer, or any other FFI.

**One candidate did pass the structural filter, and a measurement killed it.**
`MuxChannelSession.ingestPTYChunk` is in-process by necessity: the read loop's two per-byte
observers are lifetime-coupled to hostd and a per-chunk IPC hop is the one thing that would be
slower, which is exactly the case where FFI's near-zero call cost is the whole argument. The
segmenter measured **115 MiB/s** against its sibling sniffer's **614 MiB/s** — a 5× gap between two
machines of the same shape on the same thread, which reads like a language ceiling and is the
strongest pro-uniffi datum this codebase had. It was not a language ceiling. It was
`ingest(_ bytes: some Sequence<UInt8>)`: a `Data` chunk went through a non-specialized iterator into
a byte-at-a-time `append`. Given the sniffer's shape — one `withUnsafeBytes`, a `memchr` run-scan in
`.ground`, a bulk append between escapes — it runs at **375 MiB/s**, and the read loop at **232**.
The only candidate uniffi had was a Swift bug worth 3.3×, and fixing it cost no new binary, no new
build system and no new failure mode.

**What adoption would have cost, had a candidate survived.** `swift build` on a clean checkout would
need cargo (the headless-build line is load-bearing: it is what keeps `swift test` runnable without
a toolchain zoo) or a committed per-architecture binary blob of our OWN source, which is a different
thing from pinning a third-party jar. Crash isolation goes: screend dying today means passthrough,
and a linked screend dying means hostd dying. And the shape stops being one shape — "a separate
binary over a socket" is currently true of six components with no exceptions, and an exception is
the expensive part, not the FFI.

**Note on what "never FFI" actually rules out.** It is not a ban on native code in-process:
`CSlopDeskSIMD` is a C NEON kernel linked straight into the client, and nothing about that is
controversial. The line is a foreign BUILD SYSTEM in the `swift build` graph. Rewriting that kernel
in Rust would be a lateral move that buys no instruction (NEON intrinsics either way) and pays cargo
in every clean checkout, so it is not proposed.

**Reopen it if**, and only if, a candidate appears that is (a) in-process by necessity, (b) measured
as a real ceiling after its Swift has actually been read, and (c) not fixable in Swift. Nothing in
the tree meets that today.

## slopdesk-ctl is Rust — the one port the uniffi review left standing (2026-08-12)

The table above listed `slopdesk-ctl` as planned, for a reason that is the exact inverse of every
other entry: the other six moved to escape hostd's lifetime, and this one moved because it has no
lifetime at all. An agent forks it once per `read`, `wait`, `write`, `run` — several times a minute,
sometimes several times a second inside a `wait` loop — and what it *does* is one `connect(2)` and
one line of JSON. Its cost is process startup, and nothing a faster algorithm could touch.

**The number.** 400 runs of `--help` each (which reaches `main`, formats, writes and exits, and
needs no host), medians, against `/usr/bin/true` as the fork/exec floor:

| binary | median | above the floor |
| --- | --- | --- |
| `/usr/bin/true` | 2.28 ms | — |
| Swift `slopdesk-ctl` | 5.74 ms | **3.47 ms** |
| Rust `slopdesk-ctl` | 3.01 ms | **0.73 ms** |
| Rust `slopdesk-hook` (reference) | 2.96 ms | 0.68 ms |

2.7 ms removed per invocation, and the port lands on the hook — which is the interesting part of the
measurement, not the ratio. The hook is 60 bytes and one socket write with **zero** dependencies;
this one parses thirteen subcommands, builds JSON and renders tables through `serde_json`. That they
cost the same says the 0.7 ms is the dynamic-loader floor for a Rust binary on this machine and the
CLI's own work is under the noise. It also settles the one design question the crate had: `serde_json`
is the single dependency, and it is free at startup (~100 KB of text, no initializers).

The Swift 3.47 ms is not Swift being slow at anything — the binary is 163 KB — it is
`libswiftCore` + `Foundation` being resolved and initialized before `main`, which is a fixed toll on
a program whose entire runtime is shorter than the toll.

**Parity was proved, not asserted.** An 87-case differential ran both binaries against the same fake
`AF_UNIX` server and compared four things per case: stdout, stderr, exit code, and *the request line
that reached the socket*. 86 are byte-identical. The one difference is deliberate and pinned by a
test: under `--json`, Foundation writes `"cwd":"\/tmp\/x"` and `serde_json` writes `"cwd":"/tmp/x"`.
Escaping `/` is legal JSON and pointless; every parser reads the two identically, and the Rust form
is what the other five daemons already emit.

Two behaviours were kept *because* they were the original's, not because they are good: `--help`
after a subcommand still overrides that subcommand, and a bare invocation still prints usage to
stdout and exits 2. A port that quietly fixes things is a port whose differential proves nothing.

**What the port bought beyond the milliseconds.** In the Swift original the subcommands called
`sendRequest` directly, so `main.swift` — every flag, every exit code, every rendered line, 907
lines of it — was compiled-and-reviewed only, and its 48 tests could reach nothing but the parameter
builders. The Rust one puts a `Control` trait between the subcommands and the socket, so the same
subcommands run against a fake in-process: **103 tests**, covering the flag parsing, the exit codes,
the rendering and the streaming rules that previously had no test at all. That was not the reason to
port, but it is the reason the port is worth more than 2.7 ms.

Three bounds the Swift lacked came with it: a 16 MiB cap on a single event line (`subscribe` could
previously grow one line without limit), saturation instead of a trap where `Int(Double)` met a NaN
timeout, and `sockaddr_un`'s 103-byte path limit checked before the connect rather than by it.

**The Swift is gone** — `Sources/slopdesk-ctl/`, `Sources/SlopDeskCtlCore/` and
`Tests/SlopDeskCtlTests/` were deleted in the same change, per the one-implementation rule, and
`scripts/check-supervisor.sh` §13 ratchets both that absence and the verb sets on the two ends of
the wire. The two NDJSON line helpers the *client* CLI still needed (`encodeRequestLine` /
`decodeResponseLine`) moved into `SlopDeskWorkspaceCore`'s `ClientControlProtocol`, which already
owned that CLI's method vocabulary — one module fewer, not one module renamed.

It lives in the ROOT cargo workspace with the hook rather than in its own, and that is the same
profile argument the daemons make in reverse: cargo profiles are workspace-global, the two
short-lived programs both want `opt-level = "z"` + `panic = "abort"`, and the five long-lived
per-byte daemons want the opposite. `make lint-rust` said six workspaces when this was written; the
wire crate below made it seven, for the same profile reason.

**The other CLI does NOT follow, and the number is the reason.** `slopdesk` is the obvious next
question — it is a CLI, it is short-lived, and it is *worse* on the same axis: **5.18 ms** of its own
above the same floor, because it links `SlopDeskWorkspaceCore` and drags AppKit and `Defaults` in
behind it. It stays Swift anyway, because startup cost is only a cost where something pays it in a
loop. `slopdesk-ctl` is forked by an agent several times a minute; `slopdesk` is typed by a person,
and the completion scripts it emits are static text that never re-invoke the binary. 5 ms in front of
a keystroke is not a ceiling, it is invisible. It also reads font-family names through
`CTFontManagerCreateFontDescriptorsFromURL`, which a Rust port would have to re-derive from the
`name` table and match Apple's answer on — real work in exchange for nothing measurable.

The rest of the tree was re-checked at the same time and had not moved: the PTY chunk path still
measures 633 MiB/s (sniffer) / 379 (segmenter) / 235 (both, the read loop), the same numbers the
"what is left in Swift stays in Swift" entry above recorded after the `some Sequence<UInt8>` fix. A
PTY that delivered even 10 MiB/s would be a pathological build log; there is no ceiling here to move.

## The scrollback journal stays in hostd; its resume point becomes crash-exact (2026-08-12)

> **REVERSED 2026-08-13** — see "The journal moves to superd after all, because the objection
> that stopped it was about a pane" at the end of this file. The reasoning below is kept for the
> record; its resume-point machinery no longer exists.

A standing task said to move the disk scrollback journal into superd and delete hostd's
`ScrollbackJournal`, on the reasoning that superd already owns every PTY master's `read` and its
ring already holds the same bytes, so one owner would collapse the resume-offset sidecar entirely.
Rejected on reading the thing being moved.

`ScrollbackJournal.swift:11-14` states the requirement the move would break: the journal exists
because every path ending in a fresh spawn — "hostd restart/**reboot**, detach-TTL eviction, shell
death" — starts on an empty transcript, and it is keyed by the **client session UUID**. superd is
keyed by **pane id**, and its panes die with the machine. After a reboot superd has no pane to hang
that transcript on, so the archive would have nowhere to live. The journal has to outlive every
process in the system, superd included; a daemon that dies with the machine cannot own it. (The same
reading kills the softer version — journal in superd, archive in hostd — which is two owners of one
byte history, i.e. the alignment problem it was meant to remove.)

**The bug that motivated the move is real, and is fixed in place.** The resume sidecar was written by
exactly one caller, `MuxChannelSession.relinquish()`. A hostd that is KILLED never reaches it, so
`HostServer.resumePointForSurvivor` had nothing to align the journal against and took the only safe
option left — keep the transcript, resume the stream from NOW — dropping every byte the pane produced
during the unclean window. Unbounded, since a hostd can be killed hours into a session, and silent,
because the gap is on the far side of the handover and no reader is there to log it.

`PaneOutputStream`'s `onChunk` now carries the offset each chunk ENDS at, and
`ScrollbackJournal.claimResumePointIfDue` writes the same sidecar from the flush path, rate-limited
to 250 ms. An unclean exit costs one claim interval instead of a whole session. The claim goes down
BEFORE the bytes it describes: the two writes cannot be atomic, and the failure modes are not
symmetric — a sidecar behind the file replays a region the next daemon already restored (re-feeding
the sniffer, the block ledger and the screen engine, and re-appending the duplicate to the journal,
so it compounds on every restart), while a sidecar ahead of it loses one interrupted flush and
nothing else. `docs/51` §6.8.

Worth noting what the rejected move would ALSO have cost: journal compaction avoids cutting inside an
open alt-screen segment via `AltScreenCutScanner`, which `ReplayBuffer` uses too. In superd that
scanner would have had to be written a second time in Rust while Swift kept the copy `ReplayBuffer`
needs — the same capability in two languages, which is the one thing the porting rule forbids.

## The hostd port starts at the wire, and the retired Rust core is where it starts from (2026-08-13)

The instruction was to migrate as much as possible to Rust — for safety and for the language, not
only for speed — while holding performance parity. `CLAUDE.md` already says how to decide that:
"Rust is the default; perf parity is enough to move existing Swift. Only SwiftUI/AppKit justifies
staying in Swift. A measured regression is the only veto." An earlier answer in this tree applied a
much stricter test — in-process by necessity *plus* a measured ceiling *plus* not fixable in Swift —
and concluded nothing was left to port. That test is the one for reopening **uniffi/FFI**, and
applying it to porting in general was a mistake; it retires the repo's own default rule by accident.

Under the actual rule the largest legitimate target is `slopdesk-hostd`: 26.3k lines, of which only
four files are framework-pinned (`PreventSleepAssertion` on IOKit, `HostPathActionPerformer` and
`HostClipboardPerformer` on AppKit, `RepoStatusWatcher` on CoreServices). It is far too large for
one change, so it goes in stages, and stage 1 is the PATH-1 wire codec.

**Why the wire first, and not something easier.** Every later stage has to speak to a client before
it can be tested at all, so the codec is the floor. It is also the one module in the tree with a
mechanical oracle already committed: `golden/golden_vectors.json` is generated from the Swift codec
and predates the port, so "did moving this change the wire" is answered by bytes nobody wrote for
the answer.

**It was resurrected, not retyped.** `a2b51614^` still holds `rust/aislopdesk-core` — 29,278 lines,
`#![forbid(unsafe_code)]`, zero dependencies — covering this exact codec, retired 2026-06-19. The
reason recorded then was that "the two-language cost was the boundary, not the languages": ~21k
lines of FFI machinery bridging to ~700 lines that genuinely needed SIMD. That verdict rejected the
**seam**, not Rust, so it does not bind a port that ships as a separate binary over a socket. About
half of today's message table (14 of 28 types) predates the retirement and came back from that
commit; the other half was translated fresh from today's Swift.

**One divergence was found by reading, not by the tests.** The recovered `bytes.rs` decoded strings
LOSSILY — correct on the video path it came from, where a corrupt datagram must not be able to fail
a session. The terminal path is STRICT (`WireMessage+Decode.swift:110`): invalid UTF-8 is
`malformedBody`. Copying the helpers over unchanged would have silently relaxed that and let a
corrupt title through as `U+FFFD` — and every golden vector would still have passed, because none of
them carries invalid UTF-8. Resurrection is not free; the recovered code has to be re-read against
the contract it is landing in, not the one it left.

**Parity is checked from both sides, on purpose.** Decoding a pinned frame and re-encoding it to the
same hex proves less than it looks: a decoder that reads two fields in the wrong order, paired with
an encoder that writes them in the same wrong order, round-trips perfectly and is incompatible with
every Swift peer. So `tests/golden_vectors.rs` also compares each vector's decoded fields against
the JSON's own field values, which the Swift generator wrote independently of the hex. 63 field-level
vectors plus 10 workspace vectors (which pin only bytes and size, and are documented as such).

**The number.** 200k frames, best of 5, M-series, both sides release-built (`-Ounchecked` for Swift),
decode fed in 64 KiB chunks the way the receive loop actually feeds it:

| workload | Swift | Rust | |
| --- | --- | --- | --- |
| `.output` 1 KiB — encode | 448 ns/frame | 50 ns/frame | 9.0× |
| `.output` 1 KiB — decode | 441 ns/frame | 90 ns/frame | 4.9× |
| control mix — encode | 395 ns/frame | 23 ns/frame | 17× |
| control mix — decode | 282 ns/frame | 28 ns/frame | 10× |
| `wireByteCount` | 55 ns/frame | 1.7 ns/frame | 32× |

Parity was the bar; this clears it by 5–17×. Two notes keep the number honest. The decode gap is
partly a design difference and not only a language one: Swift copies each payload into a fresh `Data`
before decoding because its decoder needs an owned one, while the Rust decoder borrows straight out
of the receive buffer. And the FIRST decode measurement was 42 µs/frame in **both** languages — that
is the lazy-compaction algorithm going quadratic when 206 MB is handed to `append` in one call, which
is not how the receive loop behaves. It is shared by both implementations and is not a porting
finding; it is recorded here so the next person who sees it does not read it as one.

**What came back that the reversal lost.** `docs/DECISIONS.md` records `forbid(unsafe_code)`'s
compiler proof as "the one real guarantee lost" in 2026-06-19. It is back, as `forbid` rather than
`deny`, so not even a downstream `allow` can reintroduce it.

**The uncomfortable part, stated rather than buried.** `CLAUDE.md` says porting means deleting the
original in the same change. This change does NOT delete `Sources/SlopDeskProtocol`, because hostd
and every client still speak through it — so for the duration of the hostd migration the codec exists
twice, which is the exact thing the rule forbids. The carve-out in `check-supervisor.sh` ("a protocol
has two ENDS, and each end is written once") does not cover this: both ends are Swift today. What
bounds it is that `slopdesk-wire` is linked by nothing yet, and that the golden corpus is a gate both
implementations must pass, so they cannot drift silently. The debt is real and its only honest
retirement is finishing the hostd port; if that stalls, the correct move is to delete this crate, not
to keep it.

**Staging after this.** The mux layer (7 files, all with old-Rust ancestors), then `MetadataCodec`
(841 lines) and `WorkspaceChannelCodec` (466), then hostd's own services. Each stage keeps the golden
pin as its gate; the Swift deletions land with the stage that makes them unreachable.

## The mux layer moves next, and the one thing it could not resurrect was the flow-control policy (2026-08-13)

Stage 2 of the hostd port, per the staging the entry above set out. Eight Swift files became
`rust/slopdesk-wire/src/mux/`: the envelope codec and its five frame types, the streaming decoder,
the channel table, and the three flow-control policies plus the constants all three are sized from.
The Swift originals are NOT deleted yet, for the same reason and under the same bound stage 1
recorded — hostd and every client still speak through `Sources/SlopDeskProtocol`, and the debt's only
honest retirement is finishing the port.

**The corpus already had an oracle for most of it, and none for one field.** All twelve
`muxEnvelopes` vectors are pinned field-by-field in both directions, and the whole corpus is
additionally fed to `MuxFrameDecoder` **one byte at a time** — because `MuxFrame::decode` is handed
an inner run whose boundary the test computed, so nothing else checks that the DECODER finds the same
boundaries in a stream that carries no framing of its own. A prefix read off by one passes every
field assertion and desynchronises the moment two frames share a read. What the corpus does NOT
cover is `initialCwd`: no pinned vector carries one, so the optional field, its `u16` length prefix
and its strict-UTF-8 rule are pinned only by tests written alongside the port. That is a weaker pin
and it is said in the test rather than left to look like coverage.

**Two decode behaviours are deliberately asymmetric, and both were kept because they are the
original's.** An unrecognised close REASON reads as `retired` rather than faulting — a close must
always close, so a newer peer's reason may not leave a channel open — while trailing bytes past that
reason are still `malformedBody`, because an unknown VALUE and unknown FRAMING are different faults.
And `Some("")` for the cwd encodes a present zero-length field that decodes back as `None`. Neither
was tidied: a port that quietly fixes things is a port whose parity proves nothing.

**`MuxFlowControl` is the one part with no Rust ancestor to resurrect.** The retired core predates
credit flow control entirely, so the window, the queue bound, the merge cap and the four env knobs
were translated from today's Swift. Two details survive translation only if you read for them. The
policies are `i64`, not `usize`: the Swift deliberately ACCEPTS and clamps negative inputs and
saturates a peer-chosen grant at `Int.max` rather than trapping, and `usize` would make those cases
unrepresentable and push the guard out to every call site. And `clippy::integer_division` is denied
crate-wide, which is the right lint here rather than an obstacle — every window in the file rounds
DOWN on purpose, since a threshold that rounded up could sit above what the sender can put in
flight. It is a named `half()` now, with that reason written where the rounding happens.

The credit progress invariant (`frame wire bytes <= window/2`, or a sender parks against a receiver
that can never re-grant) is now a TEST rather than only a comment, including at the worst pair the
env bounds allow — a 16 KiB window against a 128 KiB merge cap. Both knobs are independently
tunable, which is exactly how a deadlocking combination gets shipped.

**The number.** Best of five, in-process, M-series, both sides release-built (`-Ounchecked` for
Swift), decode fed the inner run the way the receive loop hands one over:

| workload | Swift | Rust | |
| --- | --- | --- | --- |
| `channelOpen` (with cwd) — encode | 1010 ns | 22 ns | 46× |
| `channelOpen` — decode | 505 ns | 39 ns | 13× |
| `channelOpenAck` — encode / decode | 509 / 100 ns | 19 / 6 ns | 27× / 16× |
| `channelClose` — encode / decode | 174 / 68 ns | 17 / 3 ns | 10× / 22× |
| `windowAdjust` — encode / decode | 226 / 80 ns | 17 / 4 ns | 13× / 22× |
| `channelData` 1 KiB — encode / decode | 380 / 208 ns | 45 / 51 ns | 8.4× / 4.1× |
| `channelData` 32 KiB — encode | 1055 ns | 707–1427 ns | ~parity |
| streaming decode, 1 KiB frames in 64 KiB chunks | 527 ns/frame | 80 ns/frame | 6.6× |

Parity was the bar. One row is honest about being only that: the 32 KiB encode is one allocation and
one memcpy in both languages, so it measures the allocator rather than the codec, and Rust's spread
across process runs (707–1427 ns) is wider than Swift's steady ~1055. Reporting the best-of as a win
there would be reporting cache state. Everything that is actually codec work — the control frames a
mux connection is mostly made of — is 4–46× faster, and the streaming path that a flooding pane
drives is 6.6×.

`examples/muxbench.rs` stays in the tree on the `slopdesk-sniffbench` precedent: re-running that
bench is what caught a 3.3× Swift defect a port would otherwise have carried across and credited to
Rust. A bench that is still here is the difference between the next person re-asking and re-guessing.

## The metadata RPC and the workspace channel move next, and one of them had no oracle (2026-08-13)

Stage 3 of the hostd port, per the staging two entries above. Two Swift files became three Rust
modules: `MetadataCodec.swift` (841 lines) and `MetadataVerb.swift` (230) are now
`rust/slopdesk-wire/src/metadata/{verb,codec}.rs`, and `WorkspaceChannelCodec.swift` (466) is
`src/workspace.rs`. The Swift originals stay, on the same bound and for the same reason stages 1 and
2 recorded: hostd and every client still speak through `Sources/SlopDeskProtocol`, and the debt's
only honest retirement is finishing the port.

The two envelopes these ride inside — `metadataRequest`/`metadataResponse` (16/30) and
`workspaceRequest`/`workspaceEvent` (17/37) — moved in stage 1 already. So this stage is the part
the envelopes carry OPAQUELY, which is exactly why it needed its own pin: the envelope round-trips
perfectly while the body means something else to every Swift peer.

**One half had an oracle in the repo and the other had none.** All ten `metadataCodecPayloads`
vectors are pinned field-by-field in both directions — the corpus is generated from the Swift codec
and predates this crate, so it answers "did the port change the wire" with bytes nobody wrote for
the test. Because that group pins only `hex`/`kind`/`note` and no machine-readable field values,
the expected fields are transcribed by hand in the test rather than read back out of the JSON; a
decoder and encoder that agreed on the WRONG field order would otherwise pass. The workspace CHANNEL
payloads have no corpus group at all — `workspaceWireMessages` pins the envelope, and
`workspaceStateCodec`/`workspaceIntentArgs` pin the DOCUMENT codec in the model target, which is a
different file and a later stage. So `subscribe`, `presence`, `intent`, `intentResult` and the
presence roster are pinned only by tests written alongside the port. That is a weaker pin and it is
said here rather than left to look like coverage.

**Three behaviours were carried across unchanged specifically because changing them would prove
nothing.** `CharacterSet.whitespaces` is NOT `char::is_whitespace`: Swift's set is Unicode `Zs` plus
tab and excludes the line terminators, so a font family of `"\n"` is legal to Swift's validator and
empty to Rust's `trim`. The Rust decodes through an explicit `Zs`-plus-tab predicate, because this
particular validation decides whether a payload reaches a `settings.json` the workbench trusts, and
the two implementations have to refuse exactly the same bodies rather than similar ones. The roster
decoder's per-client floor of 42 bytes is a conservative under-estimate of the true 56 — both reject
the same hostile counts in the end, the smaller one just one read later — and it is carried verbatim
rather than corrected, because the number is unobservable and drift between two implementations is
not. And `hasRepo == false` still returns the canonical no-repo payload regardless of any trailing
bytes.

**The number.** Best of five, in-process, M-series, both sides release-built (`-Ounchecked` for
Swift), payload byte counts printed and matched on both sides before the timings were compared:

| workload (encode / decode) | Swift | Rust | |
| --- | --- | --- | --- |
| `processList`, 200 entries | 78.6 / 18.2 µs | 0.79 / 4.88 µs | 99× / 3.7× |
| `portList`, 100 entries | 25.6 / 6.4 µs | 0.67 / 2.29 µs | 38× / 2.8× |
| `dirListing`, 2000 entries | 572 / 308 µs | 12.4 / 59.2 µs | 46× / 5.2× |
| `gitStatus`, 500 files | 144 / 77.7 µs | 3.45 / 16.7 µs | 42× / 4.7× |
| `agentSessionList`, 300 sessions | 281 / 124 µs | 7.12 / 25.5 µs | 39× / 4.9× |

Parity was the bar and every row clears it by an order of magnitude on encode. The encode gap is
not cleverness: it is `Data.append` versus a `Vec` with one reserve, repeated once per field, and it
shows up as ~40× because these payloads are thousands of small appends each. The decode gap is the
ordinary one — borrowed slices where the Swift copies into a fresh `Data` per field.

**A row that is deliberately absent.** `hostVitals` is seven fixed bytes with no loop and no
variable-length field, so at 400k iterations it measured 0.3 ns/op — the optimizer had folded it
flat, and both a `.len()` and a `.first()` sink folded the same way. That is not a fast codec, it is
an absent measurement, so the row is not in the table. It is stated in `examples/metadatabench.rs`
where the next person will look for it.

**Why the Swift half is a throwaway program and not an XCTest.** `swift test -c release` cannot
build this package's test tree at all: `ConnectionViewModel.foldEventForTesting` is `#if DEBUG`-gated
by design ("never leaks into release API") and several suites call it, so a release test build fails
in `SlopDeskWorkspaceCoreTests` before it reaches anything being benchmarked. Adding
`-Xswiftc -enable-testing` does not help, because the gate is the `#if`, not testability. The Swift
numbers therefore come from a throwaway SwiftPM executable depending on the `SlopDeskProtocol`
product by path; `examples/metadatabench.rs` records that so the comparison can be re-run.

## The workspace document moved next, and it was the first port to change a data structure (2026-08-13)

`WorkspaceStateCodec` (555 lines), `HostWorkspaceState` (186) and `WorkspaceIntentArgs` (411) are now
`rust/slopdesk-wire/src/document/{codec,state,intent}.rs`. This is the layer under the one the
previous stage moved: `crate::message` frames the type-17 / 37 envelope and treats its payload as
opaque, `crate::workspace` decodes the channel's own request and event bodies and treats the argument
bytes as opaque, and `crate::document` is what those opaque payloads actually say. The three modules
still do not import each other, so the layering survived the port rather than dissolving into it.

**The oracle is real this time, and it is the strong form.** Unlike the workspace CHANNEL payloads,
which had no golden group, all three of `workspaceStateCodec` (16 vectors), `workspaceIntentOps` (27)
and `workspaceIntentArgs` (18) are pinned in `golden/golden_vectors.json`, generated from the Swift
codec long before this crate existed. The new tests do not merely decode-and-re-encode them: the Rust
side CONSTRUCTS the same fixture the Swift generator did and compares the bytes. A decoder and
encoder that agreed with each other on a wrong field order pass a round-trip and fail this, because
the value never came from the pinned bytes. All 61 vectors matched on the first run.

**The one thing that deliberately did not survive verbatim.** Swift held the document in a
`Dictionary` and sorted its keys at every snapshot, diff and object query; the Rust holds a
`BTreeMap` whose iteration order already IS `WorkspaceKey`'s ordering, which already IS the wire's
canonical order. That removes a whole class of bug — a hand-written `Comparable` drifting out of step
with the encoder that depends on it — but it is an algorithmic change, so "perf parity" stopped being
a formality and `examples/documentbench.rs` exists to answer it rather than assume it.

Two API consequences fell out of measuring it. `from_entries` collects instead of inserting in a
loop, because `BTreeMap` bulk-builds from an already-sorted iterator and the hot caller
(`decode_snapshot`) hands it exactly that — worth 2.9× on snapshot decode. And `apply(&mut self)`
now exists beside `applying(&self) -> Self`: Swift only needed the value form because `Dictionary` is
copy-on-write and `var next = self` is free until touched, whereas a `BTreeMap` copy is real. A
mirror should call `state.apply(&d)`, and `applying` says so in its own doc.

**The number.** Best of five, in-process, M-series, both sides release-built (`-Ounchecked` for
Swift), payload byte counts printed and matched on both sides — 92894 / 9998 / 1133, 200 sets and 50
deletes — before the timings were compared:

| workload (encode / decode) | Swift | Rust | |
| --- | --- | --- | --- |
| `snapshot`, 2000 cells | 3659 / 548 µs | 55.8 / 65.6 µs | 66× / 8.4× |
| `diff`, 200 sets + 50 deletes | 23.8 / 30.9 µs | 1.54 / 4.47 µs | 15× / 6.9× |
| `layoutStructure`, 32 leaves | 4.39 / 5.61 µs | 0.57 / 0.91 µs | 7.7× / 6.1× |
| `diffFrom` / `applying`, 2000 cells | 3829 / 70.2 µs | 201 / 62.8 µs | 19× / 1.1× |

The last row's two columns are not a codec — nothing there touches a byte. It is the row the
container change lands on, which is why it is in the table: computing a diff is 19× faster and
applying one is 11% faster, so the structural swap costs nothing on either side of the algebra.

The 66× on snapshot encode is not cleverness either. Swift's `WorkspaceKey.<` builds two fresh
16-element `[UInt8]` arrays per comparison, and `sortedEntries` runs it ~22 000 times for a
2000-cell document — the sort allocates about 44 000 arrays before a single byte is written. Rust
compares `[u8; 16]` in place and does not sort at all. That is the same finding as the previous
stage's encode gap, one layer up: the cost was never the codec, it was what the codec had to do to
get its inputs in order.

**Two shapes were carried across, one was not.** The `Result`-vs-`Option` split is carried: the
structural decoders (snapshot, diff, layout, weight) answer `Result` because a caller parsing a frame
wants to know why it was refused, while the single-cell decoders answer `Option` because the only
useful reaction to a wrong-width cell is to drop that cell and render the rest. Collapsing it either
way would change what a caller does. Swift's `UInt16(truncatingIfNeeded:)` on the reopen and divider
indices is carried too, spelled as an explicit mask so the two cannot disagree on the one input that
reaches it. What was NOT carried is Swift's wrapped `u16` length on a sub-payload blob: writing a
wrapped length while appending every byte produces a frame that mis-splits at the decoder, so the
Rust truncates the blob to the length it declared. Identical for every input under 64 KiB, which is
every real payload and every pinned vector, since `MAX_BLOB_BYTES` refuses anything past 16 KiB on
the way back in.

## The video FEC moves next, and `forbid(unsafe_code)` finally costs something measurable (2026-08-13)

Stage 5 of the hostd port opens the SECOND transport. `Sources/SlopDeskVideoProtocol` is 9 719 lines
across 46 files with ZERO AppKit/SwiftUI/UIKit imports — the largest pure-logic target left in the
tree — and it starts at the bottom of its own stack: `GF256.swift` (264), `ReedSolomonMatrix.swift`
(135) and `FECScheme.swift` (442) are now `rust/slopdesk-video/src/{gf256,rs_matrix,fec}.rs`, a new
crate with its own workspace on the same profile argument as `slopdesk-wire`.

**This one was resurrected in the most literal sense available.** `GF256.swift`'s own header says it
is "the resurrected, native-Swift port of the Rust `slopdesk-core::gf256` reference". So the sentence
runs backwards here: `a2b51614^` still holds `rust/aislopdesk-core/src/{gf256,rs_matrix,fec}.rs`,
1 781 lines under `#![forbid(unsafe_code)]` with zero dependencies, and the field tables, the Cauchy
block, the Gauss-Jordan inverse and the codec's structure come back from there rather than being
retyped out of the Swift that was typed out of them.

**Why the FEC and not something bigger.** It is the least SAFE code in the tree. `NeonGf` reaches
`Sources/CSlopDeskSIMD` through `UnsafeBufferPointer` and `withUnsafeTemporaryAllocation` behind a
`swiftlint:disable force_unwrapping`, and both `encodeGroup` and `recoverGroup` pass raw
`UnsafeMutableBufferPointer` accumulators around — on a path whose entire input is UDP datagrams from
the network. `forbid(unsafe_code)` does not make that code safer, it makes it inexpressible.

**Parity is pinned from both directions.** `fecParity` (4 vectors) and `fecRecover` (3) were
generated from `XORParityFEC(groupSize: 5)` — `RustReedSolomonFEC(groupSize: 5, parityCount: 1)`
under its alias — so every pinned vector exercises `m == 1`, the shipped operating point and the one
the wire contract declares byte-identical to plain XOR. All seven matched on the first run. The
`fecRecover` vectors matter more than they look: two of the three are NEGATIVE — two holes in one
group, and a hole whose parity was also lost — so a decoder that repairs more than it should fails
here rather than in production. The `m >= 2` Cauchy path has no corpus, and does not need one: its
answer is verifiable rather than merely agreed, so the unit tests check the algebra directly (every
one of the 35 four-subsets of a `[7,4]` encoder inverts, and `A · A⁻¹ == I` for each).

**The number, and it does not all go one way.** Best of five, M-series, both sides release-built
(`-Ounchecked` for Swift), parity byte counts printed and matched — 40 936 / 122 808 / 1 808 — before
any timing was compared. `k = 5`; the IDR is 170 × 1200 B, the delta 6 × 900 B; recover repairs the
maximum the code allows (one hole per group at `m = 1`, three at `m = 3`):

| workload (parity / recover) | Swift + NEON | Rust, safe | |
| --- | --- | --- | --- |
| IDR 170 × 1200 B, `m = 1` | 15.5 / 38.3 µs | 6.75 / 17.3 µs | 2.3× / 2.2× |
| delta 6 × 900 B, `m = 1` | 648 / 1643 ns | 187 / 526 ns | 3.5× / 3.1× |
| IDR 170 × 1200 B, `m = 3` | 79.1 / 117 µs | 233 / 281 µs | **0.34× / 0.42×** |
| delta 6 × 900 B, `m = 3` | 3.27 / 4.91 µs | 7.67 / 7.63 µs | **0.43× / 0.64×** |

**So the shipped path is 2.2–3.5× faster and the Cauchy path is 2.3–2.9× SLOWER, and that is the
whole finding.** `m == 1`'s inner loop is a plain XOR, which is exactly what LLVM autovectorises out
of a bounds-check-free `zip`; Rust wins there on everything around it, the same way every earlier
stage did. `m >= 2` multiplies by a field coefficient, and `vqtbl1q_u8` looks up 16 bytes per
instruction through two 16-entry nibble tables while safe Rust looks up one byte at a time. Stable
Rust has no safe SIMD (`std::simd` is nightly) and `forbid(unsafe_code)` bars the intrinsics, so this
is structural, not a missing optimisation. Two real optimisations were applied and are in the number
above — a per-coefficient 256-entry multiplication table above a measured length crossover, and
hoisting those tables out of the group loop to the frame (15 built per IDR instead of 510, worth
23%) — and they closed part of the gap, not the kind of it.

**It lands anyway, and here is the argument rather than a shrug.** `SLOPDESK_FEC_M >= 2` is
env-gated and OFF by default (`AdaptiveFECPolicy.MultiLossFEC.resolveParityCount` defaults to 1), so
the regression is on a path no shipped configuration takes. Its absolute cost is 233 µs on a 200 KiB
IDR — 1.4% of a 60 fps frame budget, against Swift's 0.5% — and IDRs are rare; the delta frames that
dominate cost 7.7 µs. Against that, the code that is actually on every frame got 2–3× faster while
losing every `unsafe` it had. If `FEC_M >= 2` ever becomes a default, this reopens with a real
question attached: whether a `tbl` kernel is worth relaxing `forbid` to `deny` for one module, and
the answer then must come with its own measurement. It is not worth it for a path that is off.

**One divergence from the old Rust, deliberately.** The resurrected core shipped `XorParityFec` and
`ReedSolomonFec` as two types, and a `GfRegion` trait with a scalar and a SIMD conformance. Today's
Swift has already collapsed the first pair into one type behind a `typealias`, so the port follows
today's Swift, not its own ancestor. The trait went too: it existed ONLY to swap the NEON kernel in,
this crate cannot have one, and an abstraction with a single implementor is something to read past
rather than something that carries weight. The independent XOR reference it used to provide now lives
in the test module, where it belongs — a reference you can check against is worth having, a second
shipped implementation is exactly what `CLAUDE.md` forbids.

**The debt is the same bounded one, said again rather than assumed.** This does not delete
`Sources/SlopDeskVideoProtocol/{GF256,ReedSolomonMatrix,FECScheme}.swift`, because the packetizer,
the reassembler and both session types still drive them. `slopdesk-video` is linked by nothing, and
the golden corpus is a gate both implementations must pass, so they cannot drift silently. Its only
honest retirement is finishing the port up through `FramePacketizer` / `FrameReassembler`; if that
stalls, the correct move is to delete this crate, not to keep it.

## The video protocol's message layer follows the FEC, and the UTF-8 split turns out to be the interesting part (2026-08-13)

Stage 6 continues the same crate: `slopdesk-video` now holds the whole pure message layer of
`Sources/SlopDeskVideoProtocol` below the packetizer — `bytes`, `error`, `geometry`,
`coordinate_mapping`, `nal_unit`, `ycbcr`, `window_geometry`, `cursor`, `swipe_nav`, `input_event`,
`audio_wire` and `video_control`. Ninety-nine unit tests and thirteen golden tests, all green under
the same maximal-strict clippy the wire crate runs, `unsafe_code = "forbid"`, no dependencies outside
the dev-only `serde_json`.

`window_geometry`, `cursor`, `input_event` and `video_control` came back from `a2b51614^`'s
`rust/aislopdesk-core`, the same resurrection route the FEC took. The rest were written against the
Swift, because they had no ancestor: `swipe_nav` and `audio_wire` postdate the old core entirely.

**The corpus decided the shape of the tests, not the other way round.** Every codec group is now
checked in BOTH directions by one helper: the pinned hex must decode, and re-encoding what came back
must reproduce the same hex, and the decoded VALUE is then compared field by field against the
corpus's own record. Round-trip alone would pass a codec that consistently swapped two same-width
fields; field comparison alone would pass one that read the right values from the wrong offsets. The
`videoControl` test additionally asserts the group still covers type bytes 1 through 28 with no gap,
because a gap is exactly where a future port drifts unnoticed.

**`ycbcr` and `coordWindowPoint` are pinned as raw bit patterns, and that is load-bearing.** A
coefficient that drifted by one ulp — an `f64` intermediate narrowed to `f32`, or an FMA fusing what
the wire rounds twice — still prints as the same decimal. Which is also why this crate now sets
`suboptimal_flops = "allow"` and `imprecise_flops = "allow"` crate-wide: both nursery lints want
`f64::mul_add`, which is precisely the fused multiply-add `CLAUDE.md` forbids. Per-site `#[expect]`
on every geometry expression would be noise for a reason that is a repo invariant, so the allow
carries the reason instead, and `every_pinned_window_point_has_the_same_f64_bit_pattern` is what
makes it a decision rather than an oversight.

**The UTF-8 split had to be carried exactly, and it is not arbitrary.** `window_geometry` and
`input_event` decode strings STRICTLY — invalid bytes drop the datagram. `video_control` decodes
LOSSILY. Porting these together made the reason legible in a way reading either alone does not: the
strict pair carries a value the user SEES or TYPES, where a substituted U+FFFD is worse than a
dropped update, because the update self-heals on the next poll and the mojibake does not. A control
datagram carries a DECISION, and dropping the whole thing over one bad byte in one window's title
would take the other nine windows with it. Both behaviours now have a test that states the reason,
so a future tidy-up that "makes the codecs consistent" has to argue with the tests.

**Two hostile-input disciplines survived the port intact.** No list decoder reserves capacity for its
untrusted `u16` count, so a bogus 65535 with an empty body fails on the first missing byte instead of
allocating; there is a test per list type. And every declared length is bounds-checked against the
buffer BEFORE the read, so a corrupt `blobChunk` byte count or cursor bitmap length is truncation,
not a large allocation. In safe Rust these are ordinary code rather than a review item, which is the
whole argument for the move — the Swift originals get them right, but nothing in the language was
holding them to it.

**The same bounded debt, unchanged.** Nothing Swift is deleted here either: `FramePacketizer`,
`FrameReassembler` and both session types still drive these codecs, and `slopdesk-video` is linked by
nothing. The golden corpus gates both implementations, so they cannot drift silently. The honest
retirement is still finishing the port up through the packetizer and reassembler.

## The send path follows the codecs, and the 80-vector tier sweep passed on the first run (2026-08-13)

Stage 7 of the video port: `fragment`, `mux_header`, `adaptive_fec`, `interleaver` and `packetizer`
in `rust/slopdesk-video`. The layer above the message codecs — everything between an encoded frame
and the datagrams that leave the host. 154 unit tests plus 18 golden tests, `make lint-rust`,
`make lint-supervisor` and `swift build` all green.

**The corpus agreed on the first run, which is the point of having it.** The five new golden groups —
`fragmentEncode`, `muxBare`, `muxFragment`, `adaptiveGroupSize`, `adaptiveTier` — passed without a
single byte of adjustment, including the 80-vector sweep of the loss ladder against every previous
tier. That is a real result for the hysteresis code specifically: `tier_for_loss` has asymmetric up
and down thresholds, a one-step clamp and a relax floor, and any one of those transcribed slightly
wrong would have shown up in some corner of an 80-cell grid rather than in the obvious cases.

**Two 19-byte headers that are not the same 19 bytes.** `FrameFragmentHeader` is 15 bytes of fields
plus a 4-byte `host_send_ts_millis`; `MuxFrameFragmentHeader` is the same 15 plus a 4-byte channel
id, with no timestamp. Reading one with the other's decoder parses cleanly and produces nonsense. So
both golden tests compare FIELD BY FIELD rather than against a rebuilt struct: a same-width field
swap round-trips its own bytes perfectly, and the only thing that catches it is naming each field.

**The ladders became their own rungs.** `target_level` and `m_target_level` were transcribed as
if/else-if chains and clippy's `bool_to_int_with_if` objected to their tails. Rewriting them as
`level_from_thresholds(loss, &[0.005, 0.02, 0.05, 0.10])` — the count of thresholds reached IS the
level — removed the lint and made the up-ladder and the down-ladder differ only in the numbers they
carry, which is what they actually are. The 80 pinned vectors are what made that safe to do.

**The dwell test was wrong and the implementation was right.** `an_unrecovered_loss_doubles_the_dwell`
asserted a step one report later than it happens: the arming report itself counts toward the relax
streak. Checked against `AdaptiveFECPolicy.swift` line by line before touching anything — the Rust
matched. The test now walks the undoubled dwell first as a baseline, so the doubling is visible as a
difference rather than as a number someone has to trust.

**`VideoPacketizer` is deliberately not `Copy`, with the lint expected rather than obeyed.** It is
two `u32` counters and an `Option<ReedSolomonFec>`, so `missing_copy_implementations` fires. An
implicit copy would fork the stream sequence and hand two senders the same `stream_seq`, which reads
downstream as duplicate datagrams. The `#[expect]` carries that reason.

**The m-tier rule is carried verbatim, not simplified.** `parity_with_m` exists on the Rust codec and
would have been the shorter call, but the Swift builds a fresh codec at `(k = groupSize, m)` and the
two are only equivalent because every m-tier resolves its group size to the codec's own `k`. That
equivalence is an argument, not a guarantee, so the port keeps the shape the Swift has and the
crate-level doc records why `wire_tier` forces tier 0 whenever multi-loss is on.

**The same bounded debt, one stage smaller.** `FramePacketizer.swift`, `FragmentInterleaver.swift`,
`AdaptiveFECPolicy.swift` and `VideoMuxHeaderCodec.swift` still drive the live host; `slopdesk-video`
is still linked by nothing. What is left before the Swift can go is the receive path — the
reassembler and the policies around it.

## The receive path and every policy around it, and a hash that only looks like xxHash64 (2026-08-13)

Stage 8 of the video port, and the last one inside `SlopDeskVideoProtocol`: `reassembler`,
`recovery`, `frame_hash`, `scroll_shift`, `adaptive_qp`, `playout`, `keepalive`, `blob`,
`window_feed`, `scroll_resample`, `scroll_reproject` and `swipe_recognizer` in
`rust/slopdesk-video`. 296 unit tests plus 19 golden tests, `make lint-rust`, `make lint-supervisor`
and `swift build` all green.

**The frame hash had no oracle, and the reason is that it is not the algorithm it looks like.** The
first pass pinned the Rust against published xxHash64 vectors and both failed. `PRIME64_E` in
`FrameHasher.swift` is `0x2752_5BA1_84B2_3A5D`, and xxHash64's fifth prime is
`0x27D4_EB2F_1656_67C5`; primes A–D match. So the fold is xxHash64-SHAPED and self-consistent — every
value it produces is only ever compared against another value from the same code — but `xxh64sum`
will disagree with it forever. There is no `frameHash` group in the corpus to have caught this. A
scratch Swift probe compiled against the real `FrameHasher.swift` supplied the pins instead, the
Rust matched bit-for-bit, and the divergence is now documented on the constant so nobody later
"fixes" the prime and silently invalidates every hash the capture path has ever compared.

**Two Swift splits collapsed into one Rust entry each, because the reasons for them were Swift's.**
`hashRow` exists beside `StreamHasher` only because the streaming hasher's 32-byte carry is a heap
`[UInt8]`; in Rust the carry is a `[u8; 32]` field, so `hash_run` IS the streaming hasher over one
slice. `hashNV12Scalar` exists beside `hashNV12` only as the safe fallback for the pointer path; with
`forbid(unsafe_code)` there is one path and it is the safe one.

**One real porting bug, found by transcribing rather than by a test.** `matchedRow` bounds the source
row by `n = min(prev.count, cur.count)`, not by `prev.count`. Written the obvious way, a longer
previous row-hash array would have matched rows the estimator is not allowed to see, and the shift
estimate would have drifted only on frames where the two arrays disagree in length — which is exactly
a resize, where a wrong scroll estimate is least visible and most wrong.

**`LumaPlane` exists because a plane must not be readable at another plane's stride.** The NV12
entries take a plane and its stride as one value, which also drops them under clippy's argument-count
threshold. That is the second-order benefit; the first is that `hash_plane(y, cbcr_stride, …)` is now
unspellable.

**The swipe recogniser reuses the wire enum rather than declaring a second direction.**
`swipe_nav::SwipeDirection` already carries the "fingers right ⇒ history BACK" convention and its
justification; the recogniser returning a different-but-identical enum would have made the wire and
the decision two vocabularies that happen to agree. `slow_required_travel` stays a free function so
the lift decision and the live-candidate mirror provably share one surface — a client whose feedback
disagreed with the host's fire is the failure that shape prevents.

**The bounded debt is now the whole directory at once.** Every file in `SlopDeskVideoProtocol` bar
`Settings/` has a Rust counterpart, and `slopdesk-video` is still linked by nothing: the Swift
originals drive the live host until the daemon that speaks this crate over a socket exists. That
daemon, not another module, is what unblocks the deletions.

## The host's policy layer follows the protocol, and the tick counter is off by one everywhere (2026-08-13)

Stage 9 of the video port, and the first one outside `SlopDeskVideoProtocol`: `congestion`,
`fps_governor`, `session_state`, `input_routing`, `recovery_routing`, `swipe_nav_config`,
`mint_rescue` and `packetize_lane` in `rust/slopdesk-video`. `VideoSessionLogic.swift` is covered
end to end. 472 unit tests plus the 19 golden tests, `make lint-rust`, `make lint-supervisor` and
`swift build` green.

**Three congestion tests were wrong and the implementation was right, twice for the same reason.**
The warmup test asserted a decision one report later than it happens: `ticks += 1` precedes the
`ticks < warmupTicks` gate in both `LiveCongestionController` and `FPSGovernor`, so an N-tick warmup
means the Nth report is the FIRST that may act, not the first that may not. Checked against the
Swift line by line before touching anything. The third failure was subtler: a queue-depth test
expected a floor-factor cut and got 0.87, because `min_rtt` re-baselines UPWARD at 1% of the gap per
fold — sixty folds of a 120 ms sample dragged the baseline to ~59.7 ms and the queue the test
thought it had built was gone. The helper now folds twenty times and its doc comment records why
sixty is a different experiment.

**`effective_slack_millis` had to leave the controller to stay one rule.** `FPSGovernor`'s
congestion evidence reads the same RTT slack the controller cuts on, and the Swift doc explicitly
forbids forking those constants. As a method it would have been reachable only through a controller
instance the governor has no reason to hold, so it is a free function over `&CongestionConfig` and
both callers provably consume the identical arithmetic.

**`VideoChannel` was TWO Swift enums.** `SlopDeskVideoHost/VideoDatagramTransport.swift` and
`SlopDeskVideoClient/VideoClientTransport.swift` each declare it, identically, because neither
module imports the other. In Rust it is one enum in `recovery_routing`, and the pair can no longer
drift — which for a channel discriminant would mean datagrams silently routed to the wrong lane.

**The mint rescue became a trait, not eight closures.** `resolve_off_screen_window` took the full
enumeration, the on-screen enumeration, the id accessor, the frame accessor, the un-minimize and the
sleep — eight arguments, one past clippy's threshold. Bundling them into a `WindowSource` trait was
the fix that was not an `#[expect]`: the settle poll now takes `fn(&mut S) -> Option<Vec<S::Window>>`
and picking the WRONG enumeration for an outcome is a different function pointer rather than a
different argument position.

**`MouseButton` gained `Ord` for a reason that is not ordering.** The held-button ledger keys a set
on it, and `BTreeSet` iterates deterministically where `HashSet` does not — an injector that
released held buttons in a varying order would produce a different `CGEventPost` sequence per run.
The derive is documented as ordered by the wire discriminant so nobody later "fixes" it to something
semantic.

## The mux, the window feed and the send schedule, and two modules written twice (2026-08-13)

Stage 10, and the last of `SlopDeskVideoHost` that is not AppKit, ScreenCaptureKit or Network:
`mux_routing`, `mux_flow`, `window_feed_host` and `send_pacing`. 526 unit tests plus the 19 golden
tests, all three gates green.

**Two modules were written, compiled and deleted, because the crate already had them.** `StillnessCrispDecider` and `should_suppress_static_frame` live in `frame_gate.rs`; the virtual-display
recreate gate and `arrange_streamable_windows` live in `capture_recovery.rs` — both landed in an
earlier stage under module names that describe the DECISION rather than the Swift file. Porting by
walking the Swift directory listing found them again. The cost was two compile errors, because
`lib.rs` re-exports both names and Rust refuses the duplicate; had the port used private modules it
would have shipped two implementations of the same rule, which is the failure this whole migration
exists to prevent. The listing is not the inventory: the crate is.

**`MuxFlowTable` lost its object-identity dance.** The Swift keys every map by `ObjectIdentifier` of
an `NWConnection` and filters reply stamps with `!==`, because the flow handle is the identity. The
Rust takes a caller-supplied `FlowId`, so "drop every stamp pointing at this flow" is `retain(|_, f|
*f != flow)` over a `BTreeMap` and the transport keeps its sockets to itself. The reap's two rules
stay in their load-bearing order — the never-admitted stamp sweep must run BEFORE the reference
snapshot, or a stale stamp goes on protecting the flow it orphaned.

**The title truncation is a documented divergence, not a transcription.** Swift's `removeLast()`
drops a whole grapheme CLUSTER; Rust's char-boundary walk drops a whole SCALAR. Both satisfy the
rule the Swift doc actually states — a truncation is always valid UTF-8, never a replacement
character client-side — and they differ only for a cluster straddling the 120-byte cap, where the
Rust leaves the cluster's leading scalars and the row renders them as their parts. Matching Swift
exactly would mean a grapheme-segmentation dependency in a crate that has none, to change what a
truncated emoji looks like.

**Only the send lane's SCHEDULE ported, and that is the whole decision.** `VideoSendLane` is an
`NSLock`, a FIFO, an `AsyncStream` and a consumer `Task`; none of that is a rule. What is a rule is
the absolute-deadline pacing — chunk k due at `k × gap` from the job's start, so an oversleep eats
the next gap instead of pushing the schedule right — and the inline-send admission test. `pace_plan`
returns the chunk boundaries with their offsets and `may_send_inline` answers the one question the
lock was protecting, so the daemon's runtime supplies the queue and the sleeps and neither can
change what gets sent when.

## The client is a decision layer with a renderer attached (2026-08-13)

Stage 11 of the video port, and the first one on the CLIENT: `trendline`, `pacer_depth`,
`audio_jitter`, `mux_client_pool`, `client_session`, `client_view`, `client_input`, `client_jitter`,
`cursor_overlay` and `present_queue` in `rust/slopdesk-video`, plus the one-shot blob fetch in
`blob`, the one-shot discovery in `mux_client_pool` and the codec-free PCM convert in `audio_wire`.
743 unit tests plus the 19 golden tests, `make lint-rust`, `make lint-supervisor` and `swift build`
green.

**`StallVerdict` was already in the crate, and `lib.rs` is what said so.** The client's scrim latch
needs the live-versus-stalled verdict, so the port wrote the enum — and the crate refused it,
because `keepalive` had exported that name since stage 7. This is the same catch as stage 10's two
deleted modules and the same reason it worked: the re-export list turns a duplicate into a compile
error. A private module would have shipped two verdicts that agree today.

**The pointer inverse and the cursor forward are one transform, deliberately.** `client_input`'s
`normalize` and `cursor_overlay`'s `layer_frame_fit` are the two directions of the same mapping, and
they call `geometry`'s `displayed_video_rect` and `view_point` rather than each open-coding the
letterbox. If they ever disagreed the user would see the cursor on one pixel and the host would
receive a click on another — the class of bug that is invisible in a unit test of either side alone.
The actual-size viewport is a SECOND mapping, not a parameter of the first: it maps a texture
sub-rect onto the whole drawable with independent per-axis scales, which the fit path's single scale
cannot express.

**The queue's re-prime floor is two ticks and the comment explaining why is longer than the code.**
At the adaptive floor of one frame, a threshold of `max(1, depth)` collides with the transient-dip
detector: the first empty tick re-primes and wipes the run before any present can observe the dip,
so neither growth path can fire and the buffer pins at one frame with single-frame-repeat judder and
no way back up as a clean link degrades. `max(2, depth)` is inert at every depth above one and
load-bearing at exactly one.

**`clamp` is wrong wherever a NaN can reach it, and right where one cannot.** `f64::clamp` returns
NaN for a NaN input; the chained `max`-then-`min` lets the bound win, which is what Swift's
`Double.minimum`/`.maximum` do and what the wire needs — a NaN normalised coordinate or a NaN
playout delay is a poisoned schedule, not a clamped one. So `client_input::clamp_unit` and
`present_queue::clamped_playout_seconds` keep the chain with the reason in a comment, while the
`pacer_depth` env parsers, whose inputs are already `is_finite`-filtered, use the real `clamp`.
Clippy's `manual_clamp` does not fire inside a `const fn`, which is why only some of these carry an
`#[expect]`.

**The pacer's frames never enter the crate.** `PresentQueue` carries opaque `u64` handles and the
caller keeps the map to its image buffers, so the whole presentation policy — priming, homeostasis,
the transient-dip discriminator, the idle re-prime — runs off a virtual clock with no image pipeline
anywhere near it. The same line drawn for `VideoSendLane` in stage 10 and for the audio ring here:
`AudioJitterBuffer` ports every buffering DECISION while the lock-free hand-off stays in the runtime.

**The lane allocator takes its randomness as an argument.** Two clients each counting lane ids from
one both mint id one, and the host's reply maps are keyed by the bare lane id — so the second
client's lane hijacks the first's video and cursor replies. Seeding each process separates the
ranges. The crate stays deterministic, so `VideoFlowPool::new` takes the seed rather than drawing
it, and the module doc records the bug the seeding fixes so nobody "simplifies" it back to one.

**The one-shot fetches are a gate, not a transport.** Discovery, the icon fetch and the preview
fetch are all the same shape — acquire a transient lane, resend until an answer or a deadline,
release — over a path with no request-and-response machinery. `request_send_offsets` says when to
resend, `OneShotDiscovery` and `OneShotBlobFetch` say when to stop, and both make the FIRST matching
reply win so a resend that crosses the answer is harmless. The empty result is a first-class answer:
a host too old to understand the request never replies, and the picker must fall back to manual
entry rather than hang.
