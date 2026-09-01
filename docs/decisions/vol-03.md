# DECISIONS vol-03 — 2026-07-24 … 2026-07-26

> Volume 3 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## One-shape status circle, round 2: signature readings (2026-07-24)

The badge vocabulary consolidated onto ONE Ø12 circle (`0a6e8bd6`): every lifecycle state is a
hue/fill reading of the same silhouette (the otty per-state symbol set — rays spinner, raised
hand, warning triangle — is retired), and the iOS toolbar + Peek & Reply header mount the same
`StatusRing` instead of their SF-symbol set. On review the individual readings still looked
STOCK — a dashed 8-segment spinner is every loading indicator since Aqua, ring+halo is a
recording dot, ring+✕ is a generic error glyph. Round 2 keeps the one-shape contract (the
`Reading` enum, the mapping, and every pin are unchanged) and swaps the drawing of the three
dynamic readings for shapes in the app's own dialect:

- **working = the COMET arc**: one ~110° arc whose tail fades to nothing (angular gradient in
  the shape's own space), sweeping the ring smoothly (1.4s/rev, wall-clock phase — remounts
  land mid-revolution). Replaces the ticking dashed ring; motion reads as one object in
  flight, not a segmented spinner.
- **awaiting = the blinking cursor dot**: the solid ring holds steady while the 5pt centre dot
  hard-blinks on the terminal cursor's cadence (0.53s phases, on/off cut — never a fade). An
  awaiting pane IS a prompt with a parked cursor; the badge borrows exactly that signal. The
  stepped halo (recording-dot cliché) is deleted.
- **error = the BROKEN ring**: the circle itself with a ~50° gap bitten out (round caps, gap
  at the top-right), static and red — "the loop broke". The inner ✕ is deleted; the failure
  state is the only reading whose silhouette is damaged, which is the message.

`resting` (thin muted ring) and `done` (the established green 7pt filled dot) are unchanged;
`#`/`∞` stay text. Client-only, no wire change; pins untouched by design (they assert reading
CLASSES, not pixels).

### Round 3 — the circle yields to the terminal dialect: `AsciiStatusBadge` returns as `StatusGlyph` (2026-07-24)

Round 2's drawn readings (comet arc, cursor-dot ring, broken ring) still read as generic drawn
iconography on hardware review; the requested register is the TERMINAL's — status spoken as the
text a CLI would print. The v3 `AsciiStatusBadge` dialect (deleted by the otty reset) returns as
`StatusGlyph`, replacing `StatusRing` outright while keeping its surface contract (the `Reading`
enum + `TabBadgeStyle` mapping + the same three mount surfaces):

- **working = the AI-CLI asterisk pulse** `· ✢ ✳ ✶ ✻ ✽` breathing out and back (0.15s/frame,
  accent) — the agent's own spinner vocabulary.
- **busy = the braille dot-walker** `⠋⠙⠹…` (0.1s/frame, muted) — the shell's spinner. The busy
  tiers now split by VOICE, not just hue: `.running` speaks agent, `.commandRunning`/`.commandBusy`
  speak shell (new `Reading.busy`; the pins split accordingly).
- **awaiting = `?`** amber bold, blinking full↔dim ink on the cursor cadence (0.53s hard duty
  cycle, never fully off — the question keeps its slot).
- **error = `✗`** red static; **done = `●`** green (the established quiet dot, now as the printed
  character — the ✓ stays retired); **resting = `·`** muted; `#`/`∞` unchanged.

All glyphs render in the instrument (mono) face inside the same fixed 16pt box; both spinners are
frame-stepped off a fixed wall-clock epoch (all spinning rows step in unison, re-mounts land
mid-cycle), and the frame function is pure + static, pinned headlessly
(`testSpinnerFrameCadenceAdvancesOnePerBeatAndWraps`). Client-only; no wire change.

### Round 4 — the glyph column dissolves: status becomes the title's INK (2026-07-24)

Round 3's text glyphs were the right register but the wrong anatomy: `?` / `✗` / `●` are three
unrelated characters sharing one slot, and the review verdict was that the rows that show NOTHING
(working = title shimmer, running command = still title, idle = bare) are the ones that look right.
Round 4 follows that conclusion to its end — the **ink dialect**: a sidebar row never mounts a
lifecycle glyph. The states that need the eye recolour the text that is already there, the same
move the working shimmer makes for motion:

- **awaiting input** — the title turns amber and BLINKS full↔dim on the terminal cursor's cadence
  (`cursorBlink`, 0.53s hard duty cycle, never fully off): the row waits the way a prompt waits.
- **error** — the title turns red, static (red text is what a terminal already means by red text).
- **completed/finished** — the title turns green until the pane is visited (the unread-mail move,
  spoken in the hue budget's unread-finish green).
- **motion/idle** — unchanged: shimmer for a thinking agent, still text for a running command,
  secondary ink at rest. The trailing slot now belongs ONLY to the shell label / elapsed readout /
  privilege markers (`#`/`∞`, the sole remaining `TabBadgeView` renderings) / hover `×`.

One mechanism everywhere the status shows: the sidebar row, the iOS row, and the title-menu
NEEDS-ATTENTION rows (which drop their leading badge for a tinted title via `SlatePopoverRow`
`titleInk`) all speak `StatusPresentation.attentionInk`, and the titlebar pip reuses the same map —
the ink can never disagree with itself. `StatusGlyph` survives only where a compact single-pane
agent readout has no title to tint (iOS toolbar, Peek & Reply header), shrunk to
resting/working/awaiting/done — the braille walker and `✗` readings are deleted with their last
mounts. AX: the state the ink speaks rides the title's `accessibilityValue`. Pins:
`attentionInk ⇔ needsAttention` exhaustively, no-slot-glyph for every lifecycle kind, only-awaiting
blinks. Client-only; no wire change.

**Round 4.1 — the blink dies too (2026-07-24).** The awaiting blink read as tacky on hardware
review. Every attention ink now holds STILL — one rule, aligned with MERIDIAN's hard-cut ethos
(animation is reserved for the sustained live signal, i.e. the working shimmer; a waiting state is
not motion). `CursorBlinkModifier` deleted with its mounts; `StatusGlyph`'s `?` is static bold.
The titlebar pip remains the roll-up cue for "something waits".

**Round 4.2 — the agent row's trailing text goes silent (2026-07-24).** An agent row's slot
carried the live elapsed readout while working ("42s") and the process name ("claude") at rest —
both redundant on review: the `✳` marker already names the agent and the shimmer already says
"working". Agent rows now pass `processLabel: nil` and the elapsed readout is deleted
(`workingElapsedLabel` + its pin); the slot on an agent row holds only a privilege marker or the
hover `×`. The store's `paneWorkingSince` turn clock stays (core state, pinned) — only its
rendering died. Duration, when wanted, belongs to the tooltip's richness, not the rail.

### Round 5 — the instrument rail: one alignment, one metadata voice, the ladder's beat (2026-07-24)

The states were settled (rounds 4–4.2); what still read as unimpressive was the COLUMN's craft.
Diagnosis (against the shipped layout, cross-checked with the strongest external references —
Slack/tmux weight-plus-ink, Things 3 quiet numerals, Cursor's elapsed-as-metadata, Warp's own
users asking for whole-row ink): three faults, none of them the vocabulary.

1. **The rail was broken.** Three unrelated left edges — "TABS" at x20, row titles at x18, and the
   section header's NAME at x46 (chevron + folder icon + gaps) — put the PARENT deeper than its
   children, the inverse of every outline. Now there is ONE text rail: list inset (`space2`) + row
   inset (`tabRowInset` = `space3`) lands the caps label, header name, git line, and every row
   title on the same x; the disclosure chevron hangs in the `tabRowInset`-wide gutter BEFORE the
   rail (the outline idiom), and the folder icon is deleted — the chevron already says "group".
2. **Metadata had no typeface law.** The git line, shell label, and hidden-row count rendered in
   the system face while the ping and privilege markers spoke mono. Now one rule (MERIDIAN L2):
   DATA — git line, process label, count, telemetry — is the instrument mono at the caption size
   on the tertiary ink; identity (titles, header names) keeps the system face. The header name
   steps up to semibold so the parent stands firmer than its rows.
3. **Off the ladder for no reason left.** `heightTabRow` drops 36 → `heightRow` (32, the ladder's
   single-line rung), `radiusTab` 7 → 6 (the control-radius family), `tabRowInset` 10 → `space3`.
   The otty measurements served the 1:1 port; the port is over. The active card's cast shadow is
   now LIGHT-theme-only — on dark, depth is the surface ladder (fill + hairline), and a
   dark-on-dark shadow read as a smudged edge.

Two additions on top of the alignment work, both inside the existing vocabulary:

- **Attention pairs weight with ink** (`SlateTabRow`): an amber/red/green title also takes the
  `.medium` step the active card uses — the Slack/tmux idiom (bold says "something changed", the
  hue says what), two signals on one scale, no new elements.
- **The collapsed count wears the roll-up ink** (`StatusPresentation.attentionRollupInk`): a
  folded group's hidden-row count borrows the strongest attention ink among the rows it hides
  (question > error > unread finish — the resolver's own precedence), so collapsing a project can
  never mute a waiting agent. No pill, no glyph — the number that was already there, in the hue
  budget that already exists. Pinned headlessly (`testAttentionRollupInkFollowsBadgePrecedence`).

Deliberately NOT taken from the research: a fourth state hue (every good reference caps at three),
left-edge accent bars (state is the title's job), a second metadata line per row (richness stays in
the tooltip), idle-age fading (Arc's move — deferred; needs per-pane last-activity state).
Client-only; no wire change.

### Round 6 — colour comes back on purpose: identity tints, ink washes, the footer lamp (2026-07-24)

Round 5 fixed the skeleton; the review verdict on it was "correct but bare": deleting the folder
icon left the headers anonymous, the states/selection read as text-only recolours, and the footer
was two grey words. Round 6 reintroduces colour — but only where it MEANS something, so the
minimal-indicator conclusion of rounds 4–5 stands.

1. **Project identity tints** (`ProjectTint` + `SlateTheme.projectTints`). Each section header's
   gutter carries an 8pt rounded-SQUARE swatch in a per-project colour (square deliberately — the
   dot shape stays the status language: attention pip, footer lamp). The colour comes from the
   THEME's own chromatic set (Monokai: cyan/purple/orange — the three that carry no status meaning;
   amber/red/green are excluded so a project can never read as a state), keyed by FNV-1a over the
   project key: launch-stable by construction (Swift's seeded `hashValue` would reshuffle per
   process — pinned in `ProjectTintTests`). The collapse chevron still exists: it trades places
   with the swatch under the pointer (Notion's outline idiom — identity at rest, affordance on
   approach). The keyless "Other" bucket keeps a neutral swatch.
2. **The attention wash** (`Slate.State.attentionWash`). An inactive row in an attention state lays
   its title's ink under the WHOLE row at film opacity — the whole-row wash Warp users ask for —
   while the title keeps carrying which state (ink + weight, unchanged). One source feeds both
   (`SlateTabRow.attentionInk`), so wash and title can't disagree. Hover stacks on top.
3. **The active card is accent-lit** (`Slate.State.activeWash`/`activeEdge`). Selection was one
   luminance step (raised fill + neutral hairline) — correct and invisible. The card now adds a
   low-opacity accent film and swaps its hairline to the accent: doctrine already reserves accent
   for the ACTIVE state, and the focused-pane corner mark speaks the same colour, so the selected
   row is the one accent-coloured object in the rail.
4. **The footer becomes an instrument block** (`ConnectionRailFooter`). The sidebar footer drops
   the compact host+ping line for a two-line block on the sidebar's own rail, rhyming with the
   section headers: a 6pt health LAMP in the `tabRowInset` gutter (green good / amber slow or
   dialing / red bad / dimmed offline, soft same-hue glow while lit — static, never blinking;
   colour rides the needle curve), the hostname on the text rail, and the mono detail line beneath
   (ping while connected, the short status word otherwise — `ledState`/`footerDetail`, pinned in
   `ConnectionClusterTests`). The titlebar + iOS mounts keep the one-line cluster. This is the one
   sanctioned dot besides the attention pip — the "no LED" note from the cluster's first pass is
   superseded for the footer only.

Hue budget after this round: three STATUS hues (amber/red/green — states), the ACCENT (active
selection + focus, one voice), and three IDENTITY tints (projects — theme chromatics, non-status).
Nothing blinks; no lifecycle glyph returned. Client-only; no wire change.

### Round 7 — monochrome restored, the folder returns (2026-07-24)

The round-6 verdict: WORSE — the standing colour (identity swatches always lit, an accent-washed
card always lit, a green lamp always lit) made the rail gaudy, and the missing folder was the real
round-5 complaint all along. Round 7 re-establishes the rule the ink dialect had implied: **the
rail is monochrome at rest; colour appears only when something needs a human** (amber waits,
red failed, green unread-finish, warn/err ping digits). Reverted wholesale: `ProjectTint` +
`SlateTheme.projectTints` (identity swatches — GONE, including the pinning tests),
`Slate.State.attentionWash` (whole-row washes — state went back to being the title's ink alone),
`Slate.State.activeWash`/`activeEdge` (the active card is again the raised fill + neutral hairline
— one luminance step IS the selection language). Identity-by-colour is a dead end here: three
tints across many projects collide, and a coloured square per header is decoration the moment you
stop reading it.

Kept from round 6, but muted: the footer's two-line rail block (`ConnectionRailFooter` — the
LAYOUT answered "the footer is two grey words" and stays), with the lamp recoloured to the
monochrome ladder: connected = secondary ink, dialing/offline = tertiary (the detail word says
which), warn/err ONLY while a live link degrades — and the glow deleted. `LedState` and the
`ledState`/`footerDetail` maps are unchanged (still pinned).

Follow-up, same day: the muted lamp still read as clutter — a status dot beside a status word is
the tell of template design, and the review called it exactly that. The dot is DELETED; the
footer is pure text on the rail (hostname + mono detail, indented onto the shared text x, the
gutter empty). `LedState` survives as the INK classifier only (hostname dims via `.dim`, digits
take warn/err) — the "no LED" doctrine from the cluster's first pass is fully restored.

Returned by request: the dim `folder.fill` in the header gutter (the pre-round-5 glyph), on the
header ink — the one pictogram the monochrome rail keeps ("a group is a place"). First pass kept
round 6's hover-swap (folder at rest, chevron on approach); the follow-up verdict was that a
lone folder still reads bare — so the header now wears the full otty trio, chevron AND folder
always visible before the name (the name indents past its rows again; the hover-swap died with
its `hovering` state). Client-only; no wire change.

### Round 8 — the mark returns: T3 Code's dashed ring, static (2026-07-24)

Round 4's "no indicator" verdict is reversed by request: with the trailing slot holding only
text, the rail read lopsided — the rows wanted a small fixed-width mark back at the right edge,
and the reference this time was T3 Code's sidebar. The first pass ported the WRONG generation:
Sidebar V1's pulsing dot (`animate-status-pulse`), rejected on sight — a blinking dot is exactly
the template tell the footer round already named. The CURRENT `SidebarV2` renders a STATIC dashed
circle (lucide `CircleDashedIcon`) for in-flight work, so the shipped mark is that: an 8-dash
ring whose dash period divides the circumference exactly (no seam), a 10pt fixed footprint at the
row's trailing edge, nothing animated. Working agent = accent (keyed on the RAW `.working`
status, the same route as the `.running` badge tier); running command = muted secondary. The
V1-vs-V2 confusion is the round's lesson: port the source's CURRENT surface, verified against the
clone, not a remembered screenshot.

### Rounds 9–10 — one shape, hue is the grammar; the title goes neutral (2026-07-24)

Round 9 killed the two survivors of the V1 misread: the solid "act-now" dot (SidebarV2's own
status ladder renders `icon: null` for approval/input/failed — the colored label is the whole
signal there) and the title's `WorkingShimmer` (with a mark present, motion on the text was doing
the same job twice — the component and its tests are deleted; nothing in the rail animates).
Round 10 then took the last step: the INK DIALECT on titles (round 4's core idea) retires. Every
state renders as the SAME dashed ring and only the HUE names it — accent working, muted busy,
green unread-finish, amber question, red failure — and the title never recolours (the neutral
ladder; attention keeps only the `.medium` weight bump, the mail-unread idiom). The solid
done-ring lost to consistency on review, so done rings dashed too — one shape everywhere.
`StatusDotStyle` collapses to an ink; `attentionInk` survives as the hue map the mark and the
collapsed-group rollup count share.

### Round 11 — attention leaves the titlebar (2026-07-24)

The titlebar's amber pip (and the NEEDS ATTENTION section inside its `⋯` menu) predate the ring
marks; with the sidebar now naming every waiting pane in place, a second attention surface on the
content side was duplication. Both are deleted — the centred title is bare at rest, and the menu
opens straight at WORKING DIRECTORY. The unseen-attention QUEUE underneath
(`WorkspaceStore.unseenAttentionPanes`) is untouched: ⌘⇧U's visited-set walk still rides it (its
tests renamed to `UnseenAttentionQueueTests`, every behavior pin kept). Cascade deletions with
the last consumer gone: `SlateStatusDot`, `SlatePopoverRow`'s title-ink override, the titlebar
snapshot fixture — and, in the follow-up audit sweep, the entry's host-label field (read only by
the deleted menu row) leaves `UnseenAttentionEntry`; `since` stays, it orders the queue.

### Round 12 — the footer stops being a dashboard: one status line, no rule (2026-07-25)

With the row list settled, the sidebar's last unexamined band was its footer: a hairline, then a
two-line instrument block (hostname over `12 ms · up 2h 14m`). The verdict on both halves —
the rule read cheap, and the second line was paying footer real estate for readings nobody acts on.

1. **The hairline is deleted.** The panel's own dialect already says how bands separate: the
   section headers carry "no caps, no rule — groups separate by the header band's own air". A
   `Slate.Line.subtle` rule at the bottom was the one seam in a sidebar that draws none anywhere
   else. The separator is now the `space3` gap above the row — the same inter-group band the
   groups use.
2. **The footer collapses to ONE line** (`ConnectionRailFooter`): hostname leading on the rows'
   text rail, metric trailing in the rows' status-mark column, so the footer reads as the list's
   last line rather than a widget bolted under it. The ink rules are unchanged — `LedState` still
   dims the host while nothing is connected and puts warn/err on the ping digits alone; a status
   WORD ("reconnecting 3/20") now takes the system face while a METRIC keeps the instrument mono,
   matching the compact mount's trailing slot.
3. **Link uptime is retired outright** — `footerExtras`, `uptimeLabel` and `AppConnection`'s
   `connectedSince` stamp all go with it (the readout was their only reader). "How long has this
   link been up" is a number you read once and never act on. The stream numbers do not move into
   the freed slot either: appending them is what truncated the hostname in the first place
   (`2850f842`), so fps/kbps stay tooltip detail on BOTH mounts.

The two mounts are now the same shape — host leading, metric trailing — differing only in their
insets and in the rail's willingness to say "connected" in the beat before the first ping sample
(the compact row stays silent there; a connected footer with an empty right edge reads as broken).
Deliberately NOT taken: a `+` New-Tab affordance in the freed space (the footer is status, not a
control strip), and a host-load readout (genuinely useful, but it needs a new host→client control
message — a separate scope, not a polish round). Client-only; no wire change.

### Round 13 — the second line comes back, this time about the MACHINE (2026-07-25)

Round 12's freed line is spent, on the one readout it explicitly deferred: the host's pulse.
The footer is two lines again, and the difference from the version round 12 killed is what the
second line is ABOUT. `12 ms · up 2h 14m` was more link: a metric nobody acts on, stacked under a
metric they do. `cpu 34% … mem 61%` is the other end of the wire — the machine you are typing into,
which you cannot see and cannot otherwise ask.

1. **New host verb: `hostVitals` (metadata verb 17, PATH 1).** A pure read, host-global and
   pane-agnostic like `hostInfo`, answering 3 bytes: `[cpu%][mem%][pressure]`. It rides the existing
   metadata RPC rather than a new push message — the client already owns a poll clock and a
   "through whichever pane has a live channel" resolver, so a push type would have bought nothing
   but a new wire surface. `AppConnection` polls it on the supervisor's own liveness clock at half
   rate (~4 s), fire-and-forget so a slow metadata reply can never delay the drop detection.
2. **CPU is a delta, so the host may answer "not yet".** Mach hands out cumulative counters;
   `HostVitalsSampler` banks a baseline, discards one older than 30 s (a window spanning a
   disconnect describes a machine that no longer exists) and repeats its cache for a call that
   arrives inside 1 s. `error` therefore means "ask again next poll", never a fabricated `0%` — and
   a missed poll leaves the last reading standing rather than blanking a working instrument.
3. **The rail still doesn't twitch.** A percent polled every 4 s jitters ±2 on an idle machine, and
   this rail has no animation by design. `HostPulse` deadbands each metric at 3 points: below that
   the row holds still, at or above it snaps to the sample EXACTLY (never a smoothed midpoint — the
   number shown is always one the host really reported). Pressure is exempt; a state change is not
   noise.
4. **Colour where it is earned.** The MEM run takes warn/err from the kernel's memory-pressure
   level, not from the percent (a high memory percent is ordinary — macOS fills the RAM it has;
   pressure is what predicts a machine about to crawl). CPU is never coloured at all: a build
   pegging the host is what the host is FOR, and a readout that goes amber every compile teaches the
   eye to ignore it. Exact numbers + the pressure word ride the tooltip, with the ping's fps/kbps.
5. **Absent, not blanked.** No reading ⇒ no second line — an instrument showing `cpu —` advertises
   breakage, while a footer that grows a line on connect just reports. Both lines share round 12's
   two rails, so the pulse sits in the same columns as the host name and the ping.

Wire change (a new verb + payload codec, golden-pinned); the daemon and the client both ship it,
and an old host answering `unsupportedVerb` simply stays one line.

**Round 13.1 — the metrics are named by their marks.** `cpu 34% … mem 61%` set the whole line in
lowercase prose, and read as a sentence adrift under the identity rather than as instruments. The
words are replaced by their symbols (`cpu`, `memorychip` — Activity Monitor's own pair), leaving
`▣ 34% … ▤ 61%`: a readout is a number and the thing it measures, and the thing it measures is the
one part that never changes, so it should be the part that is drawn rather than spelled. The two
marks differ in SILHOUETTE (square, pinned on four edges vs a wide module pinned on one), which is
the only distinction that survives at 11pt. Mark and digits carry ONE ink — when pressure colours
the memory reading the glyph turns with it, since a half-tinted readout reads as a rendering bug
rather than a warning. The words are not lost, they move to the surfaces that have room for prose:
the tooltip and the accessibility label, which cannot see a silhouette at all.

**Round 13.2 — free disk takes the middle rail.** Two runs on a 220pt line left a hole in the
middle, and the hole was worth a third reading rather than wider tracking: a host stops being useful
in exactly three ways — busy, full, out of room — and only the first two were reported. So
`hostVitals` grew a `[UInt32 disk free MiB]` field (7-byte payload; golden hand-merged) read from
`statfs` on the HOME volume, which on a modern Mac is the Data volume the work actually consumes
rather than the read-only system snapshot at `/`. Three consequences worth stating:

- **It is the one metric given in BYTES.** A disk percent lies in both directions — 2% of a 4 TB
  disk still builds, 8% of a 128 GB disk does not — so both the reading and its ink threshold are
  absolute (amber under 15 GiB, red under 5 GiB). There is no kernel "disk pressure" verdict to
  defer to the way the memory run defers to one.
- **Unreadable is not zero.** A full volume genuinely reports 0 MiB, so the failed-syscall case gets
  its own wire value (`UInt32.max`) and the run simply disappears — the two rails keep reporting. A
  metric that cannot be read must not take the working ones down with it, nor draw a full-disk alarm
  for a refused syscall.
- **The format is the deadband.** CPU and memory need one because a percent twitches; free space is
  rendered at two significant figures (`820M`, `6.4G`, `240G`), and a number that only names round
  values cannot twitch. Adding a threshold on top would have made the slowest metric also the
  laggiest.

**Round 13.3 — the three readings run fastest-moving to slowest.** Free disk went in at the middle
rail on the argument that the least-consulted metric belongs where neither rail is. Ordering by how
often a reading is *consulted* turned out to be the wrong axis; ordering by how fast it *moves* is
the one the eye already uses. So the line reads `cpu · mem · disk`: cpu changes second to second,
memory over minutes, free disk over days, and a glance travels from "right now" toward "next week"
instead of stepping over the slow reading to get to the fast one. It also keeps the two PERCENTS
adjacent — they are the pair a glance actually compares, and the odd reading out (the only one in
BYTES) now sits at the end where its different shape stops interrupting them. The tooltip and the
accessibility label speak the same order, so neither is a re-shuffle of the row. Nothing else moves:
the thresholds, the inks, the absent-not-blanked rule and the wire are all unchanged.

### Round 14 — the muted ring belongs to the agent, not to every busy shell (2026-07-25)

Round 8 gave the muted secondary ink to "running command", and in daily use that turned out to be
almost every row: any pane with something in the foreground — a dev server, a `tail -f`, a long
build — wore a mark. The ring stopped meaning anything, and the states that DO need the eye had to
compete with a rail full of quiet decoration.

The mark is now the AGENT's column. `StatusPresentation.statusDot` takes an `agentIdle` input (the
raw `ClaudeStatus.idle` verdict — a code agent PRESENT and at rest) and the muted ring is that
state's rendering and nothing else's; `.commandBusy` / `.commandRunning` mount nothing. Two things
this is not:

- **Not a resolver change.** `TabBadgeResolver` still fuses the busy tiers exactly as before — the
  control backend's badge tokens, the tooltip vocabulary and the title chain (which titles a busy
  row with its running command) all read them unchanged. Only the view-layer hue map narrowed.
- **Not a new signal for agent rows.** A resting `claude` pane already wore the muted ring, because
  the agent process holds the shell's OSC-133 block open for its whole lifetime and arrived here as
  a bare `.commandBusy`. That row looks identical; what changed is that a pane which is busy WITHOUT
  an agent no longer borrows the reading. The busy tiers keep falling through the same branch, so
  an agent at rest still rings whether or not it also carries a privilege marker.

A running command is already named by the row's own title, which is the more informative surface —
spending the mark on it too was the duplication round 9 removed from the title's shimmer, in the
other direction. Client-only; no wire change.

### Round 15 — the agent teardown edge: an announced exit must not be undone by a lagging one (2026-07-25)

`/exit` inside a pane left the row wearing Claude Code's title (`✳ <topic>`) and the agent's muted
ring for ~31 s. Measured on the wire with a mux-aware tee over six real exits, the tail was two
independent defects that happened to fire together.

**The grace paradox.** `SessionEnd` fires while `claude` is still the PTY foreground — captured at
1.0–1.5 s of overlap before the shell reclaims it. Across that gap every weak liveness signal still
sees an agent: the ~1 Hz foreground poll, the 300 ms screen scan, the OSC title still on the grid.
Any one of them lifted the presence floor straight back off `.none`, and the resurrection landed
34–440 ms after the pane went dark (4 of 6 exits; the other 2 were clean, which is what made it feel
intermittent). Worse, `ClaudePaneDetector.hook` stamped `lastAuthoritativeAt` on EVERY parsed
record, `SessionEnd` included — arming the 30 s window in which a foreground ABSENCE is suppressed.
So the one signal announcing the end was also what kept the dead state alive for the full window.

Two changes, in the two places that own the two halves. `SessionEnd` now CLEARS the stickiness
anchor instead of stamping it: the anchor exists to protect a live state from a poll that cannot see
a wrapper-launched agent, and a session that just ended has no live state to protect — the absence
about to arrive is the SessionEnd's own corroboration, not something to defend against. And
`ClaudeStatusMachine` gained a POST-EXIT FLOOR LOCKOUT: a hook `sessionEnd` arms
`postExitFloorLockout` (3 s, clearing the widest measured overlap), during which no weak signal —
presence, title, screen, manifest, an informational Notification — may lift `.none`. Only an
authoritative hook clears it, so `claude` relaunched immediately is never held dark. Presence
ABSENCE arms nothing: `processPresent(false)` is the end already observed, not an announcement of
one. This is herdr's process-exit primacy and t3code's `context.stopped` idempotence, expressed in
the reducer where both belong; the deliberate difference from t3code is that our terminating signal
is racy, so the veto has to be time-bounded rather than a plain flag.

**The orphaned title.** Claude Code DOES emit its own exit-time title clear — captured as
`OSC 0;` with an empty body — but `HostOutputSniffer` drops empty titles on purpose (zsh/p10k emit
them mid prompt-redraw), and the client dropped them a second time. A plain zsh prompt never
re-titles afterwards, so the agent's title had no way home. The fix is OWNERSHIP, not
guard-loosening: `ClaudePaneDetector` records that a DETECTED agent wrote the pane's title (the
spinner / `✳` / claude-naming shapes the machine already believes) and, on the agent-gone edge,
emits an explicit empty type-21 — a one-shot, scoped to titles the agent demonstrably owned, so a
shell's own `nvim — README.md` stays put. The host sniffer keeps dropping empty OSC bodies, which is
what makes an empty type-21 on the wire unambiguous; the client's duplicate guard is retired and it
now applies the retirement. The retirement also forgets the sniffer's coalescing anchor, since the
next `claude` in the same pane opens on the byte-identical `✳ Claude Code` and would otherwise be
deduped into silence. Titles that are OWNED and never decay is the one t3code idea that transferred
directly (`canReplaceThreadTitle`) — the difference is that t3code's titles are its own, so it never
needed the giving-back half.

Three adjacent gaps closed in the same pass:

- **A ctl-spawned pane had no agent detection at all.** `spawnStandalonePane` constructed its
  session without `agentDetectEnabled` and never threaded `SLOPDESK_SOCKET_PATH` / the pane id, so
  the one place an ORCHESTRATOR runs its agents was the one place they ran unobserved — no detector
  to fold into, and no hook route in. Both now match the mux path; `registerHookSink` gained a
  paneID-keyed form (a ctl pane's identity is its session uuid — there is no channel pair), and the
  key is retired on every teardown so a spawn no longer leaks a sink per pane.
- **The ctl `events` stream could not report the agent-gone edge.** `.none` and `.idle` collapse to
  the same supervision word by design, and the subscriber dedupes consecutive identical states — so
  a pane whose agent left emitted an `"idle"` byte-identical to the one it was already at, and the
  transition vanished. `AgentControlState.presence(from:)` carries that one bit alongside the state:
  it joins the dedupe key and rides the event as `agentPresent`. The four-state vocabulary the
  `report` verb validates against is untouched.
- **`Stop` carries `background_tasks`.** Undocumented in the hooks reference but present in the
  shipped payload (verified against the CLI binary), already filtered producer-side to
  running/pending backgrounded tasks. Parsed tolerantly onto `StopInfo.backgroundTaskCount` and used
  as the done-chip label ONLY when the turn ended without an assistant message — "3 background tasks
  running" beats an empty chip. Deliberately NOT a status change: the rest-title demote would undo a
  `.working` within a second, and no hook fires when a background task finishes, so any richer state
  this set would have no way home.

Rejected: a herdr-style DEFERRED clear (hold the teardown briefly in case the agent respawns, to
avoid flicker). The veto already prevents the flicker it targets — nothing resurrects, so nothing
flickers — and a settle delay works directly against the reported complaint, which was that the pane
took too long to go quiet.

### Round 16 — a finish you have READ is not unread (2026-07-25)

The unread agent-finish latch (`paneUnseenDone`, round 7.3) has exactly one clear path:
`clearAgentBadge`, which runs on a SELECTION change — a tab switch, a rail click, a ⌘⇧U step.
Returning to the app selects nothing. So the common shape — a turn finishes while you are in a
browser, you come back to the pane you already had focused — left the finished marker sitting on the
one pane you were staring at, and the only way to dismiss it was to click to another tab and back.
"Unread" had drifted from *you have not seen this* to *you have not re-selected this*.

The fix is a DWELL, not a clear-on-contact: a pane that is focused, in an active app, and carrying a
finished-turn marker (a live `.done` or the latch) starts a watch clock; after
`focusedDoneSettleWindow` (30 s) the client acknowledges it for you. Contact alone changes nothing —
the marker's whole job is to tell you a turn ended, and it still gets to.

Scope is deliberately narrow, and is the part worth protecting:

- **Only a focused pane in an active app.** An unfocused pane keeps the original contract exactly —
  unread until visited, however long that takes. Nothing can expire behind the user's back.
- **The window measures an UNBROKEN watch.** Focus leaving, or the app backgrounding, abandons the
  clock; a later return starts a fresh one. Two one-second glances never add up to an acknowledge.
- **Only a FINISHED turn.** `.working` and `.needsPermission` are live signals, never unread output,
  so neither starts a clock — the settle can therefore never silence a waiting approval gate.

The driver is the same one-shot idiom as the completion flash (`doneSettleScheduler`, armed when a
watch starts), because a finished agent stops mutating the store and nothing else would look again.
It gets its own property rather than sharing `flashDecayScheduler` so the two boundaries stay
independently injectable. The three edges that can change the answer — an agent-status transition, a
focus change, and the `isAppActive` edge — all call the same refresh, which both starts and retires
clocks; the acknowledge feeds back through `setAgentStatus`, by which point the pane is no longer a
candidate, so the recursion terminates on its own.

Host-side nothing changed: the status machine's own `done → idle` decay stays at 8 s. That decay
answers "what is the agent doing"; this window answers "has the user seen it" — the same split the
latch was introduced to make.

### Round 17 — the git line gets its states back (2026-07-25)

The project header's second line (`main ↑2 ↓1 +1 !3 ?5 ~2 $1`) was painted in one flat
`Slate.Text.tertiary` — the metadata register it shares with the rows' process labels and the footer
telemetry. That register is right for text that is *there if you look*; it is wrong for a line where
a merge conflict and a branch name rendered identically. The whole line sank.

Each run now carries its own ink, on two registers: a state that wants a HUMAN wears a status hue
(conflict red, dirty amber, staged green, divergence/stash info), everything else wears the readable
body ink. Nothing on the line resolves to tertiary any more — the flatness *was* the bug.

The dialect is unchanged (same sigils, same fixed order, non-zero only). `gitSegments` is now the
single source of truth and `gitLine` joins it, so the painted line, the hover tooltip and the
accessibility label cannot drift. The runs are concatenated into ONE `Text` via an `AttributedString`
rather than laid out in an `HStack`, so the line still truncates by tail — an `HStack` would clip a
whole run instead, and the run it would drop is the rightmost, which is where `~conflicts` sits.

Roles, not colours, in the pure layer (`GitInk`): the palette resolution lives in the one `@MainActor`
`ink(_:)`, so the dialect stays headlessly pinnable and a theme swap repoints every run at once.

Colour turned out not to be the whole answer, and measuring said why. Against the sidebar ground on the
default theme the runs rank `!modified` 11.9 : `↑↓`/`$` 10.3 : `+staged` 10.2 : `~conflicted` 5.7 :
branch 5.3 — the one state that genuinely needs a human pulls the eye LEAST of the coloured runs.
Monokai's yellow is bright and its red is a mid pink; no re-assignment of hues fixes that without lying
about what the states mean, and `statusErr` is theme-owned. So the line also carries a WEIGHT ladder,
which costs no palette and holds on every theme: the branch stays regular (identity, not a status),
every COUNT is semibold (at 10 pt mono a regular weight leaves the readout thin enough that colour does
all the work), and `~conflicted` is bold. The step also buys a third cue under the one CVD collapse the
measurement found — under protanopia `+staged` and `~conflicted` land ~3 ΔE apart, indistinguishable by
hue; the sigils already carried the meaning, the weight now backs them.

Measured but NOT acted on: both LIGHT themes fail AA on this line (`paper` branch 1.86:1,
`monokaiProClassicLight` every run 2.80–3.32:1). That is a theme-token defect, not a git-line one —
`paper.textSecondary` on `paper.ground` is 1.86:1 for every secondary label in the app, the folder name
directly above this line included. Fixing it repaints the whole chrome and is its own decision.

### Round 18 — Monokai Pro only, and the git line gets a ramp (2026-07-25)

The theme list shipped six Monokai Pro filters plus two one-off palettes (`paper`, `dark`) built by hand
rather than from a `MonokaiSeed`. Those two are gone. The cull is not tidying: it is what makes a
guarantee possible. Every shipped theme is now seed-built, so every theme has the SAME six chromatics —
which means chrome can reach past the status quartet and know that every filter can supply the ink.

`SlateTheme` therefore surfaces `chromaOrange` / `chromaPurple` (`Slate.Chroma`). Each Monokai filter
ships six chromatics; the status quartet spends four (green / yellow / red / cyan) and these are the
other two. They previously reached only the terminal's ANSI palette. They are deliberately NOT statuses:
no urgency attaches to them, the consumer assigns the meaning.

Which lets the git line stop sharing inks. The four WORKTREE states are a RAMP, not a set of labels:
`+staged` → `!modified` → `?untracked` → `~conflicted` is *how far this work is from being committed* —
in the index, in the worktree, git has never seen it, it is broken. The filter's chromatics sweep that
distance exactly: measured on the default theme the hue angles run 126.9° → 89.2° → 51.5° → 9.8°,
green→yellow→orange→red, monotone, in the SAME left-to-right order the sigils already appear. `?` is
orange not because a sixth colour was available but because it is the rung between "you changed it" and
"it is broken". `↑↓` divergence and `$` stash sit OFF the ramp on cool hues — neither is a worktree
state — and the branch keeps the body ink. No two runs now share an ink, which a test pins.

Measured across the six survivors: every run clears WCAG AA on all five DARK filters (min 4.89:1).
`monokaiProClassicLight` still does not (2.80–4.65:1) — unchanged and still upstream of this line, since
its own `textSecondary` and status colours are too light for its own sidebar ground.

No migration, per the standing rule: a persisted `"paper"` / `"dark"` no longer decodes as a
`ThemeChoice`, so the whole `AppearancePreferences` blob decode-fails to its all-`nil` default and the
app follows the OS onto Monokai Pro Classic / Classic Light. Nothing to write, nothing to version.

### Round 19 — the shape becomes the grammar, and two marks are allowed to move (2026-07-30)

Rounds 9–10's twin verdicts — ONE shape, hue is the whole grammar, and *nothing in the rail
animates* — are reversed BY REQUEST: the shipped rail read "tĩnh lặng và đơn điệu quá" (too still,
too samey). Four dashed rings differing only in hue is a legend you have to learn; and with motion
banned outright, a row that was *working right now* looked exactly like a row that had finished an
hour ago apart from its tint. The reference is otty's own sidebar, which spends a distinct
pictogram per state and mounts a real spinner while a command runs.

So the mark column keeps its fixed footprint and its one-mark-per-row rule, and swaps the alphabet:

| state | mark | ink |
|---|---|---|
| agent working | the breathing asterisk `· ✢ ✳ ✶ ✻ ✽` (0.15 s/frame, palindrome) — ⚠️ **superseded twice by the follow-up below; shipped as the closed turning RING** | accent |
| agent at rest | the round-8 static dashed ring — UNCHANGED | muted secondary |
| agent blocked | `hand.raised` — otty's "answer me" hand — ⚠️ **superseded: now `questionmark.circle`, see follow-up 3** | amber |
| agent done / unread finish | the filled dot (otty's `circlebadge.fill`) | green |
| failure | `exclamationmark.triangle.fill` — ⚠️ **superseded: now `exclamationmark.circle`, see follow-up 3** | red |
| plain running command | **not in this column** — see below | — |

Motion is now permitted, but under a rule narrow enough to keep the round-9 lesson: **a mark may
move only while something is genuinely in flight, and only two marks qualify.** A settled rail is
still perfectly motionless — nothing pulses to attract the eye, nothing blinks to say "unread"
(the finish is a still dot; the mail-unread weight bump on the title survives untouched).

The working pulse is not a new spinner: it reads its frames from the pulse `StatusGlyph` has
spoken on the iOS toolbar and the Peek & Reply header since MERIDIAN. The definition MOVED to
`StatusDot.pulseFrames` and `StatusGlyph` now reads from there — one breath, so the rail and a
compact header can never disagree about one pane. Frame-stepped off a fixed wall-clock epoch, so
every spinning row steps in unison and a re-render lands mid-cycle instead of restarting it.

**The running command's spinner takes the SLOT, not the mark column.** otty's `TabsPanelRowView`
mounts an `NSProgressIndicator` where the row's right-hand shell label sits, and that is the shape
of the fix: while a real command runs, the still process name (`swift`) — which looked identical
whether the command was live or had exited twenty minutes ago — yields to a drawn eight-spoke
wheel with a comet tail (0.1 s/spoke, one revolution in 0.8 s). Drawn rather than `ProgressView`
so the ink is a theme token, the footprint is pinned to the mark column's, and the phase comes off
the same epoch the pulse uses. The command line itself is unchanged in the tooltip, and the row
title still upgrades to the running command wherever it already did.

Three exclusions on that spinner, each load-bearing:

- **the busy-badge tier is the reveal gate.** No new threshold: the spinner keys on
  `commandBusy`/`commandRunning`, which `WorkspaceStore.paneShowsBusyDot` already delays by the
  "Busy reveal delay" (default 1 s), so a fast `ls` never flashes a wheel.
- **an AGENT pane never spins.** `claude` holds the shell's OSC-133 block open for its whole
  interactive lifetime, so `isBusy` stays true for HOURS — a naive "busy ⇒ spin" would leave every
  idle agent row spinning forever. This is the same trap round 14 hit from the other side (the
  muted ring belongs to the agent, not to every busy shell), and it is why the gate takes
  `isAgent` rather than reading the badge alone.
- **the shell is not a command.** A busy pane fronted by a bare login shell keeps its label, as
  does a pane whose foreground process the host has not reported: with nothing to name, there is
  nothing to claim is running.

`accessibilityReduceMotion` freezes both moving marks rather than hiding them — the pulse on `✳`
(the mid-swell frame; `·` would read as a resting dot) and the wheel on its fully-lit step. A
state that only exists as an animation would be invisible to a user who asked for stillness.

`StatusDotStyle` grows from an ink to a (shape, ink) pair; `attentionInk` is untouched and still
shared with the collapsed-group roll-up count. Client-only, no wire change, no new setting — the
existing agent/command badge gates keep governing what the row is allowed to say.

**Follow-up, same day — BOTH animated marks become drawn geometry, and no typed spinner survives in
the rail.** The AGENT's pulse read as ugly on hardware (the command wheel was never in question and
is unchanged — a misread of "the running indicator" briefly swapped it for an ASCII line sweep; that
detour is reverted). The verdict on the pulse was "drop the ASCII spinner, draw it instead so font
errors can't happen", and chasing that is what turned up WHY it looked wrong — which had nothing to
do with the design:

**The instrument face is only JetBrains Mono when that font is installed, and it is not.** It is
absent on the dev Studio, so `Slate.Typeface.instrument` falls back to the system monospaced face,
and CoreText then substitutes per-character from wherever it likes. Measured:

| frames | resolves to | advance |
|---|---|---|
| `·` U+00B7 | the system mono's own | 6.80 |
| `✢ ✶ ✻ ✽` | Menlo-Bold | 6.62 |
| **`✳` U+2733** | **AppleColorEmojiUI** | **16.00** |
| `⠋⠙⠹…` / `⣾⣽⣻…` | **AppleBraille** | — |

So the "asterisk pulse" was never one typeface: nine frames of Menlo plus one **colour emoji** at
2.4× the advance that ignores `foregroundStyle` — a coloured star that jumped the mark's width
mid-cycle, and (since the Reduce-Motion frame was `✳`) the ONLY thing a Reduce-Motion user ever saw.
Braille, tried as a replacement, is worse: **no mono face we can count on carries U+2800…U+28FF**, so
both the light `⠋⠙⠹…` and the heavy `⣾⣽⣻…` land in **AppleBraille** — an embossing font that draws
sparse little circles, ignores the requested weight, and renders the two cycles indistinguishable and
nearly invisible at 11pt. Two renders looked unchanged before the font check explained why.

Hence the first rule this round ends on: **in the mark column, animation is VECTOR, never type.**
`CommandSpinner` keeps its eight-spoke comet wheel; both animated marks step on one shared primitive,
`StatusDot.frame(at:frames:beat:)`, off the fixed epoch — so they stay in unison and pin as pure
numbers. Exact size, exact ink, no font on the machine to get in the way.

**The asterisk did not survive being drawn either, and that gave the second rule.** Redrawn faithfully
as six capsules budding out of a centre dot, the star was still judged ugly — and rendering the
candidates at true size next to a 4× blow-up showed why, in pixels rather than prose: at 12pt a
radiating star is a burr of spikes, and magnified it reads as a cogwheel. **One stroke scales down;
detail does not.**

So the working mark becomes the RESTING RING, turning: `AgentSweepMark` draws the same circle at the
same diameter and stroke weight. Which turns the agent's column into ONE CIRCLE with three readings:
**dashed while it waits at its prompt, closed and turning while it works, filled once it has finished
something you haven't read.** A progression, not a legend to learn. The choice was made from a
rendered comparison sheet of four drawn candidates (star bloom, arc sweep, travelling gap, orbiting
dot); the rig was deleted once it had done its job.

**Follow-up 3 — the circle takes the last two states, and the rotation stops being plastic.**

The two states needing a HUMAN were left outside the circle as otty's raised hand and warning
triangle. They are now **inside** it: `questionmark.circle` amber and `exclamationmark.circle` red,
drawn at the point size whose circle lands on `ringDiameter` rather than at a type-scale size — a `?`
a point wider than the ring above it breaks the family faster than any hue could. So EVERY mark in the
column is one silhouette and the INSIDE carries the state, which is the difference between a
progression and a legend: `◌` waiting · `◯` turning · `?` asking · `!` broken · `●` finished unread.
`StatusMarkShape.symbol` exposes the two circle variants precisely so a test can pin that a triangle
never creeps back.

And the rotation is now **continuous, not stepped**. Twelve discrete hops per turn read as plastic — a
hop is the mechanism showing through, and the eye reads mechanism as cheap. The angle is a smooth
function of the wall clock sampled per display frame (capped at 60 fps), and two further things move
with it, which is what separates a thinking indicator from a loading widget: the tail **dissolves**
(the stroke is an `AngularGradient`, full ink at the head to nothing at the tail, so the figure reads
as something travelling rather than a gapped shape being rotated), and the arc **breathes** (its
length oscillates across 0.45…0.78 turns on a 2.3 s sine, deliberately incommensurate with the 0.9 s
revolution, so the silhouette never repeats and the motion never reads as a loop).

Both derive from the same clock as the rotation, so the mark holds no animation STATE — which is not
an aesthetic point: a `repeatForever` animation would restart on every chrome tick and snap the arc
back to the top, and every working row would drift out of phase with its neighbours. `turns(at:)` and
`length(at:)` are pure and pinned, including that the ramp has **no plateaus** when sampled far finer
than a frame (a plateau is a hop) and that the two cycles stay incommensurate.

**Follow-up 4 — a constant rate is also plastic; the tail dot; one diameter for everything.** Three
findings from the same look, each with a mechanism behind it rather than a taste:

1. **Continuous was not enough — a CONSTANT RATE reads as mechanism too.** The angle now leads and
   lags an even sweep by `swing` = 0.055 turns twice per revolution (roughly 0.3×…1.7× rate), so the
   arc accelerates and coasts. The amplitude has an ARITHMETIC ceiling, not a stylistic one: the angle
   is `t + swing·sin(4πt)`, whose derivative is `1 + 4π·swing·cos(4πt)`, so at or above `1/4π ≈ 0.0796`
   the arc STALLS and then runs BACKWARDS once a cycle — broken, not eased. `swingCeiling` is pinned so
   a later "make it bouncier" cannot cross that line unnoticed. ⚠️ Note for whoever tests this: the
   ease crosses zero at every QUARTER turn, so a quarter-period sample sits exactly on the straight
   line and would "prove" the motion is linear; the pin samples an EIGHTH, where the lead is full.
2. **The dot trailing the arc was `lineCap: .round`.** A round cap paints a half-disc beyond each end
   of the stroke; at the tail — where the gradient has faded to nothing and the angular gradient wraps
   its seam — that cap picks up ink from the far side of the seam and shows as a DETACHED dot chasing
   the arc. Butt caps end exactly where the stroke ends, so the fade is the only thing terminating the
   tail. (At a 1.5pt stroke the now-flat head is imperceptible; verified across a full revolution and a
   full breath on a phase sheet, not on one lucky snapshot.)
3. **One diameter, no exceptions.** The finish dot was drawn at 6pt against the ring's 8pt, on the
   reasoning that a solid mark carries more weight per point than an outline one. True in the abstract
   and wrong here: it made the column's sizes wobble row to row, which is the one thing a fixed status
   column may not do. `dotDiameter` is now an ALIAS of `ringDiameter` so it cannot drift again, and the
   `?`/`!` point size is chosen by where its circle lands (≈0.8× the point size) rather than by type
   scale. All four pinned.

**Follow-up 5 — the working ring is DASHED, and the whole gradient idea was the problem (user's
proposal).** The eased comet arc was still rejected, and the suggestion that replaced it — *"để ring
là các nét đứt rồi xoay xoay có đẹp và độc đáo hơn nét liền không"* — is right, for a reason the
render sheet makes plain rather than a stylistic one. Six cuts were drawn at true size and at 8×:

- ⚠️ **At 12pt, a gradient spends half its length being invisible.** That is what a comet IS — full ink
  at the head, nothing at the tail — and it is why the arc looked good magnified and generic-to-muddy
  at the size it actually ships. Every gradient cut on the sheet lost its faded half at 1×. The rule
  that now covers this column: **flat ink and whole shapes at 12pt; gradients and detail are luxuries
  of the zoomed-in view.** (Same shape as the round-19 lesson "one stroke scales down, detail does
  not" — a third instance, so it is written as a rule now.)
- ✅ **Dashes carry motion that a comet cannot at this size**: several small shapes crossing the ring
  are legible even though each is barely 2pt long, and no single one has to fade to say "moving". It is
  also not the arc-spinner every platform already ships, which is what "generic" meant.
- ✅ **The cut is FIVE dashes, not the resting ring's eight.** Eight at 8pt reads as a nearly solid ring
  (measured — the dashes stop separating), and identical dashes would have made the working mark the
  resting mark in a different hue the moment Reduce Motion froze it. Five longer arcs is the same
  circle carrying MORE INK while it works — a progression — and stays legible frozen and to a
  colour-blind eye. Pinned: `dashCount` < `ringDashCount`, and each working arc longer than a resting
  dash.
- ✅ **The surge is per DASH, not per revolution.** What the eye tracks is one arc crossing into the
  next slot, so the ease rides `sin(2πN·t)` and the stall ceiling TIGHTENS to `1/2πN` (0.0318 at five
  dashes, vs `1/4π` for the one-per-half-turn cut) — `swing` = 0.020 gives 0.37×…1.63×. A surge per
  revolution would read as a wobble with no visible cause. ⚠️ Test trap moves with it: the ease now
  crosses zero every HALF dash period, so the "not linear" pin samples a QUARTER of one.
- ✅ **Revolution is 3.6 s, read through the dashes**: one arc reaches the next slot in ~0.7 s. Spinning
  the RING at that rate would strobe — with rotational symmetry every 1/5 turn, a 1 s revolution is
  five visual cycles a second.
- ✅ **The breath moved from the arc's LENGTH to the dashes' FILL** (0.5…0.7 of each period, still on the
  incommensurate 2.3 s cycle): the arcs lengthen and shorten as they travel. Above ~0.75 the ring is
  solid with notches in it; at 0.5 ink and gap are exactly even, and that is the floor. Pinned that the
  dashes tile the circumference exactly at EVERY breath frame — a breath may not open a seam.
- ✅ **Two problems deleted rather than fixed:** a dashed ring has no ends to cap (so no round-cap tail
  dot, follow-up 4 №2) and no gradient seam to cross. `AngularGradient` and `lineCap` are gone from
  this mark entirely.

**Follow-up 6 — the glyphs come OUT of the two human states, and the arcs learn to split and knit
(both user calls).** Two changes, and the second is why the first is affordable:

- ✅ **`?` and `!` are gone from inside the ring** — *"bỏ 2 cái symbol ở trong ring của block và error
  đi"*. Those two states now draw the ring **CLOSED and still**, on amber and red. That completes a
  ladder the column had been circling for six follow-ups: the mark's **COMPLETENESS rises with how
  much the row wants from you** — fine dashes at rest → five turning arcs at work → CLOSED when it
  wants a human → FILLED when it has finished something unread. Third cut of these two states to be
  pulled (hand/triangle → `?`/`!` → nothing), each time for the same reason: detail does not survive
  8pt.
- ⚠️ **The cost, stated plainly: blocked vs failed is now HUE-ONLY.** `question` and `alert` remain
  distinct enum cases but draw identically, so amber-vs-red is the whole difference in that column —
  the exact thing round 19 set out to stop doing. It is a deliberate user ruling, pinned as such
  (`testTheColumnIsFiveDrawnShapesAndNoGlyphs` asserts the two inks can never collapse together), and
  it is survivable only because the row's title, tooltip and VoiceOver value still name the state in
  words. `symbolSize` and `StatusMarkShape.symbol` are deleted — the column now has NO glyph at all.
- ✅ **The working arcs SPLIT and KNIT** — *"thêm hiệu ứng các dash tách nhỏ hơn, rồi định kì gộp
  lại"*. Each of the five arcs parts down its middle into two, the ring travels a while as ten, and
  the halves close back into five, on a 2.9 s cycle incommensurate with the 3.6 s revolution. This
  REPLACES the fill breath: three oscillations on an 8pt mark is mush, and this one is visible where
  the breath was subliminal.
- ✅ **The parting is ONE continuous parameter, not a swap between two dash patterns.** The dash array
  is `[half, parting, half, gap]`, and at rest the parting is a **zero-length gap** — so the halves
  abut and render as exactly the arc they came from. A pattern swap would pop; this cannot. Pinned that
  the four elements still tile the circumference exactly at every parting (a split may not open a seam).
- ✅ **Eased at BOTH ends (smoothstep of a raised cosine), so it DWELLS as five and dwells as ten** and
  crosses quickly between. A plain sine spends its time mid-parting and reads as a wobble rather than
  two states trading. Pinned by the dwell (a tenth of a cycle from an extreme stays within a tenth of
  it) and by the crossing rate beating a raw cosine's.
- ⚠️ **`splitMax` = 0.26 is a legibility ceiling, walked on a render sheet rather than guessed**: at
  0.16 the pairing is clean, 0.26 is the most parted the halves stay visibly PAIRED at, and by 0.45 the
  ring is ten thin specks. The upper bound matters twice — past it each half is a speck at 8pt, AND ten
  evenly-spaced short dashes IS the resting ring's cut, which the working mark may not borrow. Reduce
  Motion therefore freezes it fully KNIT (five long arcs), the frame furthest from the resting ring.

**Follow-up 7 — split-and-knit is OUT: one mark, one idea.** *"nhìn cái trò chia ra hơi quê"*. The
parting worked exactly as specified — continuous, eased, seam-free, bounded — and still read as a
gimmick, which is the useful part of the finding: **at 12pt a mark can carry ONE idea, and "turning" is
the one that means "working".** Every second rhythm tried on this mark has now failed the same way (the
arc-length breath was subliminal, the parting was corny), so the ring is a fixed dash pattern with a
single eased rotation, and `dashFill` is a constant rather than a function of time.

⚠️ Kept for the next round rather than argued in prose: a **motion study rig** renders nine candidate
dash-ring motions (turn, chase, runner, pendulum, wave, gyro, breathe, conveyor, inchworm) as a frame
sequence → animated GIF, because four cuts of this mark have now been rejected on MOTION, which no
still can settle. The lesson those four share: judge a 12pt animated mark by watching it at 12pt, not
by reasoning about it magnified.

**Follow-up 8 — the fifth cut: the ring stops moving, and the LIGHT travels instead ("chase").** The
nine-motion study was watched as a GIF and cut 2 was picked. Shipped as `AgentWorkingMark` (renamed from
`AgentSweepMark`, and `StatusMarkShape.sweep` → `.working` — named for the STATE, because the motion has
now been recut five times and the type should not be renamed a sixth):

- ✅ **Nothing moves geometrically.** Five arcs sit at fixed angles for the mark's whole life; a gaussian
  pulse of BRIGHTNESS travels round them, each arc handing the light to its neighbour (lap 1.2 s ⇒ an arc
  lights every 0.24 s). Pinned by the API's own shape: `start(arc:)` takes an index and no instant, so
  there is nothing to move the geometry with.
- ✅ **This is the closest the rail gets to round 9's original verdict** (*nothing in the rail animates*)
  while still saying "in flight": the figure's silhouette is as still as the resting ring's, and it does
  not read as any platform's loading spinner, because a spinner is a shape going round.
- ⚠️ **`dimFloor` = 0.28, not zero.** The comet cut already proved that ink fading to nothing at 12pt
  simply disappears — a floor of zero would break the ring into a moving arc, i.e. back to the generic
  spinner. The floor is what holds the SHAPE constant while only the light moves. Pinned both ways
  (below ~0.15 the dim arcs vanish; above ~0.5 the light stops reading as a light).
- ⚠️ **The falloff distance is WRAPPED** (measured the short way round). Unwrapped, the chase stalls and
  jumps at 3 o'clock once per lap, where the seam is — pinned by asserting the two sides of the seam
  light arc 0 identically.
- ⚠️ **Reduce Motion parks the light ON an arc, not at 12 o'clock.** With five arcs nothing sits exactly
  at the top, and a light frozen in a GAP is the one still frame that reads as broken: two half-lit arcs
  and no subject. `stillPhase` is computed as the middle of the arc nearest the top, so it stays on an
  arc if the count ever changes. (Both of these were found BY the pins, not by eye.)
- ✅ **Linear travel, deliberately** — the opposite call from the turning cut, where a constant rate was
  the tell. A light has no mass, so easing it would be the mechanism showing rather than hidden.

**Follow-up 8a — the cut is now the resting ring's, ALIASED** (*"để dash ngắn hơn, giống idle
indicator được không?"*). The working ring had been five longer arcs on the argument that "more ink =
more happening"; it made the column's rhythm change from row to row for no gain, and the light says
"happening" better than extra ink ever did. So `dashCount`/`dashFill` are now aliases of
`StatusDot.ringDashCount`/`ringDashFill` — shared at the source, not merely equal today — and working
vs resting is **hue + one travelling light**, nothing else.

Two consequences worth writing down, both pinned:

- ⚠️ **Frozen legibility moves from the CUT to the LIGHT.** The old safety was "five long arcs are not
  eight short ones"; with the cut shared, Reduce Motion would collapse the two marks to one shape in two
  hues — except that the parked light is itself the difference: exactly ONE dash at full ink against
  neighbours at `dimFloor`, in the accent. Pinned as a contrast floor (>0.5) and as "exactly one dash
  above the midpoint", because a frozen frame with two equal candidates has no subject.
- ⚠️ **The HAND-OFF is the constant; the lap is DERIVED.** What the eye times is one dash lighting the
  next (0.24 s), not the lap — so `lap = handoff × dashCount` and `pulseWidth = 0.7 × slot`. Going from
  five dashes to eight under a fixed lap would have flickered 1.6× faster and strobed; a cut with more
  dashes must take LONGER to go round. Pinning the lap instead of the hand-off is exactly how a
  dash-count change turns into a strobe nobody meant.

Rejected on the sheet, each for a stated reason rather than taste: **runner** (the discrete cut of chase
— a hop is what "plastic" meant), **conveyor** (a comet in disguise: half the ring fades to 0.12 and
disappears at 8pt), **gyro** (two rings fill the gaps at 8pt, so the dashes stop being dashes). Held in
reserve: **wave** (arc lengths ripple, positions fixed — the same "geometry still, content alive" idea
expressed in SHAPE rather than ink, and so immune to the dim-arc risk if `dimFloor` turns out too faint
on real glass) and **inchworm**.

**Follow-up 9 — the SIXTH cut, and it is nearly the third: a solid arc that CHASES ITS OWN TAIL**
(*"để thành nét liền xoay vòng quanh đi, làm spinner xoay mượt, giữ nguyên đuổi, xoay đầu đến 1 mốc rồi
thu đuôi lại quay tiếp"*). Material's indeterminate circular indicator, drawn on the house tokens: through
the first half of a 1.4 s cycle the HEAD runs out to a `span` of 0.75 turn; through the second the TAIL
catches up to it; the figure drifts the remaining 0.25 turn so it advances **exactly one turn per cycle**.

⚠️ **The distinction from cut 3 is the whole lesson, and it is why this is not a circle back to a rejected
design.** Cut 3 was also a solid arc — but its tail DISSOLVED through an `AngularGradient`, and what
failed was the gradient, not the arc: at 12pt a fade spends half its length invisible, so the figure read
as a shrinking smudge and needed an argument about `lineCap` bleeding ink across the gradient's seam. This
cut is FLAT INK with two hard ends, where the "tail" is a real geometric end that MOVES. Which also makes
**round caps safe again** — no gradient means no seam for a cap to pick ink up across — and round ends are
what make a spinner look drawn rather than cut.

- ✅ **Seamless by construction, so the mark still holds no animation state**: at a cycle's end head and
  tail have both travelled exactly `span`, which is precisely where the next cycle begins. Pinned across
  the boundary, plus tail-monotonic over 2,000 samples: a discontinuity here is a visible jump every
  1.4 s, which is exactly what a `repeatForever` animation produces on every chrome tick.
- ✅ **`span + spin == 1` exactly** — not arithmetic tidiness: it means the head lands on the same clock
  position every cycle, which is what stops a spinner from looking like it is wandering.
- ⚠️ **`minSweep` = 0.07 turn (~25°), never zero.** An arc allowed to collapse to nothing BLINKS OUT at
  the end of every cycle, and a mark that vanishes 40 times a minute reads as broken rather than busy.
- ✅ **The head EASES onto its mark** (smoothstep, pinned as a rate ratio between the middle and the
  ends). The constant-rate finding from the turning cut is kept, not relitigated.
- ✅ **Frozen legibility goes back to SHAPE.** Reduce Motion parks the widest arc; a continuous
  three-quarter arc cannot be mistaken for the resting ring's eight dashes, so the guarantee no longer
  leans on a parked light's contrast the way cut 5's did.

The rail's motion budget is unchanged by all six recuts: **two marks may move, only while something is in
flight** (this arc, and a command's slot wheel), and nothing blinks to say "unread".

The typed twin that survives is `StatusGlyph` (iOS toolbar, Peek & Reply header): 16pt in a text row,
where the glyph is the right primitive. Its frames now carry `\u{FE0E}` (variation selector-15, text
presentation) — the same guard `SlateTabRow` already applies to the title's `✳` marker — which fixes
the colour-emoji frame those two surfaces have shipped since MERIDIAN. It shares the BEAT with the
drawn mark and nothing else; one constant is not worth a font dependency at 11pt.

### Round 20 — round 19 is REVERTED whole: the rail goes back to static marks (2026-07-30)

*"Thôi, quay về các indicator tĩnh như ngày xưa đi cho tôi, lúc mà command vẫn chỉ hiện tên command
đang chạy, các indicator tĩnh ấy."* Rounds 9–10 are reinstated exactly: **ONE shape — the static dashed
ring — the HUE names the state, a running command shows only its NAME in the slot, and nothing in the
rail animates.** `AgentWorkingMark`, `CommandSpinner`, `StatusMarkShape`, `RailRowsBuilder`'s spinner
gate and `SlateTabRow.commandRunning` are all gone; `StatusDotStyle` is one `ink` again.

⚠️ **The whole of round 19 above is kept in this file on purpose, because it is a rejection history, and
it is the second time the rail has arrived at the same verdict from opposite directions.** Round 9 banned
motion by argument; round 19 spent a day of iterations proving it by exhaustion — SIX cuts of one 12pt
mark, every one rejected on looks:

| cut | what it was | why it died |
|---|---|---|
| 1 | asterisk bloom, TYPED | the mono face has no star ⇒ `AppleColorEmojiUI` drew a colour emoji at 2.4× the advance |
| 2 | the same bloom, DRAWN as capsules | at 12pt a radiating star is a burr of spikes; magnified, a cogwheel |
| 3 | solid arc, comet tail (`AngularGradient`) | a gradient at 12pt spends half its length invisible |
| 4 | dashed ring turning, arcs splitting into ten and knitting back | the split read as a gimmick; a turning ring is still a spinner |
| 5 | dashed ring standing still, a LIGHT running through the dashes | calmest of the six, still not it |
| 6 | solid arc chasing its own tail (Material's indeterminate) | "quay về các indicator tĩnh" |

**What survives the revert, and why each one is worth keeping:**

- ✅ **The `\u{FE0E}` fix in `StatusGlyph`** — a REAL pre-existing bug, unrelated to the rail question:
  bare U+2733 `✳` resolves to `AppleColorEmojiUI`, a colour emoji that ignores the tint and measures
  16pt of advance where its Menlo siblings measure 6.62. The iOS toolbar and the Peek & Reply header had
  been flashing a coloured star at the wrong width since MERIDIAN. Kept, and pinned.
- ✅ **The rule that a 12pt mark is judged at 12pt, by WATCHING it.** Every cut above looked defensible
  magnified and cheap at size; the render sheets and the frame-sequence GIFs (`ffmpeg` out of an
  `ImageRenderer` rig) are what settled each round, not prose. Cheap to rebuild, so the technique is
  written down rather than the rigs kept.
- ✅ **The design rules the six cuts bought**, all of which now apply to whatever comes next here: at
  12pt use FLAT INK and WHOLE SHAPES (gradients and detail are luxuries of the zoomed-in view); a mark
  this size carries exactly ONE idea; motion in a status column must mean "in flight" or not exist.
- ⚠️ **`StatusDot.footprint` goes back to 10pt** (round 19 widened it to 12 for the spinner). Anything
  re-added to this column must fit 10.
- ❌ **Not kept, deliberately:** the otty pictogram vocabulary (raised hand, warning triangle, `?`/`!`
  glyphs, the filled finish dot). Every one of them was pulled during round 19 itself for reading as
  fussy detail at this size, so the revert loses nothing that survived its own round.

**Follow-up — one shape distinction survives after all: the unread FINISH closes the ring** (*"để done
indicator là nét liền cho tôi đi"*). Every open state keeps the dashed circle — working, resting, waiting
on a human, failed — and the finish draws it as one continuous stroke. It earns the exception that the
otty pictograms did not:

- ✅ **It needs no legend.** "Broken = still open, whole = it ended" is readable the first time it is
  seen, where a raised hand or a `!` has to be learned.
- ✅ **It survives 8pt**, which is what killed every previous shape distinction: there is no detail in
  it — the same circle, the same diameter, the same stroke weight, with the dash pattern withheld. The
  implementation is literally the one draw call with `dash: []`, so there is no second code path to
  drift out of alignment with the dashed one.
- ✅ **Both finish tiers close it** (`.completed` flash and settled `.finished`), because that split is
  semantic — freshness machinery and control-backend badge tokens — and has never been visual.
- ⚠️ **Pinned as the ONLY shape distinction the column carries**, with the rounds-19–20 history cited at
  the pin, so "while we are at it, the error could be a triangle" has to argue with the ledger first.

### Round 26 — a clean exit is the TICK ALONE; the name stays only where it is needed (2026-08-10)

*"xoá bỏ tên command đi, khi command exit success thì bên phải chỉ hiện indicator là symbol tick
thôi."* Round 25 left the succeeded slot printing two things — `swift ✓` — and the user cut it to one.
The trailing slot now reads `swift` (running) → `✓` (exit 0) → `make` in red (exit ≠ 0): the receipt
is a SINGLE item in every state, and which item it is says which outcome it was.

- ✅ **A finished-clean pane is one the reader is done with, and its slot should stop talking about
  it.** Round 24's argument for the word ("the reader's next question is *what*") is a question about
  a run you still have business with — a FAILURE. For exit 0 the honest answer is "nothing further":
  the row already carried that name for the whole run, the tooltip still holds the full command line,
  and a 10pt column spent restating history it can read at a glance is the slot's scarcest space
  going to its least urgent news.
- ⚠️⚠️ **The tick INHERITS the word's register — it does not get the punctuation register it had.**
  Round 25 set it at 9pt on the tertiary grey precisely because a bold primary name stood beside it;
  with the name gone, keeping that would have made "cleanly finished" quieter than "still running",
  which is the opposite of the round. So `StatusDot.receiptCheckSize` goes 9 → `Slate.Typeface.small`
  and the ink becomes `outcomeInk(.succeeded)`, the same primary the name read in.
  `testTheSucceededReceiptIsTheTickAloneAndTheFailedOneIsItsName` pins both, and the check against
  the agent's own finish (`checkmark.circle.fill`, 13pt, green) still has two steps of clearance:
  no plate, three points smaller.
- ⚠️⚠️ **The ASYMMETRY is now the round's whole shape, not a detail of it.** A clean exit is a fact
  you acknowledge and leave; a failure is a fact you have to act on, so it keeps its name and the red
  (and still takes no cross — a cross beside a red word is the same news twice, the fault that cost
  round 23's triangle its place). `StatusPresentation.outcomeSymbol(_:)` IS the switch both views
  branch on: non-`nil` ⇒ glyph alone, `nil` ⇒ name alone. One function, so the two platforms cannot
  drift into printing both.
- ✅ **`testEveryBadgeHasExactlyOneVoice` is untouched and still true.** The mark column stays the
  agent's — `mark(for:agentFinish:)` is still `nil` for every command tier — and the receipt is now
  literally one item, so the "one voice" claim needs no caveat about how many glyphs it is drawn with.
- ✅ **Both platforms, one reading.** The iOS row (`NavigatorColumn`) branches on the same
  `outcomeSymbol` and drops its `HStack(spacing: 3)`; `SlateTabRow.receiptTickGap` is deleted rather
  than left at 3 for nothing to sit either side of.
- ⚠️ **The resolver is NOT touched.** `RailRowsBuilder.commandReceipt` still refuses a receipt it
  cannot name (`testANamelessOutcomeMountsNothing`), even though a succeeded receipt no longer prints
  that name. The fallback chain makes this near-unreachable in practice — a pane with no OSC-133
  block still has a foreground process — and relaxing it would put a bare tick on rows whose exit
  nothing in the client can actually attribute.
- ⚠️ **Cost, accepted:** the slot's width now CHANGES at a clean exit (a word's width → a glyph's), a
  bigger jump than round 25's tick-width shift. It buys a settled rail that is shorter, and the
  reserve (`slotMinWidth` 28) means the row's right edge does not move.
- ✅ **Judged by rendering.** `testRenderTabRowBadges` keeps both receipts, so the lone tick and the
  red word are read at true size against the agent's green filled check four rows up.

**Follow-up — the hover `×` and the tick join the mark's centre line (2026-08-11).** *"cái symbol X
(close pane) khi hover vào pane bị lệch sang trái so với các indicator."* Measured off the render at
2× (slot trailing edge = 201pt), the trailing column held THREE different centre lines: the marks at
194.0 (a 14pt `StatusDot.footprint` box), the round-26 tick at 196.25 (a bare glyph is only as wide
as itself, so flush-right puts its centre further right), and the `×` at 192.0 (an 18pt box
trailing-aligned centres 2pt further LEFT than a 14pt one).

- ⚠️⚠️ **A wider box, trailing-aligned, is a box whose CENTRE moves left — that is the whole bug.**
  The resting cluster and `closeButton` share one `ZStack(alignment: .trailing)`, so only equal
  widths give equal centres. Both are `StatusDot.footprint` now, and anything else added to this
  column must take that box or it will land off the line in exactly the same way.
- ⚠️ **The `×`'s 18pt HIT target survives, spent LEADING** (`SlateTabRow.closeTargetSide`, leading +
  vertical padding around a `footprint` plate). Spending it trailing would push the box past the
  slot's edge and undo the alignment it is paying for.
- ✅ **The tick took the same box, one day old.** Round 26 drew it flush-right like the word it
  replaced, but it is a MARK-shaped thing and belongs on the marks' line. Box, not ownership:
  `mark(for:agentFinish:)` is still `nil` for every command tier, so `testEveryBadgeHasExactlyOneVoice`
  is untouched.
- ✅ **Verified by pixel, not by eye.** After: `×` 194.75, tick 195.25, check 194.5, hand 194.75,
  spinner 195.25 — all inside one point, which is the natural side-bearing scatter of the SF Symbols
  themselves. Text runs (a failed command's name, `zsh`) deliberately stay FLUSH RIGHT: a word is a
  run, not a mark, and centring it in a glyph box would indent the one thing that has to read as text.

### Round 25 — the command name is bold ALL ALONG, and a tick closes it (2026-08-10)

⚠️ **Superseded in part by round 26**: the succeeded receipt below (`make ✓`) is now the tick alone,
at the slot's own 10pt rung on the primary ink rather than 9pt on the tertiary grey. Everything about
the RUNNING label, the failure, and the causal chain that forced a symbol into existence stands.

The user split round 24's single treatment in two: the command NAME goes bold from the moment it
starts running, not only once it exits — and because that spends the weight step early, a clean exit
is given a SYMBOL instead, one deliberately quieter than the agent's finish, with the text colour
left normal. The trailing slot now reads `make` (running) → `make ✓` (exit 0) → `make` in red
(exit ≠ 0): one register for the word, and the news carried by punctuation and hue alone.

- ✅ **The row no longer restyles the word at the finish line.** Under round 24 a command was tertiary
  regular while it ran and primary bold once it exited, so the slot brightened and thickened at the
  same instant — two channels saying one thing, and the WORD ITSELF changing appearance as you
  watched it. Holding the name in one register the whole way through is what the user asked for, and
  it makes the finish a thing that is ADDED rather than a restyling.
- ⚠️⚠️ **Weight was the completion signal, so removing it forced a replacement.** This is the whole
  causal chain of the round, and `testAFinishDoesNotRestyleTheCommandName` pins it from the other
  end: `outcomeInk(.succeeded) == slotNameInk(isCommand: true)`. If those two ever diverge again the
  brightness step is back, the tick has become decoration on a signal already being sent, and this
  round is undone without anyone editing the symbol.
- ⚠️⚠️ **A glyph returns to a command's outcome, sixteen rounds after round 24 removed one — and it
  is NOT the same proposal.** Round 24's disc lived in the MARK COLUMN, competing with the agent's
  alphabet and saying only "something happened". This one is punctuation ON the receipt, inside the
  slot, closing a name that is already printed. `mark(for:agentFinish:)` is still `nil` for every
  command tier and `testEveryBadgeHasExactlyOneVoice` still holds unchanged: the receipt is one
  voice however many glyphs that voice is drawn with.
- ⚠️ **Three simultaneous steps down from the agent's check, all pinned.** The agent's finish is
  `checkmark.circle.fill`, 13pt, green. The receipt's is a bare `checkmark`, 9pt
  (`StatusDot.receiptCheckSize`), on the tertiary metadata grey. No plate, four points smaller, no
  hue — and it needs all three: any one of them alone would read as the agent's check gone faulty
  rather than as a smaller, different speaker. `testTheCleanExitTickStaysQuieterThanTheAgentsCheck`
  asserts the symbol differs, the size is strictly smaller, and it sits under the 10pt name it
  closes.
- ⚠️ **A FAILURE takes no glyph.** Red is already the exception's whole budget, and a cross beside a
  red word is the same news twice — precisely the fault that cost round 23's triangle its place. The
  asymmetry is the argument: success needed a symbol because it had nothing else left to say it.
- ⚠️ **A bare login shell stays quiet.** `processLabel` is not only commands — an idle pane shows
  `zsh` there, and bolding every resting row would spend the exact step this round reserves for
  work. `RailRowsBuilder.slotLabelIsCommand` reuses `processDisplayName`'s login-shell set rather
  than re-spelling it, so "is this a real program" keeps one answer across the title fallback and
  the slot.
- ✅ **Both platforms, one reading.** The iOS row (`NavigatorColumn`) carries the same name/weight/
  tick, since the receipt was already shared.
- ⚠️ **Cost, accepted:** a finished row's name shifts left by the tick's width, so the slot jiggles
  once at the exit. Reserving the tick's width permanently was the alternative and is worse — it
  would hold a gap open beside every running command for a mark that is not there yet.
- ✅ **Judged by rendering.** `testRenderTabRowBadges` puts the agent's green filled check and the
  receipt's bare grey tick in one image, four rows apart; that gap is the round, and a still is the
  only place it can be read.

### Round 24 — a command's outcome is a WORD, not a mark (2026-07-31)

The user pulled the command-outcome indicator outright: drop the mark, and let the text at the row's
trailing edge carry the exit instead — a clean one in the git line's own register (bold, text
foreground), a non-zero one in red. Round 21's two speakers survive with one of them moved off the
mark column: the ring/check/hand/spinner column is now the AGENT's alone, and a COMMAND's exit is the
trailing slot's text, reading the command's own name (`make`, `swift`, `deploy.sh`).

- ✅ **A mark could not name the command; a word does both jobs at once.** The disc said "something
  you didn't watch has ended" and the triangle "something broke", and in both cases the reader's next
  question was *what*. Round 23's own decision to EMPTY the slot beside the mark (`d3e68936`) is what
  made this obvious: the row was already giving up its only naming space to keep a glyph that named
  nothing. `make` in red is one glance, and it is strictly more information than the triangle was.
- ✅ **The register is the git line's** (round 17 → `1b289043`), not a new one: the same instrument
  mono at the same caption size the resting process label uses, stepped up to the primary ink and
  BOLD. Only the register changes between "what is running here" and "what just finished here", so
  the slot never becomes a second alphabet — and a settled rail still reads as one column of text.
- ⚠️ **Red is the only hue spent, and success gets NONE.** Green was tried as the disc's ink and is
  not worth carrying over: a clean exit is the expected outcome, and hue spent on the expected leaves
  nothing for the exception. Brightness + weight carries "this row did something"; red carries
  "and it broke" — the same two-register answer the git counts settled on.
- ⚠️⚠️ **A badge now has exactly ONE voice, and that is pinned.** `StatusPresentation.mark(for:)`
  returns `nil` for the command tiers and `commandOutcome(badge:agentFinish:)` returns `nil` for
  everything the mark speaks for; `testEveryBadgeHasExactlyOneVoice` walks all nine kinds × both
  finish owners asserting they never both fire. Without that pin the obvious "restore the dot too"
  edit reads as additive and lands as the same news twice in two dialects.
- ⚠️ **The failed block's attribution moved into the builder** (`RailRowsBuilder.failedBlock`) because
  a SECOND consumer now needs it. The gate is unchanged and still load-bearing: `.error` is reachable
  from a live `OSC 9;4;2` whose block is still OPEN, so `blocks.last(where: \.isFailed)` would name an
  older, unrelated command. Unattributed failures fall back to the foreground process — red without a
  culprit beats red with the wrong one.
- ⚠️ **The name is the command's FIRST real word, basenamed**, with a leading `sudo` and leading
  `KEY=value` env assignments skipped. The slot is one narrow column beside a title that must
  truncate last, so arguments stay in the tooltip; `sudo` in particular would restate the privilege
  badge two glyphs away.
- ✅ **`StatusMark.commandFinish` / `.failure` are DELETED, not left unreachable**, along with
  `dotDiameter` and `markSpeaksForTheSlot`. A dead case in this enum is an invitation to re-mount it.
- ✅ **Judged by rendering.** `testRenderTabRowBadges` now carries both receipts, so the red word and
  the bold word are checked at true size next to the agent marks that stayed.

### Round 23 — the marks are otty's, TRANSCRIBED not approximated (2026-07-30)

The user reversed the abstract-geometry line: otty's badge symbols are more elegant than our
ring/ring/dot, so follow them — but draw them PROPERLY this time, because the earlier attempt to
follow them produced symbols that were not otty's and looked bad. The rail's mark column now speaks
otty's `TabBadge` vocabulary, case for case, read out of the shipping app rather than guessed:

| otty `TabBadge` | what otty draws | ours |
|---|---|---|
| `running` (tag 0) | a spinning `NSProgressIndicator`, **14×14**, 8pt in from the row's trailing edge | agent working |
| `completed` (tag 1) | `checkmark.circle.fill`, 12pt `NSFontWeightMedium`, `ottySuccess` | the AGENT's turn ended |
| `finished` (tag 2) | a plain filled **8pt** oval | a background COMMAND's clean exit — *dropped in round 24; the slot names it instead* |
| `error` (tag 3) | `exclamationmark.triangle.fill`, 11pt Medium, `ottyDanger` | a failure — *dropped in round 24; the slot names it in red* |
| `caffeinate` (tag 4) | a Material duotone cup (`PrivilegeIconSVG.caffeinate`, an embedded `<svg>`) | caffeinate — replaces our `∞` |
| `awaitingInput` (tag 5) | lucide `hand` (`AgentRegistry.awaitingInputIcon`, an embedded `<svg>`), 14×14, `ottyWarning` | a question waiting |
| `sudo` (tag 6) | `shield.fill`, 11pt Medium | sudo — replaces our `#` |

Plus ONE mark that is ours, because otty has no need for it: an agent that is merely PRESENT takes
lucide `circle-dashed`, muted. otty draws nothing there; our rail needs it, because `claude` sitting
at its prompt is otherwise indistinguishable from a shell that has been busy for an hour.

- ⚠️⚠️ **"Follow otty" failed last time because we redrew otty's icons by eye.** Two of them are not
  system symbols at all — they are literal SVG path data compiled into the app — so the nearest
  look-alike is a different icon, not a rounding error. The fix is a path-data reader
  (`SVGPath`, `VectorIcon.swift`) and the `d` strings kept VERBATIM in `OttyIcon`. The ones that ARE
  system symbols are mounted with `Image(systemName:)` at otty's own point size and weight, which
  makes them Apple's artwork exactly rather than a copy of it.
- ⚠️⚠️ **The other half of "it looked bad" was the SIZE.** otty lays every badge out in a 14×14 box;
  rounds 19–21 squeezed the same silhouettes into an 8pt column and pulled them for reading as fussy
  detail. `StatusDot.footprint` is now 14 — otty's box, undivided — and the ring grew 8 → 10 to sit
  with a 12pt filled check. The "three marks is the ceiling" pin from round 21 is SUPERSEDED: the
  ceiling was a symptom of the column being too small for a silhouette to survive in.
- ⚠️⚠️ **The working mark is the PLATFORM's indeterminate indicator, not a shape of ours.** That is
  what otty shows for `running`, and it is what this rail shows now. Round 19's hand-rolled
  `SpokeSpinner` and round 22's radial pump and this round's first attempt (a shimmer sweeping the
  ring's dashes) are all gone: they were inventions where the app being copied simply uses the
  system spinner. Nothing about it is ours to tune — no ink, no cadence, no frozen frame — and
  Reduce Motion becomes the platform's call, which is correct for the platform's own control.
- ✅ **Round 21's two speakers turn out to be otty's split as well**, drawn the same way: the AGENT's
  finish is the check, a background command's clean exit is the plain disc. The reason is unchanged —
  an agent's state is continuous and survives being looked at, while a command badge is an unread
  receipt the store keeps only for an UNFOCUSED pane and drops on focus. (Our `.completed` /
  `.finished` split stays semantic — freshness machinery — and both resolve to the same mark.)
- ✅ **Everything round 22 decided still holds**: motion instead of hue, and the gate on RAW
  `.working` — never `isBusy`, because `claude` holds the OSC-133 block open for its whole lifetime,
  so busy-means-motion would move every idle agent's row for hours. Exactly one mark moves.
- ⚠️ **The path reader's one real trap: an arc's two flags are ONE CHARACTER each.** Minified data may
  pack them against the coordinate that follows (`a2 2 0 014 0`), and a number-shaped read swallows the
  lot — silently, yielding a path, just the wrong one. Pinned by `VectorIconTests`.
- ⚠️ **Material duotone fills need EVEN-ODD.** The cup punches its inner wall with a second subpath
  wound the same way as the outer one; non-zero winding fills the hole in solid.
- ✅ **The generating row's TITLE shimmers too** — a highlight band sweeping across its own glyphs,
  keyed on the SAME raw-working input the spinner is, so the two can never disagree about which row
  is alive. The spinner says it in the mark column; the shimmer says it where the eye already is,
  which is what matters on a rail running several agents at once. It is a MASK, not a recolour: the
  glyphs keep their shape, weight and ink, and no layout moves. ⚠️ Its floor was set from a render —
  at 0.55 the unlit title sat BELOW the resting rows' secondary ink, so for most of every pass the
  row doing the work read dimmer than the ones asleep. Reduce Motion simply drops it, and that costs
  nothing: it is the second voice on a fact the mark already states.
- ⚠️ **The crest is held BACK from the band's leading edge** (0.3 of the band, not centred). The band
  travels head-first, so with a centred crest the first thing the glyphs ever show is the peak
  itself, arriving at full strength the instant it crosses the head — it reads as the highlight being
  switched on AT the left edge rather than sliding out from behind it. Held back, a long ramp enters
  ahead of the peak and the light creeps out of the corner.
- ⚠️⚠️ **The band must stay well UNDER the run's width.** Shipped first at 0.45 with a 60pt floor,
  which on the rail's real titles — a project name, a bare `api` — covered the run end to end: the
  title blinked on and off instead of being swept, and the wrap read as a jerk back to the head
  rather than as a band leaving. Now 0.35 with a 16pt floor, and the render carries a SHORT title
  precisely because that is where the defect lives.
- ⚠️⚠️ **The pass's two endpoints must DIFFER.** Wrapping the phase (`phase - phase.rounded(.down)`,
  tried once so a mid-pass restart would be seamless) makes `offset(0) == offset(1)` — and SwiftUI
  animates the RESULTING offset between a transaction's endpoints, it does not sample the function
  over time. The interpolation becomes a no-op and the shimmer silently stops existing. It compiled,
  it passed every pinned-phase render (those set the phase by hand), and it shipped to hardware
  before anyone saw it was gone. `Slate.Shimmer.offset(phase:runWidth:)` is now a pure function with
  `testThePassActuallyTravels` pinning that it is monotonic and that its ends differ — the class of
  bug a snapshot harness is structurally blind to.
- ⚠️ **A layer render photographs an animation's MODEL value**, so a live capture of a shimmering row
  yields the same frame every time. `SlateTabRow.shimmerPhase` exists for that: the filmstrip and GIF
  draw the SHIPPING row at pinned instants rather than a mock of it.
- ✅ **A command's OUTCOME empties the slot beside it.** The disc or the triangle is the row's whole
  news; `make` / `swift` printed next to it is what WAS running, past tense, on a row whose title
  already says it — two words where one was doing the work. Everything still LIVE keeps its label,
  because a running command's name is current information (`markSpeaksForTheSlot`).
  **SUPERSEDED by round 24**: giving up the slot to keep a glyph that names nothing was the tell —
  the outcome IS the word now, and the marks (and `markSpeaksForTheSlot`) are gone.
- ⚠️⚠️ **The spinner's APPEARANCE has to be set on the control.** `ProgressView` came out dark grey
  on a dark theme, and neither obvious fix moved it: `\.colorScheme` in the environment is SwiftUI's
  own notion, and the WINDOW's `NSAppearance` is pinned by `SlopDeskSplitViewController` but
  `.preferredColorScheme` does not cross into the column `NSHostingController`s (SlateDesign's
  header says so for the tokens; it is just as true for system controls). Shipped as an
  `NSViewRepresentable` over `NSProgressIndicator` with `appearance` set directly — which is the
  class otty uses anyway. Measured after the fix: the fins land on the SAME grey as the rail's
  muted marks, which is the register they belong in.
- ⚠️⚠️ **`ImageRenderer` CANNOT rasterize the spinner** — it silently substitutes the yellow
  unavailable-placeholder tile for any AppKit-backed view. `SlateSnapshotRender.renderHosted` hosts
  the view in a real offscreen `NSWindow` and draws its layer instead. Three details are load-bearing
  and each one cost a wrong render: the WINDOW is not optional (an `NSProgressIndicator` outside one
  never starts animating); the window's appearance must be pinned from the theme or the capture lies
  about every system control; and the layer tree's `contentsScale` must be raised before
  `CALayer.render(in:)`, which replays cached contents and otherwise photographs 1× tiles. A system
  SYMBOL additionally has to be re-drawn at the larger point size to magnify — `Image(systemName:)`
  rasterizes at its point size, so a `scaleEffect` tile is a blown-up 12pt bitmap. `StatusMark`
  exposes `systemSymbol` so the shipping view and the magnified tile read one source.
- ✅ **Judged by rendering.** `testRenderStatusMarks` writes the whole vocabulary at true size and 8×.
  A mistyped coordinate parses happily and is invisible in the values.

⚠️ **How the symbols were measured**, so the next round does not guess:
`nm -a … | swift demangle | grep -i badge` finds `TabsPanelRowView.cached*Badge`; `otool -tV -p
'…TabsPanelRowViewC4draw…Tf4dn_n'` shows each `imageWithSystemSymbolName:` beside its
`configurationWithPointSize:weight:`. Names of 15 characters or fewer are NOT in the literal pool —
they are small strings built by `mov`/`movk`, little-endian ASCII (`0x662e646c65696873` = `shield.f`).
`strings -a … | grep '<svg>'` yields the 20 embedded icons. Case names come out of
`__TEXT,__swift5_reflstr`. Tints are `NSColor.ottySuccess` / `ottyWarning` / `ottyDanger` off
`UiThemeJson.semanticCache` — the same green/amber/red budget the rail already spends.

### Round 22 — thinking is the one thing in the present tense, so it MOVES (2026-07-30)

The user proposed the thinking indicator directly: keep the mark on the TEXT colour and change no hue
at all, and let the dash chunks slide outward from the ring and back in one after another, the way an
EDM visualizer's bars run around a circle. The mark for a WORKING agent is now exactly that — the same
dashed ring with a crest travelling around it, on the row title's own primary ink.
Round 19's blanket "nothing in the rail animates" is narrowed, NOT reversed — see the gate below.

- ✅ **Motion instead of hue, and both halves are wins.** Thinking is the only state on this rail
  happening in the present tense, and motion is the one thing a static mark cannot forge (the accent
  ring said "working" the same way an hour-old finish said "finished" — a legend you have to learn).
  Handing the state to movement also hands its ACCENT BACK to the hue budget, so colour on this rail
  now means only what wants the eye: amber question, green finish, red failure.
- ✅ **The trough IS the resting ring** — same 8pt diameter, same lucide `circle-dashed` cut, same
  weight — and the wave only ever pushes OUTWARD from it. So the pumping mark is visibly the same
  alphabet, not a new pictogram: three marks is still the ceiling (round 21), and `pulsing` is a flag
  on the open ring rather than a fourth case.
- ⚠️ **The gate is `.working` RAW, and that is load-bearing.** `claude` holds the shell's OSC-133 block
  open for its whole interactive lifetime, so an `isBusy`-keyed rule leaves every idle agent's row
  moving for HOURS — the exact failure that got round 19 reverted. Nothing settled pumps, pinned by
  `testNothingSettledPumps`.
- ⚠️ **Footprint 10 → 12.** The column is sized by the widest thing it draws, and at full crest that is
  `4 + 1.25 + 0.75 = 6`. Every settled mark keeps its own size and simply gets more air.
- ❌ **Rejected: shrinking the ring to fit the excursion inside 10pt** (base `6.5pt`, so the crest
  grazes the old edge). Rendered: at r=3.25 the gaps fall UNDER the stroke width and the eight
  segments fuse into a notched blob. The dash rhythm is the mark's identity — spending it to save 2pt
  of column buys a different, worse mark.
- ⚠️ **`addArc` is a trap in this shape, in both spellings** — found by rendering, not by reading. With
  no current point it sweeps the 333° COMPLEMENT (eight near-complete rings at eight radii = one fat
  blob); seeded with a `move`, CoreGraphics recomputes the arc start an ulp off it and leaves a
  hairline connector at a ~180° corner, which mitres into a 10×-lineWidth SPIKE out of the mark, rounds
  into a fat pill on every lifted segment, and bevels into a visible notch. The segments are polylines
  (8 chords, 0.002pt off the true arc) precisely so there is no seam to dress.
- ✅ **Reduce Motion FREEZES on a crest** rather than dropping the mark — a state that exists only as an
  animation is invisible to someone who asked for stillness — and the thinking ink is PRIMARY against
  the resting ring's SECONDARY, so the two never collapse into one mark when held still.
- ✅ **Judged by watching it, per round 20's rule.** `SlateSnapshotRender.testRenderThinkingRing` writes
  BOTH a phase filmstrip (true size + 8×) and an animated GIF at the shipped 1.4s period. A still frame
  is not sufficient evidence for this mark, and the three geometry bugs above were all invisible in the
  values — only the render showed them.

### Round 21 — the column has TWO speakers: the ring is the agent's, the dot is a command's (2026-07-30)

*"Status của command thường cần khác với agent, ở trạng thái complete và error."* Correct, and the rail
could not say it: `TabBadgeResolver` FUSES an agent turn ending and a background command's clean exit
into the same `.completed`/`.finished`, so a finished agent and a finished `make` drew the identical
green ring. Three facts decided the shape of the fix:

1. **`.error` was already command-only.** `ClaudeStatus` has no error case — red can only come from a
   non-zero exit or a held-red `OSC 9;4;2`. The rail was spending the agent's mark on a command's fact.
2. **A command badge is an EVENT, not a state.** `BackgroundCompletionPolicy` records it ONLY for an
   UNFOCUSED pane (failures always, clean exits only past the ~10s long-running floor, so `ls` never
   greens the rail) and `clearActiveLeafCompletionBadge` deletes it the instant the pane is visited.
3. **An agent's state is CONTINUOUS** — working, resting, blocked, done — and survives being looked at.

So the geometry names the SPEAKER and the hue keeps naming the STATE:

| | mark | states |
|---|---|---|
| **agent** (a living session) | the dashed RING, closed when its turn ended | accent working · muted resting · amber question · green finish |
| **command** (an outcome) | a small filled DOT | green clean background finish · red failure |

- ✅ **The split is the data's own, not decoration.** Ring = something is (or was) alive here; dot =
  something happened here while you were away. That is exactly the state/event line the store already
  draws, so nothing has to be learned that the rail is not already doing.
- ✅ **It costs the hue budget nothing** — a command's green is the same green — so the column keeps ONE
  palette and adding the second alphabet did not add a colour.
- ✅ **One envelope, one column.** The dot is `5pt` inside the ring's `6.5pt` aperture, both centred in
  the same 10pt footprint, so the right edge cannot widen depending on which mark a row draws. Diameter
  picked by RENDERING 3–6pt beside the ring at true size (round 20's technique): below 4 it reads as a
  stray pixel, at 6 it weighs as much as the ring it must stay quieter than.
- ✅ **The dot is deliberately the LIGHTER mark.** A finished `make` must not outshout a live agent.
- ⚠️ **ONE predicate owns "whose finish is this"** — `RailRowsBuilder.finishIsAgents` (a live `.done` or
  the client's unread latch, and only on a finish badge). It already existed as the gate for the row's
  agent FINAL LINE; the mark now shares it, so the row that shows the agent's last words is exactly the
  row that draws the closed ring. Pinned both ways.
- ⚠️ **Three marks is the CEILING for this column** (open ring, closed ring, dot). A shape here may only
  say what a hue cannot: whether the work is over, and who did it. Rounds 19–20 killed everything else.
- ❌ **Rejected: tinting the row's process-label slot** green/red instead. It adds no new shape, but it
  breaks the property that state reads down ONE column, and a coloured label fights the neutral-title
  rule the whole rail is built on.

## Cold reattach: the third churn pass is the progress bar that never entered a frame (2026-07-25)

- ✅ **Problem (field report):** a session where `git push` / `swift build` ran replays "cực nhiều
  dòng" on reconnect although the visible result is two or three lines. Measured on a synthetic
  `git push` (101 percentage ticks + the done line, 9,753 bytes): the whole existing pipeline —
  alt-screen strip, sync-frame collapse, distiller, query strip, EOL marks — returned 9,712 bytes,
  a 0.4% saving that is only the OSC marks. Progress reporters repaint ONE line with `CR` (or
  `CSI 2 K` + `CR`), never enter the alt screen (`AltScreenSegmentStripper` blind), never open a
  synchronized-output frame (`SyncUpdateFrameCollapser` blind), and live in the command OUTPUT span
  (`133;C`→`D`) that `ScrollbackDistiller` passes verbatim BY CONTRACT. Nothing owned this domain.
- ✅ **Fix — `LineOverprintCollapser`** (`SLOPDESK_SCROLLBACK_COLLAPSE_OVERPRINT`, default-ON; runs
  after the sync collapse, before the distiller). A line is split at each cursor-to-column-0 motion
  (`CR`, `CSI G`/`CSI 1 G`) into REVISIONS. Droppability rests on ONE quantity: the columns a
  revision TOUCHES — paints a glyph into or blanks with an erase. A revision is redundant exactly
  when later revisions touch every column it did, because the last writer of each of those columns
  is then a later revision either way. Synthetic `git push`: 9,753 → 255 bytes. Real captured
  `swift build` PTY transcript: 56,233 → 34,142 with a byte-identical rendered screen.
- ⚠️ **Two model errors the tests caught, both worth keeping written down.** (1) "What a revision
  still SHOWS" is the WRONG quantity: a revision that only erases shows nothing yet still decides
  those columns, and dropping it resurrects what it wiped. Only "what it touches" is sound — the
  cost is that a repaint loop's FINAL `CSI 2 K` survives, one revision instead of thousands.
  (2) A line's opening revision does NOT start at column 0: a bare `LF` moves down keeping the
  column (the PTY's `ONLCR` is what normally makes it `CRLF`), so its span can reach past anything
  a successor covers. The column is carried across flushes and, when unknown — the ring opens
  mid-stream, or the previous line was unmodelled — that revision is never dropped. A line ending
  in `CRLF` re-anchors column 0, so the conservative state never cascades in practice.
- ✅ **Proof is differential, not assertional** (the herdr-parity habit): every case, plus seeded-fuzz
  streams over the full vocabulary (text, wide scalars, all three erases, carried SGR and
  `?25`/`?7`, and sequences that must force the verbatim fallback), is rendered through
  `TerminalScreenModel` before and after collapsing and the grids must match. The suite pins 2,000
  streams per run (~2 s); the 120,000-stream sweep that shook the design out was a one-time
  development run, not the enforced gate. The fuzz found both model errors above AND a real bug in
  `TerminalScreenModel` itself: `EL`/`ED`/`ECH` wrote `Cell()` directly, so erasing half a wide
  pair orphaned the other half — they now go through the same `clearWidePartner` path printing
  already used.
- ✅ **Review-hardening batch (same day, adversarial code review):** six holes closed. (1) The
  compaction backstop ran on UNSAFE lines — coverage is garbage there — and permanently forfeited
  the verbatim fallback; compaction is now safe-lines-only and an unsafe line stops splitting
  revisions instead (bounded memory either way, and unsafe-after-compaction emits the buffered
  survivors verbatim, which is screen-neutral because those drops happened while modelled). (2) A
  revision OPENING with a zero-width scalar attaches it to a predecessor's cell, so it marks the
  line unsafe. (3) `decodeScalar` accepted overlong UTF-8 and credited it width a terminal never
  paints — now rejected like surrogates. (4) The carry cap discarded one-shot `?25`/`?7` toggles
  wholesale; the carry is now STATE (last toggle per mode outside the cap, SGR sequences
  reset-aware and oldest-out) rather than a byte stream. (5) The unknown-start "never dropped"
  promise was encoded as `covers = Int.max`, which a full-coverage successor TIES (strict `>`
  dropped it); the keep rule — now ONE `keepMask` shared by flush and compaction — keeps
  `startKnown == false` explicitly. (6) `ICH`/`DCH` still orphaned wide-pair halves at their
  splice seams, the exact class the `EL`/`ED`/`ECH` fix above closed — both now blank split halves
  at their two seams (and `eraseCells` checks only its two edges, where a split can happen).
- ⚠️ **Accepted gaps (the first identical in kind to the sync collapser's):** a revision WIDER
  than the recording-time grid wrapped onto extra rows and its `CR` returned only to the last
  visual row, so dropping it loses the earlier rows. The pass has no grid width — the ring spans
  resizes and the client re-wraps at its own width, so that layout was never faithfully replayable
  — and width-aware progress reporters, which are what emit this churn, never exceed the grid.
  Second: a LINE whose first scalar is a combining mark attaches it across the line boundary into
  the already-emitted previous line; the target only moves if that line ended in an erase-only
  revision with drops before it, which no real reporter produces.
- ❌ **Not done: multi-line redraws** (`docker pull`, `cargo`: print N lines, `CSI N A`, repaint).
  Cursor-up marks the line unmodelled, so those replay verbatim as today. Modelling them needs a
  real grid, i.e. rendering the ring through `TerminalScreenModel` and replaying the DUMP — which
  loses colour and every scrolled-off row, and is a different design, not a bigger heuristic.

## Cold reattach becomes STATE-TRANSFER: render the screen model once, stop replaying history (2026-07-25)

- ✅ **Problem:** every reconnect with a fresh surface still replays SECONDS of byte history. The five
  churn passes (alt-screen, sync-frame, overprint, distiller, query/EOL strippers) minimize the BYTES,
  but the client still re-parses whatever survives, under real libghostty feed backpressure
  (`TerminalViewModel.ingestBatch` awaits `feedBackpressure()` per 256 KiB pass), and the documented
  accepted gaps (inline churn outside `?2026` frames, open command spans, multi-line cursor-up
  redraws) pass through raw. The cost is O(byte history); the client only needs the FINAL state.
- ✅ **Decision: cold PATH-A replay is composed by RENDERING, not by filtering.** The host feeds the
  ring + un-acked tail + detached-window out-FIFO backlog through `TerminalScreenModel` (extended
  with SGR cell attributes + scrollback capture) at the live PTY size, and sends the RENDERED
  equivalent stream: each scrollback line printed once (soft-wrapped lines re-joined so the client
  re-wraps at its own width), the screen grid painted once, cursor/scroll-region/charset/keypad/SGR
  state re-established, input modes re-asserted via the existing `TerminalInputModeStripper` net
  state. "Clean scrollback" becomes a construction guarantee instead of a heuristic outcome, and
  client re-parse cost drops to O(final state). The stream rides the SAME replay seqs
  (`ReplayBuffer.rechunk`, `mustCoverLastSeq` — ack-release semantics unchanged); the wire format is
  untouched on the output path. Gate: `SLOPDESK_SCROLLBACK_SNAPSHOT` (default-ON, `!= "0"`).
- ✅ **The detached out-FIFO backlog is consumed INTO the snapshot** (peek → compose → splice-out,
  the `compactDetachedBacklogForColdClient` discipline: sniffed control preserved on an empty
  replacement chunk, queue-gate accounting rebalanced). Without this the overnight-agent case —
  up to the 64 MiB detached budget of repaint churn, the bulk of the pain — would still replay
  after a clean snapshot. Post-snapshot PTY output drains normally with fresh seqs on top.
- ✅ **Warm reconnect stays byte-exact BELOW a threshold, snapshots ABOVE it.** A warm grid mid-TUI
  needs byte-exact continuation, so small tails replay raw exactly as before. When pending replay
  (tail + FIFO backlog) exceeds `SLOPDESK_SNAPSHOT_WARM_BYTES` (default 4 MiB — the "this will
  visibly take seconds" line), the snapshot preamble (`DECSTR`, `?1049l`, `ED 3`, `ED 2`, home)
  wipes and re-renders the client's world instead; on a fresh surface the same preamble is a no-op.
  A warm overflow with an EMPTY un-acked tail has no seqs to ride and falls back to raw (rare).
- ✅ **Fallbacks keep the old pipeline alive:** the distiller composition remains injected for the
  journal-restore path (PATH B/C — no authoritative grid size survives a daemon restart), for the
  seq-budget guard (rendered bytes must fit `replaySeqs × maxOutputFramePayloadBytes` — a
  pathological tiny-session expansion falls back to raw+distill), and for `SLOPDESK_SCROLLBACK_SNAPSHOT=0`.
- ✅ **Proof is differential + idempotent:** feeding `render(model)` into a FRESH model must
  reproduce the model's visible state (grids, styles, scrollback, cursor, modes), and rendering is
  a canonicalization — `render(feed(render(A))) == render(A)` byte-equal, fuzzed over the VT
  vocabulary corpus. The 400 ms redraw-jiggle stays only on the non-snapshot cold path: a snapshot
  paints every row the app believes is painted, so the differential-renderer blank-row hazard it
  worked around no longer exists.
- ✅ **`channelOpenAck` grows the designed-but-never-wired host-authoritative `resumeFromSeq`**
  (docs/20 §8.2), appended `Int64` BE, decode-tolerant when absent; the host acks BEFORE the replay
  on the same FIFO data link, so the client learns resume-vs-fresh authoritatively ahead of the
  first byte instead of inferring it from the first delivered seq (the inference stays as fallback).
- ⚠️ **Accepted gaps (documented, all strictly no worse than the stripper pipeline's):** OSC 8
  hyperlinks and app-set palette colors (OSC 4/10/11/12) are not modeled and drop out of the
  snapshot (the query stripper already dropped stale color state); `REP` immediately across the
  snapshot boundary repeats nothing (no real emitter splits a REP from its glyph); the saved-cursor
  slot restores position but not its saved SGR/charset; scrollback capture follows xterm (full-screen
  scroll region only, `ED 3` clears it, capped lines oldest-out).

## Snapshot replay follow-up: the compose walk gets fast, and the history gets CANONICAL (2026-07-25)

First real-hardware night exposed two defects in the state-transfer replay and one latent data-loss
hole; all three land together because the fix for the stall IS the canonicalization that fixes the
hole.

- ✅ **The model walk was ~1.2 MiB/s — a 64 MiB ring composed for ~55 s.** Every grid mutator
  copied the active grid out (`var grid = usingAlt ? alt : main`), which left TWO references on the
  row buffers, so the first cell write CoW-copied a whole row (plus the outer array) PER PRINTED
  CHARACTER. `takeActiveGrid()` now parks the stored slot on empty arrays so the local copy holds
  the ONLY reference and mutations run in place. With the scrollback cap eviction de-O(n²)'d (dead
  prefix index + amortized compaction instead of `removeFirst` per scrolled line), a contiguous
  feed walk, and an ASCII fast path (prebuilt single-scalar strings; width lookup short-circuits
  below U+0300), the walk measures ~21 MiB/s (`cd rust/slopdesk-instruments && cargo run --release --bin slopdesk-replay-bench`) —
  rendered output byte-identical before/after.
- ✅ **The retained history is ADOPTED after every successful compose** (`ReplayBuffer/
  adoptSnapshotReplay`): ring + un-acked tail are replaced by the rendered chunks exactly as sent,
  "as if the host had emitted the rendered stream all along". Two loads: (1) the consumed
  detached-window backlog got no seqs of its own — before this it existed ONLY in the delivered
  bytes, so the NEXT cold reattach replayed a history the backlog had vanished from (real data
  loss, e.g. an agent's overnight output missing from scrollback on the second reconnect); (2) the
  next compose walks the small canonical history instead of the raw ring. Warm re-reconnect
  mid-delivery resumes the rendered stream byte-exact because adopted == sent.
- ✅ **Detach folds the ring in the background** (`scheduleDetachedRingFold`, floor 128 KiB): the
  moment the client leaves is the one moment a multi-second render is free, so the acked ring is
  rendered once and spliced back (generation-guarded against concurrent ring mutations — a stale
  fold is dropped whole, never merged). The eventual reattach compose — the moment the user IS
  staring at an empty pane — walks O(canonical + delta). Memory falls out: an idle detached
  session's ring collapses from up-to-64 MiB of churn to the rendered size.
- ✅ **DECSCUSR joins the modeled state.** The zsh integration sets a bar cursor per prompt
  (`precmd` → `ESC[5 q`); the model consumed all intermediate-family CSIs unmodeled, so the
  snapshot silently reset every reattached pane to a block cursor. The model now tracks the
  last-wins shape (RIS resets it), the renderer re-emits it after keypad state, and the preamble
  wipes with `ESC[0 q` so a warm-overflow re-render can't inherit a stale shape.

## PATH B joins the state transfer: journal restore renders a TRANSCRIPT (2026-07-26)

The last replay path still on the distiller was the fresh-spawn journal restore (hostd restart /
TTL eviction / shell death → `spawnFreshShell`): the blocker was that after the daemon dies there
is no authoritative grid size to parse the journal at. Decision: the parse-correct size is the one
the bytes were EMITTED for — persist it beside the journal and render the restore like PATH A.

- ✅ **Size sidecar** (`<uuid>.scrollback.size`, "rows cols"): every APPLIED winsize is recorded —
  `startRelay()` seeds the spawn-time size (a headless CLI pane may never send `.resize`), each
  flushed client resize overwrites it (last-wins, deduped, atomic, on the journal queue). The
  journal file itself stays raw/headerless; a missing or garbled sidecar decode-fails to the
  distiller path (no-backcompat: no migration, old journals just take the old path once). Delete/
  sweep reap the sidecar with its journal, plus fully-orphaned sidecars.
- ✅ **`TerminalReplaySnapshot.composeTranscript` + `renderTranscript`** — the fresh-spawn variant
  of the snapshot render. The restored bytes front a NEW shell, so the transcript is CONTENT-ONLY:
  scrollback and main grid form one uniform run of rows (a soft-wrapped logical line straddling
  the scrollback↔grid boundary re-joins — splitting there also broke the fixed point, because the
  re-feed's scroll phase moves the boundary), blank edge rows are trimmed (interior blank lines
  kept), SGR styled per cell and reset before every line feed, ending on a fresh line for the new
  prompt. No preamble (the restore gate guarantees a cold surface), no alt screen (the dead TUI
  cannot resume; the main screen beneath it is what the raw path's `?1049l` revealed too), no
  private modes, no cursor/DECSCUSR state, no input-mode reassert, no sanitize suffix (mode-free
  by construction). A dead stream's trailing incomplete escape/UTF-8 fragment is DROPPED, not
  held back — nothing will ever continue it.
- ✅ **Proof:** transcript-of-transcript is a byte-exact FIXED POINT — pinned on curated churn and
  on the existing 300-seed fuzz vocabulary (this is what keeps repeated daemon restarts at zero
  render growth). Store-level tests pin the sidecar lifecycle (record/last-wins/degenerate-reject,
  delete/sweep, corrupt-sidecar fallback, composer-vs-distiller selection, the
  `SLOPDESK_SCROLLBACK_SNAPSHOT=0` kill switch — one env gate governs BOTH replay paths); a real
  PTY test pins both sidecar writers; the hostd-restart E2E now asserts the "(snapshot replay)"
  restore log line on the shipped binaries and the absence of the sanitize suffix.
- ✅ **Observability:** `spawnFreshShell` logs "restored N journaled bytes (snapshot|distilled
  replay)" — the PATH-B sibling of the reattach "replay in N ms" line.
- Accepted: the compose still runs synchronously on the channel-open path (a full 64 MiB journal
  ≈ 3 s at the measured ~21 MiB/s — once per pane per daemon restart, replacing a much longer
  client-side parse; the distilled path was synchronous there too). Restores at a size the client
  immediately changes re-wrap client-side like any transcript line.

## The title comes back: type 21 joins the reattach re-assert (2026-07-26)

> Phase 1 of [45 — Multi-client state sync](../45-multi-client-state-sync.md). Fixes the reported bug
> (`nvim` titles a pane; quit the client, reopen, the row reads `vi .` forever) with **no wire
> change and no golden churn**. The remaining phases move ownership; this one closes the leak.

- ✅ **The class of bug, named.** A host-derived fact extracted by a stateful host parser was exposed to clients **only as an edge-triggered event**. The host's memory of "what is true right now" was wired to an unrelated consumer (`list-panes`), so any client that started listening after the edge fired had permanently missed it and **had no way to ask**. At one client this is a stale sidebar; at N clients it is silent, permanent, undetectable divergence. Every other activity truth (23/26/27/32/33/34/36) was already re-asserted on reattach — type 21 was the sole omission, and it was the one the user could see.
- ✅ **`reestablishActivityOnReattach()` re-asserts `.title(_currentTitle)`, skipping empty.** Empty is not "no title": `publishAgentEmission` sets `_currentTitle = ""` as the ownership-RETIREMENT signal (pinned by `MuxChannelSessionTitleRetirementTests`), so re-asserting an empty would resurrect a dead agent's `✳ <topic>` on every reconnect. Skip-when-empty is the correct reading of both producers.
- ✅ **The `.title`-after-`.commandStatus` ordering is load-bearing, and temporary.** Until the host ships its own `pane/titleFresh` verdict (45 §4.4), the CLIENT decides whether to trust a title by comparing arrival stamps, so the type-21 must land after the type-23 in the same batch. Pinned by `testTitleIsEnqueuedAfterCommandStatus`; **deleted in Phase 4** along with the comparison itself.
- ✅ **A title with NO command-start stamp is TRUSTED (`programTitle(for:)`).** Requiring BOTH stamps meant a shell without OSC-133 integration (Starship, a bare `sh`) — which never stamps `paneCommandStartedAt` — could never show a program title at all. That is the hookless half of the same bug, and `.title` re-assert alone does not fix it: `commandStatusForReattach()` returns `nil` at a prompt, so the second stamp never arrives. Safe because the host only ever asserts a title it CURRENTLY holds. A title predating a KNOWN command start is still rejected — the relaxation is scoped to a MISSING stamp, not a stale one.
- ✅ **`list-panes` enumerates detached sessions.** `listPanesForControl()` read only `muxSessions + controlSessions`, so a pane that survived a client quit — precisely the reported scenario — was invisible to the one "describe all panes" API in the product. New `DetachedSessionStore.allSessions()` (ordered by `detachedAt`; every other production API existed except enumeration). The three sources are disjoint by construction: `handleLinkDown` removes from `muxSessions` before `detachMuxSession` inserts, and `claim` removes before the reattach re-registers.
- ✅ **The frozen golden keys were not actually pinned by anything.** `scripts/golden-check.sh` diffs the 35 EMITTED keys and prints the other 13 as "XCTest-pinned, not emitted" — but **no test loaded the corpus at all**. The suites those keys name pin BEHAVIOUR with hand-written cases, never the committed BYTES. Two of the 13 (`hostOutputSniffer`, `terminalModeTracker`) sit directly on the PATH-1 title path, so a change there produced no golden signal AND no XCTest signal. New `HostOutputSnifferGoldenGuardTests` replays the frozen vectors through the live sniffer (driving the injectable `clock` from each step's `nowMs`, which is why the duration bytes are reproducible at all).
- ✅ **First catch: `invalidUtf8Title` had already rotted.** The corpus expected an EMPTY type-21 for `ESC ] 0 ; \xff\xfe BEL`; the live sniffer emits nothing, because the deliberate empty-title drop (zsh/p10k emit a blank OSC 0/2 during prompt redraw, and wiring it would clear the client's shown title) post-dates the vector. **The code is right and the corpus was stale** — and it matters more now than when it drifted, since an empty type-21 is the retirement signal. Hand-merged the vector to `messagesHex: []`; corpus stays at 48 keys.
- ✅ **Scope limit, stated.** The client's `.title` sink is gated on `SettingsKey.titleShellControlledEnabled` (default ON), so the fix holds for every default install and is a deliberate no-op where the user turned shell-controlled titles off. `_currentTitle` lives in memory on `MuxChannelSession`, so a **daemon** restart still degrades the title until Phase 5's persistence. And if a program genuinely never emits an OSC 0/2 title, `vi .` **is** the last true title — Phase 4's `pane/runningCommand` + `pane/foregroundProcess` covers that variant.
