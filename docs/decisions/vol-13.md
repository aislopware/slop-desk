# DECISIONS vol-13 — 2026-08-17 … 2026-08-31

> Volume 13 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## The canvas is deleted, two years after it stopped being live (2026-08-17)

The 2026-06-20 W5 cutover made the `TreeWorkspace` the live source of truth and left the canvas
"retained-but-dead": `Canvas`, `PaneGroup`, `Workspace`, the drag/snap/non-overlap/camera solvers,
the free-floating `WorkspaceCommand` enum and its interpreter, all still compiling behind a
`liveModel` switch that the app only ever constructed as `.tree`. The entry that made that call
booked the deletion as "a later W5 follow-up". This is that follow-up.

**What went.** Swift: `Canvas.swift`, `Canvas+Ops`, `Canvas+Codable`, `CanvasGeometry`,
`CanvasNonOverlap`, `CanvasSnap`, `PaneGroup`, `Workspace`, `CompactLayoutResolver`,
`CommandInterpreter`, and ~40 `WorkspaceStore` members that only the canvas reached (viewport
membership, the focus-history ring, `addPane`/`closePane`/`duplicatePane`, the recently-closed
single slot, zoom, `move`, the spec side-door). Rust: `canvas.rs`, `canvas_arrange.rs`,
`canvas_geometry.rs`, `canvas_non_overlap.rs`, `canvas_snap.rs`, the camera half of `geometry.rs`,
the canvas half of `persist.rs`, and `PaneGroupId`/`LayoutPresetId`. The `liveModel` switch itself
went with them — a two-case enum whose second case has no model behind it is not a choice.

**27 FFI doors went too, and that is why this landed as one commit.** `check-ffi-doors` fails on a
door nothing calls, so deleting the Swift callers without deleting the doors is a red gate, and
deleting the doors without the callers does not compile. The two languages are one change here, in
exactly the way `CLAUDE.md`'s one-implementation rule says a port is: the original goes in the same
commit, not a fallback, not a test fake.

**The tests were ported, not deleted.** 22 canvas suites went, but the LIVE contracts inside them
did not: agent-status eviction on close, the in-flight video-cap accounting, the quiesce fixpoint,
the focus reassert, the phone video cap, the pause/resume fan-out, and the palette recents ring were
each rewritten against the tree. A test deleted with its fixture is a contract that silently stopped
being checked — which is the failure this repo has a supervisor script for.

**The recents ring changed shape on the way.** It held `WorkspaceCommand` values, an enum that no
longer exists; it now holds palette CATALOG IDs (`"action.closePane"`), which is what the palette
was already keying rows by. One vocabulary instead of an enum plus a lookup table between it and the
rows a person actually sees.

Docs 30, 32 and 35 stay where they are, marked historical in `docs/README.md`'s index. They describe
a design decision and its reasoning, and that reasoning is why the split tree looks the way it does.
What they no longer describe is any code.

## The git line stopped forking, and libgit2 came into the archive with it (2026-08-19)

`gitStatus` was five process spawns for one struct: hostd forked `slopdesk-probe`, and the probe
forked `git` four times inside it — `status --porcelain -b`, `remote get-url origin`, `rev-parse
--show-toplevel`, `stash list`. That was affordable when the verb rode a person. It stopped being
affordable when `RepoStatusWatcher` began polling it on every debounced FSEvents tick, per watched
repo: an editor writing a file could cost five `fork`/`execve` pairs, and a repo with a busy build
directory could keep doing it.

It is now `rust/slopdesk-git`, LINKED. One `Repository::open_ext`, seven questions off the handle,
zero spawns. `CLAUDE.md`'s "pick by lifetime" rule decided the shape: the watcher lives exactly as
long as hostd, so this is a library, not a binary on a socket.

**Why not gitoxide.** The expectation going in was gix — pure Rust, no C, no linker flags. Measured
and read on 2026-08-19, it lost on two counts either of which was enough. It has no stash support
(there is no `gix-stash`; every stash capability is an unchecked box in gitoxide's own
`crate-status.md`), and the stash DEPTH is one of the seven sigils the git line draws — so a gix port
would have kept a `git` fork for it, which is most of the cost this removes. And `gix::status`
decomposes into `index_worktree` and `tree_index` with no `XY` output, while `golden_vectors.json`
freezes the porcelain pair; `git2::Status` is already that X/Y split as one bitflag value, which is
the difference between MAPPING a wire contract and reconstructing one. Everything else agreed with
gix (16 transitive crates against 163, 27 s cold build against 64 s) and none of it outweighed those
two. Revisit when `gix-stash` exists and gix is 1.0 — the parity suite below is written against the
public function, so a re-port is validated by the tests that are already there.

**It is not in `slopdesk-probe`, and could not be.** That workspace is tuned for programs whose
whole cost is starting up (`opt-level = "z"`, `lto`, `panic = "abort"`), and every member is forked
per event. Linking a vendored libgit2 there would pay `git_libgit2_init` on every fork — the cost
this port exists to remove, moved rather than removed.

**The parity suite is the reason the old path could be deleted in the same commit.** Twelve fixtures
build REAL repositories under the temp directory and compare every field with what the `git` binary
says about the same directory: staged-and-unstaged on both axes, an untracked directory as one
entry, a rename at its new path, two conflict pairs read from our side first, the stash depth, ahead
AND behind at once, a detached head, a subdirectory, and a directory in no repository at all. The
oracle is the BINARY — the file spells porcelain's grammar and nothing about how the old probe used
to read it, because copying that parser in would have left a mirror of a deleted implementation
behind forever.

**One deliberate divergence, and it is a fix.** Porcelain prints `## No commits yet on main` for an
unborn head and the old parser took the whole sentence as the branch name — the sidebar said `No
commits yet on main` where a person expects `main`. The new path reads the name off the symbolic
reference. The test asserts both sides of that disagreement rather than smoothing it over.

**What linking a C library cost, since it is not nothing.** libgit2 wants zlib, iconv, `Security` and
`CoreFoundation`. zlib is compiled INTO the archive (`libz-sys`'s `static`) because it was small
enough to vendor; the other three are declared once in `Package.swift` as `ffiCLibraries` and carried
by every target that names `CSlopDeskFFI`. Every target, not just hostd's, because a Rust staticlib
is one object per crate: the object holding this door holds every other `slopdesk_*` entry point, so
an executable calling ANY of them drags libgit2's members in. `-dead_strip` removes the code from
products that never call it; what they pay is a link-time symbol lookup.

The iOS slices do not pay even that. The door is `cfg(target_os = "macos")`, its declaration sits in
a `TARGET_OS_OSX` region of `slopdesk_ffi.h`, and `build-ffi.sh` reads that region's markers: the
symbol is REQUIRED on the macOS slice and REQUIRED ABSENT on the other two. A client on either
platform RECEIVES the git status as a metadata reply and never computes it, so there was never a
phone caller to serve — and now the three spellings of that fact cannot drift apart quietly.

## The domain crate was four crates wearing one name (2026-08-22)

`rust/slopdesk-workspace` had grown to 25,342 lines across 44 modules, and `slopdesk-wire` — the
crate holding the golden-pinned protocol — depended on all of it. That is the inversion the split
was meant to remove: a wire format sitting underneath the Settings catalogue, the phone keyboard,
the git status line, the notification policy and the rail titles, none of which it serialises.

**The first module graph was wrong, and the way it was wrong is worth writing down.** `grep 'crate::'`
counts rustdoc intra-doc links as dependencies. That phantom graph shows six cycles — `drop_action ↔
drop_zone`, `hid_virtual_key ↔ keystroke_replay`, `settings_rows → binding_rows`, `settings_catalog →
session`, `binding_search → settings_rows`, `notify → chrome` — and **not one of them exists in the
code**. Stripping comments first leaves exactly one real 2-cycle in the whole crate,
`settings_layout ↔ settings_rows`, and it falls inside a single new crate. A carve planned against
the phantom graph would have been built around cycles that were never there.

**The carve as designed was also wrong, and measuring said so.** The plan was two leaves. But the
wire does not merely borrow identity and JSON: `document/apply.rs` alone calls **25 distinct
`tree_ops` entry points**, and the wire's transitive need is ten modules — 7,692 lines. Two leaves
would have left the `wire → workspace` edge fully intact, just pointed at an 18.8k-line crate
instead of a 25.3k one. The third crate is what actually cuts the edge.

| | before | after |
| --- | --- | --- |
| `slopdesk-workspace` | 25,342 / 44 files | 11,978 / 28 |
| `slopdesk-ids` (leaf, no deps) | — | 1,060 / 4 — `identity`, `json`, `shell_quoting` |
| `slopdesk-tree` (over ids) | — | 6,851 / 9 — the document proper |
| `slopdesk-settings` (leaf, no deps) | — | 5,571 / 6 — the catalogue, its layout, its rows |

`slopdesk-wire` now names `slopdesk_workspace` nowhere, and neither does `slopdesk-terminal`. No
re-export shims: every module has exactly one path, because a shim is how a carve grows a second
spelling of where something lives. Golden vectors are byte-identical.

**`secrets` did NOT go to the leaf, though it looks like it should.** The two mentions of
`slopdesk_workspace` in `slopdesk-terminal` beyond its one real import are prose — a doc comment
*contrasting* `secrets::assess` with what paste does, and a code comment. The single real edge is
`shell_quoting`. Sinking `secrets` would have dragged `regex` into both `slopdesk-wire`'s and
`slopdesk-terminal`'s dependency trees to serve a caller that does not exist.

**The residual `wire → tree` edge stays, and that is the line.** `apply.rs` is 2,076 lines and *is*
a domain applier; the honest fix is moving it into the domain crate, which changes public paths that
`slopdesk-ffi` and `slopdesk-superd` name — a separate change, not a free one. A protocol depending
on the model it serialises is not an inversion. A protocol depending on the settings catalogue is.

**Owed: the residual crate no longer contains `workspace.rs`.** `slopdesk-workspace` is now the
client's remaining *surfaces*, not the document, and the name says otherwise. Renaming it touches
`slopdesk-devicepanel`'s manifest and 34 `slopdesk-ffi` files — mechanical, and deferred rather than
declined.

## The last shared view target becomes two, and the seam is why it is not three (2026-08-22)

`Sources/SlopDeskVideoClient` was the one view target the docs/56 UI split never reached — outside
`scripts/check-supervisor.sh`'s ratchet entirely. Thirty-three files, and ONE of them,
`VideoWindowView.swift`, was 2,898 lines of which the middle 2,514 were a single
`#if os(macOS)` / `#elseif os(iOS)` two-armed conditional: an AppKit implementation and a UIKit one
in the same file, linked by both app shells. Two implementations is the standing directive; two
implementations *inside one `#if`* is the shape the directive exists to abolish, and it hid a live
parity gap for a release — the swipe-peel chip was MOUNTED on both platforms and DRIVEN on one, so a
two-finger swipe on the phone navigated the remote app with no chip and no haptic while the shared
overlay sat permanently dark. The doc comment that caused it ("never set on iOS — no trackpad scroll
phases") had been false since the phone started sending phase-carrying scroll.

**Option B: two sibling view targets, `SlopDeskVideoClientMac` and `SlopDeskVideoClientPhone`**, each
depending on the now view-free `SlopDeskVideoClient`, each linked by exactly one app shell.

**Option A — fold the two arms into `SlopDeskMacUI` / `SlopDeskPhoneUI` — was rejected, and stays
available.** It is the tidier graph on paper: two targets instead of four, and the halves would sit
beside the UI files that mount them. What it costs is the `VideoWindowFactory` seam. That seam is not
incidental plumbing — it exists so the view layer never NAMES a VideoToolbox or Metal type, which is
the only reason the headless `swift build` and the whole test graph do not pull those frameworks in.
Folding the halves into the UI targets spends that property to buy target-count tidiness. If the day
comes that the headless graph is allowed to link VideoToolbox, A becomes correct and cheap; until
then B is the one that keeps the invariant.

The starting position was also not what it looked like: **neither UI target imports
`SlopDeskVideoClient` at all.** Only the two `AppMain.swift` shells, three CLI tools and the test
target do. That is what forced the choice — there was no existing edge for A to reuse.

**What actually moved, and what deliberately did not.** The two arms became seven files (four Mac,
1,986 lines; three phone, 1,213). `VideoWindowConnection` was the only piece of the old common head
that stayed shared, and it now imports `SlopDeskVideoProtocol` and nothing else. `VideoWindowPipeline`
went `package`, not `public` — 33 members, and `package` is the narrowest width that reaches a sibling
target in the same package. Nothing was raised to `public`.

**The zoom ladder shipped first, alone, and the framing that scheduled it was wrong.** `ViewportZoom`
was extracted before any file moved, because the clamp/snap/step arithmetic was spelled inline at five
call sites. It was NOT a merge of the two platforms' ladders: the Mac floors at 0.25× and the phone at
1×, and `TouchPointerPlan` already said in as many words that these are two viewport models rather
than one policy. Merging them would have been a regression dressed as deduplication. `bounded` (clamp
only) and `clamped` (clamp then snap to unity inside a 0.06 band) stay two functions, because `fitted`
must not snap a genuine 0.97 fit away.

**`LocalInputPolicy` came out of the Mac half for the same reason, one step later.** Three pure
statics — modifier-edge direction, which modifiers a refocus resync re-forwards, and the click-count
clamp — were about to be duplicated by the carve. Layout diverges, capability does not: arrangement is
duplicated, a rule never is. They now live once in the engine over `InputModifiers`, which deleted an
`#if os(macOS)` from the test file: the rule is exercised on the phone triple too, where the
modifier-resync path it governs is still unbuilt.

**The naming follows the house.** Mac takes the `Mac` prefix, phone takes the bare name — sixty such
pairs already exist across `SlopDeskMacUI` and `SlopDeskPhoneUI` (`MacGuiLeafView` / `GuiLeafView`).

**Five ratchet rules, two of them ledgers that fail both ways.** Rule A bans a view declaration in the
engine; Rule B asserts `VideoWindowView.swift` stays deleted BY PATH (a `DELETED_SWIFT_UNION` entry
would false-positive forever on the phone half's legitimate bare type names); Rule C names the five
files that legitimately keep an `#if os(macOS)` — actuators picking an API, not surfaces drawn twice —
and fails if one loses the arm it was excused for. Rules D and E compare the two halves: D the seam
sinks each takes, E the pipeline callbacks each subscribes. Both carry named exceptions, and both fail
when an exception stops being true. **One of Rule E's three entries is a known BUG, not a platform
floor**: the swipe-peel chip. The day it is built, Rule E goes red until its entry is deleted — which
is the whole mechanism by which a fixed bug stops being filed as an accepted difference.

**Two of Rule E's entries stop being floors if iPad pointer support lands.**
`onRemoteCursorChanged` and `onServerCursorVisibilityChanged` are excused because iOS has no hardware
cursor to swap or hide. The app ships `TARGETED_DEVICE_FAMILY "1,2"` and has zero
`UIPointerInteraction` anywhere in the tree; when that is built, these two are the first thing the
phone half must subscribe.

## The LTR capability probe is deleted, not ported (2026-08-23)

`VideoEncoder.swift` carried `runLTRCapabilityProbe`, ~130 lines behind `SLOPDESK_LTR_PROBE`: it
allocated a scratch pixel buffer, built a throwaway compression session, asked it to enable long-term
references, encoded a frame with `ForceLTRRefresh`, and read four `OSStatus` values plus whether an
acknowledgement token came back — then interpreted the five into supported / unsupported /
ambiguous / unknown and printed the verdict. When the encoder moved to Rust, the probe did not.

**Porting it needed a second §2 admission, and the admission is the expensive part.** The probe's
first step is `CVPixelBufferCreate` — a Create-rule out-parameter, so a second `CFRetained::from_raw`
in `slopdesk-apple-vt`, which §2 caps at one per crate and `apple-family` fails on. The way out
inside the rules is a new crate, because CoreVideo pixel-buffer allocation is a different framework
area than VideoToolbox compression and the family is one area per crate. So the real price of a
default-off diagnostic was a whole `slopdesk-apple-cv` crate: a leak test, a `# Safety` note per
block, a ledger row, and a permanent widening of the family's surface.

**Against a question that is already answered and already load-bearing.** The probe exists to find
out whether this hardware supports long-term references. It does; the answer is why
`FrameOptions::cf` writes `EnableLTR` and `ForceLTRRefresh` at all, and why the whole LTR ack path
downstream of it was built. A probe that re-derives a settled answer on demand is a harness, not a
capability, and the tree does not carry a crate to hold a harness.

**What survives is the part with the reasoning in it.** `interpret_ltr_probe` and
`LtrProbeVerdict` are in `slopdesk_video::encoder_config`, with tests — the five-signal fold that was
the only non-mechanical thing in the probe, and the only part that was ever hard to get right. If the
question is ever live again (a new chip, a virtualised host, a report of LTR silently doing nothing),
re-instrumenting is wiring four status values into a function that already exists and already passes
its tests, not re-deriving what they mean.

Two callers went with it: the `SLOPDESK_LTR_PROBE` block in `slopdesk-videohostd/main.swift`, and the
liveness smoke at the top of `slopdesk-loopback-validate`. The second was replaceable by nothing,
because the scenario immediately after it encodes real hardware frames and fails loudly if the path
is dead — the probe was proving, one line earlier, a thing the next line proves anyway.

## The client decoder is a face, and the Swift parameter-set span door went with it (2026-08-23)

`VideoDecoder.swift` was 380 lines. Behind it now: the session, the format description and the
sample buffer in `slopdesk-apple-vt`; every decision that drives them in
`slopdesk_video::decoder_state`; the join in `slopdesk-ffi/src/decoder.rs`. What is left in Swift is
a `Data`, a `Bool`, and turning four outcome codes into the two a caller acts on.

**Two of its decisions turned out to be load-bearing in a way the Swift spelling did not show.** The
parameter-set cache must be CLEARED by a hard decode failure: on a fixed-capture-size stream the
recovery IDR carries byte-identical VPS/SPS/PPS, so a cache that survived would answer "reuse" and
hand the next frame to the session that just failed — permanently, with nothing reporting it. And
the decode-wall average's first sample must SEED the average whole rather than fold against zero, or
the stats HUD shows a warmup ramp no decode ever took. Both were true in the Swift and both were
comments; both are now named tests in `decoder_state.rs` and content bans in `hevc-decode-is-rusts`.

**Three test seams disappeared rather than moving.** `cachedParameterSetsForTesting` and
`seedCachedParameterSetsForTesting` existed only so a test could model a configured decoder without
creating a `VTDecompressionSession` that would hang. In `decoder_state` the state IS a value, so a
test builds one by calling the constructor, and the seams have nothing to expose.

**`HEVCParameterSets.swift` is deleted, which supersedes "The HEVC parameter sets are spans, not a
second walk" (2026-08-15) as far as the Swift half goes.** That decision made the Swift type a face
over `slopdesk_video::hevc_parameter_sets` through three FFI doors. Its only caller was the decoder,
so with the decoder in Rust the face had no reader and the doors — `slopdesk_hevc_types`,
`slopdesk_hevc_nal_type`, `slopdesk_hevc_parameter_sets` — had no Swift caller. Face and doors both
went; the crate module is unchanged and keeps its own tests, and the shim calls it directly. The
span-shaped answer that decision argued for was right and is still the shape the crate exposes — it
simply no longer has to cross a boundary to be used.

**`stampDisplayImmediately` went too, which closes the note left at "The five sidecar managers keep
their vocabulary" (2026-08-15).** That note recorded a deliberate decision NOT to share those three
lines of CoreFoundation with the device panels' `annotate`, because the two live in targets with
different dependency floors and mark a sample for different reasons. The decision holds and the
panels' copy is untouched; what changed is that the decoder's copy is no longer Swift at all, so
there is nothing left to consider sharing.

**The four outcome codes are four rather than a `throws` with five cases.** The Swift had
`sessionCreateFailed`, `formatDescriptionFailed`, `sampleBufferFailed`, `decodeFailed` and
`awaitingKeyframe`, and no caller ever matched on which of the first four it got — every catch site
logged `String(describing:)` and ran the same recovery. What a caller genuinely distinguishes is
four things, each asking for something different: deliver, drop in silence, ask for a keyframe
without tearing down, and fail. Collapsing any two of those has a visible symptom, which is why they
cross as separate codes rather than as one status the caller has to interpret.

**The ScreenCaptureKit calls moved to Rust; the 2 350-line file did not.** `WindowCapturer.swift`
looked like a large port and was a small one — of its 2 350 lines only about 250 ever touched
ScreenCaptureKit. `slopdesk-apple-sck` took exactly those: shareable content, the three content
filters, the stream configuration, start/stop/reconfigure, and the per-sample status read. The
frame-DECISION pipeline — backlog pacer, encode-load governor, adaptive QP, scroll reprojection, the
static-IDR timer, the cadence gate — stayed in Swift, because none of it calls a framework; it is
arithmetic over numbers the capture callback hands it, and moving it would have been a rewrite
motivated by line count rather than by an effect on the system. What DID leave with the calls is
every rule they are made under: the delivery ceiling, the queue depth, the surface depth, which
filter a parked window wants, whether a resize may happen in place, where a moved window's crop
belongs. Those are now `slopdesk_video::capture_config`, `forbid(unsafe_code)`, tested headless. The
Swift they replace conceded in its own header that its `start()` was never called from a test — an
`SCStream` needs a window server and a Screen-Recording grant — so the split put the testable half
where tests can reach it and left the untestable half as thin as the framework allows.

**`slopdesk-apple-sck` costs NEITHER Core Foundation admission, and that is not luck.** `docs/57` §2
budgets one `CFRetained::from_raw` and one `CFRetained::retain` across the whole family. Capture
looked certain to spend one: it reads `CMSampleBufferGetImageBuffer` and the sample-attachments
array on every frame, both of which are get-rule CF returns in C. In `objc2-core-media` 0.3.2 they
are generated returning `CFRetained` already, so the ownership question was answered by the binding.
The lesson is the order of operations — READ the generated signature before budgeting an admission,
because the admission is for the calls objc2 has not modelled, not for CF-shaped calls in general.

**The doors block, so Swift routes them through a queue of its own.** ScreenCaptureKit's lifecycle is
completion handlers end to end, and a C door cannot return a Swift continuation. `handoff.rs` blocks
on `Mutex` + `Condvar` with a ten-second ceiling, which makes `slopdesk_capture_start` and its
siblings synchronous and slow. Rather than hide that, `WindowCapturer` owns a serial
`controlQueue` and every door call crosses it under `withCheckedContinuation`, so a start that waits
on the window server never occupies the session actor. The delivery queues are the opposite: they
come from the CALLER and the crate never makes one, because the frame queue being the same serial
queue as the static-IDR timer IS the discipline that lets the callback and the timer share a cached
frame with no lock.

**`Package.swift` had to name ScreenCaptureKit once the Swift stopped importing it.** The link was
implicit while `WindowCapturer.swift` said `import ScreenCaptureKit`; when that became
`import CSlopDeskFFI` the build failed on `_SCStreamFrameInfoStatus`. Classes are not the problem —
objc2 resolves those at runtime — but an `extern` CONSTANT is a link-time symbol, and a `#[link]`
attribute in Rust does not survive `xcodebuild -create-xcframework`. So the framework is listed in
`ffiCLibraries` with `.when(platforms: [.macOS])`. Any later `slopdesk-apple-*` crate that reads a
framework constant will need the same one-line entry, and the symptom will be identical.

---

## The audio row is Rust's, and one of its two crates is the family's only raw-pointer exemption

**2026-08-23.** Four Swift files — `AudioStreamEncoder` (395), `AudioStreamDecoder` (245),
`AudioPlaybackEngine` (205) and `AudioJitterBuffer` (363) — are three faces that marshal. What was
behind them is `rust/slopdesk-apple-audio` (the `AudioConverter` calls) and `rust/slopdesk-audio-out`
(the ring, the pump and the output stream). The `slopdesk_audio_stage_*` door family, fifteen
entries, went with them; so did `slopdesk_audio_decode_pcm_s16le`, whose only caller was the Swift
decoder.

### Why the stage's door was in the wrong place, having been in the right shape

`docs/55` §4b argued the stage should be a HANDLE and that argument still holds: its whole product
is the samples, so they live where the decisions are. What that reasoning did not settle is how much
of the pipeline the handle should cover. It covered the middle. A Swift `AudioPlaybackPump` asked
the stage for a priming latch, a target sample budget, a high-water budget, a starvation test and a
shed bound, and then moved samples into a Swift `AudioSampleRing` for an `AUHAL` render callback to
drain. Every answer the door gave was correct in isolation. Their ORDER was a law spelled on the
near side out of doors — prime, pull, shed, starve, drop-oldest — and could be spelled wrong there
without any door refusing.

So the boundary moved up rather than the shape changing: the same handle, two verbs (here is frame
N; play), and no order left for a caller to get wrong. **A handle with a large surface is a law
moved without its sequencing.**

### cpal, and why the playback path ended up with no hand-written unsafe at all

Two ways to open an output stream were on the table. Wrapping `AudioUnit` in a fifth
`slopdesk-apple-*` crate keeps everything in one family, and costs a render callback holding a raw
`AudioBufferList` on a real-time thread — the worst place in the system to be arguing about pointer
provenance. `cpal` is `dasp`/RustAudio's, is what essentially every Rust audio program on macOS
uses, and hands the callback a `&mut [f32]`.

The dependency was checked rather than assumed. cpal 0.18 reaches CoreAudio through
`objc2-core-audio` and `objc2-audio-toolbox` — the same `objc2` family this repo already pins — and
NOT through `coreaudio-sys`, which would have meant bindgen and a libclang build dependency. That
correction is what settled it: the edge adds no toolchain the tree did not already have.

`rtrb` is the hand-off ring, replacing `AudioSampleRing`'s two atomics and raw storage.
`slopdesk-audio-out` is `forbid(unsafe_code)`, which means the one real-time deadline in the client
now carries no hand-written unsafe — a strictly better position than the Swift it replaced, which
had a raw render callback and an `@unchecked Sendable` promise around it.

**One behaviour this port had to ADD rather than move.** `AUHAL` converted from the wire rate to the
device's own; `cpal` does not. So `slopdesk-audio-out` resamples on the producer side, linearly,
carrying phase across calls. On every Mac and iOS output this has been pointed at the device offers
48 kHz and the conversion is a copy; it matters only on a device pinned to 44.1 kHz, where the
alternative is playing everything a semitone sharp.

### The §2 exemption, and why it is a ratchet rather than a category

`docs/57` §2 bans hand-written raw-pointer work in the `slopdesk-apple-*` family and says the
obligation belongs in `slopdesk-ffi` when a framework call needs one. That escape hatch does not
exist for audio: `slopdesk-ffi` already depends on the `apple-*` crates, so `apple-audio → ffi` is a
dependency cycle.

And the obligation is unavoidable, because Core Audio hands out SAMPLE MEMORY rather than objects.
`AudioBufferList` is a C flexible-array member — a header with a count and a trailing array the
caller allocates and sizes — which is a shape Rust has no type for. AVFAudio does not escape it
either: `AVAudioPCMBuffer::floatChannelData` is `*mut NonNull<c_float>`, and
`AVAudioSourceNodeRenderBlock` hands over `*mut AudioBufferList`. The higher-level framework wraps
the pointer in an allocation, not in a type.

So §2 was widened for exactly one crate, and the amendment is written as a RATCHET: `apple-family`
counts the raw-pointer sites in `slopdesk-apple-audio` against a fixed number and fails BOTH ways —
above it, because a crate that grew a site did so in a commit that should have said what the site is
for, and at zero, because an exemption nothing spends should be deleted rather than left for the
next crate to notice. The counting pattern is deliberately wider than the ban's — it adds `.read(`,
`.write(`, `.add(` and `.offset(` — since a ratchet that missed `pointer.read()` would let the
exempt crate grow sites the count never saw. **A ratchet with slack is a budget.**

One judgment call is recorded here rather than left for a reader to find: reading the
`AudioStreamBasicDescription` out of a `CMFormatDescription` is `asbd_pointer.read()`, and that is a
framework-owned `#[repr(C)]` POD rather than literal sample memory. It is inside the exemption and
counted by it. The alternative — reinterpreting the bytes as `f32` without validating the format
first — is strictly worse, which is the whole reason that read exists.

### The loopback's `--audio` arm is `cargo test` now

`slopdesk-loopback-validate --audio` existed because of a hang: XCTest must never build a real
`AudioConverter`, so the only encode→decode proof in the tree ran as a separate executable nobody
ran by default. That constraint was Swift's, not AudioToolbox's.
`slopdesk-apple-audio`'s round-trip test builds both converters, encodes a synthetic tone and
asserts the wire cadence, in `cargo test`, with no window server and no grant — so the loopback arm
was deleted rather than kept as a second proof of the same thing.

## Settings are a file, and the onboarding is deleted rather than shortened (2026-08-24)

**Detail: [58-configuration.md](../58-configuration.md).**

- ✅ **The settings GUI is DELETED, not simplified.** Eighty-two files: nineteen `Settings/` views on
  the Mac, seventeen on the phone, six onboarding step cards, the row catalogue and taxonomy that
  indexed them, both chord recorders, and the four FFI door families underneath (`settings_rows`,
  `settings_layout`, `settings_catalog`, `settings_options`). Replaced by `config.toml`, a generated
  `docs/config.schema.json`, and defaults chosen once. Ghostty's shape, for Ghostty's reason: install
  it and it works. Held by the `settings-is-a-file` invariant, which bans the directories AND the
  type names, so the shape cannot return at a new address.
- ✅ **`config set` does not exist and is not deferred.** The CLI reads the file and never writes it —
  a verb that edits a document a human also edits is a merge conflict with a comment-eating parser on
  one side. This VOIDS the 2026-06-29 "`config set/unset --transient` is honestly rejected" entry and
  the "`font apply` / `font import --apply` are implemented" entry above: `font apply` is gone with
  `config set`, and `font import` now installs the file and prints its family name, leaving the
  reader to write `terminal.font-family`.
- ✅ **The good defaults are ENFORCED, never offered.** The Claude Code hooks install on every
  connection establish (`AgentHookEnforcer`) — agent detection is what this app IS, so a host without
  them is a host with half the product dark, and it runs per-establish because the next host is not
  necessarily the last. The `slopdesk` command links at launch into `~/.local/bin`, a directory the
  user already owns: the old switch escalated to `/usr/local/bin` and spent an administrator prompt
  on a convenience in the user's first two minutes. "Set as default terminal" is deleted outright.
- ✅ **No first-launch state exists at all.** Not a shortened flow, not a skippable one — there is no
  flag saying the flow was seen, which is what kept two installs of the same build from being the
  same product. Banned as a token by the same invariant.
- ✅ **There is no reload verb and no file watcher.** The app re-reads the file on every ACTIVATION,
  which is the moment a reader who just saved it comes back to look. `ConfigFile.reload` guards on
  `AppConfig` equality first, and the guard is the feature: `PreferencesStore` bumps the
  terminal-config generation unconditionally, so re-applying an identical reading would rebuild every
  live terminal's config and re-measure its grid — a visible flash on every ⌘Tab back.
- ✅ **`docs/config.schema.json` is an artifact with a producer.** `make config-schema` is the only
  writer; `rust/slopdesk-settings/tests/checked_in_schema.rs` is the gate. A STALE schema is worse
  than none — it tells the reader a key exists that this build ignores, in the editor where they are
  most likely to believe it.
- ✅ **The chord RECORDER is deleted; the two dispatchers stay.** A file has no recorder. The
  recorder half was strictly stricter than the dispatcher (it refused a base it could not spell
  back), and what replaces its guarantee is a round trip: canonicalise the dispatcher's chord, parse
  that text back, require the same chord. Comparing the two dispatchers directly for the first time
  found a real divergence — the phone accepted the DEL scalar as a printable base while the Mac
  refused it, so ⌘⌫ resolved to a chord no `keybind` line on the other client could ever match.

## The detached window is superd's ring, not a fourth copy in hostd (2026-08-25)

**Detail: [59-hostd-projection.md](../59-hostd-projection.md) §5 step 1 · [51-process-supervision.md](../51-process-supervision.md) §6.5.**

- ✅ **`detach()` DROPS the subscription and keeps a byte OFFSET.** hostd's out-FIFO used to be
  re-sized to `MuxFlowControl.detachedHostQueueCapacityBytes` (64 MiB) on detach and fed by a read
  loop that kept running with nobody to send to — the same PTY bytes buffered a fourth time, beside
  superd's ring, superd's journal, and hostd's own `ReplayBuffer`. It is gone. `detach()` now
  unsubscribes the `PaneOutputStream` and records `streamOffset`, the absolute ring offset the
  stream had reached; `rebindRelay` opens a NEW subscription at exactly that offset. It is a
  `subscribe`, never a `read` — superd owns the only reader on the master, and a second one would
  steal bytes rather than observe them.
- ✅ **The retention contract is the ring (4 MiB, `SLOPDESK_PANE_RING_BYTES`), and the drop is
  DELIBERATE.** Raising `DEFAULT_CAPACITY_BYTES` to match the old 64 MiB was the alternative and is
  rejected: superd never calls `ring.forget()` in production, so a raised default is resident per
  busy pane ALWAYS — twenty panes ≈ 1.3 GiB inside the daemon whose entire job is to be small —
  whereas the old 64 MiB was hostd's only while detached. Anyone who wants the old window sets
  `SLOPDESK_PANE_RING_BYTES`; that is what the knob is for.
- ✅ **What the drop buys is that a detached agent NEVER FREEZES.** The 64 MiB budget did not buy
  retention so much as postpone a stall: at the ceiling the gate paused the read loop, superd stopped
  reading, the kernel PTY buffer filled and the shell blocked — the exact failure `docs/51` exists to
  prevent, arriving after 64 MiB instead of after 64 KiB. With no subscriber superd's pump keeps
  draining and the ring evicts, and losing the last subscriber CLEARS the pause, so the agent runs at
  full speed for as long as it is away.
- ✅ **The loss is ANNOUNCED, and the cold case never sees it.** A resume older than the ring's start
  sets `Resume::is_lossy` on superd's side and `PaneOutputStream.resumedLossily` on hostd's, and the
  gap is logged with the byte count. A COLD client does not go through the resume at all — it is
  restored from the journal (`ScrollbackTranscripts.restored(sessionID:supervisor:)`, gated on
  `open.lastReceivedSeq == 0`), which is disk-backed and unaffected.
- ⚠️ **This REVERSES "Detach folds the ring in the background"** (2026-07-25, `scheduleDetachedRingFold`,
  floor 128 KiB). The fold rendered the acked `ReplayBuffer` ring at detach so the reattach compose
  would walk O(canonical + delta). It went with this change for two reasons: its stated payoff was
  "an idle detached session's ring collapses from up-to-64 MiB of churn", and up-to-64 MiB of churn
  is precisely what no longer accumulates; and the compose it optimised no longer folds the FIFO
  backlog in, so its input is the acked ring alone. `ReplayBuffer.ringFoldSource()` /
  `adoptFoldedRing(_:from:)` have no caller left in the host.
- ⚠️ **A cold reattach after a long detached window now ships raw churn where it used to ship
  cleaned bytes**, because `compactDetachedBacklogForColdClient` is deleted with the FIFO it
  compacted. It is bounded by the ring rather than by the old 64 MiB budget, so the worst case
  SHRANK by 16×; the snapshot still renders the sequenced history, and the resumed bytes land after
  it on the ordinary drain.
- ⚠️ **A command started while detached re-asserts no busy indicator on reattach.** superd re-runs
  `sniff_backlog` over resumed bytes, so sniffed control (titles, cwd) replays — but block events
  (`0x05`) do not, and `commandRunningSince` is fed only by those. `blockSnapshot()` still rebuilds
  the navigator for CLOSED blocks; what is missing is the type-23 `.running` re-assert for a command
  still executing, until its next edge.

## The client control socket has one vocabulary, and it is a crate (2026-08-26)

`Sources/SlopDeskWorkspaceCore/Control/ClientControlProtocol.swift` was 264 lines and it was the
SECOND spelling of `rust/slopdesk-cli/src/clientctl.rs`: fourteen method literals, a
`token → TabBadgeKind` map, two `String`-raw-valued enums, an NDJSON codec and one `*Params` builder
per verb. No compiler crossed that boundary, so `slopdesk-invariants`' "the client control socket has
one vocabulary" held the two files together by extracting regexes from each and comparing the sets —
a gate written because the two ends ship on different clocks (the app from a `.app`, the CLI from
`brew upgrade`), so a rename moves both in one commit, passes both suites green, and then meets the
peer the user launched this morning.

**~130 of those lines had no Swift caller at all.** Every `*Params` builder, `encodeRequestLine` and
`decodeResponseLine` were only ever run by the CLI; `Sources/` reaches exactly seven members of the
enum. The mirror was not merely duplicated, it was mostly dead.

**The vocabulary is `rust/slopdesk-clientctl` now** — its own crate, taken as a DIRECT path edge by
both `slopdesk-cli` (which re-exports it as `clientctl`, so no call site moved) and `slopdesk-ffi`
(so it lands inside `slopdesk-gate ffi`'s content stamp). Not `slopdesk-wire`, which was tried and
reverted: that crate's zero-third-party-dependency rule is about a codec parsing hostile PTY bytes,
and this module is `serde_json` end to end.

**Two crossing shapes, and the reason for each.** METHODS cross as WORDS — one delivery,
`[u16 count]` then `[u32 length][UTF-8]`, read once into a `static let` — because the far side
dispatches a `switch` on the string a foreign process wrote, so the string IS the thing. TOKENS
cross as INDICES, because the far side turns each into a case of its own enum and only ever switches
on that: `Placement` and `FontScope` are `UInt8`-raw-valued now, their raw value is the token's
position in the crate's vocabulary, and an unknown token answers `-1` → `nil` → the refusal that was
already there. A token is parsed exactly once, in Rust.

**The badge table absorbed the map rather than sitting beside it.** `SETTABLE_BADGE_TOKENS` is
`&[(&str, TabBadge)]`, so `settable_badge_tokens()` (the usage line) and `badge_for_token` (the
parser) read one table and cannot offer a token the other refuses. `token_for_badge` is the total
reverse, because a tab can be LISTED wearing a badge no request may set — `caffeinate`, `sudo` and
the two command tiers are spellable and unsettable, which the doors reproduce exactly.

**The gate shrank to what a compiler still cannot see.** It no longer compares two spellings; it
bans a literal reappearing in the face or the dispatcher, requires the face to name all five doors,
and checks the one thing an index-answering door cannot check for itself — that each `UInt8` enum
declares as many cases as the crate's vocabulary has entries. A placement added in Rust and not in
Swift would otherwise parse to a `rawValue` no case answers: silently unreachable rather than wrong.

## A lint opt-out lives where its reason is true, and no wider (2026-08-26)

Sixteen crates disabled a code-level clippy lint in their manifest. Each carried a written reason,
and the reasons were good — a daemon whose stderr IS its log, a VT scanner whose `bytes[i]` is
bounded by the `while` head above it, `pub(crate)` items in a private module where
`redundant_pub_crate` and rustc's denied `unreachable_pub` demand opposite things. **What was wrong
was the SCOPE.** `lint = "allow"` in a `[lints]` table is a claim about every file in the crate,
including the ones nobody has written yet, and none of those reasons was that wide.

Measuring each one — flip the entry to `deny`, run clippy, collect the sites — showed how far the
claims had already drifted from the code:

- **Two fired nowhere at all.** `slopdesk-instruments` disabled `significant_drop_tightening` and
  `too_many_lines`, both with a paragraph explaining why. Neither lint had a site.
- **`slopdesk-sanitize` disabled `indexing_slicing` for "a terminal grid… clamped by
  `clamp_row`/`clamp_col`".** That crate has no grid. Every one of its 121 sites is a byte cursor in
  a VT scanner. The sentence was true of `slopdesk-screend`, which it had been copied from.
- **`slopdesk-audio-out` named three of the four modules its exemption covered**, and
  `slopdesk-apple-audio` named a module the lint does not fire in.

So the manifests state the DENY and the code states the exemption: `#![expect(…, reason = "…")]` at
the top of the module that earns it, or `#[expect(…)]` on the item. Thirty-eight sites, each with the
reason that is true of THAT file — which meant writing nine different reasons where sanitize had one,
and discovering that four of screend's ten were test-only, where a panic is the failure report and
the crate's existing `mod tests` expect block already said so.

**`expect`, never `allow`, and that is the half that pays for itself.** `expect` errors once the lint
stops firing; `allow` goes quiet, which is how the two dead ones survived. Converting the tree's four
hand-written `#[allow]`s turned up a fifth immediately: `release::pack::run` had shrunk under
`too_many_lines` at some point and nothing could have said so.

**Three lints stay in the manifests, because no code site could carry them.** `suboptimal_flops` and
`imprecise_flops` are REQUIRED there by the `flops-opt-out` rule — the whole point is that a workspace
carries them before its first float lands, so a lint teaching the opposite of the bit-exact-floats
invariant never gets to teach it. `multiple_crate_versions` fires on a resolved dependency graph and
has no line anyone wrote.

`scoped-opt-outs` ratchets both halves.

## The build entrypoint is a justfile, and one gate had to change to keep asking its question (2026-08-27)

`make` → `just`, 127 targets to 127 recipes with the same names, the same dependency order and the
same behaviour. Proved rather than asserted: every recipe's `just --dry-run` plan was diffed against
the same target's `make -n` plan before the `Makefile` was deleted, and the only differences left
were the four intended ones — `help` is `just --list`, `install-tools` also installs `just`,
`release` refuses an argument carrying `=`, and the command substitutions print unexpanded, which is
the subject of the rest of this entry.

**What make expressed that just does not, and what replaced each:**

- `$(MAKE)` recursion inside a recipe → `{{just_executable()}}`. `lint` and `quick` still fan five
  and four gates into per-gate logs and replay them in the declared order; they are shebang recipes
  now, which is how a body that carries shell state across lines is spelled.
- `.PHONY` → nothing. Every target here was phony; just has no file targets to disambiguate from.
- `$$` → `$`. just does not expand `$` in a recipe body at all, so the doubling is not merely
  unnecessary, it would be wrong.
- `$(shell …)`, `$(wildcard …)`, `$(patsubst …)` → one backtick each. The two derived lists —
  `RUST_WORKSPACES` and `SHELL_FILES` — still derive themselves from the filesystem, which is the
  whole reason they are not spelled by hand.

**The gate that had to change is `lint-reach`, and it is the only interesting part.** It asks what a
recipe would RUN, which is a question only an expansion can answer, and two things about
`just --dry-run` are not `make -n`:

1. It prints the plan on **stderr**, where make printed it on stdout. A gate left reading stdout
   would have seen an empty plan for every recipe. `proc::ask_err` is the other stream.
2. It does **not run a command substitution** — it prints the expression verbatim. So the plan comes
   back with `` `grep -l '^[workspace]' rust/*/Cargo.toml …` `` exactly where the sixty crate paths
   used to be, and a gate asking "does this plan enter `rust/slopdesk-superd`" would have answered
   no about every crate in the tree.

`gates::reach::expand_backticks` runs each substitution itself, which is what the shell would have
done a moment later, and the reachability question is then asked of the same text make used to hand
over. **That is why the justfile uses a BACKTICK and not `shell(…)`**: a dry run prints `shell(…)`
as its own source text, escapes and all, which nothing downstream could honestly re-run. The
distinction is written at the variable and again in the gate, because it is the one place where the
runner's behaviour, not the recipe's, decides whether a gate is real.

**`linked-artifacts-are-built` moved from the target line to the doc comment.** A make target
declared its artifact in a `## ` help string ON the recipe line; `ffi: ## Build …xcframework` is a
parse error in just, where the doc is the comment directly above. So `producers()` walks forward
from the comment that names the artifact to the recipe it belongs to — and a blank line ends the
block, exactly as just itself decides, so prose that merely mentions the artifact nominates nobody.

**Rejected.** *A hand-written workspace list* — it would have made `--dry-run` print the paths with
no backtick expansion needed, and it is the three-places-to-forget failure the derivation was
introduced to end. *`just --shell /bin/echo`* as a plan printer — `--shell` overrides backtick
evaluation too, so the variable comes back holding its own command text. *just's `[parallel]`
attribute* for `lint` and `quick` — it does not order the output, which is the whole reason those
two fan into logs rather than into a terminal.

## The video daemon's four modules are registered debt, not a wired daemon (2026-08-27)

The Rust `slopdesk-videohostd` now holds the encoder session, the window feed, the mux registry and
the geometry poller. `no-stranded-rust-module` found all four written, tested and reached by
nothing, which is exactly the failure that rule exists for — `e6b1ce9b` is the precedent, where four
`slopdesk-workspace` modules landed with 47 tests, no caller, and the Swift still running.

**They are registered in `STRANDED_RUST_MODULES` rather than wired.** `docs/61` §3 says the capture
half is unported: there is no `SCStream` in this crate yet, so a `main.rs` that opened the encoder
and started the feed would compose a daemon that runs, binds its sockets and serves no frames. That
is worse than the debt, because a gate cannot tell a daemon that produces nothing from a daemon that
is merely idle, and the four names would leave the list having bought no guarantee. The list is
DEBT, which is what its own doc comment says it is: green while it shrinks, and every name leaves in
the commit that lands `docs/61` §1's cascade, whose rows 12 and 13 are these two debts — the
composition and the deletion are one
change, because until it lands `Sources/SlopDeskVideoHost` is the only implementation and the
one-implementation rule is satisfied, not broken.

**The two poll constants got a ratchet instead, and that asymmetry is the point.**
`shared-number-asked-or-ratcheted` caught `dragPollHz`/`DRAG_POLL_HZ` and
`unionPollDivider`/`UNION_POLL_DIVIDER` spelled once per language. Neither of its usual answers
fits mid-port: a `CSlopDeskFFI` door would build an ABI into a file scheduled for deletion, and
deleting the Swift first leaves zero implementations. So the pair is ratcheted by value —
`drag-cadence-ratchet` in `rules::window_placement`, which compares the two literals as sets and
registers both names in the sweep's own corpus. A stranded module has nothing to disagree with; two
live constants do, and the window where both exist is precisely when they can drift. The rule is
deleted by the same commit that deletes the Swift.

**Rejected.** *A `HOMONYMS` entry* — the two numbers describe the SAME law, which is the one thing
that list is not for. *A token `main.rs` composition* to silence the stranded rule — a fake wiring
reads as a finished port to every future reader and to every gate. *Deleting
`slopdesk_video_capture_should_self_heal` from the header and keeping the Rust door* — a door whose
last Swift caller died in `08d33f2e` is the second way to ask what
`CaptureGates::should_self_heal` already answers, so both halves went; the daemon calls the values
form, and re-adding the door costs one declaration.

## The panels' CoreMedia was never per-panel, and the language boundary was in the wrong place (2026-08-29)

The 2026-08-15 pass gave both device panels one `DevicePanelSampleBuffer` and left
`formatDescription` behind as "genuinely per-panel: the simulator is asked for `format=avcc` and
parses a record, `scrcpy` forwards raw `MediaCodec` output". That reading was right about the two
DIALECTS and wrong about the boundary it drew around them. What differs between the panels is how
each one's server states its parameter sets. What is identical — and identical to what
`rust/slopdesk-apple-vt` was already doing for the desktop decoder, in the same three calls in the
same order — is everything after that: `CMVideoFormatDescriptionCreateFrom*ParameterSets`, a block
buffer over a copy of the access unit, `CMSampleBufferCreateReady`, and the attachment array.

So the split was one function down from where it belonged. Two implementations of one framework
contract in two languages, and only ONE of them under a leak test: the Swift copy carried its own
`unsafeBitCast` on the attachment dictionary, which is raw-pointer work in the language that has no
way to state the obligation, and `docs/57` §2 does not admit it because §2 is about the crates that
can.

**All 286 lines went, and the dialects went with them.** `AndroidVideoFormat`,
`SimulatorVideoFormat` and `DevicePanelSampleBuffer` are deleted; `Shared/DevicePanelVideoStream` is
a handle over six `slopdesk_panel_video_*` doors. `slopdesk-apple-vt` grew the one generalisation
that made the desktop builder serve three streams — `from_parameter_sets(codec, sets, nal_length)`,
with `from_hevc_parameter_sets` as the wrapper that PINS the prefix at four because only the host
guarantees it — plus `dimensions()`, an `Attachments` pair, and `into_raw`.

**The config packet is now opaque to Swift end to end, and that is the load-bearing half.** The
stream event, the frame sink and both sidebar models carry the record or the packet as `Data`. Its
parameter sets and its `nalUnitHeaderLength` never become Swift values, so nothing on this side can
disagree with the description built from them — which is what let BOTH Swift parsers go, and the two
doors that existed only to feed them (`slopdesk_sim_avcc_parse`, `slopdesk_annexb_parameter_sets`)
with them.

**One behaviour changed, and a test caught it.** The sidebar models used to call
`noteVideoArrived()` on the configuration arm, because back when the model parsed the record it
could tell a malformed one apart and drop it. It cannot now, and it should not: a config packet is a
promise, not a frame. Calling it there would clear the loading indicator over a panel that will
never render. The arm no longer calls it, and
`testAConfigurationRecordTravelsWholeButIsNotVideoOnItsOwn` pins that.

**The gate moved up a layer with the code.** `device-panel-law` used to say both panels read their
size through one shared law; the two files it named that through are gone, so it now says all four
SCREEN VIEWS hold the shared stream. The new `one-coremedia-builder` states the stronger half
positively and TREE-WIDE, with no exemption list: no Swift file under `Sources`, `Apps` or `Tests`
may name `CMVideoFormatDescriptionCreate*`, `CMBlockBufferCreate*`, `CMSampleBufferCreate*` or
`CMSampleBufferGetSampleAttachmentsArray`. A path list would have to grow an entry per new panel;
the answer for every new panel is the same door, so the corpus is the tree.

**Rejected.** *A second Rust format builder for H.264* — the HEVC one differs from it in the entry
point and nothing else, so the fork is an enum and the flattening is written once. *Keeping
`CMBlockBufferCreateWithMemoryBlock` in `device-panel-law`'s ban with its `Shared/` exemption* — the
new rule bans it everywhere with no exemption, and leaving the weaker spelling in place would mark
one directory as permitted. *`takeUnretainedValue()` on the returned sample* — the door hands over
at +1 (the Create rule, pointed outwards), so an unretained take renders correct pixels, passes
every test, and leaks one sample buffer per frame at sixty a second; the invariant pins the retained
spelling by name and bans the unretained one.

## PATH 4's driver was eight doors and a Swift socket; it is one door now (2026-08-30)

The 2026-08-13 entry moved dropd's LAYOUTS to Rust and kept "the transport and the driving loop" in
Swift, on the reading that `NWConnection` plus `AsyncThrowingStream` was runtime glue. That reading
held for the socket and not for the SEQUENCE. What `FileTransferClient` actually owned was the law:
`hello` before any offer, an `offer` answered before a chunk goes out, a `finish` before a
`complete` is waited on, a `cancel` on a link fault, a reply about another transfer skipped rather
than mistaken for this one, and a batch that fails every file by name rather than returning silent.
None of that is Network.framework's; all of it is the protocol's, and it sat in the one language
where nothing tested it against the daemon that answers.

**`rust/slopdesk-dropd/src/upload.rs` is that law, and it is a module of the crate that already had
both ends.** `to_host` dials with `TcpStream::connect_timeout` (a `TcpStream::connect` to a host
that is asleep parks the caller until the kernel gives up); `over_link` takes any `Read + Write`, so
the suite drives a scripted peer through the frame order, the version refusal, the unreadable file,
the non-accept, the reply about another id, the host's own failure words and a link that dies
mid-body — plus one real loopback socket asserting a byte-identical body. Progress is a borrowed
`Progress<'_>` handed to an `FnMut`, so nothing allocates to report a chunk.

**The eight doors collapsed to one, which is the point and not a tidy-up.** `slopdesk_drop_upload`
blocks for the whole batch and reports through `docs/55` §4b's inversion: no handle, no `_free`, no
lifetime for a caller to get wrong, and the three obligations are the usual ones. Eight small doors
with a driver above them is the shape §4b records the audio stage earning — *a handle with a large
surface is a law you moved without moving its sequencing*. Every one of those eight answers was
right alone; nothing could check the order they were assembled in.

**The Swift target is one file and no longer imports `Network` or `Foundation`'s socket at all.**
`FileTransferProtocol.swift`, `FileTransferCodec.swift`, `FileTransferFrameDecoder.swift` and
`FileTransferChannel.swift` are deleted, with the two suites whose subjects they were.
`SlopDeskFileTransfer` dropped its `SlopDeskNet` and `SlopDeskArena` edges — the first went with the
`NWConnection`, the second with the last reply record to decode — and `docs/63` §6's `import
Network` list is eight files, not nine. `FileUploadCoordinator` did not change: the face keeps
`upload(files:host:port:onEvent:)` and `FileUploadEvent` exactly, because a caller that only ever
wanted "URLs in, progress out" was never the thing that needed porting.

**The batch crosses NUL-separated, not length-prefixed.** `push_text`'s four-byte prefix is the
tree's usual framing for N strings, and using it here would have put a big-endian write back inside
the one target whose invariant is *holds no layout*. A POSIX path may contain every byte except
`0`, so `find -print0`'s separator makes the face's whole marshalling
`Data(paths.joined(separator: "\0").utf8)` — nothing this side of the door could spell differently
from that side.

**Rejected.** *A `Task.detached` around the blocking door* — it blocks a cooperative-pool thread for
the length of a multi-GiB upload, which is a thread the whole app no longer has; the call goes on a
global dispatch queue and reaches the caller through an `AsyncStream`, which also preserves the
awaited-in-emission-order guarantee `FileUploadCoordinator` documents. *Keeping the eight doors and
adding a ninth for the sequence* — two ways to drive the same protocol is the drift the
one-implementation rule names, and the eight had no caller left. *Retiring `DropdE2ETests`* — the
codec and splitter suites lost their subjects and went, but the E2E is now the only test that
crosses the FFI boundary into a real daemon, which is the one thing no Rust test can see.

## The device panels' three sockets were one websocket written twice, and `NWConnection` was hiding the protocol (2026-08-30)

`docs/63` §6 deferred these by name — *"the device-panel and proxy lanes are their own campaigns and
are not scoped here"* — and named four files: `AndroidBridgeSocket`, `SimulatorWebSocketLane`,
`SimulatorLogConnection` and `SimulatorStreamConnection`. `docs/67` §5 booked the middle one as its
only `DevicePanelLane` floor entry, the one row on that list that was a deferral rather than a
reason. This is that campaign, and both entries are gone with it.

**What was actually Swift's was a framework, not a decision.** `NWConnection` with
`NWProtocolWebSocket` reassembles a fragmented message, answers a ping, and hands up whole frames,
so the two lanes could each say "there is no defragmentation here" and be right about the framework
while being wrong about the wire. Porting to a raw socket makes that a claim somebody has to keep:
`rust/slopdesk-devicelink`'s `ws::frame` carries a `Reassembler` and its two tests, and the
handshake it sits behind VERIFIES `Sec-WebSocket-Accept` rather than glancing at the status —
RFC 6455 §4.1 makes it a MUST, and on a mesh where any port may be forwarded to anything it is what
turns "the first frame is malformed" into "that is not a websocket".

**The RFC's own vector caught a wrong constant on the first run.** `ACCEPT_GUID` was typed ending
`…C5AB0DC85B39`; it is `…C5AB0DC85B11`, and every handshake against a real server would have failed.
Three independent digests (`shasum`, `hashlib`, node's `crypto`) agreed with the implementation and
not with the constant, which is the only way that particular error is findable — no amount of
round-tripping our own client against our own fake would have said a word.

**Ordering is `DispatchQueue.main.async`, not `Task { @MainActor }`.** The Swift lanes re-armed the
receive inside their own hop, so at most one delivery was ever in flight and ordering came free. A
Rust reader thread delivers back to back, and two `Task`s enqueued in order carry no mutual ordering
guarantee where a serial queue does — two access units arriving swapped is a corrupt picture, not a
late one.

**`Session::drop` tears down and then JOINS**, which is `slopdesk_pane_driver_free`'s promise and the
reason the Swift near side owns its sink by reference count instead of a torn-down flag of its own.
`Link::tear_down` sets the flag BEFORE the `shutdown`, so a teardown mid-read delivers nothing: the
read returns zero, the reader sees the flag, and it exits without wording an ending the caller
already knows about. The other order races.

**Six doors, one near side.** `slopdesk_device_ws_open/_send_text/_free` and
`slopdesk_device_bridge_open/_send/_free`, over `DeviceSocket.swift` — which holds doors and is
therefore not floor at all. `SimulatorStreamConnection`, `SimulatorLogConnection` and
`AndroidBridgeSocket` keep their faces (`SimulatorStreamEvent`, `SimulatorLogStreaming`,
`AndroidBridgeRequest`/`AndroidBridgeReply`) and lost their state machines; `SimulatorWebSocketLane`
is deleted; `SlopDeskNet` left the `SlopDeskDevicePanels` target with them, and `docs/63` §6's
`import Network` list is five files, not eight.

**Rejected.** *tokio + tungstenite* — this tree carries no async runtime, and three sockets that each
want one thread parked in `read` would buy a scheduler for multiplexing nobody asked for. *RustCrypto's
`sha1`* — six crates to compute twenty bytes once per dial; `sha1_smol` has no dependencies at all.
*Folding this into `slopdesk-devicepanel`* — that crate's whole charter is that it is pure, and a
`TcpStream` inside it is the charter gone. *Keeping `DevicePanelLane` as an empty class for the proxy
campaign* — a deferral kept warm reads as a reason, and the proxy gets booked when it lands.

## `NWConnection` was buying the video client a state machine, and the state machine was the bug (2026-08-30)

`NWVideoMuxClientFlow.swift` was the last `Network.framework` object on PATH 2 and the last one on
the video path in either direction — the host's half became `rust/slopdesk-videohostd`'s
`mux_transport` some time ago. It is now `rust/slopdesk-videolink`, reached through seven
`slopdesk_video_flow_*` doors, with `VideoMuxClientFlow.swift` holding the handle and deciding
nothing.

**The split was already made; only the socket was left.** Every rule the flow obeyed was
`slopdesk-video`'s and was CALLED, not restated: `mux_header` framed the datagrams, `mux_flow`
answered the re-arm and its backoff ladder, `mux_client_pool` decided which panes shared a flow. What
was Swift was two connections, two receive re-arms and a dictionary from channel id to a pair of
closures. That is the shape a port should have — the decisions crossed years before the I/O did — and
it is why this campaign is one crate and one near-side file rather than a rewrite.

**`UDPSendPathPolicy` was deleted, not ported, and its door and its six `SLOPDESK_CONN_*` codes went
with it.** The policy existed because `Network.framework` parks a `.waiting` connection's datagrams
in-process with the completion deferred indefinitely: a client whose wifi had flapped kept handing
20 Hz stats reports to a queue that would never drain, so the periodic producers had to be told to
stand down, and being told meant mapping six connection states onto a viability. A `sendto` on a raw
socket has no such queue. It fails, synchronously, with `ENETDOWN`/`EHOSTUNREACH`/`ENETUNREACH`. So
viability is now the LAST SEND's answer, which is not a weaker signal but a strictly stronger one: it
reports the path the datagrams actually took rather than what a framework thought of the path.
`ECONNREFUSED` deliberately does NOT revoke it — an ICMP port-unreachable proves a working path to a
host that is not listening, which is a different fact.

**Three more things the framework was charging for.** A bring-up failure now answers `Flow::open`
instead of arriving later through a `stateUpdateHandler`, so the pane retries instead of waiting on a
state that never settles. The class carried a "COMPILED + reviewed, NEVER instantiated in a test"
warning, and `slopdesk-videolink`'s suite drives the real thing — the framing, the demux, the drop
rules, the prime, the teardown — against a second `UdpSocket` on loopback. And the near side is a
handle plus two callback boxes, so there is no `@unchecked Sendable` class holding two connections,
two liveness objects and four mutable fields under one lock.

**What a plain socket costs, stated rather than hidden.** `UdpSocket` has no `shutdown`, so a reader
parked in `recv` cannot be woken by the close the way `cancel()` woke a `receiveMessage`. The wake is
the socket's own read timeout, which makes a teardown BOUNDED rather than instant — at most one
timeout plus one backoff, pinned by a test. Nothing is delivered after the drop returns, which is the
guarantee that was ever actually needed.

**The release callback, and why the door has one when `slopdesk_device_ws_*` does not.** A websocket
handle owns its one reader, so `_free` joining that thread is enough to promise "no callback after
this returns" — one obligation, one lifetime. A flow's lanes share two readers, so unregistering ONE
lane cannot join a thread that still serves the others, and there is no moment `unregister_lane` can
name as the last callback. `on_release` is that moment instead: this side calls it exactly once per
registration, whenever the last reference to the lane is dropped, on whichever thread drops it. The
near side retains its box across the door and releases it there.

**Rejected.** *Keeping `UDPSendPathPolicy` against a future transport that has states* — porting a
mapping for a state machine that no longer exists is a fallback under another name, and the
one-implementation rule does not make an exception for one that maps nothing. *An async runtime* —
two sockets and two parked reads is two threads, the same ruling `slopdesk-devicelink` records.
*Delivering the read window to Swift as a borrow instead of a `Data` copy* — the sink enqueues what it
is handed on the session's inbound queue, so a view onto the window would dangle the moment the
reader loops; the copy is at most a datagram and is the same one `Network.framework` made before the
old flow ever saw the bytes. *Folding the sockets into `slopdesk-video`* — that crate is PATH 2's
rules, `forbid(unsafe_code)`, no I/O, every function a fold a test can drive without a machine; a
`UdpSocket` inside it ends that for the whole crate, which is the line `slopdesk-devicelink` drew
against `slopdesk-devicepanel` two campaigns ago.

## The commit-subject rule shipped dead for three weeks, and all 1144 violations stay (2026-08-31)

**The gate was correct, tested, and never called.** `b52e5175` (2026-08-11) added the
`commit-msg-conventional` hook to `.pre-commit-config.yaml` and added `commit-msg` to
`default_install_hook_types` in the same change. Both were right. But `prek install` writes one file
per entry in that list at the moment it is TYPED, and it had last been typed on 2026-06-14, when the
list was `[pre-commit, pre-push]`. So `.git/hooks/` held two files, git called two hooks, and the
subject rule — the grammar `cliff.toml` reads to file a commit in `CHANGELOG.md` and
`git cliff --bumped-version` reads to compute the next version — was never asked a question.

Nothing about this is visible from the tree. The config is correct, the rule is correct, its unit
tests pass, and every gate that reads the tree agrees. The entire defect is the gap between a
tracked file and an untracked directory.

**Measured before it was fixed, over the window the rule actually existed.** 658 commits between
`b52e5175` and 2026-08-31; the checker rejects **97** of them — 58 past the 72-character ceiling, 39
opening on an article, and **0** outside the conventional grammar. That last zero is the one that
matters for the release: every subject in the window is still typed and scoped, so `cliff.toml`
filed all 658 correctly and no version bump was wrong. What was lost is the published prose — 97
release-note bullets that read as descriptions of the code rather than as instructions, or that
GitHub ellipses in the commit list.

**Ratcheted by `slopdesk-gate hooks`, on `just lint-reach`.** This cannot be a `slopdesk-invariants`
rule: those are pure functions of the tree, and the tree is the half that was already right. The
question is "what would GIT run", the same shape as `reach`'s question about `just`, and its answer
lives in `.git/` — untracked, per-clone, movable by `core.hooksPath`, and elsewhere entirely inside a
worktree. The gate reads `default_install_hook_types` and demands a file for each entry.

One thing it must not do, and the reason it is on `lint-reach` rather than on the `pre-push` stage:
in the state it detects, the hooks are the thing that is missing, so a gate reachable only through a
hook would be silent exactly when it matters. `just check` and `just quick` both reach `lint-reach`
by hand.

**Rejected.** *Rewriting the 4 unpushed over-length subjects* — the tree cites `a0d0aa54` in five
places (`docs/52`, `docs/DECISIONS.md`, `rust/slopdesk-ffi/src/sanitize.rs`, and two
`slopdesk-invariants` rules), and that commit sits above the oldest of the four, so a rebase that
fixed them would invalidate every one of those citations. Five live cross-references traded for four
bullets GitHub truncates is a bad trade, and the four are conventional, so the changelog and the
version bump are already right. *Rewriting the rest* — the checker rejects **1144** of all **1914**
commits in this history, and once the 97 above are set aside, **1047** of them predate the rule
entirely: the WF-era subjects and the `polish(`/`refine(`/`tweak(`/`spike(`/`reapply(` types are from
before `b52e5175` invented the type list, so counting them as "the gate was dead" would be measuring
a rule against commits it was never applied to. They are also all pushed. *Making the
gate demand that no UNDECLARED hook be installed* — a hand-written `post-checkout` in someone's own
clone is a choice, not drift, and a gate about the contents of `.git/` should assert only what this
repo declared.

## The citation gate stopped at two extensions, and the shell port's ghosts lived in the gap (2026-08-31)

**`comments-cite-real-files` reads `.swift` and `.rs`. Four dead citations were in neither.** When
`scripts/` stopped holding programs — every gate, harness and release step is Rust now — four
references to the deleted scripts survived the sweep, and each sat in a file with no reader at all:

| Where | Cited | Should be |
| --- | --- | --- |
| `.gitignore` | `scripts/package-release.sh` | `slopdesk-release package` |
| `.gitignore` | `scripts/build-ffi.sh` | `just ffi` |
| `.github/workflows/release.yml` | `scripts/cut-release.sh` | `slopdesk-release cut-release` |
| `.github/workflows/ci.yml.disabled` | `scripts/build-ffi.sh` | `just ffi` |

No compiler parses these files, no formatter rewrites them, and the citation rule's corpus was two
extensions under eight source roots. The last one is the one worth naming: the dormant CI workflow's
own header says it is "kept, and kept CORRECT, because a dormant workflow rots silently" — and it
had rotted, in the sentence three lines below that claim.

**`configs-cite-real-files` is the same claim asked of the configuration.** It shares
`is_dead_citation` and the addressable-segment derivation with its sibling and differs in exactly
two ways, both forced by what these files are. The corpus is a LIST OF FILES rather than roots,
because configuration is where it is rather than under a tree: seven top-level dotfiles and the
`justfile` through `Tree::read`, plus every file in `.github/workflows` enumerated rather than
listed, so a workflow added tomorrow is covered the day it lands. The `justfile`'s RECIPES are
judged as well as its comments — a recipe naming a deleted path is the worse failure of the two, and
it costs nothing. And a citation here need not be BACKTICKED — `.gitignore`
and `.editorconfig` are prose with no markup convention, so the backticks are blanked and the bare
token is read. That is only safe because the head test does the filtering: a URL's `github.com/…`, a
glob, a `packaging/` formula path are all rejected before anything is asked to resolve. Measured on
the tree: over those ten files the bare form finds the four above and nothing else.

The corpus is assembled by hand, so it carries by hand the floor `Report::corpus` gives the others —
fewer than two config files, or zero workflows, is a walk that died rather than a tree anyone
shipped, and it reds rather than passing quiet.

**Rejected.** *Widening it to `.md`* — `docs/DECISIONS.md` is a DATED record, and an entry from
2026-07 naming the script that was live in 2026-07 is telling the truth; `live-docs-cite-real-files`
already covers the docs `CLAUDE.md` actively sends a reader to. *Deleting the shell-lint surface*
(`lint-shell`, `fmt-shell`, the two `prek` hooks) now that no `.sh` outside `ThirdParty/` remains —
the justfile already argues the other way where `SHELL_FILES` is defined, and it is right: the globs
stay so a script that comes back is linted rather than silently unlinted, and `scripting-is-rust`
fails the moment one does. *Pointing that surface at `ThirdParty/ghostty/build-libghostty.sh`*, the
one `.sh` left — it is the vendored fork's build recipe, carried close to upstream's shape,
`shfmt -d` wants 744 lines of it, and every other tool in this tree excludes `ThirdParty/` on
purpose.

## A Cargo feature is a rule until a third crate enables it (2026-08-31)

`slopdesk-posix` declares one feature, `winsize-set`, and it is the only `[features]` block in the
tree. It exists to spell a rule cargo can enforce: `TIOCSWINSZ` on a pane's terminal belongs to hostd
and to hostd alone (`docs/51` §6.9, `docs/60` §6), because hostd is the side that knows the client's
PIXEL geometry and a second writer on one terminal is a lost update rather than a duplicate. superd's
`resize` verb only records the numbers hostd reports, and `openpty` is handed the initial size, so
its spawn path needs no ioctl either.

The claim was written out in four places — the declaration in `slopdesk-posix/Cargo.toml`, the
enablement in `slopdesk-hostpane/Cargo.toml`, the dev-only enablement in `slopdesk-superd/Cargo.toml`,
and `set_window_size`'s own doc comment — and each of them says the same sentence: two crates enable
it, and WHICH KIND of dependency they enable it on IS the rule. Nothing read any of the four.

What cargo actually enforces is narrower than what the four claim. superd's placement in
`[dev-dependencies]` means `cargo build --release` of the daemon does not compile the function at
all, so a production caller *inside superd* is a link failure rather than a review comment — that
half is real and it is the half the comments celebrate. The other half is not enforced at all: a
THIRD crate adding `features = ["winsize-set"]` to its own `[dependencies]` compiles green, and what
it has bought is exactly the second writer the rule forbids. The link error cannot see it, because
there is no link error — the function is there, and the new crate is entitled to call it.

`pty-winsize-single-writer` (`crate_policy.rs`) pins the set in BOTH directions: the declaration must
exist, the non-dev enablers must be exactly `{slopdesk-hostpane}`, and the dev-only enablers exactly
`{slopdesk-superd}`. The second direction is this rule's empty-corpus floor wearing a feature's
clothes — a renamed feature or a deleted enablement would otherwise leave it scanning for a string
nobody writes, passing by asking nobody anything.

Two shapes forced the implementation. The section a line sits under is the rule rather than context
for it, so `sectioned` carries the current `[header]` down each line instead of recovering it later.
And comments are dropped, because both enablers ARGUE about the feature in `#` comments above the
line that enables it: a rule that counted prose would read the argument FOR the policy as a breach of
it. The fixture puts superd's prose under `[dependencies]` on purpose, so that discrimination is what
the clean case is testing.

**Rejected.** *Enforcing it in `superd_bodies.rs` by banning the call* — the call is already a link
error there, and the crate that needs watching is the one nobody has written yet, which no source
scanner can see. *Generalising to "every feature has a named enabler set"* — there is one feature in
the tree, and a table with a single row is a rule with a longer name. *Pinning transitive enablement
too* — cargo unifies features, so everything depending on `slopdesk-hostpane` gets the setter
compiled; that is not a second writer, it is the one writer's dependents, and forbidding it would
forbid hostd from linking its own pane.

## A citation with a line number was still a citation, and one rule could not see it (2026-08-31)

`every_cited_path_exists` asks whether a read-first doc names a file that is gone. Its extraction was
`` `((roots)/…\.[a-z]+)` `` — the closing backtick against the extension — so it read
`` `Sources/A/View.swift` `` and was blind to `` `Sources/A/View.swift:15` ``. Nineteen citations
across the read-first corpus carry a `:LINE` suffix, and seven of them named a file the phone port
deleted. The rule had been green over all seven since the port landed.

The suffix is not an edge case, it is this repo's idiom: `docs/62` §2.4's wrapper ledger cites every
"before" by path and first line, and `repo_invariants::live_docs_cite_files_that_exist` — the same
question over a hand-copied doc list — has stripped `:[\d,+-]+` since it was written. One sibling
matched the idiom and one matched less than it, and the one that matched less is the one whose corpus
reaches `docs/57`–`62`.

**What landed.** The pattern gained a non-capturing `(?::[0-9,+-]+)?`, and the extraction moved into
one `cited_paths` both rules call. That coupling is the point rather than tidiness: the two rules ask
opposite halves of one question, so widening `every_cited_path_exists` alone would exempt each
newly-visible citation in the first rule *and* make its own tombstone read unspent in the second, in
the same pass. `a_line_numbered_citation_keeps_its_tombstone_spent` is the test for exactly that.

The seven newly-visible paths became tombstones rather than repointings. §2.4 is a before/after
ledger whose "after" column reads "deleted." / "dissolves." / "added as a subview"; three of the seven
do have a successor under a different name, and aiming a row at it deletes the only fact the row
carries. That is the argument the phone and mux blocks above it already make.

`ThirdParty/ghostty/.../GhosttyTerminalView.swift:2953` was the one row that was not a ledger entry —
`...` is prose elision, and `.` and `/` are both inside the path class, so the widened rule captured
a path that can never resolve. The doc was made to spell
`ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift`, which resolved on its own
at the time. ⚠️ **It does not any more, and the fix that replaced it is the one this entry argued
against for the other seven.** `docs/68-terminal-surface-in-rust.md` deleted the whole fork, so that
row became a ledger entry after all — an "after" column reading "deleted." — and it is a
`PATH_TOMBSTONES` entry now, beside the fork's `README.md` and the `slopdesk-ops enable-renderer` op
`docs/68` §9 lists as coupled. Spelling a path in full is what makes a citation checkable; it is not
what keeps the file alive.

**Rejected.** *An ellipsis exclusion in the matcher* — one row, and a doc that elides a path it is
citing should spell the path. *Unifying `live_docs_cite_files_that_exist`'s corpus onto
`read_first_docs` in the same pass* — measured, and it drifts BOTH ways: the derived corpus adds
`DESIGN.md` and `docs/57`–`62`, and drops `docs/45`, `docs/47`, `README.md` and `justfile`, which
`CLAUDE.md`'s table does not name. Which docs that rule should read is a coverage decision, not a
mechanical one, and it is its own change.

## The root list one rule retired was still live in its twin (2026-08-31)

`doc_citations::every_cited_path_exists` reads the repository's top-level directories off the
filesystem, and its doc comment says why: the hand-written alternation it replaced "had drifted both
ways at once — `manifests` and `research` no longer existed, and `hid-bridge`, which does, was never
in it, so any path cited into that tree was exempt without anyone deciding it should be."

`repo_invariants::live_docs_cite_files_that_exist` asks the same question over a different corpus,
and it still carried that list. Eight names against the tree's ten: `hid-bridge` and `packaging` were
missing, and `docs/49` cites `packaging/homebrew/Formula/slopdesk.rb` and its Cask twice each. Both
resolve today, so the rule reported nothing and was right to — that is the shape of the defect, not a
mitigation of it. A fix applied to one of two copies leaves the bug at full strength in the other,
and the copy is what let it come back.

Both rules now call one `top_level_directories`. The break test cites into `packaging/`, a root no
version of that list ever named, so it fails on the old shape by construction rather than by which
two names happen to be absent this month.

**Rejected.** *Merging the two rules, or unioning their corpora* — measured, and they differ by
INTENT rather than drift. Running the span rule's semantics over the derived corpus reports 74 spans,
and they are overwhelmingly `Sources/SlopDeskHost` and `rust/slopdesk-workspace::key_repeat`: a
deleted target named as the thing a stage deleted, and a Rust module path that is not a file. The
derived rule handles `docs/57`–`62` with an extension requirement and `PATH_TOMBSTONES`, neither of
which the span rule has a shape for; the span rule handles `README.md`, `justfile`, `docs/45` and
`docs/47`, which `CLAUDE.md`'s table does not name at all. *Extending `LIVE_DOCS` to `docs/57`–`62`*
— the same 74, and the same answer `DELETION_HEADINGS` already gives one scale down: the gate would
be arguing with the documents' subject. *Teaching the derived rule to read DIRECTORY citations* —
that is where ~20 of the 74 come from, all of them `docs/60` reciting which target each stage
deleted.

## A fallback safe enough to take every time (2026-08-31)

`stamp.rs` narrows each typecheck gate's input digest to what its own triple compiles, and its header
said what that buys: "`SlopDeskMacUI` is in no iOS app's closure, so a desktop-chrome edit no longer
costs an iOS typecheck." It never did. `Scope::apps` lists the shell AND `Apps/Shared`, and
`Apps/Shared` is an asset catalog with no `project.yml`. `products_named_in` opens the file, cannot,
and answers `None` — which `Scope::sources` reads as "a spec I could not understand" and widens to
the whole `Sources` tree, correctly and every single time. Measured before: union 706 inputs, iOS
703, macOS 694, the difference being `Apps/` files alone; the `Sources` closure was identical in all
three. After: 706 / 613 / 610, and the modules the narrowing drops are exactly `SlopDeskMacUI` +
`SlopDeskVideoClientMac` on the iOS side and `SlopDeskPhoneUI` + `SlopDeskVideoClientPhone` on the
macOS side, with no shared module in either diff.

The species is the one rounds 22–26 have been mining, in its quietest form: a claim wider than its
reach, where the gap is filled by a *conservative* fallback. Nothing was ever wrong — no stamp was
ever warm over code it had not compiled — so no test failed, no gate went red, and the only symptom
was a build that stayed as slow as it had been before the optimisation shipped.

**A spec that is ABSENT is now skipped; a spec that exists and cannot be read whole still widens.**
Those are different facts and the code was conflating them. The boundary that keeps the skip safe is
that each scope has exactly one spec-bearing app, so a deleted spec leaves the product list empty and
the existing `products.is_empty()` floor widens anyway; the day a scope holds two, absent has to
become an answer rather than a silence, and `Scope::sources`' doc comment says so.

**One thing the narrowing exposed.** A narrowed scope's product closure names the xcframework
binaryTarget, so it walks `ThirdParty/slopdesk-ffi` under the compiled-extension filter and picks up
`SlopDeskFFI.xcframework/Info.plist`, which `Scope::Everything` — whose closure is the literal string
`Sources` — did not. The union was one file smaller than the scope it is the fallback for. Invisible
while the fallback always won, and wrong in the one direction this gate may not be wrong in, so
`FFI_TREE` is now walked under every scope.

**Rejected.** *Giving `Apps/Shared` a `project.yml`* — it vends no target; the spec would exist to
satisfy a scan. *Widening `COMPILED` to `json` so the asset catalog reaches the digest* — an asset
catalog does not change what type-checks, and it would put every `Contents.json` in the tree into
both stamps.

## The FFI stamp read the Rust sources, not what the artifact is built from (2026-08-31)

`gates/ffi.rs` decides whether `SlopDeskFFI.xcframework` is stale by hashing every input, and its
filter was `Cargo.toml`, `module.modulemap`, `.rs`, `.h`. That set is the shim's closure of *Rust
sources*. It is not the set the three slices compile, and the two differed in two places, both in the
one direction `docs/55` names as the linked port's own failure mode: a stale artifact reported fresh.

**One input is spliced into the library by the code itself.**
`rust/slopdesk-codepanel/src/tips.rs` does `include_str!("../resources/recommendation-tips.json")`,
so that JSON is as much a part of the archive as any `.rs` — and editing it changed the built binary
while the stamp's digest did not move. It is now DERIVED, not listed: `included_paths` scans each
non-test `.rs` in the closure for `include!`/`include_str!`/`include_bytes!` and resolves the literal
against the containing directory. A list would be a second thing to forget, and forgetting this one
is exactly the defect. A first argument that is not a string literal, or one naming a file that is
not there, is an `Err` — the species this round is mining is a gate that answers "nothing to see"
about an input it cannot read, and adding a fresh silence to fix one would be absurd.

`tests/` and `benches/` are excluded because the staticlib does not compile them. Reading their
includes would pull `golden/golden_vectors.json` into this stamp, and a golden re-mint would then
cold an artifact containing not one byte of it.

**The other input is the lock.** Every crate here is its own workspace, so the only lock that governs
this build is `rust/slopdesk-ffi/Cargo.lock`: it pins every external version the three slices
resolve, and a `cargo update` changes what the archive is compiled from without touching one line of
source. `stamp.rs` hashes `Package.resolved` for precisely this reason on the Swift side.

**Hashing the lock forced `--locked`, and that is the load-bearing half.** `run` reads the wanted
stamp BEFORE building and records it AFTER. If a manifest edit left the lock out of date, the build
would rewrite `Cargo.lock` in between — so the recorded stamp would disagree with the very next
check, and `just lint` would announce the artifact stale seconds after building it. That is the
self-firing shape the `target/` pruning already exists to prevent, arriving through a new door. It
also settled a race the three concurrent slices already had: they share `crate_dir` and could all
rewrite that one file at once. With `--locked`, an out-of-date lock fails in cargo's own words
instead of being silently repaired mid-run.

**Rejected.** *Hashing all 36 `Cargo.lock` files in the closure* — correctness-safe but wrong: a
wrapped crate's lock governs only its own test runs, so its churn would cold the xcframework and buy
a 25–60 s rebuild for a resolution the artifact never used. *Listing the JSON next to `SELF_FILES`* —
the next spliced resource would not be in the list, which is the whole defect. *Recomputing the
wanted stamp after the build instead of `--locked`* — it would record mid-build source edits as
checked, trading one wrong-direction hole for another.

## The FFI stamp hashed 4.8 MB of prose it could not compile (2026-08-31)

The same stamp, the other direction. Once it hashed the right SET of inputs, it was still hashing
them as bytes — and 39.2% of those bytes were comment text: 4 787 251 of 12 220 384, across 673 files
in the shim's closure. Every one of them charged a comment-only edit a 110 MB, three-slice, ~2-minute
rebuild for a change that cannot move one instruction. `gates/code_text.rs` had solved exactly this
for the two app triples in `016f9960`; it understood `swift` and `h`, and simply had no Rust.

`Dialect::Rust` is that gap closed. Three things differ from the dialects already there, and none is
cosmetic:

- **Block comments nest**, like Swift's and unlike C's.
- **Raw strings lead with `r`**, not with hashes, and `r"…"` is raw with ZERO of them — so `raw` is
  now carried on `Ctx::Str` instead of inferred from the hash count. `r"a\"` is the input that
  decides it: read as an escape, the literal never closes where it really does, and the code after it
  is swallowed as string data. The `b`/`c`/`r` prefix is a prefix only when the preceding byte is not
  an identifier byte, which is what tells `br"x"` from `for r in`.
- **`'` is both a character literal and a lifetime.** The rule is Rust's own: a literal holds an
  escape, or exactly one character — measured at UTF-8 width, so `'é'` works — and then closes.
  `&'a str` fails that test and is punctuation. Reading it as a literal would consume every byte up
  to the next `'` in the file, and `<'a, 'b>` would lose the code between the two.

**The header is deliberately NOT stripped, and the asymmetry with the app stamp is the point.** The
`/* MACOS-ONLY BEGIN */` markers are comments to C and CONFIGURATION to `macos_only_symbols`, which
reads them to decide which doors each slice must carry. Strip them from this stamp and a marker-only
edit leaves it warm, `run` reports "up to date", the bijection is never re-checked, and a phone slice
missing a newly-required door ships green. The app stamp may strip `.h` because nothing there reads
those markers; this one may not.

**The boundary that makes the Rust stripping TRUE rather than merely convenient.** A doc comment
reaches a binary only through a proc macro that consumes one. The shim's closure has none: the whole
proc-macro set as of 2026-08-31 is `serde_derive`, `thiserror-impl`, `num-derive`, `num_enum_derive`
and `rustversion`, and not one reads `///`. A `displaydoc` or a `clap`-derive arriving in the closure
would make this stamp lie, so the doc comment names them.

**The tree canary now walks `rust/` too** — 2 294 sources, up from the Swift and C alone — pruning
`target` for the reason `stamp_inputs` prunes it. Writing it exposed a defect in the canary itself:
its marker was the literal string `/* canary */`, which appears in `code_text.rs`'s own test data, so
the moment this file joined the corpus the probe found itself. The marker is assembled at runtime
now. That is the same species one scale down — a check whose reach had grown past what its own
fixture assumed.

**Rejected.** *Stripping `.h` in this stamp too, for symmetry with the app stamp* — the markers are
this gate's configuration; see above. *Adding `code_text.rs` to `SELF_FILES`* — an algorithm change
moves the computed digest itself, so the gate colds in the safe direction with no list to maintain.
*Regex comment removal instead of a fourth lexer dialect* — the module note has ruled that out since
it was written, and a Rust lifetime is precisely the ambiguity a regex resolves the forbidden way.

**One more thing the new test found, in the module that was already shipping.** Writing the
asymmetry down as an assertion — a Rust comment may not move the stamp, a header comment must —
failed on its FIRST half for a reason that had nothing to do with Rust: a comment at the very top of
a file left a separator at position 0, so adding a `//!` header to a module that had none changed the
code hash. Trailing whitespace had been dropped since the module was written; leading whitespace had
not. A separator before the first token separates nothing and cannot join two tokens, so it is
dropped now, and both stamps stop rebuilding for a file header. The pending run is consumed either
way — clearing it only when a byte is written carried it to the second token and split `pub` into
`p` and `ub`, which the test caught in the same minute.

**And one the new tests did not find, because every fixture hid it.** `rust_char_literal_end`
returned a byte too many: the closing quote of `'a'` sits at `at + 1 + width`, so just-past-end is
`at + width + 2`, and the code said `+ 3`. All seven fixtures happened to write a `;` immediately
after the literal, and a swallowed `;` is re-emitted verbatim — byte-identical output, seven green
assertions, one live defect. The two inputs that discriminate are `'a'"/*"` (the swallowed byte is
the opening quote, so the string's contents re-lex as code and its `/*` strips the rest of the file —
the forbidden direction) and `'a'// x` (the swallowed byte is the first `/`, so the comment survives
into the hash). Both are pinned now. The escape arm had the mirror of it: scanning for the closing
quote from `at + 2` finds the quote `'\''` ESCAPES, ending the literal a byte early; the scan starts
past the escapee now, the way the C arm has consumed backslash-and-escapee since it was written. The
lesson is the round's own species one more scale down — a fixture set that agrees on an irrelevant
detail tests less than its assertion count suggests.

## The list two gates shared was spelled twice, and a ratchet said it was not (2026-08-31)

`prepush::TESTED_INPUTS` declares what `swift test` consumes; the fast loop's `touched::PATHSPEC`
declared it again. `slopdesk-invariants`' `the_green_tree_marker_means_one_thing` recorded that the
port had ended that duplication — "prepush declares the list and both markers, and touched reaches
all three through it" — and pinned two of the three. The list it checked only for EXISTING, so the
second copy sat next to it for as long as both files did, and the two disagreed in both directions.

`Package.resolved` was in the fast loop's copy and not in the declaration. That is the one that
mattered: the suite compiles against the versions that file pins and reads it from the WORKING tree,
so `tested_inputs_clean` answered "clean" while it was modified and a green went into the marker
claiming the committed tree had passed with pins the run never used. `Apps` was the other way round —
in the declaration, absent from the diff — in the harmless direction and with a real cost: no
SwiftPM target compiles a byte of the xcodegen shells and no suite opens them at run time, so every
push taken while an app shell was dirty re-ran ninety seconds the cache had already earned. There is
now ONE list, holding `Package.resolved` and not `Apps`, and the rule pins the third thing it names:
the fast loop may not declare a path list of its own.

**The other half of the same claim: what the diff was not allowed to look at.** `touched` scoped its
diff to Swift paths, and both it and `prepush` explained the FFI half of the key with "`rust/` is
untracked". `rust/` is tracked — 1 367 files. The conclusion survives for the two reasons that are
true (a tree hash is a COMMIT's tree, so uncommitted crate edits never move it, and the artifact is
gitignored outright), but the sentence had been load-bearing for scoping `rust/` out of the change
set entirely. So a dropd edit selected NOTHING while `just test-touched`'s own recipe rebuilt the
binary `DropdE2ETests` spawns. Measured before and after on the real tree: a file under
`rust/slopdesk-dropd` used to print `NONE` and now prints `SlopDeskFileTransferTests`, while this
round's own edit — two crates under `rust/slopdesk-devtools` and `rust/slopdesk-invariants` — still
prints `NONE`.

The edge is DERIVED, not listed: `prepush` already scanned the fixtures for `rust/<crate>/target` to
refuse a tree whose sidecars are unbuilt, and that scan now keeps which suite spelled it. One walk,
two reductions. A crate no suite boots contributes nothing, which is what lets `rust/` be in the diff
at all — attribution through the package graph would answer "unattributable" and escalate every gate
edit to the full suite.

**Bound, stated plainly.** A touched green never writes the pre-push marker, so the miss was a late
signal, not a green the push had not earned. It is fixed anyway for the reason the FFI baseline
exists: the inner loop's selection is a claim, and a claim that is only sometimes true is the species
this series has been mining.

**Rejected.** *Adding `rust` to the shared list* — that list is what makes the green-tree marker
mean something, and requiring `rust/` clean would refuse the marker on every crate edit while the
FFI half already witnesses the artifact. The diff's scope and the marker's definition of clean are
two questions; only the first grew. *A listed crate → suite map* — the fixtures already spell the
edge, and a hand-written list goes stale in the dangerous direction. *Escalating an unattributable
`rust/` path to FULL* — this gate's own crate is edited more than any other and no Swift test can
reach it.

## The reach gate asked its questions of a narrower set than the sentence it prints (2026-08-31)

`just lint-reach` exists because `slopdesk-invariants` cannot answer it: what a `just` recipe would
RUN is only knowable by expanding it. Its module header states the class plainly — "a crate that no
`fmt`/`lint`/`test` recipe enters is not a warning, it is silence" — and then asked the question of
`workspace_crates()`, the crates that declare `[workspace]` themselves. Three things fell outside
that set, and each was settled by SEEDING the defect and running the real gate rather than by
reading the code.

**A crate nothing adopts.** `RUST_WORKSPACES` is `"rust "` plus every `[workspace]` crate. A crate
that declares no `[workspace]` and is not listed in `rust/Cargo.toml`'s `members` is adopted by
neither: `cargo fmt --all` from the root never sees it, no recipe enters its directory, and it was
not in the list the reach questions were asked of. A seeded `rust/slopdesk-zzprobe` — four lines of
manifest and a `pub fn` — came back `check-reach: every workspace crate is formatted, linted and
tested by a just recipe`. It now fails naming the crate.

**The root workspace itself.** The bare `rust` in front of that list is the entry that covers all six
members, since `--all` and `--workspace` reach a member only from the directory that adopts it.
Nothing checked it was still there, because the loop iterated crates under `rust/` and `rust` is not
one. Deleting it left every per-crate question answering yes while six crates went unformatted; the
gate now asks about the directory too, once per recipe.

**Miri, over nothing in particular.** The arm read `check_plan.contains("cargo +nightly miri test")`.
`CLAUDE.md` buys the third hand-written-`unsafe` crate with "a differential suite that runs under
Miri", and that is a claim about `rust/slopdesk-gfsimd` specifically. Retargeting the recipe to
`rust/slopdesk-wire` left the gate green. The question is now asked of the MIRI LINES — a plan-wide
search for the crate name would be answered by the formatter, which enters that directory three
lines earlier, and a plan-wide search for `miri` by the wrong crate.

The printed success line was the tell and is now the summary: it said "every workspace crate", which
was honest about a reach the header's sentence was not.

**Rejected.** *Deriving the Miri crate from `slopdesk-invariants`' `HAND_WRITTEN` list* — one string
is not worth a dependency edge from the gate RUNNERS onto the tree RULES; the duplication is declared
in the constant's doc instead. *Making the orphan check a `slopdesk-invariants` rule* — it reads like
a pure tree question, but the reason a member is fine is that the PLAN enters `rust/`, so it belongs
where the plan is. *Accepting `)` as a name boundary* so a future `(cd rust/x && …)` would count —
that shape would read as unreached and fail loudly, which is the direction this gate must round
toward. *Treating an unparseable `members` key as "no members"* — that would report all six as
orphans and name the wrong defect, so it is a loud error of its own.

## The one carve-out that stood in for a view, once the view existed (2026-08-31)

`golden::readers` proves the sentence "a frozen key is pinned by a suite, or it is not pinned at
all". It asks a POSITIVE question — some file must name the key AND open the corpus — and that is
the shape a comment can answer for. `slopdesk-invariants` closed that class over the tree by reading
`Source::statements`; here it was patched with a path allowlist naming one file, the minter, which
says `golden_vectors` in its own prose and names fourteen frozen keys in the comments recording why
each stopped being minted.

The allowlist's own note said what it was: a carve-out closing one file rather than the class,
because the honest fix needs a comment stripper that PRESERVES STRING LITERALS — a reader cites its
key as `"naluJoin"`, and a strip to end-of-line corrupts any line holding `//` inside a string — and
the only such stripper lived in another cargo workspace, so reaching it meant a dependency edge or a
new shared crate. Both were design changes rather than sweeps, and the note recorded the measurement
that made leaving it safe: zero of the 27 frozen keys were prose-only.

That boundary dissolved and the note outlived it. `gates::code_text` was written for the FFI stamp,
in this module's own directory, and it is exactly the missing tool — Swift, Rust and C dialects,
comments removed, string literals emitted verbatim. So `readers` reads every candidate as CODE, the
allowlist is deleted, and the minter disqualifies itself for the reason it always should have. The
measurement stopped being a paragraph and became `every_frozen_key_in_this_tree_has_a_reader`, which
runs on the LIVE tree under `cargo test` — so a suite deletion that strands a frozen key is now
caught in a second rather than only by the golden gate's several-minute Swift mint.

**Rejected.** *Keeping the allowlist as belt-and-braces* — it can only re-open the hole it was
standing in for, by excluding a file that later becomes a real reader. *Leaving the walk's extension
list and the stripper's dialect list as two lists* — `code_of` returns `None` for a language
`Dialect::of` does not know, so an unreadable file answers nothing rather than answering for every
key, and the two stay in step by construction. *A fixture-only test for the tree measurement* — a
fixture cannot notice the real suite being deleted, which is the whole failure this arm exists for.

## The comment scanner that knew one language and was asked about three (2026-08-31)

`Source::statements` is the view every POSITIVE claim in `slopdesk-invariants` reads, and the reason
it exists is that it is the only one prose cannot answer: `code()` drops a whole comment LINE and
keeps a trailing one, so `let x = 1 // never call .addingProduct(` reads as a call. The scanner
behind it was written once and applied to `.swift`, `.rs` and `.h` alike, and `CommentStyle` split
only `//` from `#` — one level too shallow, because the three slash languages disagree about the
things a scanner has to know.

Three divergences, each seeded into the live scanner and confirmed by reading its output:

* `let s: &'static str = "x"; // addingProduct` — a Rust LIFETIME opened a character literal, which
  ran to the end of the line, so the trailing comment came through verbatim and a token ban read
  prose as a call. Rust's own rule is asked now: a `'` opens a literal only when what follows is an
  escape, or exactly one character and then a closing `'`.
* A Swift `"""` literal was read as one quote and closed at the next, so the scanner re-entered CODE
  inside the literal, treated its contents as comment openers and blanked to the end of the file.
* `"raw string for \(value ?? "unset")"` — an interpolated literal ended the one holding it, with
  the same result. This one was found by the canary rather than by a person.

All three end identically: the scanner loses the literal and blanks CODE, so whatever a ban was
looking for is no longer there to find and the ban passes. That is the one direction this scanner
must never fail in, and the reason the fix is a faithful three-dialect port rather than two patches
— block comments nest in Swift and Rust and not in C, Swift's raw hashes lead the quote and Rust's
follow an `r`, Rust's zero-hash `r"…"` is raw, Swift has no character literal at all. Every one of
those was already wrong; nothing in the tree happened to hit them.

The canary is the half that generalises: `no_source_in_this_tree_leaves_the_scanner_inside_a_literal`
appends a comment and a statement to every slash-commented file the tree walks and requires the
comment to go and the statement to stay. It found the third divergence, and it is the same shape as
`code_text`'s own tree canary — the property asked of every file that ships, rather than of the
shapes someone thought to write down.

The same round closed the last site the devtools census listed as deferred. `xcode::declared_tests`
counted `func test…` in RAW source and demanded the simulator execute exactly that many, so a
commented-out declaration inflated the left side and redded a run that had passed. The census called
it a false alarm rather than a false pass and left it, on the grounds that the honest fix meant
hand-rolling a second `//` filter — the duplication that note exists to refuse. `code_text` is that
filter, shared and already in the directory, so the count is over code now and the census carries no
deferred entry at all. Measured across the switch, because the consumer that compares the two counts
runs in `check` rather than in `quick` and would otherwise report a change many rounds late: 23 raw,
23 through the filter — today's suite holds no commented declaration, so the fix moves nothing but
the guarantee.

**Rejected.** *Merging this with `slopdesk-devtools`' `gates::code_text`* — the twin lexer answers a
different question. That one is for a content stamp, so it DROPS comments and normalises whitespace;
this one blanks in place, because `View::Statements` promises line numbering and rules report
`path:line:` off it. Merging means one of the two callers stops getting what it needs, and the crates
cannot share code anyway: this one's gate is `cargo test` over the TREE and may not take an edge onto
the gate runners. The dialect knowledge is duplicated in prose in both headers instead, which is what
the shared canary shape is for. *Patching only the two shapes the tree hits today* — the other
dialect facts were equally wrong and equally silent; a scanner that is right by coincidence fails the
day someone writes an ordinary line. *Keeping the old scanner's line-bounded literals as a resync
net* — that accident is precisely what hid the interpolation hole for as long as it existed.

## The view a satisfier may not pick (2026-08-31)

`slopdesk-invariants` splits every claim two ways. A BAN may read what a file SAYS — its subject is
often prose, and a comment naming the banned thing makes it fail LOUD. A claim that must be
SATISFIED may not, because the comment that answers one is almost always the tombstone the deletion
left behind: the sentence "there is no `slopdesk_inspector_decoder_buffered`" kept a rule demanding
that door green for as long as the door was gone.

That split was closed once already, in two passes. The four name-taking positive arms — `Doors`,
`Mentions`, `MentionsUnder`, `Names` — were flipped to `statements()`, then the pattern-taking ones
were swept behind them, and `Extract`, `Corpus` and `ByteMap` dropped their `view` field outright
because each only ever feeds a satisfier.

What was left after that sweep was a sweep and a sentence. `Claim::Matches`, `Exactly`, `Within`,
`Before`, `Resolved` and `PerFileCounts` still CARRIED a `View`, all 194 of their sites happened to
say `Statements`, and the only thing keeping the 195th honest was a `⚠️` on `View::Raw` saying so.
That is the exact shape this crate exists to refuse — a claim held by review rather than by a gate —
pointed at the crate. Measured before touching anything: 194 sites, every one already `Statements`,
zero exceptions. So the six arms have no `view` field at all now, and the flip moved no verdict; it
moved the guarantee out of a review and into the type, where the next site cannot disagree.

`Claim::AtMost` keeps its view, and the asymmetry is polarity rather than an oversight. It is a
CEILING: a comment matching its pattern pushes the count UP and over the maximum, which is a red
nobody mistakes for a pass — the same direction that makes a view safe on `Lacks` and `NoneOf`.
`Exactly` and `PerFileCounts` count too and are still in the flip, because a count with a FLOOR in
it can be pushed up TO the required number and satisfied by prose.

**Rejected.** *A rule that reads this crate's own sources and bans `View::Raw` next to a positive
arm* — it was the first shape considered, and it is strictly worse: it re-states in a regex what the
type can state outright, it fails at test time rather than at compile time, and it is one more
text-scanning gate whose reach can drift from its claim. Deleting the field is the same move
`Extract`/`Corpus`/`ByteMap` already made, finished. *Flipping `AtMost` for symmetry* — symmetry is
not the property; the direction a wrong reading fails in is, and `AtMost`'s is loud. *Growing the
field back for an ordered claim whose ANCHOR is legitimately prose* — a `MARK:` or a section
heading — that is the split `ByteMap` and `Corpus` already make: locate the range on the raw text,
read the FACTS out of `statements()`. All eleven `Within`/`Before` sites anchor in code today.

## The census that spelled its own length (2026-08-31)

`slopdesk-devtools`' `gates/mod.rs` carries a census answering one question per gate module — can a
COMMENT satisfy this gate? It lists the clean ones too, and says why: "not listed" and "listed as
clean" are the same line to whoever reads it next, and only one of them is a fact.

It also spelled its own length — "ALL ELEVEN modules are below" — and the directory had twelve. The
missing one was `code_text`, the comment-stripping lexer that two rounds of fixes had just routed
`golden::readers` and `xcode::declared_tests` through: the module that reads the MOST source text of
any of them. The census went stale in the same change that made it accurate everywhere else, and
nothing in the tree could say so. A count written into prose is stated once and then wrong in
silence, which is the failure mode the census itself was written against.

So the number is out of the prose and into a rule. `slopdesk-invariants`' `census-is-complete`
compares the census bullets against the `pub mod` lines in the same file, both directions: a module
with no bullet is a completeness the census no longer has, and a bullet naming no module is a
sentence certifying a gate that is gone — the unfulfilled-expectation half `DELIBERATE` and
`exemptions-are-alive` already carry. Probed by seeding the defect back into the live file: the rule
reds naming `code_text`.

The two sides read DIFFERENT views, and that is the point rather than an inconsistency. `pub mod`
reads `statements()`, so a commented-out declaration is not a module. The census reads RAW text and
must, because its subject IS prose: what is being satisfied is "somebody wrote a sentence about this
module", and a sentence is the one thing a comment-blanked view cannot hold. That admission is
written into the rule's doc so the next sweep of positive-claim views — the sweep that ended one
round earlier by deleting the `view` field off six claim arms — does not read it as an oversight and
"fix" it into a rule that can never fire.

**Rejected.** *Writing "ALL TWELVE"* — it rots again on the thirteenth, and the rule now owns the
fact. *Stating the census as a `Claim::SameSet` over two `Corpus` extractions* — `Corpus` dropped its
view field precisely so a satisfier cannot read prose, which is right, and this is the one claim
whose far side legitimately IS prose; forcing it through would have meant growing that field back
for every caller. *Anchoring the section on the first bullet instead of the heading* — the file opens
with a SECOND bulleted list, the port note saying what each gate used to be as a shell script, and
reading that one as the census reports a census that names nothing as complete.
