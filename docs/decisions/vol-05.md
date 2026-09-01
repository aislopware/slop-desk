# DECISIONS vol-05 — 2026-07-29 … 2026-08-10

> Volume 5 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## Read-only attach is removed; class 2 stays reserved (2026-07-29)

`channelClass == 2` opened a pane somebody else already held as a **read-only** member: the host
joined it to the live session, dropped its `input` frames (while still crediting them), skipped the
echo probe and `foldUserInput`, and kept it out of the PTY size fold for good. `slopdesk-client
--observe` was the one caller. It is gone — route, CLI flag, `Subscriber.channelClass`, the
`readOnly` fork in `startInputRelay`, and `ResizeContribution.observer` with it.

**Why.** Read-only attach exists in tmux (`attach -r`) and `screen` (multiuser ACLs) to serve pairing
and demos — one person driving while others watch. This product is one human on their own machines,
where every attachment is a hand that should be able to type. Nobody asked for a spectator seat.

The cost was not the route. It was that "read-only" is a property of a SUBSCRIBER, so it leaked into
every per-member path: a branch in the input relay that three other writers had to be reasoned about
against, and a passivity flag the size fold could never let expire — an exception carried by code
that is otherwise about one thing, sizing a grid for the people who are here.

**The enum case goes; the byte does not.** `MuxChannelClass` now names 0 and 1 only, and 2 falls into
the existing unserved-class guard: `accepted: false`, decided BEFORE the exclusivity critical section,
so a stale peer that still sends `--observe` is refused rather than handed a login shell it never
asked for. Nothing on the wire changed shape — the class field was already golden-pinned at 0 and 255
— and 2 is not reusable, because one byte must never name two things.

**What kept its coverage.** The observer suites pinned two behaviours that were not about observing at
all: that a JOINED member's input reaches the PTY, and that a joined member's Esc folds through
`foldUserInput` to drop a blocked agent's hand. The primary's relay is built at `init`, so both would
stay green while a joiner's relay went nowhere. They live on in
`MuxChannelSessionJoinedInputTests`. The size-fold cases the observer tests covered were the
size-passive ones, already pinned by `MuxChannelSessionResizeFoldTests`.

## Two clients CAN watch one window; the refusal that was never written stays unwritten (2026-07-29)

**Decision.** A second client's video pane ships as a real stream, not as a placeholder. The
`docs/45` §10 risk row that reserved the right to render it **unavailable** is retired, and no
refusal is added on either side.

**Why the row existed.** The workspace document advertises `pane/videoTarget` to every attached
client, so a second client sees the desktop pane and will dial it. Whether the host could serve that
— two `SCStream`s and two `VTCompressionSession`s bound to ONE capture target — was never
established, and hang-safety forbids constructing any of those four objects in a unit test. So the
document made a promise the test suite structurally cannot check.

**What settled it: measurement, not a guard.** `scripts/check-video.sh --second-client` stands up the
real videohostd, a real `slopdesk-hostd`, and two client instances. Client B is given the TERMINAL
autoconnect and nothing else — no `SLOPDESK_VIDEO_AUTOCONNECT_*` — so it has to learn the pane from
the host's document, resolve the ports off its `ConnectionTarget` defaults, and dial a window nobody
named to it. It decoded and presented. That is the whole claim, and it is true.

**The assertion that matters is the PAIR.** A host that could hold only one session per target might
hand the newcomer the stream and leave the incumbent on a frozen last frame — and every other check
in the gate would still pass. So client A's decode counter is re-read after B is up and must have
GROWN (16 → 34), and each client's media lane is asserted per-PID rather than by counting sockets on
the media port, where the host's own bound socket also lives.

**One shot per instance, raised by PID.** Two instances are two processes named SlopDesk, so
`first process whose name is "SlopDesk"` photographs whichever the window server answers with — one
client, twice, presented as two. Each instance is raised by its unix id and shot separately. B's
frame is visibly NEWER than A's, which is what makes it a live second stream rather than a copy.

**The refusal was documented but never coded.** The retired row described "the refusal in the
client's video-pane materializer" — there is no such code and there never was. A mitigation that
exists only in prose is worse than an open risk: it reads as handled. The row now records what was
measured, on which date, by which command.

## ⌃⇥ is a held gesture the dispatcher owns, not a chord-table row (2026-07-29)

**Decision.** Tab switching gains a second gesture: hold ⌃ and tap ⇥ to walk a MOST-RECENTLY-USED
ring, release ⌃ to commit — kero's `TabSwitcherView` shape. It lives in `WorkspaceKeyDispatcher`, not
in `WorkspaceBindingRegistry`'s chord table. The positional ⌘⇧] / ⌘⇧[ cycle and ⌘1–9 are unchanged.

**Why not a table row.** A row maps ONE chord to ONE action. ⌃⇥ means three different things
depending on state — open, step, commit — and the commit is not a keystroke at all but a modifier
key-up. There is no row shape that says that. Worse, adding it would put a ⌃-only chord into a table
whose invariant (`testEveryChordIsCommandOrOptionPrefixed`) requires ⌘ or ⌥ on every chord. That
invariant is not decoration: it is the thing that keeps the app from swallowing a ⌃-letter the TUI
needs. Muxy has no such rule and its ⌃[ binding eats ESC.

**Why ⌃⇥ is free to take.** xterm's `modifyOtherKeys` explicitly EXCLUDES Tab, so in a legacy
terminal ⌃⇥ is byte-identical to bare ⇥ — nothing can distinguish them, so nothing can be bound to
it. macOS reserves ⌘⇥ at the WindowServer level but leaves ⌃⇥ to the app. Under the Kitty keyboard
protocol it does become distinguishable (`CSI 9 ; 5 u`), which is why the escape hatch below exists.

**What it must not cost.** Bare ⇥ is shell completion and ⇧⇥ is how Claude Code cycles permission
modes. Neither carries ⌃, and the dispatcher claims Tab only when ⌃ is held or the switcher is
already up. `DispatcherTabSwitcherTests` pins both passthroughs first, before anything else.

**The highlight is LOCAL; only the commit is an intent.** Walking the ring stages nothing. The host
owns tab focus (`docs/45`), so staging a `.focusTab` per step would broadcast every intermediate tab
of a cycle to every other attached client and repaint their screens. One commit, one intent.

**The ring is FROZEN at open.** Candidates are snapshot from `WorkspaceTopology.focusMRU` when the
switcher opens. Committing re-fronts the ring, so a live ring would reshuffle under a still-held ⌃
and the highlight would chase itself. The order is: local active tab, then the host ring by recency,
then anything never visited, deduped and pruned to live tabs.

**Escape hatch.** `unbind: ctrl+tab` frees the gesture back to the PTY, for the Neovim user who has
bound `<C-Tab>` and runs with CSI-u on. It gates OPENING only — an open switcher owns ⇥ regardless,
or the unbind would strand an overlay with no way to step it — and reclaims each chord individually:
unbinding ⌃⇥ says nothing about ⌃⇧⇥.

**A focus change elsewhere abandons the walk.** The switcher can also be opened from the palette
(the chord-less `tab.switcher` row), and that one has no held modifier whose release would end it.
Both `stageFocus` overloads cancel it first — that pair is the choke point every local navigation
passes through — so clicking into the workspace cannot leave a card floating over a view the user
has already left.

**Not rebindable as a gesture.** Settings can rebind the chord-less `tab.switcher` row (which opens
the unarmed switcher), but the held ⌃⇥ gesture itself is fixed. Accepted: expressing "hold this
modifier, tap that key, commit on release" in the recorder UI is a larger change than the gesture is
worth, and `unbind:` already covers the user who needs the chord back.

## The notification is a pane speaking from off-screen: the rail's mark, and a door (2026-07-30)

**Decision.** The in-app notification stack is redesigned. It keeps the CARD register (it is not migrated
to the `NoticeChip` one-liner), but the card is rebuilt around one reading: every push site is gated on
the source pane NOT being focused, so a toast always names a place the user is not looking at. That makes
it three things — WHO spoke, WHAT happened, and the WAY BACK.

**There is NO LEADING GLYPH — the event class is an EYEBROW.** A caps micro-label in the instrument voice,
letterspaced with `instrumentTracking` and inked with the flavour hue, then `·`, then the subject, all on
one line. This is MERIDIAN L2 taken literally ("typography is the only ornament") and it is the DS's
existing engraving treatment (`SlateRow`, `SlatePopover`, `InstrumentChip`, `NavigatorColumn`), not a new
device. With no glyph column, every line starts on ONE left rail.

**Two leading elements were built and cut to get here.** First the SF Symbol quartet (`bell` /
`checkmark.circle` / `exclamationmark.triangle` / `asterisk`) — four glyphs from four families that never
shared a stroke weight, and the very pictograms rounds 19–21 pulled off the rail. Then the rail's own
`StatusDotView` ring/dot, which the user rejected with the decisive observation: **the ring/dot pair is
right in a 10pt sidebar column and wrong in a notification**, where it is a tiny abstract speck and the eye
expects something concrete. Borrowing the rail's vocabulary looked like consistency and was actually a
category error — the rail is a dense scannable column, a notification is a single interruption.

**Liquid Glass was considered and dropped.** The package floor is macOS 26 / iOS 26 (`Package.swift`
`.v26`), so `glassEffect` is available with no `#available` gate and no fallback path — it was a real
option, and a floating transient card is Apple's own canonical use for it. Rejected on system coherence:
`SlopDeskClientUI` contains **zero** materials anywhere (MERIDIAN L5 — depth by light, not lines; v5 already
deleted `GlassPanel`), so one glass card would be the single alien surface in the app.

**A monogram identity plate was probed and rejected.** `SlateMonogram` (MERIDIAN C2) was the closest
DS-native equivalent of a real notification's app-icon tile. It fails on the hue budget: the plate's
per-identity colour is designed to be a PERSISTENT identifier for a host, and in a transient notification it
puts a SECOND colour system on the card, fighting the status hue — four notifications become four unrelated
hues, exactly the chromatic spread the v5 bar calls slop. **Colour lives in exactly one place: the eyebrow.**
The surface is never tinted by flavour and there is no coloured edge rail.

**Flavour alone could not pick the eyebrow**, and that is why `Toast` grew a second bit, `source`
(`.agent` / `.command`). `.success` says `DONE` for an agent and `FINISHED` for a command; a resolver keyed
on flavour would have announced a finished `make` as an agent turn. This is the same fusion
`TabBadgeResolver` had (round 21) — pinned by `testEyebrowSplitsAgentFromCommand`. A factory may override
with `Toast.eyebrow` when it knows a truer word than the derivation can reach: the reconnect verdict is
`REATTACHED` vs `RECONNECTED`, a distinction no flavour encodes.

**`.attention` is AMBER, not the theme accent — and the old pin was hiding the bug.** The user asked why
needs-input was cyan rather than yellow, and the codebase already had the answer: ``StatusDot`` fixes the
rail's mapping as "green = an unread finish, **amber = a question waiting**, red = failed", so an agent
waiting on a human has to be amber here too or the app contradicts itself about what amber means. Worse, the
accent was not even *distinguishable*: every Monokai seed sets `info == accent`, so `.attention` (needs
input, the highest-signal event) and `.default` (a routine OSC notice) rendered in the SAME cyan — the one
pair that most needs to differ. The previous test explicitly declined to assert those two apart, documenting
the collision as acceptable instead of failing on it. `.attention` now takes the status quartet's unused
amber rung, which also leaves the accent free for its single job (active state). Pinned by
`testEveryFlavorInkIsDistinct`, which asserts all four flavours PAIRWISE distinct — the real invariant, since
a flavour that cannot be told from another conveys nothing.

**Card corner → `Slate.Metric.radiusPanel` (12), a new rung.** `radiusCard` (8) is tuned for content INSET
into a surface; at the notification's 320 × ~46pt it reads boxy, and 16 slides toward `radiusPill`. Picked by
rendering 8 / 10 / 12 / 16 at true size side by side.

**The card is a door.** `Toast.paneKey` carries the pane, and the mount site routes a tap through
`jumpToPaneTree` — the seam `ConnectionAlertChip` already used, so a landing that crosses a tab fires the
"JUMPED · session ▸ tab" breadcrumb. Before this the toast was strictly LESS capable than the chip beside
it: it named somewhere else and could not take you there. The two window-level notices with nowhere to go
(the failed host-path action, the dropped-folder cwd advisory) pass no `paneKey` and stay inert.

**The dwell pauses on hover, and NOTHING draws it.** A pointer resting on a card freezes its clock, so a
notification can no longer be yanked away mid-read — the 4s timer used to do exactly that. The countdown is
therefore SAMPLED (a 10 Hz tick that simply does not advance while hovered) rather than a single
`Task.sleep`, which could not be paused.

**A visible dwell track was built and CUT — the user judged it AI slop.** The first cut of this round put a
capsule hairline of the flavour hue along the card's bottom edge, depleting over `autoDismiss` and freezing
on hover, argued for as a READOUT in the same family as the long-command elapsed chip and the OSC 9;4
percent ring that the v5 restraint pass kept. The ruling: it reads as decoration on the resting card, and
the v5 bar ("permanent per-item ornament reads as AI slop") applies. `Slate.Anim.drain` and
`Slate.Metric.trackThickness` were added for it and are deleted with it. **The fix for "it vanished while I
was reading" is that it STOPS, not that it announces how long it has left.** Do not propose a progress
bar / ring / countdown on a notification again.

**The spine.** Only the newest two cards carry a detail line; older ones collapse to the eyebrow + subject
row alone, so a four-deep burst costs about a third of the corner instead of blanketing the prompt line.
Hovering a collapsed row expands just it, and rows are promoted as the cards below them expire — so no
information is stranded on iOS, which has no hover.

**The ✕ is hover-only** (unconditional on a sticky card, whose only exit it is). Four permanent ✕ marching
down the corner was chrome for something that leaves by itself. Hidden it is also not a hit target, so a
stray click cannot kill a card the user never saw a ✕ on.

**Uniform width, NOT content-hugging — reversed after rendering it.** Cards that hugged their own content
were built first and photographed as a ragged staircase: right-aligned in the corner with every left edge
landing somewhere different, and the width tracking TITLE LENGTH rather than importance. `toastWidth` is
one column edge at 320 (down from 340, affordable because the ✕ no longer holds a permanent slot).

**Surface + voice.** The fill moves from `Surface.face` — the EXACT tone of the terminal behind it, leaving
a dark-on-dark shadow as the only separation — to `Surface.raised`, the rung every other floating chip
already used. Typography moves to the INSTRUMENT voice (MERIDIAN L2): a body like `exit 1 · 42s` is a
technical readout, and setting it in proportional system text was the single thing that made the stack read
as a web toast pasted into a terminal app. The three factory bodies are re-cut as `·`-joined readout
fragments rather than sentences.

**Bonus fix: a same-id re-push now RESTARTS the dwell.** The card's timer was keyed on `Toast.id`, which a
replace does not change, so the replacement inherited the replaced toast's nearly-elapsed dwell and could
vanish almost at once. `Toast.epoch`, stamped by `pushToast`, is the `ChipNotice` remedy applied here —
pinned by `testSameIDRepushTakesAFreshEpoch`.

→ `Overlays/Toast.swift`, `Overlays/ToastStackView.swift`, `Overlays/OverlayCoordinator.swift`,
`Overlays/OverlayHostView.swift`, `DesignSystem/SlateDesign.swift`, `SlopDeskClientApp.swift`,
`Pane/PaneDropReceiver.swift`, `Pane/TerminalLeafView.swift`; pinned by `ToastStackViewTests`
(mark split, spine rule, epoch, render smoke over the PANE tone so card-vs-pane separation is
actually visible), `ToastSessionResumeTests`, `ToastSecretRedactionTests`. No wire change (golden
byte-identical).

**The states are PHOTOGRAPHABLE, and that is how this round was decided.** `ToastStateGalleryTests` dumps
the whole state space — every (source, flavour) eyebrow, rest vs hover, both stack tiers, sticky, the
content edges, the real 4-deep stack, and a light-theme pass — as PNGs:

    SLOPDESK_TOAST_GALLERY_DIR=/tmp/toast swift test --filter ToastStateGalleryTests

`ToastCardView` is internal (not file-private) with a seedable `hovering`, purely so the hovered states can
be captured at all: `ImageRenderer` never delivers a hover. Two decisions in this round were REVERSED by
looking at the output rather than at the code (content-hugging width, the dwell track), and the leading
mark was rejected the same way — which is the argument for keeping the harness.

## The working row's title shimmer is removed; the mark column speaks alone (2026-07-30)

The generating agent's title no longer sweeps a highlight band across its own glyphs. Round 23 shipped
the shimmer as a SECOND voice on a fact the trailing spinner already states, on the argument that a rail
running several agents at once wants the signal where the eye already is. Looked at on hardware, the
second voice is the problem: the rail is a column the eye SCANS, and a row whose text is in motion
takes the scan hostage — the redundancy that justified the effect is exactly what makes it noise.

- ✅ **One row-level signal, in the mark column.** `ProgressView`/`NSProgressIndicator` on the raw
  `.working` row (round 23) is the whole statement. The title is back to still ink at every state,
  which restores the round 19 rule the shimmer had carved an exception into: a settled rail does not
  move, and the ONLY thing that moves is the mark for work in flight.
- ⚠️ **Text motion is not available as a "free" second channel.** The shimmer cost no hue and moved no
  layout, which is what made it look cheap on paper; the cost it actually charges is attention, and it
  charges it on the surface least able to pay. Do not re-propose a travelling highlight, a pulsing
  title, or a stepped title weight for liveness — the mark column is where liveness lives.
- ✅ Everything else round 23 decided stands: otty's 14×14 badge box, the SVG path reader, the raw
  `.working` gate (never `isBusy`), and the two speakers (agent check / command disc).

→ deletes `DesignSystem/Shimmer.swift`, `ShimmerTests`, `SlateTabRow.shimmerPhase` (the pinned-phase
snapshot seam) and `SlateSnapshotRender.testRenderWorkingRowShimmer` with its GIF writer — the harness
existed for the one mark whose evidence had to be animated, and there is no longer such a mark.

## Settings speaks the SYSTEM, and every remaining control does something (2026-07-30)

Three complaints about the Settings surface, one root each. It was painted in the active Monokai Pro
filter, so a preferences window sat dark on a light Mac with theme-tinted labels beside system-blue
switches; it turned choices into picture-card grids even where the picture was a stand-in SF Symbol; and a
long tail of its toggles wrote a value nothing ever read.

- ✅ **Settings is OS chrome, not product surface.** Colour + type now come from `SettingsInk` /
  `SettingsType` — AppKit/UIKit semantic colours and Dynamic-Type text styles — instead of `Slate.*`. The
  scene no longer sets `.preferredColorScheme`, and `SettingsWindowAppearancePinner` is deleted: the window
  follows the OS appearance like System Settings does. **The one exception is the theme gallery**, whose
  swatches must draw from the `SlateTheme` they are PREVIEWING — painted in system colours they would be
  seven identical cards.
- ✅ **A card must be earned by its picture.** Cards stay where the illustration IS the difference (cursor
  caret, tab position, ⌥ key row, window geometry, theme swatch). The glyph-card groups — Right-Click
  Action, On Launch, Close Confirmation — are `SettingsOptionMenuRow`s: same pinned `SettingsOption` lists,
  same exhaustiveness test, one row instead of a grid. `SettingsSymbolArt` and `SettingsOption.symbol` are
  deleted so the shape cannot come back by accident.
- ✅ **One card size, everywhere.** The grid was `.adaptive(minimum:)`, which STRETCHES columns to fill —
  a 2-option group rendered two enormous cards while the theme gallery rendered seven small ones. Columns
  are now fixed at `settingsCardWidth` (96 → 116) and wrap; `settingsSwatchArt` is gone, so the theme
  swatch shares the one `settingsCardArt` band.
- ✅ **A setting that only writes to disk is deleted, not disabled.** Same criterion as the 2026-07-29 flag
  purge: if OFF is not a valid mode but a broken product, it is not a flag — and if neither position does
  anything, it is not a setting. Removed (control + `SettingsKey` + `Defaults.Key` + accessor + catalog
  entry + reset lists): **Scroll to Bottom on Output** and **Show command dividers** (ZERO read sites
  anywhere), **Backspace Deletes Selection**, **Scroll Past First / Last Line**, **Smooth Scroll**, **Cursor
  Animation**, **Render SGR underlines / blink**, the `srgb-over` / `linear` / `perceptual` **blending**
  modes and **Title Report** (all wired-but-inert: the code path exists and provably cannot change what you
  see), and the client-side **IPC — Allow Send Keys / Allow Sensitive Sessions** + **Auto Progress-Bar
  Commands** keys (see below).
- ⚠️ **The IPC / auto-progress keys were worse than inert — they were a lie in the doc comment.** Their
  description claimed a `SLOPDESK_IPC_ALLOW_*` env bridge re-drove the host on its next launch. No such
  bridge exists: `applyVideoAndAgent()` folds only `video ∪ agent ∪ rawOverrides` into the overlay and the
  sidecar, so the toggle never left the client. The honest editor for a host-read env key is **Advanced →
  Raw overrides**, which DOES reach the sidecar — the host resolvers are unchanged.
- ⚠️⚠️ **`grep Sources Apps` DOES NOT COVER THE CLIENT.** The audit that drove this round first reported
  Mouse Over to Focus, Undo at Prompt and Backspace-Deletes-Selection as unreferenced, because the live
  reader of all three is `ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift` — the
  `TerminalSurface` seam that ONLY the Xcode app target compiles, which is why `swift build` stayed green
  after deleting them. **Mouse Over to Focus and Undo at Prompt are real and were restored.** Any
  "is this setting reachable?" sweep must include `ThirdParty/ghostty/integration/` and `Apps/`, and must
  end at `xcodebuild -scheme ClientApp-macOS`, not at `swift build`.
- ✅ **Backspace-Deletes-Selection was wired and STILL dead.** `BackspaceSelectionPolicy` was called, but
  its one interesting leg passed `selectionEndsAtCursor: false` unconditionally (no geometry API), so
  `leadingDeleteCount` always returned 0 and every branch fell through to the same encoder path — ON and
  OFF identical by construction, as its own comment admitted. A call site is not evidence of an effect.
- ⚠️ **Deleting a setting deletes its pure engine too.** `BackspaceSelectionPolicy` and `ScrollPastPolicy`
  each had a full unit-test file and no reachable effect — a green suite over engines nothing could act on,
  which is exactly how an inert toggle survives review. Gone with their tests and the `ScrollPastLast` /
  `ScrollPastFirst` enums. (`FocusFollowsMousePolicy` / `PromptEditPolicy` stay: theirs DO act.)
- ⚠️ **`CutSelectionPolicy` is uncalled** and was LEFT in place: it is not behind a Settings toggle, so it
  is out of this round's scope. Wire it to ⌘X or delete it, but do not let it become the next example.

→ adds `Settings/SettingsInk.swift`; touches every file under `Sources/SlopDeskClientUI/Settings/`,
`SettingsKey.swift`, `AllSettingsCatalog.swift`, `PreferencesStore.swift`, `TerminalControls.swift`,
`TerminalPreferences.swift`, `TerminalFontSettings.swift`, `SlateDesign.swift`, `HostEnvironment.swift`,
`AutoProgressMatcher.swift` and `GhosttyTerminalView.swift`. No wire change (golden
byte-identical) — every removed key was a fire-time `Defaults` flag or a client-only render pref.

## ⌘W is a PANE gesture: an emptied tab just goes, it is not a tab close to confirm (2026-07-30)

⌘W on a tab holding ONE pane popped *"Close “Terminal”? / This window has multiple tabs."* Two independent
faults stacked, both dating to the E7 carry-over #8 fix, which corrected WHICH policy a pane close reads but
not what that policy is fed.

- ✅ **A pane close reads the busy-shell guard ALONE.** E7 made a pane close inherit the Tab policy whenever
  it cascaded its tab away (`tabRemovedByClosing ≠ nil`), escalating to the Window policy on the session's
  last tab. **Ruling: it inherits neither.** A tab is a container for panes; there is no pane-less tab, so a
  tab vanishing with its last pane is a CONSEQUENCE of the pane close, not a second close the user asked
  about. `closeConfirmationNeeded(scope: .pane)` is now `shouldConfirm(.process, isBusy:)` — ⌘W asks only
  mid-command. The Tab and Window policies belong to their own affordances (Close Tab, ⌘⇧W Close Window).
  `effectivePanePolicy(for:)` and `tabRemovedByClosing(_:)` are deleted with it, and
  `pendingCloseReasonPolicy` returns `.process` for any parked PANE close.
- ✅ **`multiple_tabs` counts the tabs the close DESTROYS, not the tabs the window happens to hold.** All
  three scopes were fed `tree.activeSession?.tabs.count`, so "ask when this would lose more than one tab"
  fired on a unit that loses exactly one — and then narrated it in window-scope copy. `.tab` now feeds `1`,
  `.pane` is `.process` (count irrelevant), and only `.window` feeds the session's `tabs.count`.
- ✅ **That makes `multiple_tabs` window-only, so the tab row stops offering it.** Same criterion as the
  2026-07-30 Settings purge: a control position that provably cannot change anything is not a choice.
  `SettingsOptionCatalog.closeConfirmationTab` is the window list's first two entries (a prefix, so the two
  rows can never word the same policy differently); `AllSettingsListView` composes its tab picker into the
  window one. A persisted `multiple_tabs` on `shell.closeConfirm.tab` stays decodable and is simply inert.
- ⚠️ **The old test pinned the behaviour being removed.** `testAlwaysTabPolicyParksAnIdlePaneClose` and
  `testCascadingPaneCloseUsesTabPolicy` both asserted a pane close inheriting the Tab policy. Rewritten to
  assert the complement — and to assert the SAME `.always` policy still parks an explicit Close Tab, which is
  the pin that keeps this from collapsing into "nothing ever confirms".

→ touches `WorkspaceStore.swift`, `WorkspaceStore+CloseConfirmation.swift`, `SettingsOptionCatalog.swift`,
`SettingsView.swift`, `AllSettingsListView.swift`, `AllSettingsCatalog.swift`,
`CloseConfirmationPolicyTests.swift`. No wire change (golden byte-identical) — both keys are fire-time
`Defaults` and `CloseConfirmationPolicy` keeps all three cases.

## The ⌃⇥ switcher names the PANE, not the place — and wears the system's glass (2026-07-31)

The switcher printed one line per tab through the folder-name rung, so a session with three panes open in
one repo read `slopdesk` / `slopdesk` / `slopdesk`. The ring was ordered by RECENCY and named by PLACE: the
only question the surface exists to answer — which of these am I flipping to — was the one it could not.
The user also judged the hand-drawn Slate card un-native.

- ✅ **The card is a grouped LIST: the project heads a section, a row is ONE line.** The first cut gave each
  row an icon, two lines and a full-bleed selection bar; the user's verdict was *"xấu thế, nhìn nó không
  thanh lịch tí nào"*. Ruling (chosen from three previews): project as a section header said ONCE, rows
  reduced to identity + a quiet note + the ⌘-number, highlight an inset capsule. The icon goes (every row is
  a terminal — the glyph was noise) and so does the second line (it restated the header on every row).
  Identity resolves through `RailRowsBuilder.liveRowTitle(...)` — the SAME chain the sidebar row and the
  window title read (rename → agent task intent → running command → last command → folder) — so a pane is
  named identically wherever it is named. The note carries the sub-path below the project and `N panes` when
  the tab is SPLIT (a tab in `slopdesk` holding three panes is not the destination holding one), and is
  absent for the common at-root single-pane row, which is what makes the list read quiet.
- ✅ **A header is a RUN BOUNDARY, not a re-sort.** The display order is the frozen ring's (recency) because
  that is the order ⇥ steps in; grouping the rows by project would make the highlight jump around the card.
  So a header is emitted wherever consecutive rows change project, and one project can head more than one
  run. A projectless row (video pane, cwd not landed) heads nothing and continues the run above it rather
  than scattering an "Other" bucket. `TabSwitcherItem.id` is the POSITION, not the name — names repeat.
- ✅ **A title that only restates its header yields to its program.** The identity chain's last rung is the
  folder name, which under a section header is the header printed twice; an idle root shell therefore reads
  `zsh` (the sidebar's metadata slot). Only when no program is known does it restate the folder — a blank
  line says less than a redundant one.
- ✅ **`projectKey` IS threaded into the structural rung, on purpose.** At the project root that rung yields
  the PROGRAM rather than the folder name, and an idle shell's empty result then falls through to the
  running / last command / folder. That fall-through is the whole disambiguation: without the key every row
  short-circuits at the folder name, which is the bug.
- ✅ **The card is native chrome, not canvas.** `glassEffect(.regular)`, system text styles, semantic
  `.primary`/`.secondary` ink, the SF Symbol `PaneChooserRegistry` already names each kind by, and the
  SYSTEM accent for the highlight — `.tint(nil)`, because the window tints its whole subtree with the THEME
  accent and a native surface wearing Monokai green for its selection is exactly the un-native reading. Slate
  supplies GEOMETRY only (the shared spacing/radius ladder), never ink. Per the native-chrome research's
  pitfall list the custom glass self-gates `accessibilityReduceTransparency` → `.regularMaterial`.
- ⚠️ **Glass over the live terminal canvas WORKS.** The 2026-07-03 research said never layer glass over a
  live `CAMetalLayer`; HW-photographed on mac-studio over a running `top` under libghostty, the backdrop
  samples correctly in both a light and a dark theme. The rule stands for a pane's OWN surface (the
  one-surface rule); a transient overlay ABOVE it is fine.

→ touches `TabSwitcherOverlay.swift`, new `TabSwitcherRows.swift` (+ `TabSwitcherRowsTests.swift`). No wire
change (golden byte-identical), no model change — `TabSwitcher` (the frozen ring) is untouched, and the
dispatcher still owns open/step/commit/cancel.

### Round 3 — the accent capsule loses, the shortcut becomes a KEY (2026-07-31)

The grouped list was still rejected (*"vẫn xấu"*), with one hard defect attached: *"bên trái title dài quá
thì bên phải sẽ bị cắt"*. This time the three candidates were BUILT and photographed side by side at true
size over a live workspace, and the ruling was made on pixels — ASCII previews had already produced one
approved-then-rejected round.

- ✅ **The ⌘-number is a keycap with `fixedSize`, and that is a CORRECTNESS fix, not a style one.** The title
  carried `layoutPriority(1)`, so in a narrow `HStack` it took its ideal width first and the shortcut was
  truncated down to a bare `⌘`. A shortcut with its number cut off is not a shortcut. The keycap is laid out
  first now; the title takes what is left and truncates; the note (`layoutPriority(-1)`) yields before both.
  The key is also ABSENT past ⌘9, where the app binds no chord — an unpressable key drawn on a row is a lie.
- ✅ **No hue anywhere: the highlight is a lifted plate + a heavier title.** The system-accent capsule read as
  a foreign object on a quiet card. This restates the house rule the git line and the footer already follow
  (*"có vấn đề" = brighter + bolder, never a colour*) — the switcher is a readout like the rest.
- ✅ **Roomier: `heightRowTall` (44) joins the ladder, the card widens to 460.** A 32pt list beat is for
  SCANNING; this surface is read at a glance for the length of a held modifier, and a real pane title (a
  running command, an agent's stated intent) has to finish on the line.
- ✅ **Glass needs a RIM and a SHADOW to read as glass.** Over a dark terminal `glassEffect` alone leaves a
  grey slab. The surface adds the two things a physical pane of glass has: a specular edge (theme-directed —
  light on dark, darkened on light) and a cast shadow. `.tint(nil)` is no longer needed, since nothing on
  the card is tinted.
- ✅ **One project ⇒ NO header.** A caption over a run that has nothing to be distinguished from is a label
  on a box holding one thing; the header survives only where it does work — a list spanning several
  projects. ⚠️ Trade-off taken knowingly: a single-project card no longer names the place. The
  title-yields-to-its-header rule stays UNCONDITIONAL even when no header is drawn, because that rule exists
  to stop every row collapsing to the folder name — which is the original bug, not a header artefact.

## A Claude Code hook must never park on the host (2026-07-31)

Editing through Claude Code kept freezing on `Update`, and `UserPromptSubmit` intermittently reported a 30s
timeout. Both are the same defect, and it is ours: the installed `slopdesk-agent` hook POSTs each event over
`nc -U` to the host's `AgentHookListener`, and Claude Code runs that hook SYNCHRONOUSLY — on `PreToolUse` /
`PostToolUse`, i.e. around every single edit — waiting up to 30s.

`UnixSocketAcceptor.acceptLoop` accepted ONE connection at a time and ran `onRecord` inline on the accept
thread, so a slow sink left every other pane's connection unaccepted and `nc` sat there until Claude Code's
ceiling killed it. Measured on a reproduction: a hook posted 0.5s behind a wedged one took **19.5s** to
return.

- ✅ **Delivery moved off the accept thread, onto a SERIAL queue.** Serial, not concurrent: hook events are a
  per-pane state machine (`UserPromptSubmit → PreToolUse → Stop`) and arrival order is meaning. A slow sink
  now delays only its own delivery, never the next client's POST.
- ✅ **`SO_RCVTIMEO` on each accepted connection.** A peer that connects and never writes used to park the
  drain `read` forever. The ceiling now exists (2s).
- ✅ **`nc -U -w 2` in the hook script.** Belt to the host's braces: a wedged host costs seconds, never the
  timeout. It stays SYNCHRONOUS on purpose — backgrounding the relay would let two `nc` processes race and
  deliver `Stop` before the `PreToolUse` it follows.
- ✅ **The one socket-binding test in the suite.** `testAWedgedSinkDoesNotBlockTheNextClient` binds a real
  socket in a temp dir and asserts the CLIENT's contract (a POST returns promptly while a sink is wedged),
  because the sink-side delay is deliberate. Hang-proof: every wait is an expectation with a timeout, so a
  regression fails instead of hanging the suite. Mutation-checked — it fails in 3.7s against the inline
  `onRecord?(record)` it replaced.

→ touches `AgentHookListener.swift`, `AgentInstaller.hookScript()`. An already-installed hook script is
stale until the host reinstalls it (or it is edited in place). **Superseded 2026-08-10** — the script is a
compiled relay now; see below.

## The hook relay is a compiled binary, because the cost was fork, not transport (2026-08-10)

The 2026-07-31 fix stopped the hook from PARKING. It did not make it cheap. Measured on the installed
script: **12.4ms per invocation**, twice per tool call, synchronously on the agent's critical path.

Decomposed, the shape is the whole argument:

| | |
|---|---|
| `sh` fork/exec | ~6.1 ms |
| `cat` (a subprocess, only to slurp stdin) | ~2.3 ms |
| `nc` fork/exec | ~4.5 ms |
| **the AF_UNIX round-trip itself** | **0.011 ms** |

The transport was never the cost. Three processes were being forked to move ~60 bytes over a socket that
answers in 11µs.

- ✅ **`rust/slopdesk-hook` replaces the generated shell.** ONE fork/exec instead of three: **12.4ms → 3.2ms**
  (13.6× on the work above the process-spawn floor). Zero dependencies — every crate linked is startup cost
  on the critical path. `AgentInstaller` copies the binary to `~/.claude/hooks/slopdesk-agent` (the basename
  still carries `hookMarker`, so `merge`/`remove` strip the old `.sh` entry with no migration code).
- ✅ **Byte-identical framing, verified against the script it replaces.** Both were run against one listener
  over 6 payload shapes (empty, trailing/embedded newlines, unicode, 256KB) and the received bytes compared.
  `payload="$(cat)"` stripped every trailing newline before `printf '%s\n' `added one back, so the relay
  replicates exactly that — a `trailing_newlines_collapse_to_exactly_one` test pins it.
- ✅ **It is still SYNCHRONOUS, and this is now measured rather than argued.** `sh -c 'exit 0'` alone costs
  ~10.5ms of the old 12.4ms; detaching would have hidden 11µs and kept the fork. Ordering remains the real
  reason — see the serial-queue entry above.
- ⛔️ **`PostToolUse` is NOT droppable, though it maps to the same `.working` as `PreToolUse`.** Halving the
  forks per tool call was the obvious next move and it is wrong twice: `PreToolUse` of `AskUserQuestion` maps
  to a BLOCK that only the tool's `PostToolUse` resolves, and `ClaudePaneDetector` stamps `lastAuthoritativeAt`
  on every record so a long turn survives the ~1Hz foreground poll under a wrapper (`node`/`npx`/`mise`).
- ⛔️ **`#![no_main]` to skip Rust's runtime init is rejected.** The relay already costs exactly what an EMPTY
  Rust binary costs (3.07 vs 3.09ms) — all of its own work is below measurement noise. The only remaining
  0.45ms is `std::rt` init (a do-nothing C binary is 2.64ms), and buying it back means giving up
  `unsafe_code = "forbid"` for ~0.2s per session.
- ⚠️ **AF_UNIX defaults to an 8KB `SO_SNDBUF` on macOS; TCP loopback gets 128KB.** Measured here: unix wins
  round-trip 4.2µs vs 19.2µs, but LOSES bulk 15.4 vs 49.0 Gbit/s at defaults — and wins it 179 vs 114 Gbit/s
  once `SO_SNDBUF` is raised. Only the SENDER's buffer matters (`SO_RCVBUF` changed nothing). Anyone moving a
  bulk path to AF_UNIX without raising it makes that path ~3× slower.
- ⛔️ **The other same-machine hops stay TCP loopback** (hostd → code-server, hostd → simulator child, hostd →
  `adb forward`). Each sits behind a cross-machine mesh leg whose measured RTT is 11ms, so the ~15µs a unix
  socket would save is 0.14% of the path. The webview → `CodeSidebarProxy` hop *cannot* move: browsers need
  loopback for a secure context.

→ touches `rust/slopdesk-hook/`, `AgentInstaller.swift` (`hookScript()` deleted, `install` copies a binary,
`defaultScriptPath` → `defaultHookPath`), `HostAgentActionPerformer.swift`, `slopdesk-hostd/main.swift`,
`Makefile` (`hook`, `hook-test`, `lint-rust`, `fmt-rust`).

## The switcher is measured against its window, and the walk is a LOOK (2026-07-31)

Two asks on the round-3 card: it read too narrow, and ⇥ should show the tab it is passing over rather
than only the one it lands on.

### Width is a band, not a constant

The card was a fixed 460 — the app's dialog rung. Wrong instrument: a dialog's content is authored and
fits by construction, while this card carries LIVE text of wildly varying length. The band was MEASURED
in the row's own anatomy (SF 13, ~90pt of chrome: card + row padding, the keycap and its gap):

| content | card | what lands there |
|---|---|---|
| 45 ch | 390 | the low end of a comfortable measure |
| 60 ch | 490 | `swift test --filter TabSwitcherRowsTests` |
| 75 ch | 590 | the high end; past it the eye loses the line |

- ✅ **`clamp(400, 0.42 × window, 640)`, then never more than 2/3 of the window.** 400 shows a real
  command untruncated; 640 is the app's widest list rung (Open Quickly) and the point past which a line
  stops being scannable. ⚠️ The last clamp OUTRANKS the floor: on a narrow window the minimum would draw
  a card wider than its host, and an overlay that fills its window has stopped being an overlay.
  HW-verified at three regimes — 820 → 400 (floor), 1280 → 538, 1600 → 640 (cap).
- ✅ **Height is capped at 0.7 of the window and the rows scroll**, with the highlight kept in view. A
  session with more tabs than the window is tall previously drew a card taller than its host.

### The walk previews the tab it is over (`controls.tabSwitcherPreview`, default ON)

⚠️ This does NOT relax the switcher's founding rule that the highlight is LOCAL. A tab focus is a
host-owned intent, and staging one per step would broadcast every intermediate tab of a cycle to every
other client on the workspace.

- ✅ **The preview rides `DeviceFocus`** — the same device-local overlay an unfollowing device lives on
  (docs/45 §8.2). It writes no intent, publishes no presence (that rides `reconcileTree`, which the
  preview never calls), and is unwound on BOTH exits. The commit still stages exactly once, and it is
  unwound BEFORE that commit so `selectTab` publishes focus from the state the gesture began with.
- ✅ **Cheap by construction:** `SplitContainer` renders every tab of the active session and merely hides
  the inactive ones, so a preview step is a visibility flip, not a mount.
- ✅ **The toggle is real, and the OFF case is a legitimate mode, not a broken product** (the flags
  criterion): the preview flips a VIDEO pane's UDP/VT/Metal pipeline on and off as the walk passes, and
  some people want the workspace to hold still. Filed under Appearance → Tabs and in All Settings.
- ⚠️ **Three existing tests pinned the behaviour this replaces** — they read `store.tree` (the projection
  WITH this device's overlays) to assert "nothing was committed". They now assert host truth
  (`workspaceMirror.topology`), which is what that sentence always meant; the preview legitimately moves
  what the device is LOOKING at.

→ touches `TabSwitcherOverlay.swift`, `TabSwitcherRows.swift` (new `TabSwitcherMetrics`),
`WorkspaceStore+TabSwitcher.swift`, `SettingsKey`/`AllSettingsCatalog`/`PreferencesStore` (+ both
Settings surfaces). New ladder rung `Slate.Metric.heightRowTall`. No wire change (golden byte-identical).

## The switcher's unit is the PANE, and so is the ⌘-digit (2026-07-31)

⌃⇥ walked TABS and ⌘1…⌘9 selected tabs, while every other surface in the app counts PANES: the sidebar
lists panes, a notification points at a pane, `⌘]`/`⌘[` cycles panes, the window title names a pane. The
container was the only thing the keyboard could reach, so ⌘3 meant one thing in the chord and another on
screen — and inside a split ⌃⇥ was a dead gesture, because a tab-keyed ring cannot tell two panes of one
tab apart.

- ✅ **One unit, one order.** `PaneSwitcher` (was `TabSwitcher`) rings PANES across the whole active
  session — every tab's panes, not the active tab's. A ring scoped to the active tab would be a switcher
  that cannot reach most of the workspace.
- ✅ **⌘1…⌘9 counts `flatOrderedPaneIDs()`** — tabs in creation order, panes within a tab in pre-order
  DFS (the walk the reconcile diff and `⌘]` already read). A split therefore renumbers what follows it,
  which is exactly what makes the number mean "the Nth pane". It lands through `revealPaneTree`, so a
  pane in a background tab brings its tab with it and that tab's badges clear on arrival.
- ✅ **The ring is PER-CLIENT** (`WorkspaceStore.paneVisitMRU`, cap 32, session-only) — tmux's
  `client->last_session`, and what docs/45 §7.3 already filed beside the latched video modes. The SHARED
  `session/focusMRU` stays tab-keyed because it exists for a different reason: close is an intent, and
  two clients computing successors from two local rings pick two different tabs. "The pane I was just
  in" is a fact about one keyboard. **No wire change** — golden byte-identical.
- ✅ **A fresh client is not blind.** Its own ring is empty on reconnect, so `paneSwitcherMRU` appends
  each remembered tab's `activePane` BEHIND the local entries — the host's recency, at the granularity
  the host has it. `candidates(active:mru:ordered:)` dedupes, so the overlap costs nothing.
- ✅ **Recorded at the ONE choke point**, `stageFocus(tab:)` / `stageFocus(pane:)`, which every
  deliberate navigation already passes through. The preview writes `DeviceFocus` directly and so records
  nothing — a walk must not reorder the ring it is walking.
- ⚠️ **A TAB rename no longer names a row.** The old builder let `tab.title` outrank the pane's live
  identity; with a row per pane that is the container's name stamped on each of its contents — the exact
  shape of the bug this builder was written to fix. The row keeps the pane's own chain, which is also
  what the sidebar shows for it. The note loses its "3 panes" segment for the same reason: it described
  the row's neighbours.
- ⚠️ **`goto_tab:N` keeps its name** and now resolves to `pane.select.<n>`. The name is Ghostty's, not
  ours; a config asking for "the Nth thing" gets the Nth thing this workspace counts.

The positional gestures are untouched and stay independent: `⌘⇧]`/`⌘⇧[` still steps the tab BAR, `⌘]`/
`⌘[` still walks the active tab's split tree. ⌃⇥ is the only recency walk, and now it can reach
everything.

→ renames `TabSwitcher`→`PaneSwitcher`, `TabSwitcherOverlay`/`TabSwitcherRows`→`PaneSwitcher*`,
`WorkspaceStore+TabSwitcher`→`+PaneSwitcher`; `.selectTab(Int)`→`.selectPane(Int)` and
`.tabSwitcher`→`.paneSwitcher` (binding ids `pane.select.<n>` / `pane.selectN` / `pane.switcher`, all
moved to the Panes group); `controls.tabSwitcherPreview`→`controls.paneSwitcherPreview`.

### The walk turns the contrast up, and only for the walk

⚠️ Dimming the unfocused panes as a RESTING treatment was tried and removed — it washed out live content,
and a pane you are watching a build in must not be half-erased because the cursor is elsewhere. Focus at
rest adds a mark to the subject (`PaneFocusCorner`) instead of subtracting from everything else.

A ⌃⇥ walk is the opposite case, which is why this is not a reversal of that: for the length of a held
modifier the whole screen is answering "WHICH pane am I about to land on", the answer changes on every
tap, and a 10pt corner marker 900pt away is not something the eye finds in 200ms.

- ✅ **`PaneRecedeScrim` on every pane but the subject, while `paneSwitcher != nil`.** The subject is the
  pane `isFocused` already names, so it works on BOTH settings of the preview: with it on the focus IS
  the highlight, with it off the lit pane is where a cancel would leave you. Exactly one pane of the
  visible tab stays lit either way.
- ✅ **0.72 over `Slate.Surface.face`** — theme-directed by construction (sinks on dark, washes on light).
  ⚠️ MEASURED, not picked: at 0.55 a light theme's black text only reached mid-grey — a real difference
  that was not findable at a glance, which is the one thing this has to be.
- ✅ Non-hit-testing, kept in the tree at opacity 0, faded with `Slate.Anim.smallFade`. A click during a
  walk still abandons the switcher and focuses the pane under the cursor — the escape must not be veiled
  shut.
- ⚠️ The predicate is trivial alone, so the TEST drives a live store and evaluates the same two calls the
  view makes (`showsSwitcherRecede` × `SplitContainer.isPaneFocused`) — what can break is the JOIN.

→ new `PaneRecedeScrim.swift`, one overlay + one static gate in `PaneContainer`.

### The project rides the row, and the row grows a second line (2026-07-31)

Section headers were the TAB era's shape and they do not survive the unit change. A header earns its line
only when consecutive rows share it; tabs arrived in project-sized runs, but PANES interleave — walk
between two repos and the recency ring reads `slopdesk, otty, slopdesk, otty`, which under a run-boundary
rule is a caption above almost every row. Re-sorting to repair that is worse: the card's order IS the
order ⇥ steps in, so grouping would make the highlight jump around the list.

- ✅ **Headers deleted; every row says its own place.** `PaneSwitcherItem` (the section/row display list)
  is gone — the view iterates rows directly.
- ✅ **The row is TWO REGISTERS**: the identity, and under it the place — project, then the sub-path it
  strayed into. Built as ONE `Text` so the two halves flow and truncate as a single run (head-truncated:
  a deep path's last components are the ones that say where the pane is).
- ✅ **The project is set a shade heavier than the path under it.** Weight, not ink: both halves are
  equally quiet next to the identity, so what separates them is which one the eye should catch running
  down a column. This is also what replaces the header's grouping cue — a run of rows from one repo still
  lines up down the card.
- ✅ **`Slate.Metric.heightRowStacked` (48)** — a new rung for a two-register row: ~29pt of stacked ink
  (13 over 11) plus a breath either side. It also answers the shrink the header removal would otherwise
  have caused: the same six panes now read as an object rather than a strip.
- ⚠️ **`unrepeated` had to learn the note.** With the path on the row, a shell deep in a project titles
  itself by the folder-name rung and the row reads `Overlays` over `slopdesk › …/Overlays` — the same
  stutter the project rule already caught, one level down. It now yields to the pane's program when the
  title matches EITHER the project or the note's last component. Photographed before and after; only the
  LAST component counts, since a match higher up the path does not read as a repeat.
- ⚠️ Aesthetic choice made from PIXELS: three anatomies were built for real and rendered side by side
  over a mock terminal (stacked / stacked + leading glyph / one line with the place trailing). The glyph
  column was dropped — every pane is a terminal, so it repeated a mark that said nothing.

→ `PaneSwitcherRows` loses `items`/`PaneSwitcherItem` and renames `header`→`projectName`;
`PaneSwitcherOverlay` loses `SectionHeader` and rebuilds `RowView`.

### Every overlay is the switcher's card (2026-07-31)

The ⌃⇥ switcher's card is the surface the user actually likes, so it stops being one overlay's private
styling and becomes the vocabulary the whole floating set speaks: the command palette, Open Quickly,
global search, the keyboard cheat sheet, Connect to Host, Peek & Reply.

Before this they were native `.sheet` bodies under the "everything outside the workspace is native chrome"
directive (2026-06-30) — a grouped `Form`, a `List` with section backgrounds, per-glyph shortcut chips, an
opaque system panel. That directive is narrowed, not reversed: Settings and the close-confirmation `.alert`
stay native, because they ARE system surfaces. The command surfaces are workspace furniture, and reading
like System Settings is what made them look unrelated to the window they float over.

**The four moves — this is all "the switcher's style" is.**

- ✅ **The SURFACE is glass with a rim and a cast shadow**, never an opaque box. Extracted from the
  switcher to `SlateGlassCard` + `Slate.Metric.panelShadowRadius`/`panelShadowY`.
- ✅ **No chrome inside it.** No grouped-`Form` insets, no `List` section fills, no system `Divider`s
  between static regions. The single allowed line is `SlateCardSeparator`, and only where content MOVES
  past content (results scrolling under a query field). This is the move that makes the set look related.
- ✅ **A selected row is a PLATE** — one surface rung up, hairline-bordered (`slateSelectionPlate`) — and
  its title goes heavier, never coloured. In global search the pointer IS the selection, so hover takes
  the same plate.
- ✅ **A pressable key is a KEYCAP** (`SlateKeycap`), one cap per CHORD rather than one per glyph: the
  modifiers are a single gesture, and a row of little boxes reads as four things to do.

**⚠️ `.presentationBackground(.clear)` does not clear a macOS sheet.** Photographed: the palette rendered
as a card nested inside a second, larger, white panel. It clears the SwiftUI-drawn ground while the sheet's
`NSWindow` keeps painting its own and casting its own shadow. `slateClearSheetWindow()` reaches the window
(`isOpaque`, `backgroundColor`, `hasShadow`); BOTH modifiers are required. The sheet is kept for what it is
genuinely good at — modality, key focus for the text fields, Esc/click-away routing through the existing
binding — and stripped of everything it draws.

⚠️ **The card title is one rung ABOVE a section header** (`footnote`/`secondary` vs `small`/`tertiary`).
The first cut set both alike and was photographed: on the connect card `CONNECT TO HOST` and the `HOST`
label under it were the same size, ink and voice — the card's name read as a third field label.

⚠️ **The cheat sheet packs COLUMNS, not a grid.** `LazyVGrid` pairs sections into grid rows, so a short
category is centred against the long one beside it and floats halfway down the card. `columnAssignment`
deals sections greedily into the shortest column, balanced by rendered height (rows + header line), and is
pure so `CheatSheetColumnBalanceTests` pins it without a view.

→ New `DesignSystem/SlateOverlayCard.swift`; `DesignSystem/SlateSheet.swift` DELETED (both its users
converted); `PaneSwitcherOverlay` loses its private `SwitcherSurface`/`Keycap` to the shared ones.

**Follow-up, same day — three corrections from looking at it running.**

- ⚠️ **The shadow gutter was a HALO.** Padding the card inside the sheet, to give its cast shadow room, put
  a 12pt band of the sheet's OWN surface around the card: brighter than both the card and the workspace,
  and tinted by the theme's ground — clearly violet on Monokai Classic. Neither
  `.presentationBackground(.clear)` nor clearing the `NSWindow` stops the sheet painting that surface; the
  only thing that hides it is sizing the window exactly to the card. So the padding is gone and the cast
  shadow with it — the rim carries the card alone. (Re-enabling the window's own shadow does not help: the
  sheet's surface makes the window's alpha a full rectangle, so it would cast a rectangular shadow around
  a rounded card.)
- ⚠️ **The tint goes back to SYSTEM.** Theme-accenting the stock buttons was tried and rejected on sight:
  a recoloured system button reads as a recoloured system button, not as workspace furniture.
- ⚠️ **The controls inside a card stay NATIVE.** A hand-drawn field plate is thinner than a real macOS
  field and reads as cramped, so Connect-to-Host and Peek & Reply use `.roundedBorder` at `.large`. The
  card supplies the SURFACE and the labels around the controls; the controls themselves are the system's.
  `slateFieldPlate()` survives for global search's search bar, which is a search bar, not a form field.

**Follow-up 2 — the cards leave the sheet, and the ink leaves the terminal.**

Three more reports from running it: a white border flashing as a popup opened and vanishing once it
settled; a radius and edge less elegant than the switcher's; and no liquid glass behind them at all.

⚠️ **One cause: a sheet is its own WINDOW.** `glassEffect` refracts what is behind the view WITHIN its own
backdrop, and a second window has nothing behind it — the material silently degrades to a flat fill
(measured: every interior pixel of the sheet-hosted card was one dead value, where the in-window card's
vary with the terminal beneath). The same window painted its own surface across its whole frame, which is
the pale frame on open AND, when the card was inset for its shadow, the violet halo of the round before.
And its mask clipped the corner to the system's radius rather than `radiusPanel`.

Substituting a behind-window `NSVisualEffectView` was built and rejected on sight: a different material
reads as a cousin of the switcher, not as the same object. **There is no separate-window arrangement that
matches an in-window glass card.** So the cards are presented the way the switcher is — a centred
`.overlay` in the workspace window — and the sheet is gone.

⚠️ **`.onTapGesture` DOES NOT FIRE on that layer.** The workspace is an AppKit split
(`NSViewControllerRepresentable`) and its real `NSView` wins `hitTest:` against SwiftUI content drawn over
it, so SwiftUI's gesture recognition never sees the click. A real control does: measured both ways in one
session — a row backed by `.onTapGesture` ran nothing while the connect card's native Cancel button, in the
same overlay at the same moment, dismissed the card. Anything clickable on these cards is now a `Button`
(`SlateClickTarget`, laid over the finished row so its layout is untouched); the dismiss backdrop is one
too. Verified on hardware: a palette row click splits the pane, a click outside closes the card.
⚠️ Hover-select does not survive this (`onContinuousHover` is a gesture) — keyboard selection and clicking
both do.

**The ink is NEUTRAL, not the terminal's** (`SlateOverlayInk`). Monokai's greys are tinted — Classic's are
violet, Ristretto's warm rose — and a dialog wearing them reads as a stained panel rather than a neutral
surface over coloured work. Every overlay colour now derives from `Color.primary` or the system accent, so
it is a true grey on both appearances; `Slate` still supplies dimension and the mono face. The workspace
keeps the filter. Status colour is the exception and stays: neutrality is about chrome not competing, never
about suppressing a signal.

**Follow-up 3 — the card behaves like a card: it swallows its own clicks, hands the keyboard back, and
follows the mouse.**

Four reports, three of them the SAME root as each other and one a self-correction of the round above.

⚠️ **A dismiss floor that spans the window is reachable THROUGH the card.** Clicking a card's own body —
a label, the padding between two fields, the gap beside the "Video ports" disclosure — hit nothing
interactive, fell to the backdrop button beneath, and dismissed the card the user was reaching into. The
card now carries its own hit barrier (a clear `Button` BEHIND its content, inside `slateGlassCard()`), so
every real control still takes its hit first and only what the content declines stops there. The
disclosure row also became full-width (`Spacer` + `contentShape`) — a hit area two words wide is a miss
waiting to happen. Verified: an inside-click leaves the card up, "Video ports" expands, a click outside
still closes.

⚠️ **An in-window card must hand the KEYBOARD back on close.** The card's field is the window's first
responder while it is up, and tearing it down leaves the WINDOW holding it, so the pane went deaf until it
was clicked. None of the surface's reclaim paths fire — they gate on a focus TRANSITION or a click, and
the workspace focus never changed. A sheet did not need this (AppKit restored the parent window's
responder); the fix is `WorkspaceStore.reclaimKeyboardFocusInActivePane()` on the card's `onDisappear`,
the same hand-back the find bar performs, resolved against whichever pane is active AT THE CALL (so a
palette split leaves the keyboard on the pane it created).

⚠️⚠️ **CORRECTION to Follow-up 2: `.onTapGesture` was never the problem — `allowsHitTesting(false)` was.**
The dead palette row was the ambient layer's hit gate suppressing everything composed into that chain,
which the same commit fixed by making the modal a ZStack SIBLING. `SlateClickTarget` was added in that
commit too and wrongly credited. Worse, it caused a regression: a click target laid OVER a row is topmost
for the pointer, so it ate the row's `onContinuousHover` and hover-select stopped working on the palette
and Open Quickly. A row is now a real `Button` WRAPPED around itself (`slateRowButton`) with the hover
modifier outside it. Measured on hardware: hover moves the selection on both surfaces, and the click still
runs the row. `SlateClickTarget` survives as the dismiss floor only.
⚠️ Automation trap: a cursor WARP (`CGWarpMouseCursorPosition`, what most drivers do) posts no mouse-move
event, so tracking areas never fire and hover looks broken. Move with real `CGEvent` moves (`cliclick m:`).

**A held arrow now WALKS the list** (`OverlayKeyRepeat`). `.onKeyPress` subscribes to `.down` only unless
asked, so every card list moved once per physical press. Repeat is a WHITELIST — the pickers route their
whole keyboard through one handler, so a held ⌘3 would otherwise re-open the third row every 30ms; the
movement keys repeat and everything else's repeats are swallowed (`.handled`, not `.ignored`, which beeps).
⚠️ Automation trap: `postToPid` drops synthetic auto-repeats. Post to `.cghidEventTap` with
`kCGKeyboardEventAutorepeat = 1` (proved on a held letter first: 1 down + 6 repeats ⇒ 7 characters).

**The SYSTEM ACCENT leaves the family too.** Neutral in Follow-up 2 meant "not the terminal's filter"; it
now also means "not the machine's accent". The caret, the fzf match run, the ✓ gutter and the default
button were the last coloured things on an otherwise monochrome card, and one blue (or, on another Mac,
pink) element makes it read as a system dialog wearing our surface. A match run is marked the way every
readout here marks importance — heavier, against quieter neighbours — and a filled control takes
`SlateOverlayInk.control` (grey, because the platform draws a filled control's label white on both
appearances, so a `primary` fill would be white-on-white in dark mode).
⚠️ The native focus RING stays the system's blue: it is drawn from `NSColor.keyboardFocusIndicatorColor`,
which `.tint` does not reach, and the only ways out are killing the ring or repainting the whole app's
accent — both worse than one blue ring on a focused field.

## The app ships ONE neutral accent, and the overlays ship one component kit (2026-07-31)

Three reports against the connect card, photographed on hardware: the field ring was still machine-blue,
the Connect button rendered as a near-white plate, and its white label vanished into it. All three were
the residue of chasing neutrality with per-subtree `.tint()`:

- The blue was `NSColor.keyboardFocusIndicatorColor` (and the text-selection wash) — AppKit derives both
  from the APP's accent, and no `.tint()` on any subtree reaches them. The round above called repainting
  the app accent "worse than one blue ring"; with the ring now reported alongside a tinted-button bug, the
  trade reversed.
- The white-on-white button was `.tint(SlateOverlayInk.control)` (a flat `Color.gray`) on
  `.borderedProminent`: in dark appearance the platform lightens that tint into a near-white plate and
  still paints the label white. A hand-picked tint bypasses the platform's own label-contrast logic; an
  ACCENT does not.

**The fix is the supported mechanism: an `AccentColor` asset** (`Apps/Shared/Assets.xcassets`, wired by
`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in both app specs) carrying a per-appearance graphite
(`#8E8E93` light / `#6E6E73` dark). Focus rings, text selection, filled controls and the close-confirm
`.alert` all resolve neutral on every theme, on both platforms, with the platform still choosing label
contrast. Verified by pixel on light + dark: no blue anywhere on the card, and the Connect label is
legible on a graphite plate.

With the accent itself neutral, every tint correction became dead weight and was DELETED: the WindowGroup's
`.tint(Slate.State.accent)` (and the satellite copy), the overlay layer's `.tint(nil)`, the Settings
scene's `.tint(nil)`, the first-launch sheet's `.tint(nil)`, and `SlateOverlayInk.control` itself. Where
the THEME accent is a deliberate signal (active tab, the focus corner, the rail), the view names
`Slate.State.accent` explicitly — the accent is now an ingredient views ask for, never an ambience they
must undo. The terminal cells and the status colours are untouched.

**The overlays now compose ONE component kit** (`DesignSystem/SlateOverlayControls.swift`) instead of
hand-rolling the same shapes: `SlateCapsLabel` (the section-level caps micro-label — palette headers, Open
Quickly headers, cheat-sheet categories, field names, Peek & Reply's RECENT), `SlateLabeledField` (caps
label over a NATIVE `.roundedBorder`/`.large` field), `SlateSearchBar` (magnifier + plain field at
`heightInput`, with the deferred focus-grab handled once), `SlateCardFooter` (Cancel + prominent confirm,
standard padding), and `SlateWarningRow` (the amber status line). Peek & Reply's off-grid literals (20/14/
12/24pt paddings, its own 460 width) moved onto the `Slate.Metric` grid, and the form-card width became a
token (`cardFormWidth`), so the connect and peek-reply cards are the same object at the same size. The
rule stands as before — the card is ours, the controls in it are the system's — this round just makes
"ours" one vocabulary instead of six dialects.

## A form card's title is a real title, and its labels speak sentence-case (2026-07-31)

The connect card was reported "not beautiful, not modern" with the complaint aimed at its TITLE and
LAYOUT. The card was wearing the instrument voice head to toe: `CONNECT TO HOST` in tracked caps-mono,
`HOST` and `PORT` in the same register right under it — three runs of engraving stacked on one small
form. Research across the current crop of macOS dialogs (Apple's Tahoe HIG alerts/panels, Linear,
Raycast, Things 3) agrees on the opposite grammar: a short sentence-case noun-phrase title one size up
from the body, sentence-case field labels, and NO caps eyebrows anywhere in a form.

So the floating family's hierarchy is now SIZE AND WEIGHT in one voice, not a voice-switch:

- **`SlateCardTitle` is a real title**: the system face at the new `Slate.Typeface.title` rung (15) at
  semibold in `primary` — the one line on a card that outranks the content it names. The caps-mono
  treatment is deleted.
- **`SlateLabeledField`'s label is sentence-case** system text (`base`/medium/`secondary`), not a caps
  micro-label. `SlateCapsLabel` survives ONLY as a LIST region's caption (palette / Open Quickly
  section headers, cheat-sheet categories, Peek & Reply's Recent) — naming a run of rows is the one
  place the caps register still earns its keep, and those surfaces were the ones already judged good.
- **A port field is port-sized**: host + port share one row (`portFieldWidth` = 96), as do the two
  video ports behind the disclosure — a five-digit answer no longer gets a card-wide question. Three
  variants were built for real and photographed (title-first / Linear-compact 13pt / title-less
  placeholder-as-label): the title-less cut died on contact with reality — this card opens PRE-FILLED
  with the live target, and a filled field with no label says nothing about what it is.

The cheat sheet inherits the same real title through the shared component. Peek & Reply keeps its own
header (the agent pane's title IS that card's identity — it was already content-first) and the
search-led overlays (palette / Open Quickly / global search) were never titled at all.

## The notification card joins the floating family: glass, sentence-case headline, one filled status mark (2026-07-31)

The in-app notification was reported disliked WHOLESALE — no part of the previous round's design
survived contact with the new floating-family grammar. It was the family's last opaque outlier: a
coloured caps-mono EYEBROW (`DONE · Claude`, `NEEDS INPUT · Claude`) over a mono subject on a
`Surface.raised` plate, which after the form-card round read as four hues of instrument engraving
stacked in a corner. Research (Warp's `ex-toast` — the closest analog, a terminal speaking 14px
sentence-case in ONE voice; Linear's toast tokens; Sonner's neutral-card default; HIG/`hudWindow`
restraint) agrees the modern in-app toast is a quiet neutral card, sentence-case, with at most one
small semantic accent.

- **The card is the family's glass card** (`slateGlassCard(hitBarrier: false)`) with the neutral
  system ink — the same object as the switcher/palette/connect card. The barrier is OFF because the
  toast's whole body is already its jump button; a background barrier would eat the clicks the card
  exists to take (measured against the modal cards, where the barrier is load-bearing).
- **The eyebrow's words became the HEADLINE**: a sentence-case event phrase derived from
  source + flavour + title ("Claude needs input", "Claude is done", "make check failed",
  "make check finished") — the two-speakers bit lives on, it just picks a VERB now instead of a caps
  word. Notices/advisories pass their title through untouched (the title IS the message). Factories
  override with a truer phrase where the derivation can't reach ("Session reattached" /
  "Reconnected to a fresh shell"). The long-command fallback title became the verb-less "Command" so
  the derivation can append the outcome without doubling.
- **The leading mark is ONE filled SF family** (`*.circle.fill`) in the status hue — checkmark/xmark/
  exclamationmark, `info` NEUTRAL (cyan on every routine OSC notice was chrome pretending to be
  signal). Three variants were photographed in the real window: the filled-symbol card won; a 6px
  status dot re-committed the "tiny abstract speck" mistake that killed the rail's ring here, and a
  no-mark card was elegant but blind — every card read identical until parsed, forfeiting the one
  signal (status colour) the neutral family explicitly keeps. This does NOT re-run the rejected
  SF-symbol quartet of two rounds ago: that was four glyphs from four families at four stroke
  weights; this is one family, one size, one weight.
- **Behaviour is untouched**: card-is-a-door jump, dwell pause-on-hover with nothing drawn,
  hover-only ✕ (unconditional on sticky), the 2-expanded spine, epoch-keyed dwell restart.
- **Photographing it**: the glass surface is a GPU backdrop effect `ImageRenderer` cannot rasterise,
  so the gallery tests judge layout/type/marks only. `SLOPDESK_TOAST_DEMO=1` seeds a sticky demo
  stack in the shipping app for real-window shots — that seam is the new judging surface.

## The command palette learns the panes: ⌘⇧P searches jump rows too (2026-07-31)

E11 scoped ⌘⇧P to verbs-only and sent every jump-to to Open Quickly (⌘⇧O). That split kept the
taxonomy clean but taxed the muscle memory every other tool trains: in VS Code / Zed the ⌘⇧P box
is where you type the name of the thing you want, verb or not. Reaching for a pane in the palette
and finding only verbs was a dead end that cost a re-open on the other chord.

- **The ⌘⇧P mixer now registers `TabsPaletteSource`** (the pane-jump source that had no surface
  since E11 folded jump-to into Open Quickly): one row per open pane of the active session,
  snapshotted per open like the Move-Pane verbs, accept = `jumpToPaneTree` and close. The section
  is titled **Panes** (the switcher's unit — the row is a pane, not a tab), registered AFTER the
  verb categories so an action title always outranks a pane row on a shared query.
- **The zero-state lists the open panes** under the Panes header after Move Pane, so the palette
  doubles as a pane switcher before a query narrows it.
- **Pane rows carry their cwd/app-name as a rendered subtitle** — the palette row view now shows
  a subtitle in the secondary ink (head-truncated, so a squeezed path keeps its leaf), because
  every fresh pane is titled "Terminal" and title-only rows would render indistinguishable twins.
- **Open Quickly is unchanged** — it keeps the richer multi-source jump-to (recents / folders /
  agents / files / command index). ⌘⇧P panes is the low-ceremony subset: the open panes, in the
  box people already have under their fingers.

## A pane is named once, and the chrome learns the terminal's alphabet (2026-07-31)

Two reports against the day-old ⌘⇧P Panes rows, one root cause each:

- **The palette named panes by `liveProgramTitle ?? spec.title` while the ⌃⇥ switcher resolved
  the full identity chain** (`RailRowsBuilder.liveRowTitle` — rename → intent → running command →
  stripped program title → process → blocks → folder), so the same pane wore two names two
  keystrokes apart. Fixed by extracting the switcher's per-pane resolution as
  `PaneSwitcherRowsBuilder.identity(pane:spec:tab:store:)` and pointing `TabsPaletteSource` at it:
  the palette row now carries the switcher's title verbatim and its PLACE line (`project › note`)
  as the subtitle, with the raw cwd demoted to a hidden search keyword so full-path queries still
  land.
- **A nerd-font glyph in a title drew as a notdef dot.** Private-use codepoints have no system
  fallback BY DESIGN — only the terminal grid could draw them, because ghostty embeds a symbols
  face. The app now bundles that SAME face (`SymbolsNerdFont-Regular.ttf`, MIT, licence beside it,
  ~2.4 MiB) as a `SlopDeskClientUI` package resource, registered process-wide on first use.
  `Text.nerdAware(_:size:)` splits a string into private-use vs ordinary runs (pure, unit-pinned)
  and splices ONLY the symbol runs into the bundled face — ordinary titles stay plain `Text`,
  byte-identical to before. Adopted by every chrome surface that renders live titles: the sidebar
  row, the ⌃⇥ switcher (title + place), the ⌘⇧P palette (fzf highlight runs + subtitle), and
  Open Quickly's highlight.

### The agent mark returns to the title — normalized, never animated (2026-07-31)

The follow-up ask: stop STRIPPING the agent glyph now that the chrome can draw glyphs. The strip
existed for a real reason — the leading glyph is the agent's SPINNER (braille frames, the `✢✳✶✻✽·`
asterisk cycle), and keeping the raw frame means the title's text changes on every animation tick:
the row-flash bug (`e551dc0b`) and the R23 no-motion-on-text rule both trace to exactly that. So
`strippedProgramTitle` became `normalizedProgramTitle`: every frame of the spinner family maps to
the ONE static `✳︎` mark ("⠙ build" / "⠹ build" / "✻ build" → `✳︎ build`, pinned identical), other
leading symbols stay user content, a bare glyph still carries no title. The mark shows; nothing
moves. The sidebar row's own `✳` agent marker skips itself when the title already leads with one.

## The right sidebar returns as the CODE panel: project-scoped embedded VS Code (2026-08-02)

> User-directed: "làm triệt để theo hướng code-server + WKWebView … mở lại cái right sidebar mà
> ngày xưa mình bỏ đi … project-scoped — các pane trong cùng 1 project show chung 1 cái vscode mở
> sẵn folder là project đó." RE-SCOPES the Host Windows rail retirement's "no right sidebar" state
> (the full-desktop pivot removed the rail, not the slot).

- ✅ **Embedding approach = code-server (Coder, MIT) in a WKWebView — decided by research + spike.**
  The official `code serve-web` / VS Code Server EULA forbids embedding in third-party apps and the
  marketplace ToU is restricted to official products; openvscode-server is frozen (22 versions
  behind); monaco-vscode-api has no full-workbench-in-WKWebView precedent; window reparenting is
  impossible on macOS. code-server ships the full workbench (Open VSX extensions), and the spike
  proved the service worker + full workbench run in a plain third-party WKWebView at
  `http://127.0.0.1` with no special entitlements.
- ✅ **The host owns the code-server lifecycle: metadata verb 18 `ensureCodeServer` NEVER waits.**
  `CodeServerManager` (one child per canonical project root) spawns `code-server --auth none
  --bind-addr 0.0.0.0:0` and learns the ephemeral port from the announce line (the cmux port-0
  pattern — no allocation race); the RPC replies with the CURRENT state (`starting`/`ready`/
  `unavailable` + port) immediately because a cold Node boot is multi-second and the metadata
  channel times out at 5s — readiness is CLIENT-side polling. `--idle-timeout-seconds 7200`
  self-reaps; a dead child respawns on the next ensure; `HostServer.stop()` terminates all.
  No auth token: the WireGuard mesh IS the security boundary (the no-app-layer-auth invariant).
- ✅ **The panel is the third plain `NSSplitViewItem` — the Host Windows rail's anatomy, revived.**
  Navigator | content | CODE. A PLAIN item, never `.inspector` (its collapse unmounts the hosted
  view — the exact reason the rail entry pinned this), so a collapse just unparents while the
  webview survives. ⌘⇧R (the chord the rail held, freed by its retirement, deliberately re-taken —
  `E1KeymapParityTests` re-pinned) toggles it via `.toggleCodeSidebar` through the standard
  closure chain (route → dispatcher/menu/palette → `WorkspaceChromeState.codeSidebarCollapsed`).
  Default COLLAPSED; the flag persists (`Defaults[.codeSidebarCollapsed]`) — unlike the left
  panel's session-scoped collapse, opening the code panel is a workstyle choice.
- ✅ **Project-scoped = keyed by the host-pushed `projectKey`, one warm webview per project.** The
  ACTIVE pane's `paneProjectKey` (wire type 34 — the SAME key the sidebar sections group by, and
  the absolute host path `CodeServerManager` canonicalizes) picks the workbench; every pane of one
  project shares the ONE instance opened at `?folder=<root>`. `CodeSidebarWebViewPool` keeps one
  WKWebView per project for the app's lifetime (cmux keep-alive lesson): switching projects is a
  warm swap, not a workbench reboot. `CodeSidebarModel` (pure, unit-pinned) owns the poll loop +
  URL build; the collapse unmounts the column so the poll only runs while the panel is open — a
  code-server is only ever ensured on first expand.
- ✅ **Keyboard: the dispatcher YIELDS to the webview (the cmux collision lesson).** The NSEvent
  monitor preempts the responder chain, and VS Code's chord vocabulary (⌘P/⌘⇧P/⌘F/⌘S/⌘W/⌘1–9)
  collides with the workspace table wholesale — so while the code panel's webview holds first
  responder every chord passes through UNCHANGED (the shortcut-less menus mean nothing else claims
  it en route; system ⌘Q stays alive via the app menu). The ONE exception: ⌘⇧R stays app-owned —
  closing the panel is how the keyboard comes back. Pinned by `DispatcherCodeSidebarYieldTests`;
  literal-byte text bindings sit BELOW the yield (they target the terminal, never an editor).

### The leftovers closed the same day: no fallback ensure, no focus steal, no light workbench (2026-08-02)

- ✅ **The ensure gate is the HOST-pushed key ONLY — the cwd fallback may section, never spawn.**
  The first pixel run showed TWO code-server children for one project: the panel had ensured on
  `paneProjectKey`'s cwd-fallback leg before the type-34 push landed, spawning a workbench for the
  shell's start directory that nothing would ever use again. `CodeSidebarColumn` now reads
  `WorkspaceStore.hostPushedProjectKey(_:)` (the pushed-only accessor, made public and pinned by
  `ProjectKeyStoreTests`): a client-side GUESS must never cost the host a Node process. Until the
  push lands the column shows a brief "Resolving project…" spinner (`paneProjectKey` non-nil
  proves a key is coming); a pane with no identity at all still gets the no-project placeholder.
- ✅ **VS Code cannot STEAL the keyboard — it can only be handed it by a click.** The workbench
  focuses its own editor on load/file-open/layout change, and WebKit forwards each page `focus()`
  as a first-responder claim — an autofocus mid-keystroke would silently re-route the terminal's
  keyboard into the editor (the cmux focus-steal lesson, now ported). `CodeSidebarWKWebView`
  (the pooled class) refuses `becomeFirstResponder` unless the CURRENT event is a mouse-down
  whose location falls inside the webview; the decision is `CodeSidebarFocusPolicy` (pure,
  truth-table-pinned — programmatic claims arrive with no current event and are refused, as is
  any claim riding an unrelated key/scroll/hover event).
- ✅ **First-run workbench defaults are SEEDED host-side, never overwritten.** A pristine host
  rendered VS Code's stock light theme against the dark chrome. `CodeServerManager` now writes
  `{"workbench.colorTheme": "Default Dark Modern", "workbench.startupEditor": "none"}` to the
  code-server user settings (`$XDG_DATA_HOME`/`$HOME/.local/share` + `code-server/User/
  settings.json`) ONLY when the file is absent — an operator's own settings are untouchable
  (`.withoutOverwriting` backstops the exists-check) — once per manager lifetime, before the
  first child boots (after that a seed would need a reload to take). Trap pinned in the tests:
  "home" must be resolved `$HOME`-first like the Node child's `os.homedir()` — `NSHomeDirectory`/
  `homeDirectoryForCurrentUser` go through directory services and ignore a `HOME` override, so a
  gate-sandboxed hostd seeded the REAL user's file while its children read the sandbox's.

### The panel regressed the rail's chrome on its first real deploy — restored, content unchanged (2026-08-02)

- ✅ **ATS: the workbench must load over plain HTTP to a NON-loopback host.** ATS exempts only
  literal localhost, so the 127.0.0.1 gate run masked a silently blank webview on every real
  address. `NSAllowsArbitraryLoads` is declared in `project.yml`'s `info:` block — **Info.plist is
  a PRODUCT: xcodegen regenerates it from `project.yml` on every generate** (check-macos and the
  deploy script both run xcodegen), so a direct plist edit evaporates. Security remains the
  WireGuard mesh (the no-app-layer-crypto invariant).
- ✅ **The code divider is hand-dragged — the host-rail machinery, restored.** AppKit's constraint
  drag cannot grow a trailing item that holds harder than its leading neighbour (panel 260 >
  content 250, deliberate), so the rail's tracked `setPosition` loop returns in
  `FlatDividerSplitView.mouseDown`, clamped between the content floor and the panel floor
  (`CodeDividerClampTests`; the panel floor wins over-constrained; no drag-collapse — hiding
  belongs to the toggles).
- ✅ **The rail's split of toggle duties returns**: a hover-revealed reopen plate in the titlebar's
  trailing cluster (always-reserved zero-shift slot) while collapsed; the expanded toggle inside
  the column's own traffic-light strip row; the "CODE" header in the instrument voice BELOW the
  strip. The `</>` glyph replaces `sidebar.right` wherever the action shows a face.

### The workbench goes secure-context + lean: loopback proxy, AI stripped (2026-08-02)

> User-directed: kill the "insecure context" warning ("mình có thể setup local ssl được không?")
> and slim the workbench ("bỏ mấy tính năng AI đi, giản lược bớt giao diện đi").

- ✅ **Loopback proxy beats local SSL.** The insecure-context toast (and dead clipboard/
  `crypto.subtle`) is browser SECURE-CONTEXT semantics, not transport security — and browsers
  treat loopback as a-priori trustworthy. `CodeSidebarProxyPool` (client, macOS) binds one
  `127.0.0.1` TCP relay per project and pipes bytes to the host over the mesh; the WKWebView
  loads `http://127.0.0.1:<local>`. A self-signed `--cert` was REJECTED: it needs trust-override
  plumbing in the webview, still rotates the origin with every respawned ephemeral port, and
  reintroduces app-layer crypto theatre the WireGuard-mesh invariant exists to avoid.
- ✅ **The local port is FNV-1a-derived from the project root** (`CodeSidebarProxyPorts`, pure,
  pinned — Swift's `Hasher` is process-seeded and would break this): the workbench ORIGIN is
  stable across code-server respawns AND app relaunches, so per-origin localStorage (layout,
  view state, dismissals) finally persists. Bind collision strides to the next candidate; total
  bind failure falls back to the direct remote URL (the ATS arbitrary-loads exception stays for
  exactly this path). The relay is retargetable — a respawn moves the backend, not the origin.
- ✅ **The seed grows a LEAN profile and an upgrade rule.** v2 seed adds `chat.disableAIFeatures`
  (the whole AI/chat surface), command-center/layout-control/navigation-control off, tips off,
  recommendation nags off, minimap + breadcrumbs off; `--disable-getting-started-override` joins
  the argv. Because the seed is only-if-absent, `seedUserSettings` now also REWRITES a file that
  is byte-identical to any seed in `obsoleteSeeds` — pristine by construction (the workbench
  rewrites the file on any user edit), so this is seed evolution, not a migration; anything else
  stays untouchable. Every lean key is user-scope — flipping it back in the workbench UI sticks.

### The workbench's two side strips merge; the boot loses its white flash (2026-08-02)

> User-directed: "làm gọn luôn... cái sidebar thứ nhất, để 2 cái sidebar gộp vào nhau" + fix the
> "đen xì → trắng cái → show ra" boot sequence.

- ✅ **Seed v3: `workbench.activityBar.location: "top"`** folds the activity strip into the top of
  the primary sidebar — one column, not two, in a 380pt-min panel. Known cost, accepted: any
  non-default activity-bar location FORCES the workbench title bar visible (it inherits the
  Account/Manage buttons; upstream offers no off switch — vscode#197163), and a CSS-hide would
  leave a dead band because the part grid is JS-positioned. `workbench.secondarySideBar.
  defaultVisibility: "hidden"` joins it — the relocation had flipped the CHAT aux bar visible by
  default. v2 moved into `obsoleteSeeds` (the pristine-upgrade path reaches deployed hosts).
- ✅ **The white flash was WebKit's base canvas, killed twice over.** `drawsBackground = false`
  (the long-standing KVC key; no public macOS API) makes the canvas transparent so the dark
  column shows through, and a per-project VEIL (`CodeSidebarWebLoadState`, pooled with its
  webview) keeps the column's dark waiting surface OVER the webview from main-frame load-start
  until the navigation settles, then fades (`smallFade`). Failures also settle — WebKit's error
  page must surface, never an eternal spinner. A reload re-veils through the same delegate
  events; a warm project swap mounts unveiled. `navigationDelegate` is WEAK — the pool retains
  the observer beside the webview.

### The code panel remembers its width; the app keeps its own chords (2026-08-02)

- ✅ **`shell.codeSidebarWidth` persists the panel's dragged width** (default `0` = never dragged →
  open at the 380 minimum), written when a code-divider drag settles — the only gesture that
  changes it — and applied through the SAME clamp as a live drag at launch (`viewDidAppear`,
  panel starting expanded) and in the expand animation's COMPLETION (a `setPosition`
  mid-animation loses to the collapse animation's final frame). The left sidebar deliberately
  restores nothing (capped, session-scoped).
- ✅ **WKWebView's `performKeyEquivalent` claims ⌘-chords for the page before the menu bar sees
  them** — a focused workbench swallowed ⌘Q whole. `CodeSidebarWKWebView` now refuses the
  app/window-management set (⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌘`) so those fall through to the main menu;
  everything else (⌘W = close editor tab, ⌘,, ⌘P…) stays with the editor the user deliberately
  focused. Pure `CodeSidebarFocusPolicy.isReservedAppChord` truth table, pinned — including the
  device-dependent-bits case (match the chord, not raw equality).

### One shared code-server; the workbench auto-saves and answers to SlopDesk (2026-08-02)

> User-directed: "làm triệt để cho tôi luôn đi" — ship the optimization chain the code-server
> research recommended.

- ✅ **RE-SCOPE: per-project code-server instances → ONE shared instance.** Empirically proven:
  code-server serves any folder from a single process — the workbench resolves its folder from the
  client URL's `?folder=` query (the HTML for two folders is byte-identical; the positional argv
  folder is only a default, now dropped). Per-project children were a Node runtime + extension
  host each for nothing, and they FOUGHT over the session socket (`code-server-ipc.sock` is per
  user-data-dir; only the first child owns the registry) — which the CLI's open-in-a-running-
  session routing (`code-server -r <file>`) depends on. Verb 18's wire format and validation are
  UNCHANGED (a root the host cannot see still answers `.notFound`); every root now reads the same
  endpoint. A stale child's log line can no longer poison a respawn (spawn-generation guard).
- ✅ **Client mirrors it: ONE loopback relay, one stable origin** (`CodeSidebarProxyPorts.
  sharedProxyKey`, FNV-derived port) fronting the shared instance; per-project webviews stay
  pooled — same origin, differing `?folder=`, so each project keeps its own workbench state while
  layout/storage live under one origin (standard code-server shape).
- ✅ **Seed v4: `files.autoSave: "onFocusChange"`** — the terminal beside the editor is where
  builds/tests run; leaving the editor IS the moment the file must be on disk. v3 moved into
  `obsoleteSeeds`. **`--app-name SlopDesk`** replaces the `{{app}}` branding strings.

### ⌘click on a terminal path opens in the embedded workbench (2026-08-02)

> Same directive — the third link of the chain: the code panel joins the terminal's link gestures.

- ✅ **Verb 19 `openInCodeServer`**: the "open" link action on a detected terminal PATH
  (⌘click, Hint Mode ⌘⇧J, Jump-To ↩, context-menu Open) now routes to the embedded workbench
  instead of the host's default app — `code-server -r path[:line[:col]]` lands the file (with
  cursor position) in the most recently registered workbench session. ⌘⇧click (reveal in
  Finder) and drag-drop (verb 9) are unchanged; URLs still open client-side.
- ✅ **No new detection layer.** The client already owned pure path detection
  (`TerminalLinkDetector`) and gesture policy (`LinkActionPolicy`) — the integration is one new
  `LinkAction` case (`openCodeHost`, carrying the `:line:col` suffix `resolvedAbsolute` drops)
  plus one new verb. The original plan (ghostty ABI text-at-point) was obsolete on arrival.
- ✅ **Accepted-not-completed reply + 1-byte disposition.** The workbench session registers only
  after a client webview boots — which typically happens in the same breath as the panel reveal
  this very reply triggers. So the host replies immediately (`ok` + disposition `workbench`) and
  retries the CLI async (10 × 2 s); the metadata queue never sits out a workbench boot. A
  directory, or a host without code-server, falls back to the verb-9 default-app open and says so
  (disposition `hostDefault`) — the client reveals the code panel ONLY when the file actually
  went to the workbench.

### The workbench dresses like the app: SlopDesk Monokai, sidebar right, flush top (2026-08-02)

> User-directed: dissect the Monokai Pro vsix into a SlopDesk-fit theme; workbench sidebar to the
> right; the code panel flush to the window top; a generic right-panel toggle icon.

- ✅ **"SlopDesk Monokai" = Monokai Pro with the CHROME yellows neutralized.** Dissecting the
  vsix showed its surfaces already equal the app's Slate seeds (both derive from monokai.pro) —
  the one real mismatch is the `#ffd866` UI interaction accent (active tab border/foreground,
  list selection, menus, badges…). Those ~17 keys move to the app's accent-neutral register
  (brightness, not hue: fg `#fcfcfa` / secondary / elevated; links take the filter cyan
  `#78dce8`). SEMANTIC yellows stay — `gitDecoration.modified`, find-match, syntax tokens,
  terminal ANSI — they match the app's own git ramp. Full theme JSON ships as an SPM resource
  (`SlopDeskHost/Resources`, too large for a source literal).
- ✅ **Seeded as a folder-dropped extension** (`extensions/slopdesk.slopdesk-monokai-1.0.0/`,
  package.json + theme) — empirically verified code-server recognizes it with no registry entry
  or vsix packaging. Unlike the user's settings file, the folder is OURS (namespaced) — the
  seeder repairs byte drift unconditionally. Seed v5 selects it (`workbench.colorTheme`) and
  moves the workbench sidebar right (`workbench.sideBar.location`); v4 joined `obsoleteSeeds`.
- ✅ **The code column is chrome-less.** Its strip/header died; the workbench runs flush to the
  window top (the titlebar overlay only spans the CONTENT column, so nothing collides). The
  panel's toggle + reload moved to the titlebar's trailing plates — toggle now bidirectional,
  reload speaks through a `WorkspaceChromeState` counter (the titlebar must not reach the
  column's private model). Both slots always reserved (zero-shift rule).
- ✅ **Toggle icon = SF `sidebar.right`** (palette row too), replacing `</>` — otty's actual
  lesson is "use the system vocabulary", and the right panel is a generic tab surface (code
  today, more tabs later), never a code-specific mark.

### The workbench goes fully chrome-less; fonts sync; the slopcat letterpress (2026-08-03)

> User-directed: "làm triệt để" on the workbench-UI research — ship the max-lean variant, and
> sync both the UI and monospace faces with the app, nerd-font fallback included.

- ✅ **Seed v6 = the chrome-less recipe.** Dissecting the shipped workbench bundle found the
  force-show rule: `activityBar.location` "top"/"bottom" (the v3–v5 fold) FORCES the title bar
  visible and even rewrites `customTitleBarVisibility: "never"` back to `"auto"`. The recipe
  that lets "never" stick: activity bar `"hidden"`, menu bar hidden, command-center /
  layout / navigation controls off. Status bar hidden too (its duties live app-side: the git
  readout; ⌘⇧M for problems). The panel's top edge is now the EXPLORER header itself; view
  switching is keyboard-first (⌘⇧E/⌘⇧F/⌃⇧G — chords the webview already passes through).
  Plus: compact tab height, empty-editor text hints off, overview-ruler border off,
  `window.title` drops `${appName}` ("code-server" never renders). Three variants were built
  and screenshotted; max-lean won. v5 joined `obsoleteSeeds` (verified byte-pristine after a
  real 30s workbench boot — the "never"→"auto" rewrite only fires on runtime config changes).
- ✅ **Fonts match the app on all three axes.** Workbench UI font already IS the app's (web
  default `-apple-system` → SF — nothing seeded). Editor: `ui-monospace` → SF Mono in WebKit,
  the terminal's default family, at the terminal's default 13pt. Nerd glyphs: the WebContent
  process cannot see the app's `CTFontManager` process-scope registration, so the bundled
  Symbols Nerd Font rides into the page as an @font-face data URI (~3 MB, built once per
  process) via a `WKUserScript`, and the seeded `editor.fontFamily` lists
  `'Symbols Nerd Font'` before `monospace` — agent marks and powerline glyphs render in the
  editor exactly as in the terminal chrome.
- ✅ **The empty-editor letterpress is the slopcat.** code-server's stock watermark is its own
  logo; the same injected stylesheet overrides `.editor-group-watermark .letterpress` with
  `docs/brand/logo-slopcat.svg` (ink made literal `#727072` — a data-URI SVG resolves
  `currentColor` to black — at the stock `opacity=".3"` subtlety). All builders are pure
  (`CodeSidebarPageDressing`, pinned headlessly); the WebKit wiring stays out of unit reach.

### The theme registry bug; seed v7 = registered keys only; the panel grows its own tab strip (2026-08-03)

> User-reported after living on the panel: unknown-setting warnings in the settings editor, the
> editor font not matching the terminal, the theme not applying, and no tab strip on the panel.
> All four traced to two root causes plus one design correction.

- ✅ **`extensions.json` is the source of truth — folder-dropping is not installing.** The
  batch-8 "no registry entry needed" finding held only while `extensions.json` did not exist;
  code-server writes an empty `[]` on first boot, and from then on the registry — not the
  directory scan — decides what is installed. On the real host the seeded theme folder was
  therefore INVISIBLE (`--list-extensions` empty, workbench silently fell back to stock dark —
  which is also why the font read "wrong": stock dark + pre-upgrade seed). Fix:
  `registerThemeExtension` writes our entry (identifier/version/location/relativeLocation, the
  shape the server's own validator wants) into the registry — foreign entries preserved,
  a drifted ours replaced, a missing file created. The workbench also deterministically strips
  `workbench.colorTheme` from a settings file naming a theme it cannot resolve; that mutated
  form joined `obsoleteSeeds` (byte-verified) so already-touched hosts still auto-upgrade.
- ✅ **Seed v7: every seeded key must be REGISTERED in the shipped workbench.** Code-OSS web
  ships no chat, and `window.customTitleBarVisibility` is desktop-only — the settings editor
  flags all three as unknown (the user's first complaint). A pixel-proofed variant run showed
  the title bar stays hidden without `customTitleBarVisibility`; `chat.*` dropped with it.
  Tests pin the three keys as never-return.
- ✅ **The tab strip lives on the panel, not over the terminal.** First cut put the panel's
  tab/reload/collapse in the titlebar's trailing plates (over the CONTENT column); user
  correction: "tab phải ở trên top của right sidebar" — the otty pattern puts the strip on
  the surface it controls, pushing the workbench down below it. `CodeSidebarColumn` now owns
  a top strip (`PanelTabPlate` "Code" selected + reload + `sidebar.right` collapse,
  top-anchored on the titlebar's traffic-light row so the two chrome rows read as one line);
  the titlebar keeps only the mirrored REOPEN plate while the panel is collapsed — the exact
  mirror of the left sidebar. The `codeSidebarReloadRequests` chrome relay died with the
  move: the strip calls the pool + poll model directly, in the one file that owns them.

### The panel becomes a native citizen: clipboard bridge, the terminal's own face, plate tabs, per-client light/dark (2026-08-03)

> User-reported, second round of living on the panel: copy inside the workbench never reached the
> system clipboard; the editor still rendered `ui-monospace` (not the terminal's JetBrains Mono);
> size/line-height out of rhythm with the terminal; tabs "vuông vức" — square, not the app's soft
> plate vocabulary. Plus: a light-themed client showed a dark workbench.

- ✅ **Copy is bridged natively, not permissioned.** The failure is WebKit's async clipboard API:
  `navigator.clipboard.writeText` demands a transient user activation that VS Code's async copy
  path has usually already spent, so the promise rejects silently and ⌘C dies inside the webview
  (the key event itself arrives fine — the dispatcher yield was innocent). Private WebKit
  permission prefs via KVC were rejected (crash-prone, version-locked). Instead a document-start
  user script (all frames) wraps `writeText`/`write` to ALSO post the plain text to a
  `WKScriptMessageHandler` that writes `NSPasteboard.general` directly; the original call stays
  best-effort with its rejection swallowed (a surfaced rejection would toast a false copy error).
  Copy is now deterministic on every client; paste already worked.
- ✅ **The editor face is the face the terminal ACTUALLY renders — the embedded JetBrains Mono.**
  The preference says "SF Mono" but CoreText resolves it on neither machine; libghostty falls back
  to its EMBEDDED JetBrainsMono Nerd Font. So "match the terminal" ≡ JetBrains Mono: the two
  upstream variable TTFs (upright + italic, OFL) ride in `SlopDeskClientUI` resources and inject
  as @font-face data URIs (the WebContent process cannot see `CTFontManager` registrations —
  same seam as the nerd font), and the seed's `editor.fontFamily` leads with `'JetBrains Mono'`.
- ✅ **Line rhythm is derived, not eyeballed: `editor.lineHeight: 1.32`.** JBM metrics (upm 1000,
  hhea 1020/−300/0) → ghostty `Metrics.zig` rounds cell height to exactly 1.32 × size. Seeding
  1.32 at the shared size 13 makes editor lines and terminal cells the same height to the pixel.
- ✅ **Tabs are Slate plates — geometry from the CSS coat, fill from the theme.** VS Code 1.112's
  own cornerRadius tokens already sit on Slate's ladder; the surfaces that never adopted them
  (tabs, list rows, scrollbar sliders, inputs, menus/hovers) get a geometry-ONLY injected recut
  (radius 6/8, capsule sliders, tabs inset 4px as floating plates — colours stay the theme's,
  test-pinned). Two traps: the label's stock `line-height` equals the FULL tab-height var, so the
  shrunk plate must recut it too (else glyphs overflow and the underline strikes through them —
  caught by pixel proof); and the underline containers are hidden outright — a Slate plate
  carries selection by fill. Which exposed that stock Monokai Pro flattens strip/active/inactive
  tabs to ONE colour and leans entirely on that underline: the themes now differentiate —
  active = the app's own active-tab card tone (`elevated` #403e41 dark ≡ Slate `selected` over
  the strip; white light), hover = the Slate hover tint, inactive flush with the strip.
- ✅ **The workbench follows EACH client's appearance from one shared settings file.** A second
  derived theme "SlopDesk Monokai Light" (Monokai Pro Light + the same 17-key chrome
  neutralization, pink accent → light neutrals, semantic pinks kept) ships beside the dark one,
  and seed v8 sets `window.autoDetectColorScheme` + preferredDark/Light themes. The client pins
  window `NSAppearance` to the active Slate theme, the webview's `prefers-color-scheme` follows
  it, and the workbench flips per client — a dark client and a light client on the SAME host
  each see their own register (pixel-proofed both directions in the gate fixture).

### The panel syncs the CURRENT terminal settings, and the chrome grows its seam language (2026-08-03)

> User-reported, third round: the editor's 13/1.32 are the terminal's DEFAULTS, not the client's
> CURRENT settings (macbook-pro runs 14pt / loose) — "cần sync cả current settings"; the compact
> tabs recut to 14px plates "nhìn height ngắn rất xấu"; the bare split divider "xấu, tôi nghĩ có 1
> line màu fg nhẹ… đẹp và native hơn"; the panel's top bar "nhìn xấu".

- ✅ **Verb 20 `syncCodeFont` — the client's LIVE font truth crosses the wire.** Font prefs are
  client-side (`PreferencesStore.terminal`) and never reached the host (EnvBridge carries no font
  keys), so the seed could only ever guess defaults. Now every ensure round (and every live
  Settings edit) pushes `[family][size][effective line-height ratio]`; the host patches exactly
  the three `editor.font*` keys in the shared settings.json (family first, then the seeded
  fallback stack), churn-free when in sync, never a file creator, JSONC = the user's. The RATIO is
  computed client-side the way the terminal actually renders: CoreText metrics for an installed
  family, the embedded JetBrainsMono 1.32 when the family resolves nowhere (exactly when ghostty
  falls back to that face), × the `adjust-cell-height` multiplier — macbook-pro's 14/loose lands
  as `14` / `1.58`. Host-global last-writer-wins (one shared file — the workspace document's rule
  applied to chrome). The decoder is the validator (family non-blank, size 4…128, ratio 0.5…4;
  NaN fails the range gates). Old host → `unsupportedVerb`, silently kept defaults.
- ✅ **Seed-upgrade stays FONT-BLIND.** A pristine former seed that verb 20 has re-serialized would
  never again be byte-identical — the comparator now canonicalizes both sides (sorted-keys JSON)
  with the three synced keys dropped, so a font-synced seed still upgrades and any OTHER
  divergence stays the user's. The current seed with synced fonts is left alone.
- ✅ **Seed v9 drops `window.density.editorTabHeight`.** Compact = 22px rows; the Slate plate
  recut (height − 8) squeezed those to 14px plates. Stock 35px rows → 27px plates ≈ the app's own
  control height.
- ✅ **The split divider carries the Slate `divider` tint — reversing the bare-ground rule.**
  User-directed: the seam gets "1 line màu fg nhẹ". `flatDividerTone()` now composites the theme's
  `divider` token (fg at its hairline opacity) over `ground` into one opaque colour (the layer bg
  cannot alpha-blend), per-channel plain lerp. The old worry (a raw white/black hairline reads
  heavy against one neighbour) is answered by using the THEME's tint at hairline opacity — the
  same register the pane-grid dividers already draw, so every seam in the window speaks one line.
- ✅ **The panel strip gets a bottom edge in the same language.** A `Slate.Line.divider` hairline
  under the strip closes the ground band against the workbench's tab row — previously two
  mismatched grays stacked with no rule between them. Pixel-proofed: strip hairline, both split
  dividers and the pane-grid line all sample the identical composite tone.
- ⚠️ **Gate trap (cost a full bisect): a SIGNED verify app silently loses the defaults suite.**
  The GUI gates' `SLOPDESK_DEFAULTS_SUITE` mechanism assumes the app is UNSANDBOXED — an
  xcodebuild WITHOUT `CODE_SIGNING_ALLOWED=NO` produces a signed, sandboxed app whose
  suite-named `UserDefaults` resolves in its CONTAINER, where the gate's `defaults write` never
  landed: every fixture key silently reads default (light theme, panel collapsed, fresh-install
  path). Always rebuild gate apps the way `check-macos.sh` does: `CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO`.

## The panel strip becomes a real tab row, and markdown reads rendered (2026-08-03)

- ✅ **The strip speaks otty's tab vocabulary, with a second surface announced.** User-directed:
  the selected tab expands to symbol + text, an unselected tab collapses to its icon —
  `PanelTabPlate` already encodes that grammar; the strip now leads with the selected "Code"
  plate AND the icon-only **Desktop** placeholder beside it — the window-OS surface the 07-22
  pivot promised, a no-op click until that panel exists. Actions (reload, collapse) stay
  trailing. Two same-day follow-ups: the row is CENTERED in the strip band (the titlebar-row
  top-anchor read off-balance), and Desktop's glyph is `display` (the app's existing GUI-surface
  vocabulary; `macwindow` rendered as a blob at strip size).
- ✅ **Seed v11: no git-decoration letter badges on editor tabs.** The sub-baseline "A"/"M" the
  workbench appends to tab labels read as a stray misaligned character (it is the git
  Added/Modified letter, stock workbench behavior, not a theme artifact).
  `workbench.editor.decorations.badges: false` scopes to TABS only — the explorer keeps its
  badges, and the git colour on filenames stays everywhere.
- ✅ **The dark divider tint steps up 0.07 → 0.10.** At 0.07 the fg-tinted seam sat barely above
  the ground tone — more shadow than line. One step brighter keeps it a quiet hairline that
  still reads as light. Light filters stay at 0.08 (their line is black; raising it would darken,
  not brighten). Every seam moves together — the token is the single source.
- ⚠️ **Never quote the user's prompt phrases (Vietnamese or otherwise) in code comments or docs.**
  User-directed 2026-08-03: describe the direction in the file's own language instead.
- ✅ **Seed v10: markdown opens as the RENDERED preview.** `workbench.editorAssociations` maps
  `*.md` to the built-in `vscode.markdown.preview.editor` — in this panel markdown is READ
  (README, docs, agent output), not authored; "Open Source" is one click when needed. v9 moved
  verbatim into `obsoleteSeeds` (10 entries), the font-blind pristine-upgrade carries a
  font-synced v9 forward. Pixel-proofed: README.md boots as a styled preview, no gutter.
- ✅ **Theme polish: the vsix conversion's junk is gone.** Both themes carried five EMPTY-string
  colour values (`diffEditor.move.border`, `diffEditor.moveActive.border`,
  `simpleFindWidget.sashBorder`, `statusBarItem.offlineBackground/Foreground`) — invalid per the
  workbench's colour parser, dropped (defaults are correct). And `settings.checkboxForeground`
  still sat on the chrome ACCENT (yellow dark / pink light) while its twin `checkbox.foreground`
  was already neutral — the one key the neutralization pass missed, now aligned. A test pins
  every colour value to `#rrggbb(aa)` and the two checkbox keys to each other, so conversion junk
  cannot return. Semantic accents (git-modified yellow, error red/pink, lightbulb) stay Monokai.

## The panel tabs go live, and the navigator header becomes a search bar (2026-08-03)

- ✅ **The strip's tabs are REAL — only Desktop's CONTENT is the placeholder.** User-directed:
  `CodeSidebarColumn` grows a `SurfaceTab` selection (`@State`, per-window; survives a
  collapse because the hosting controller keeps the SwiftUI hierarchy, resets to Code on
  relaunch). Selecting Desktop unmounts the pooled webview (warm swap back — the workbench
  returns instantly with its state intact) and shows the placeholder panel; the reload action
  renders only while Code is selected. Pixel-proofed both directions with a live click pass.
- ✅ **The navigator's caps header row is replaced by a full-width SEARCH FIELD.** User-directed,
  two same-day follow-ups: NO trailing hamburger menu (its collapse-all / expand-all / refresh
  actions are gone with it — the chevrons and the git line's own cadence cover them), and the
  field shares the tab cards' exact gutter so both read as one column. The filter reuses the
  pure `RailRowsBuilder` query pipeline the iOS `.searchable` path already exercised; an empty
  result set shows the standard empty label.
- ✅ **The right-panel toggle moves to the terminal section's top-right — and its persistence
  was ALREADY real.** The strip's trailing collapse plate is gone; `SlateTitlebar`'s
  hover-revealed trailing plate now toggles the panel in BOTH states (one location owns
  show/hide). Investigating the "remember open/closed" ask found no defect:
  `WorkspaceChromeState` seeds from `Defaults[.codeSidebarCollapsed]` and both write paths
  persist — proven empirically on the deployed client and pinned headlessly by
  `testCodeSidebarCollapseSeedsFromAndPersistsToDefaults`.
- ✅ **Seed v12: the activity bar folds into the sidebar top — and buys back the web title
  bar.** User-directed after v7's fully-hidden bar left Search / Source Control / Extensions
  reachable by chord only. `workbench.activityBar.location: "top"` FORCE-SHOWS the web
  workbench title bar (re-confirmed on 4.112 — it must host the relocated accounts + manage
  actions; `window.customTitleBarVisibility` stays desktop-only). Accepted: one quiet themed
  band naming the file + project, in exchange for clickable views. CSS-hiding it was rejected —
  the workbench grid positions parts with inline absolute geometry, so `display: none` leaves a
  dead gap rather than reflowing.

## The title bar loses its head, the panel follows the project, the gutter slims (2026-08-03)

- ✅ **The web title bar is CLIPPED off client-side.** User-directed. No seedable key hides it
  while the activity bar sits at "top" (the band must host the relocated accounts/manage
  actions), and CSS `display: none` leaves a dead gap — the workbench grid positions parts with
  inline absolute geometry. The macOS mount (`MacCodeWorkbenchView` since docs/56 increment 51)
  now lays the webview out 35px taller than its clipping container and shifts it up by the same:
  the workbench keeps believing in its title bar, the user never sees it. The container
  bounds-guards `hitTest` — without that the overhang sits under the panel's strip and eats its
  clicks.
- ✅ **A project switch can no longer strand the panel on the OLD project's folder.**
  User-reported: focusing another project's pane left the workbench on the previous project.
  Root cause: the column re-renders BEFORE the switched project's poll task runs, so
  `CodeSidebarModel.phase` still holds the previous `.ready` — and the pool minted the NEW
  root's webview from that stale URL (`?folder=` of the old project), then never corrected it
  (the re-load check compares host/port only, and the shared code-server keeps both constant).
  `.ready` now carries the project root it was ensured for, and the column mounts the webview
  only when that root matches the active one.
- ✅ **Seed v13: the gutter slims.** User-directed ("wasted width"): the panel reads code beside
  a terminal, it does not debug it. `editor.lineNumbersMinChars` 5→3, `editor.glyphMargin` off
  (breakpoints have no meaning here), `editor.folding` off (the arrows column; folding by
  command still works for the rare need). v12 joins `obsoleteSeeds` (13 entries).

## The panel owns its hide toggle, the strip animates as one gesture (2026-08-03)

- ✅ **The right-panel hide toggle moved INTO the panel's strip trailing corner.**
  User-directed. The titlebar over the terminal keeps only the collapsed-state REOPEN
  (hover-revealed, fade-in delayed past the split slide) — the exact split the left sidebar
  already had: hide lives inside the surface it hides, reopen lives in the chrome that
  remains. Both sides now read identically.
- ❌ **Otty's toggle glyphs (`inset.filled.leftthird.square` / `.rightthird.square`) — tried
  and rejected.** Extracted from the otty binary (its `PanelToggleButton` pair, 13pt regular,
  palette two-tone), shipped to pixels, user-rejected on sight as not fitting the app. The
  `sidebar.left` / `sidebar.right` pair stays. Do not re-propose.
- ❌❌ **Two tab-switch animation redesigns — both rejected; the ORIGINAL restored.** Round 1
  (fixedSize label + opacity transitions + surface crossfade on the tab-select token) was
  rejected as cheap-looking fades. Round 2 (pure width morph: label always mounted behind a
  width-0-or-intrinsic frame + clip, reload plate width-clipped, surfaces hard-cut, zero
  opacity anywhere) was rejected as stuttery. The user restored the batch-14 original by name:
  label conditionally in the hierarchy, everything on `smallFade`, surfaces swapping plainly.
  Do not re-propose either redesign; the "jank" both rounds chased reads better to the user
  than either cure.
- ✅ **"Code" → "Files" (`folder` glyph).** User-directed, settled in two steps the same day:
  first a lone `document`, then the folder register from a reference image — the tab opens the
  whole project tree, not one file. Trap recorded on the way: the `doc` family is renamed
  wholesale in SF6, so its new constants need a macOS 15 floor the package (14) does not have
  while the legacy `.doc` deprecation-warns at the app target — if an SF6-only glyph is ever
  required, the raw `SFSymbol(rawValue:)` spelling is the one warning-free path. `folder`
  sidesteps the family entirely.

## The workbench installs from the official VS Code Marketplace (2026-08-03)

code-server ships pointed at Open VSX, whose catalog is opt-in — most first-party `ms-*`
tooling (Pylance, C/C++, …) is simply absent, so the panel's Extensions view could not serve
the extensions a user actually reaches for (user-directed). Every code-server child hostd
spawns — the supervised server and the one-shot CLI — now launches with `EXTENSIONS_GALLERY`
set to the official marketplace URL set (the override code-server itself supports: the env var
is JSON-parsed and replaces the Open VSX default wholesale, so the value mirrors VS Code
stable's `product.json` in full). Consciously NO new flag (important features ship unflagged):
the escape hatch is the env var itself — an operator who exports their own gallery before
hostd keeps it verbatim. No proxy either: the marketplace API answers CORS-open (vscode.dev
consumes it from a browser), so the webview workbench reaches it directly. The ToS trade
(Microsoft scopes the marketplace API to VS Code products) is the operator's own, the same one
every code-server/VSCodium user makes on their personal setup. Proven end-to-end in the GUI
fixture: search finds Pylance, Trust-Publisher + Install lands `ms-python.vscode-pylance` in
the profile's extensions dir, and the language server starts analyzing.

## The workbench theme goes back to stock Monokai Pro (2026-08-03)

Reverses the 2026-08-02 "SlopDesk Monokai" derivation (17 chrome-accent keys neutralized,
Slate plate tab fills, checkbox alignment): the seeded themes are now the STOCK Monokai Pro
pair from the vsix (2.0.13) under their real names — `Monokai Pro` / `Monokai Pro Light` —
with the filter's own accents (dark yellow `#ffd866`, light pink `#e14775`) intact on tabs,
lists and links (user-directed: the stock theme is right as-is). Exactly two departures
survive, both deliberate: the seven structural seam borders (`sideBar`/`panel`/`activityBar`/
`statusBar`(+`noFolder`)/`titleBar`/`editorGroup` `.border`) trade stock's near-black
`#19181a` for the app's Slate `divider` token in alpha form (dark `#fcfcfa1a` = foreground
@ 0.10, light `#00000014` = black @ 0.08), so the workbench's internal seams match the split
dividers around the panel; and the vsix's five empty-string colour values (rejected per-key
by the workbench) are dropped. The vsix's icon themes are deliberately NOT taken — the color
themes only; file icons stay the workbench's stock set. Seed v14 renames the three
`workbench.*ColorTheme` keys and also brings the STATUS BAR back (same user direction:
`workbench.statusBar.visible: false`, hidden since v6, is simply dropped — the workbench
keeps its stock footing, its seam riding the retinted `statusBar.border`); v13 joins
`obsoleteSeeds` so pristine hosts upgrade in place. The extension id/folder
(`slopdesk.slopdesk-monokai-1.0.0`) is unchanged — the drift-repair seeder rewrites the
theme bytes on the next hostd start.
