# 61 — Deleting `Sources/SlopDeskVideoHost`

`CLAUDE.md` says a port deletes its original in the same change. This tree is the ONE place that
rule is deferred, and this file is why it is safe to defer it and what the deferral owes.

The reason is arithmetic, not preference. `SlopDeskVideoHostSession.swift` is 2051 code lines and is
the only thing that OWNS the other 46 files — the capturer, the encoder, the packetizer, the
injector and the window feed are all reached through it and through nothing else. Deleting the tree
before that file is ported would delete a working daemon and leave nothing that serves; deleting it
one file at a time would mean a fallback, a shim or a cross-language mirror at every step, each of
which `CLAUDE.md` names by name. So the tree goes in ONE commit, with the session, and every row
below has to be green in that same commit.

**The Rust side is landing meanwhile.** `rust/slopdesk-videohostd` already holds the argv grammar,
the settings overlay, `--list`, the UDP mux and the encoder's lifetime. None of it is reachable from
Swift, by design: no FFI door was added for any of it, so there is no bridge to unpick later.

## §1 The cascade — everything that must move in the deletion commit

| # | What | Where | What it needs |
| --- | --- | --- | --- |
| 1 | `SlopDeskVideoHostSession.swift` | `Sources/SlopDeskVideoHost/` | the port itself: 2051 lines, the keystone |
| 2 | the `SlopDeskVideoHost` library product | `Package.swift:121` | deleted |
| 3 | the `SlopDeskVideoHost` target | `Package.swift:699` | deleted |
| 4 | the `slopdesk-videohostd` executable target | `Package.swift:811-817` | deleted — the Rust binary is the daemon |
| 5 | `slopdesk-perfbench` | `Package.swift:832-836` | dissolve or retarget onto the Rust encoder. It drives `VideoEncoder` + `VideoDecoder` + the packetizer at real host configs, and every one of those is Rust already |
| 6 | `slopdesk-framewatch` | `Package.swift:840` | it has NO `SlopDeskVideoHost` edge — an SCK capture that logs arrival timestamps. `rust/slopdesk-apple-sck` covers it; retarget or dissolve on its own merits |
| 7 | `SlopDeskVideoHostTests` | `Package.swift:1071` | deleted with its target |
| 8 | the `apple_floors` rules that name the tree | `rust/slopdesk-invariants/src/rules/apple_floors.rs:35,188,358,405,575,583` | each names a path under `Sources/SlopDeskVideoHost/` or `Sources/slopdesk-videohostd/`. A rule whose subject is deleted must be RE-AIMED at the Rust that replaced it, never merely dropped — and its break-test with it |
| 9 | the devtools GUI's video page | `rust/slopdesk-devtools/src/gui/mod.rs`, `gui/video.rs` | check whether they name the Swift target or only the daemon's socket |
| 10 | `EnvBridge.loadDefaultSidecarIntoEnvConfig` | Swift client side | the daemon's `setenv` fold. `crate::env::Overlay` replaced it; the Swift call site dies with the launch path |
| 11 | `docs/00` and `docs/01` | prose | the "genuinely left to Swift: Network.framework" line is no longer true of this path |
| 12 | the four `slopdesk-videohostd` names in `STRANDED_RUST_MODULES` | `rust/slopdesk-invariants/src/rules/repo_invariants.rs` | `encode`, `feed`, `mux_registry` and `windowgeometry` are registered DEBT, not exemptions. The session port is what reaches them, so all four leave the list in this commit — removing a name is the last step of finishing the port, never a step of its own |
| 13 | the host's whole FFI door surface | `rust/slopdesk-ffi/` | 248 doors across 26 modules had the deleted Swift as their ONLY caller, so they die with it — plus the three settings faces that were the last thing keeping four of those modules alive (`HostGateTable`, `CaptureGateTable`, `InjectorGateTable`). Six more modules SHRINK to the doors a client still opens. See §5 |
| 14 | the `drag-cadence-ratchet` rule | `rust/slopdesk-invariants/src/rules/window_placement.rs` | it pins `WindowGeometryWatcher.swift`'s poll cadence to `windowgeometry.rs`'s. Its Swift subject dies here, so it is re-aimed or dropped WITH its break-test, the same way row 8 treats `apple_floors` |

## §2 The one architectural debt the port took on — PAID, in this commit

`rust/slopdesk-videohostd` used to depend on `slopdesk-ffi`, which is the Swift shim crate, and that
edge would be wrong in any other daemon. It was there because `slopdesk-ffi::encoder` held the
ENCODER DRIVER, and the driver held one `unsafe` obligation that is legal in exactly three crates:
HEVC parameter sets have no copy-out variant in the SDK, so `slopdesk-apple-vt` answered them as
`(ptr, len)` values and the single `slice::from_raw_parts` that laid them in front of a slice was
made in `slopdesk-ffi`, whose whole remit `docs/57` §2 states is that question.

Three ways out were checked and two failed on the repo's own terms:

- **A crate of its own for the driver.** A fourth hand-written-`unsafe` crate. `CLAUDE.md` admits one
  only for a MEASURED perf conflict; this is code organisation, so it does not clear the bar.
- **Put the driver in `slopdesk-videohostd`.** That crate is `forbid(unsafe_code)` like every crate
  outside the two families. The slice could not be written there at all.
- **Amend `docs/57`'s buffer paragraph to give `slopdesk-apple-vt` the exemption
  `slopdesk-apple-audio` has.** This is the one that works — but it could not be taken early. The
  audio exemption was granted only because that crate's "move the obligation to `slopdesk-ffi`"
  escape hatch was a dependency CYCLE. For `slopdesk-apple-vt` the hatch existed and was already
  taken, so the doc's own three-route test rejected the amendment while `slopdesk-ffi` was still the
  natural home.

It stopped being the natural home the moment the C doors died, which is this deletion. The
amendment landed here, and what landed is NARROWER than the three edits above anticipated:

1. `slopdesk-apple-vt` gained `copy_parameter_sets_into(&mut Vec<u8>)`, written the way
   `copy_payload_into` already was. `FrameworkBytes`, `parameter_sets()` and `contiguous_payload()`
   were then DELETED outright, so the crate answers only copies and no framework pointer leaves it.
2. A second, unplanned move came with it. `slopdesk-ffi::pixel_plane` existed for no reason but
   "this crate may write `unsafe` and apple-vt may not": it turned a locked buffer's
   `(base, stride)` into a slice for the capture path and the loopback harness. With the daemon no
   longer linking the shim, that module had no home, so the mapping went to the crate that locks the
   buffer — `Locked::plane_view` and `Locked::plane_mut` — and `pixel_plane.rs` was deleted. The raw
   `Plane` type is private now.
3. The driver moved to `rust/slopdesk-videohostd/src/encode.rs`, which is `forbid(unsafe_code)`. It
   needed no exemption of its own, precisely because of 1 and 2.
4. `CSink`, `CallerContext`, `SlopDeskEncodedFrameFn` and the whole of `slopdesk-ffi/src/encoder.rs`
   were deleted, with `pub mod encoder;` from `lib.rs` and the `---- The HEVC encoder ----` block
   from `slopdesk_ffi.h`. The header's third-convention paragraph was not merely deleted: the
   CAPTURE stream's own callback door had said "the callback convention is the encoder's above,
   term for term", so that paragraph now states the convention itself.
5. `slopdesk-loopback-validate` followed the driver rather than keeping a copy. Its whole claim is
   that it measures the object the host actually drives.

`slopdesk-apple-vt`'s ratcheted spend is therefore THREE raw sites, one per framework area plus the
plane pair, listed per crate in `SAMPLE_MEMORY` in `rust/slopdesk-invariants/src/rules/crate_policy.rs`.
`docs/57` §2 carries the argument; a fourth site fails the ratchet, and so does an entry naming a
crate that no longer exists.

## §3 What the Rust daemon owed before the commit could be written — PAID

Ported: the argv grammar, the settings overlay, `--list`, the UDP mux and its lane registry, the
encoder's lifetime and its four encode paths, the whole WINDOW FEED — the census (`windowsource`),
the budgeted accessibility probe (`windowprobe`), the four placement sequences (`windowplace`), the
drag/union poll cadence (`windowgeometry`) and the feed loop over them (`feed`) — and, in this
commit, the capture stream (`capture`), the paced send lane and its retransmit log (`sendlane`), the
packetize lane (`packetize`), the cursor channel (`cursor`), the host blank (`privacy`), the display
wake (`wake`), the virtual display and its recovery policy (`vdisplay`), the off-screen mint rescue
(`rescue`), the audio lane (`audio`), and the session itself — its state (`session_wiring`), its
composition and lifetime (`session`), its bring-up and teardown (`session_capture`), its inbound
path (`session_inbound`), its feedback fold and actuation (`session_actuate`), and its
encoded-frame pump (`session_pump`) — and, last, REMOTE INPUT (`injector`): the raise chain, the
scroll resampler's pump, the swipe-back translation and every event that reaches the window server.

The injector was the port's one genuine hole rather than a missing file. `raise_target_window`
existed as a trait method and a test recorder and nothing else, `slopdesk-apple-cgevent` was not
even a dependency of the daemon, and a ported host in that state could not accept a click. The
orchestration moved out of `slopdesk-ffi` whole — it was already safe Rust behind a C door — and
landed in the crate that installs it, which is what deleted the door.

`VideoSessionLogic` never needed porting: it was a FACE. `SLOPDESK_VIDEO_SESSION_*` and
`SlopDeskVideoSessionEffect` are C spellings of `slopdesk_video::session_state`, which has held the
real state machine all along — as `LiveCongestionController`, `FPSGovernor`, `LTRController`,
`QPController` and `RecoveryIDRPolicy` were faces over `congestion`, `fps_governor`, `ltr`,
`qp_control` and `recovery_idr`. The daemon composes them; it re-derives none of them.

Structural changes worth naming, because each deletes a whole class of bug rather than a file:

- **The encoded-frame queue is gone.** The Swift ran finished frames through a FIFO, a coalesced
  wakeup and a consumer task purely to undo the reordering an `actor` hop caused. `VideoToolbox`
  already calls back on a serial queue, so `EncodedFrameSink` runs on the framework's thread and the
  pump IS that call — one queue, one wakeup and one thread hop per frame removed from between the
  encoder and the wire. The INBOUND queue stays, for the one reason that survives: coalescing needs
  a motion run to pile up, and injecting inline would back-pressure the socket instead.
- **One pacing plan, not two.** `PacePlan::for_frame` is a single value because the Swift computed
  pacing separately in two drains and they had already drifted — the second could not see
  `keyframe` and floored a recovery IDR at the delta pace floor.
- **One generation, not five `===`.** `Live<Capture, Encode>` replaces the five-way identity guard
  every rebuild path wrote by hand, and the class of bug where a new path forgets one of the five.
- **One `Outgoing`.** `packetize.rs` had re-declared the rules crate's own `Outgoing` and
  `schedule_frame_raw`; both were deleted in favour of `slopdesk_video::recovery_routing`'s.

## §4 The spine, and the two new homes the port needed

The modules above are what a session IS. What actually runs them landed in the same commit:

- **`main.rs`** — the nine-step launch order, and nothing else. Each "before" carries the reason it
  is not the other way round; the file's own header is the authority, not this list.
- **`minter.rs`** — one hello into one running session. Every failure DEGRADES to in-place 1×
  capture; exactly two things refuse, a window that is gone and unrescuable, and a hello after
  `close()`.
- **`parking.rs`** — the accessibility and crash-journal half of parked windows, over
  `slopdesk_video::window_parking`'s pure ledger. The journal's serde rows pin the PREVIOUS
  release's spellings (`windowID`, `originalX/Y/Width/Height`, `schemaVersion`) so this daemon can
  recover the last one's crash, and launch hygiene deletes the journal FIRST so a restore that
  itself crashes cannot loop.
- **`discovery.rs`** — the answers that mint nothing, asked BEFORE the registry so a lane that only
  wanted the window list never starts a capture for the privilege.
- **`session_resize.rs`** — the resize ladder, landed as the RESTART path only. The Swift's
  in-place fast path — reconfigure the live `SCStream` and swap the encoder under it — is not
  wired, and the module's header says exactly what is missing: a `swap_encoder` door in
  `session_pump`, because a `VTCompressionSession` cannot change dimensions and the capture pump
  holds its `Arc<Encoder>` immutably. `HostGates::in_place_resize_enabled` is deliberately left
  unread rather than consulted for a branch that does not exist. Correctness is unchanged — this is
  what the Swift's own fallback did on any in-place failure — and only the ~120 ms spin-up is paid.
  The AUDIO LANE survives the rebuild: it is handed to the new capturer by
  `CaptureStream::hand_over`, which is the whole reason that door exists, because tag 6's sequence
  is monotone across capturer rebuilds and a client that late-drops on it would go silent for the
  rest of the session. Three more things survive with it — the client's latched audio wish, the
  user's stream settings, and the FPS governor, which is not re-minted because its ladder position
  is knowledge about the LINK and a resize does not change the link.
- **`diag.rs`** — one `write_all` of one buffer to stderr, prefixed with the invoked basename so two
  daemons in one log are distinguishable.

Two things could not live in the daemon and got their own homes:

- **`slopdesk_video::window_parking`** — the park/unpark refcount, the retarget and the restore
  ledger. It is a DECISION, so it is not in the daemon: the Swift file's own doc said as much.
- **`slopdesk-apple-nsapp`** — `become_accessory`, `run`, `drain_main_queue`. Zero `unsafe`;
  `objc2-app-kit` generates all three calls safe behind a `MainThreadMarker`.

### The divergences from the Swift, each one deliberate

None of these is an accident, and none should be "fixed" without reading why:

1. **`AppIconRequest` and `WindowPreviewRequest` are not answered.** No door exists:
   `slopdesk-apple-app` exposes no `NSRunningApplication.icon`, and `slopdesk-apple-sck` has no
   `SCScreenshotManager` surface at all. Both fall through to the registry's unbound-lane drop, and
   a test in `discovery.rs` pins that fall-through so the gap is visible the day a door lands.
2. **Nothing ticks the window feed on a workspace change.** The Swift's `WindowFeedKicker` debounced
   `NSWorkspace` and frontmost-app notifications at ~150 ms; `Discovery::kick()` is exposed for a
   future one, and until something calls it the feed falls back to renewal-driven rebuilds and the
   differ's own tick. A named LATENCY regression, not a correctness one.
3. **A display hello resolves the main display as "the one at the global origin"**
   (`cgdisplay::under(0,0)`), which is CG's own definition of it. The Swift additionally fell back
   to the first display `ScreenCaptureKit` reported when the two disagreed; that fallback is gone,
   because `SCShareableContent.displays` is deliberately private in the sck crate and a
   locked-screen `None` is the honest answer rather than a guessed display.
4. **The drain deadline `abort()`s where the Swift `_exit(0)`d**, so `launchd` records a crash and
   writes a report. That is the price of a `forbid(unsafe_code)` crate — `_exit` is a raw libc call
   — and it is the right price: the deadline thread races the drain thread, and two concurrent
   `exit()`s run the atexit handlers twice, which is undefined behaviour. An abort racing an exit is
   not. It only ever fires on a daemon that is already wedged.
5. **The adaptive-`m` FEC ladder is unreachable, and so is small-frame duplication.** Both need
   `m > 1`, and there is no `SLOPDESK_FEC_M` gate in `host_gates` — `Session::new` pins
   `ReedSolomonFec::default()` at `m = 1`. The GROUP-SIZE ladder (`SLOPDESK_ADAPTIVE_FEC`) is live
   and stepped per report; the `m` ladder's step, its three tiers 5/6/7 and the small-frame
   duplicate that keys off them are all dead code paths until that gate exists.
   `session_pump::wire_tier` names the exact argument that must become the gate.

## §5 The door surface the deletion took with it

A door is a rule spelled a second time in C. The Swift video host was the only caller of 248 of
them, so deleting the host deleted them — this is the half of the port that removes header surface
rather than adding it, and `slopdesk-gate ffi` proves both directions of it in one run: no exported
symbol the header does not declare, and no declaration the library does not export.

**Twenty-six modules die whole.** `abr`, `app`, `capture`, `capture_gates`, `capture_region`,
`cgdisplay`, `cgwindow`, `cursor_sampler`, `frame_rate`, `host_gates`, `host_policy`, `host_state`,
`injector`, `input_routing`, `mint_rescue`, `mux_host`, `nav_history`, `power`, `recovery_idr`,
`send_pacing`, `session_state`, `swipe_nav_config`, `virtual_display`, `window_feed_host`,
`window_list`, `window_placement`. Every one of them had a live Rust module behind it already; what
died is the C spelling in between.

**Three Swift settings faces die with them**, and they are the reason four of those modules looked
alive to the gate: `HostGateTable`, `CaptureGateTable` and `InjectorGateTable` under
`Sources/SlopDeskVideoProtocol/Settings/`. Each resolved a HOST operating point through the shim,
and nothing but the other two referenced any of them. The daemon resolves the same keys from
`crate::env::Overlay` directly.

**Six modules shrink to what a client still opens.** `audio_codec` keeps the decoder and loses the
encoder — every client decodes, only the host encoded. `ax` keeps only the Accessibility TRUST
read, which is a question about the calling process and so belongs to the client that installs an
event tap. `rate_control` keeps only `slopdesk_qp_config_default`, because the settings sidecar has
to show the number each `SLOPDESK_QP_*` parse falls back to. `input_event`, `recovery` and
`video_policy` each lose the one or two host-only arms of an otherwise client-facing module.

**One shared type moved rather than died.** `SlopDeskByteSpan` lived in `host_state`, but two
surviving doors speak it — the pane session's paths and the folder store's — and neither
vocabulary can own the other's, so it sits in `lib.rs` beside the arena helpers that produce it.

**One door died for a different reason.** `slopdesk_input_box_event` had a Swift caller, but that
caller was `InputBoxModel.onEvent`, a sink nothing outside a test ever bound — the cross-language
mirror fixture the one-implementation rule bans. The events it published had already moved the
model, which is what a view actually reads, and `TerminalModeTracker::consume` remains the one way
to ask for the events themselves. With the sink gone the door had no caller, and
`slopdesk_input_box_ingest` answers a plain `size_t` instead of a two-field record whose second
field nobody could read.

**Four dead typedefs went with the last pass.** `SlopDeskIdrPolicy`, `SlopDeskIdrConfig`,
`SlopDeskQpController` and the five `SLOPDESK_IDR_VERDICT_*` constants outlived every door that
spoke them, because the gate compares SYMBOLS and a typedef exports none. A handle type for a handle
nothing mints is exactly the drift this section claims the commit removed, so the admission-laws
section is now the one struct a client still reads — `SlopDeskQpConfig`, and the default it falls
back to.

## §6 The one push the deletion broke, and where it lives now

`SwipeNavStatusGlue.swift` was not a face. It was the swipe-nav status kicker — the 4 Hz beat that
tells every client whether a swipe would translate right now (`docs/20` §9.6, cursor channel type
`3`) — and deleting the Swift daemon deleted the only producer of a wire message the client still
decodes. Nothing was red: the chip simply never lit again, which is the failure mode a deletion
ledger exists to catch.

It is two Rust modules now, split by who else wants them.

| module | what it holds |
| --- | --- |
| `rust/slopdesk-videohostd/src/navhistory.rs` | the accessibility JOIN: `slopdesk-apple-ax`'s walk under `slopdesk_video::nav_history`'s rules, with the cached pair |
| `rust/slopdesk-videohostd/src/navstatus.rs` | the CADENCE: the thread, the 250 ms beat, the forced-every-eighth heartbeat, the change key, and the fan-out |

Three things changed shape in the move, and each is a fact rather than a preference.

**The reader never leaves its thread.** Its cached pair holds live `AXUIElement`s, which are Core
Foundation objects and therefore neither `Send` nor `Sync`. The Swift held them in an
`@unchecked Sendable` class; this crate is `forbid(unsafe_code)` and may not write the equivalent,
so the reader is constructed inside the beat loop and shared with nothing. It wanted no second
caller anyway — the cache exists to make the NEXT beat cheap, and there is one beat.

**`NavHistoryFlags` stopped being a second struct.** `slopdesk_video::swipe_nav_config` declared its
own copy of `nav_history::Flags` for as long as the reader was Swift, because the two ends of a C
door cannot share a type. With the reader in Rust the copy was a translation the daemon would pay
for on every beat, so the name is a re-export now and there is one declaration.

**The operating point is resolved once.** `navstatus::operating_point` is the single overlay read of
the `SLOPDESK_SWIPE_NAV*` family, and `injector::resolve` asks it rather than repeating the parse —
which is the invariant `swipe-nav-handle` exists for, now true by construction rather than by
inspection.

What did NOT come back is the instant push on `NSWorkspace.didActivateApplicationNotification`:
nothing in the `slopdesk-apple-*` family carries workspace notifications, and which crate would own
them is a `docs/57` §2 question. An activation lands on the next CHANGE beat instead, so the chip is
at most one 250 ms beat late rather than never.

**`rust/slopdesk-navprobe` follows the reader.** It drove `slopdesk_ffi::nav_history` and carried a
note saying it would not compile until that reader had a safe constructor — a note whose premise was
already false, because `just lint` clippies every workspace crate. It links
`slopdesk-videohostd`'s `navhistory` now, which is the same reader the beat drives rather than a
copy of it, and it takes its forced-beat interval from `navstatus::FORCED_EVERY` so a probe run and
a live session force on the same beat.
