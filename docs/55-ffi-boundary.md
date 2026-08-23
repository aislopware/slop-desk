# 55 — The FFI boundary: how Rust reaches an in-process Swift caller

Most of the Rust in this repo is reached over a socket: `superd`, `screend`, `dropd`, `androidd`,
`inspectord` are daemons, and a daemon's interface is a wire format that both sides already have to
agree on. This document is about the other case — logic that has no daemon to live in because its
caller is a Swift process that must call it *synchronously, in-process*.

## 1. When a port must be linked rather than dialled

Two facts decide it, and neither is about performance:

- **The iOS client cannot host a sidecar.** There is no `fork`/`exec` to a helper binary on iOS.
  Anything both clients need is either linked into both or reimplemented for one — and the second
  is the two-implementations trap the one-implementation rule exists to stop.
- **Some of it is on the terminal's output path.** Scrollback eviction runs per truncation, inside
  the retainer. A round trip to a daemon there buys a lifetime boundary nobody needed.

`CLAUDE.md`'s rule states this as "pick by lifetime": a component that must outlive its caller, be
`execve`d, or be dialled by two processes is a binary on a socket. Everything else — in-process by
necessity, lifetime-coupled to its caller — is a linked library.

## 2. The artifact

`scripts/build-ffi.sh` builds `rust/slopdesk-ffi` for three arm64 slices (`macos-arm64`,
`ios-arm64`, `ios-arm64-simulator` — `docs/49`, "arm64 only"), checks every symbol the header
promises is actually in each slice, and assembles
`ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework`.

**It is gitignored.** Measured: 5.7 MB per slice, 17 MB for the three, rewritten by every Rust
edit — a git history nobody wants for a build output. `libghostty.xcframework` is gitignored for
the same reason and rebuilt by its own script. What the app pays is far smaller: **+384 KB linked**
after `-dead_strip`.

**It IS in the SwiftPM graph** — and this is where it differs from `libghostty`, which is
Xcode-only. The one-implementation rule requires `swift test` to exercise the Rust, because a Rust
implementation the Swift tests cannot reach would leave the Swift version alive as the thing
actually under test. The cost, stated plainly: a clean checkout must run `make ffi` once before
SwiftPM resolves. `make build`, `make test` and `make check` all depend on `ffi`, and a warm tree
short-circuits in milliseconds on the stamp, so in practice this is invisible.

cargo still never runs inside `swift build`.

## 3. The one failure mode a socket port does not have

A daemon cannot go stale: it either answers the current protocol or it does not. A **linked** port
can. The Swift side keeps calling last week's logic, every test green, because the tests link the
same stale archive.

`ThirdParty/slopdesk-ffi/sources.sha256` is written **last**, after the xcframework is assembled,
so an interrupted build leaves the artifact stale rather than falsely fresh. It hashes the `*.rs`,
`Cargo.toml`, `*.h` and `module.modulemap` of the shim *and every crate it wraps* — `INPUT_CRATES`
is the transitive closure of path dependencies from `rust/slopdesk-ffi`, read out of the Cargo
graph rather than kept by hand — plus `scripts/build-ffi.sh` itself, which decides which slices
exist and which symbols each must carry. File names are inside the hash, so a rename or a deletion
moves it too. Each crate's own `target/` is pruned: build scripts write `.rs` under it, and cargo
mints a fresh one *during* the build being stamped, so an unpruned walk made the gate fire on its
own output.

`scripts/check-supervisor.sh` runs `build-ffi.sh --check`, which reports staleness without
building. That gate is in `make lint`.

**SwiftPM does not watch the artifact.** A rebuilt `.a` alone does not make `swift test` relink —
it will happily re-run the previous test binary against the previous library, so a fixed rule can
keep failing its test with everything on disk correct. Touching any source file in the target that
links it forces the relink. This bit once during stage 31 and cost twenty minutes chasing a
non-existent Rust bug, which is the same class of failure as the stale stamp above: the answer you
get is last week's, and nothing says so.

> **A wrapped crate must reach the shim as a `path = "../…"` dependency, directly or through
> another wrapped crate.** That edge is what puts it in the stamp; a crate pulled in any other way
> is invisible to the closure, and the stamp will call a stale library fresh — precisely the
> failure this section exists to prevent.

## 4. The calling convention

One shape, every entry point, no exceptions:

| | |
| --- | --- |
| inputs | zero or more `(const uint8_t *ptr, size_t len)`; NULL means empty |
| output | one `(uint8_t *out, size_t cap)`; `out` may be NULL when `cap` is 0 |
| returns | how many bytes the answer NEEDS |

- `0` — there is no answer (the Rust `Option::None`).
- `n <= cap` — `out[0..n]` holds the answer.
- `n > cap` — **nothing was written**; call again with at least `n` bytes.

The "nothing was written" half matters: a caller that retries must see an untouched buffer, or a
partial escape sequence reaches a terminal. It is a test in `rust/slopdesk-ffi/src/lib.rs`.

**No allocation crosses the boundary in either direction.** There is no free function, no allocator
pairing to get wrong, and no leak that could be a Swift-side mistake. The price is that an
undersized buffer costs a second evaluation — acceptable *only* because every wrapped function is
pure, so the second call cannot disagree with the first. A stateful entry point needs a different
convention — §4b — and adding a THIRD is a decision, not a patch. §4d records one that was tried
and rejected, so the next person to have the idea can read why.

Passing `(NULL, 0)` as the output is the supported way to ask for the length before allocating.

### The answer that is an OFFSET, not a copy

`slopdesk_video_fragment_decode` parses a datagram and writes back a fixed `#[repr(C)]` header plus
a `payload_offset` — not the payload. Copying it would be free of §4's convention and still wrong:
the caller just handed those bytes over, so copying them back means every byte of every video frame
crosses twice for nothing. The parse borrows, the caller slices its own buffer at the offset the
answer reports, and the wire layout still lives on exactly one side — no caller has to spell 19.

The shape generalises: when the answer is *where in the input*, say so. It is not a third
convention, because nothing is allocated and nothing is retained — the offset is a scalar in a
struct §4 already permits, and it is only meaningful for the duration of the buffer the caller owns.

### The input that is an ADDRESS, not bytes

The three per-frame measurements — `slopdesk_video_frame_hash_nv12`, `slopdesk_video_scroll_nv12`,
`slopdesk_video_adaptive_qp_nv12` — take a base address and a row stride instead of a `(ptr, len)`
pair, because the pixels have no other form: they live inside a Core Video mapping that
`CVPixelBufferLockBaseAddress` holds open for the call, and there is no `Data` to lend. A 1080p NV12
frame is three megabytes arriving sixty times a second; copying it to measure it would cost more
than the measurement.

The obligation is the same one §4 already carries — is this memory live for this call — and the lock
is what `withUnsafeBytes` is elsewhere. What the shape adds is that the LENGTH is not given: it is
`stride * rows`, and it is computed with a `checked_mul` on the Rust side, so an absurd or hostile
stride is a defined "no measurement" rather than a read past the mapping. A plane and its stride
cross as one `#[repr(C)]` value for the same reason — a plane read at another plane's stride is the
bug this port exists to remove, and a pair that cannot be split cannot be mismatched at a call site.

The answers come back BY VALUE, as small `#[repr(C)]` records: each is four words or fewer, so there
is no buffer to size, nothing to write into and no sizing call. That is not a third convention
either — nothing is allocated and nothing is retained.

### The entry that takes no memory at all

The `video_policy` door — `slopdesk_ycbcr_coefficients`, `slopdesk_coord_window_point`,
`slopdesk_playout_step_ms`, `slopdesk_stream_stall_verdict` — has no pointer in its signature and no
buffer in its answer. Every argument is a scalar or a small `#[repr(C)]` record of scalars, and
every result comes back by value. There is no §4 return code to read, because there is nothing that
could fail to fit.

These are the entries where "is this worth a door" gets asked, and the answer is the golden corpus:
`coordWindowPoint` and `ycbcr` are pinned as raw IEEE bit patterns, so a second implementation drifts
the instant a compiler fuses a multiply and an add or an `f32` literal picks up an `f64`
intermediate. A door with no memory in it costs one non-inlinable call and removes the only way
those numbers can disagree with themselves.

**An `Option` crosses as a value plus a flag, never as a sentinel.** `SlopDeskLiveness` carries
`last_frame_at` beside `has_frame` rather than encoding "never" as a magic time, because "no frame
has EVER arrived" and "the last frame arrived at time zero" are different states, and a sentinel
makes the Swift side pick the magic number — which is a decision, which is the one thing this crate
may not hold. Rust rebuilds the `Option` on entry and the domain crate sees the shape it was written
against.

### The answer that is one scalar, and the refusal that cannot collide

`slopdesk_fuzzy_rank` takes two `(ptr, len)` pairs and answers an `int64_t`. There is no out-buffer,
no size call and no allocation on either side, because the answer is one number — and the refusal is
`-1`, which cannot be mistaken for one: an fzf score is `max(…, 0)` at every cell, so it is never
negative. That is the whole reason a sentinel is admissible here and not in `SlopDeskLiveness` above:
the sentinel is outside the answer's range *by construction of the algorithm*, not by a convention
someone has to remember.

`slopdesk_paste_dangers` is the same shape read one step further: its answer is a BITMASK, and a
mask of `0` is a real answer — nothing about this clipboard is dangerous — where `0` from an
`(out, cap)` entry means the caller should stop. The two cannot be confused because the return type
is not `size_t`; a scalar door that wants a refusal has to say so in its own type.

The same matcher also has `slopdesk_fuzzy_score`, which is §4-shaped because it answers a score AND a
variable number of matched positions. Two doors over one implementation is not two answers — the
score is bit-identical, and `rust/slopdesk-fuzzy` pins that in a test — it is one implementation told
whether the caller will underline anything. Most rows will not be: a filtered list ranks every row
and highlights only the handful it draws, which is why the list door below asks for positions BY
TIER rather than for all of them.

### The door whose answer is a constant

A number both languages have to name is not two constants; it is one constant and a door. Some get
an entry of their own — `slopdesk_ws_schema_version`, `slopdesk_ws_max_string_bytes`,
`slopdesk_phone_floating_cursor_run_capacity` — and some are INDEX-SHAPED, one door vending a small
family that is read together: `slopdesk_workspace_constant`, `slopdesk_replay_constant`,
`slopdesk_video_packetizer_flag`, `slopdesk_video_reassembler_frame_flag`. The index form exists so
a family of five does not become five entry points, and it costs nothing a caller notices: every one
of these is read once into a `static let`.

An index nobody defined answers a value the family cannot hold — `-1` where the answers are lengths,
`0` where they are bit masks — so a caller that asks for a constant that does not exist gets an
answer it cannot mistake for one that does.

The FLAG doors are the ones worth the entry twice over. A bit position is the worst thing in the
codebase to transcribe: the word is ORed together on one side and ANDed apart on the other, nothing
on the wire pins it, and a side that disagrees produces no error and no decode failure — just a
keyframe encoded as a delta, or an LTR the client never acks. `scripts/check-shared-constants.py` is
the gate that keeps a number from being spelled on both sides in the first place; it is birth
control, not a drift check, which is exactly why the constant should live behind a door and not in
its allowlist.

### The scalar answer whose refusal is not a refusal

The nine `slopdesk_vi_*` doors answer an `intptr_t`, and `-1` on half of them means the copy-mode
cursor ran off the row — which is not an error but a WRAP: the caller moves to the neighbouring row
and asks again. That reading forces the type. Column `0` is the most common landing a vi motion has,
so §4's "0 means no answer" is unavailable here, and `size_t` has no room for the sentinel at all.
`intptr_t` with `-1` outside the answer's range gives one, and the four doors that always land —
`first_non_blank`, `column_step`, `snap_to_cell`, `cell_width` — never return it, which the header
states so a caller knows which three lines need the `nil` arm.

Nine doors rather than one that returns a struct of nine columns: a keystroke asks exactly one of
them, and a door here costs a `withUTF8` over a row that is already contiguous. The row crosses
once per keypress, not once per column — which is the actual saving, because what moved to Rust was
a per-`Character` FFI call in a Swift loop.

### The record type that covers four kinds, so the reader is one loop

`slopdesk_hint_scan` is `slopdesk_link_scan`'s handle-over-arena shape a second time, because the
answer is the same shape: a variable list of records each carrying up to three strings. What it
adds is that a hint target has FOUR kinds and one of them wraps a detected link whole — its link
kind and its resolved absolute path ride in the same record, so the actuator keeps routing through
the one link policy the ⌘-click path uses instead of a second mapping that would drift. The other
three kinds leave those fields at their absent values.

One record type rather than four is what keeps the Swift reader a single loop. Four would mean four
doors to size, four arenas to take, and a Swift face that has to know which door to ask before it
knows what it found. The unused fields cost nothing a second crossing would not cost more of.

The two pattern lists cross as PARALLEL blobs under one count: entry `i` of `actions` is pattern
`i`'s `{0}` template. A zero-length action is NO action rather than an empty one, which is the
opposite of the presence-bitmask rule above — and it is right here for the reason it is wrong there:
a pattern with an empty template and a pattern with none behave identically at the actuation site,
so a flag would name a distinction nothing downstream can act on.

### The COUNT rides in the blob when zero is an answer

`slopdesk_find_matches` answers a §4 blob, not §4b's handle, because a match carries no strings —
three numbers per record, so the answer has a size before the scan runs and the ordinary
size-then-read retry is enough. A handle here would buy a second crossing and nothing else.

What it does need is a `[uint32 count]` in front of the records, even though the count is derivable
from `needed / 12`. Zero matches is a state the find bar is in on most keystrokes, and a §4 return
of `0` means *no answer*; deriving the count would make "nothing matched" and "ask again" the same
number. Four bytes in front buys the distinction for every reader, and the same reader handles the
truncated answer by refusing it whole: a find bar showing "3 of 7" over four highlights is worse
than one showing nothing, because the count is what the user navigates by.

Its columns are UTF-16 code units rather than bytes or scalars, which is the one place this boundary
lets the *caller's* unit win. The surface that highlights a match indexes in UTF-16, so any other
unit would be converted on the way out — by a second walk over the same line, in Swift, per match.
Counting them inside the scan is a pass over a prefix it already has in hand.

### Two answers in one call, and the second size that makes it retryable

`slopdesk_ws_search_rank` fills TWO buffers: where each candidate placed, and one flat run of the
scalar offsets the placements point into. They are one call because they are one pass — the matcher
backtraces while its alignment matrix is still filled, so asking for the underline afterwards would
mean scoring every title a second time on every keystroke, which is the cost this door exists to
avoid.

Two buffers need two sizes, and §4's return can only carry one. The return carries the row count,
because that is what a caller loops over; the run's size comes back through a `size_t *needed`
out-param. A short buffer of EITHER kind leaves both untouched and still reports both numbers, so the
retry stays the one docs/55 §4 describes rather than becoming a two-step negotiation. In practice
neither retry is travelled: no more rows can match than were offered, and a match carries exactly one
offset per query scalar, so the caller's first guess is the arithmetic bound rather than an estimate.

The ranking itself answers in the CALLER's indices. A palette row is an id, an icon, a shortcut and a
closure, almost none of which decides where it goes, so the answer names rows and the near side
reorders the array it already holds.

### The header is written by hand

cbindgen would have to run *somewhere*, and "somewhere" is either inside `swift build` (forbidden)
or a step that can silently not have run. A short header a reviewer diffs against `src/lib.rs` is
the cheaper guarantee — and `build-ffi.sh` checks every symbol declared in it against every slice,
so a header that drifts from the library fails the build rather than the app.

## 4b. The handle convention — and when it is allowed

Some types do not fit §4, because they are not functions, and they fail to be functions for different
reasons worth naming separately.

`ReplayBuffer` **is** memory: up to 256 MiB of retained PTY output, appended on every PTY chunk, and
the `should_pause_drain` answer after that append is what stops the host reading the master. Passing
that across per call would copy the whole history twice per chunk.

`VideoPacketizer` is smaller than its own arguments — it is two `u32` counters — and it still cannot
be a function. `streamSeq` advances per datagram and `frameID` per frame, and the host reads
`frameID` *before* packetizing so it can record the frame's LTR token against the id the frame is
about to carry. Threading both in and out per call would work right up until one side advanced a
counter the other did not, and nothing in the types would say so. The handle makes the disagreement
unrepresentable, which is the whole reason to reach for it when the state is this small.

`FrameReassembler` is both at once. It holds frames under construction — an IDR's worth of buffer,
which would cross once per fragment — and its state IS the answer: a frame is declared lost only
once a NEWER frame's fragments arrive while it still has a hole the code cannot fill, so a verdict
depends on everything the reassembler has been shown, not on the datagram in hand.

`SlopDeskBlockStore` is one handle for two things — the per-pane command-block ring and the output-request
registry — because a reset drops the blocks and has to answer every in-flight request in the same
breath, and two handles could be reset in either order.

`RecoveryIdrPolicy` is the smallest of them: a token bucket, a four-entry keyframe ring and a latch.
It earns a handle the way `VideoPacketizer` does, by being state that must not be copied — but it is
also where the rule below was written down.

`ChannelTable` is the mux's, and it is the one that shows what a handle is *for* beyond avoiding a
copy. It crossed first as storage — allocate, open, reject, close, read a state — while the rule that
decides what to do with a frame stayed in Swift as `MuxRoutingCore.route`. That worked and was
wrong: every branch of the decision reads a state and then writes one, so the rule was six crossings
per frame *and* a rule kept apart from the state it reasons about, which is the arrangement that
lets one of them be edited alone. `slopdesk_channel_table_route` moved the decision to the table,
and the crossing went from six calls to one.

**A verdict flattens; a payload does not travel.** A C enum with a payload is not a thing, so
`SlopDeskMuxRouting` carries the discriminant plus every field any verdict could want, and the
caller reads the ones its verdict names. The frame's bytes stay on the near side — a decision says
WHERE they go, and copying a chunk across a boundary to be told its channel id would be the whole
cost of the mux for nothing. Both refusals fail CLOSED (an unknown type byte, a null handle), which
is the opposite default from the platform tables in §4: those fail open because a missing row means
"nobody said otherwise", and here a missing table means "there is no channel", so delivering would
be the defect.

**A glyph is not text.** `slopdesk_git_line_runs` answers the project header's git dialect — `main ↑2
↓1 +3 !4 ?5 ~1 $2` — as an array of fixed records, with no arena and no spans, though every other
list door in the crate hands its records' strings over through a blob. The reason is that a git run
is not made of text: it is a role, ONE glyph and a number. The glyph crosses as a Unicode scalar, so
the near side puts `↑` next to `2` where it is already laying out glyphs, and the whole answer is
`(role, weight, scalar, count)` × at most eight. The one string in the line is the BRANCH, which
never crosses at all — it is the caller's own, and the rule reads only the one bit it needs from it
(was there a name), which is why the branch run carries `detached` and no text.

What that split has to survive is the obvious objection: if the near side does the writing, has the
dialect really moved? It has, and the boundary is exactly where the disagreement can live.
Concatenating a glyph with a number is not a choice; CHOOSING `~` over `=` for a conflict is, and
that one had already been got wrong — a dead second Swift renderer spelled it `=` beside a live one
spelling `~`, and both compiled until the copy was deleted. `scripts/check-supervisor.sh` bans a
sigil literal in the Swift face for that reason, which is a cheaper pin than any test: a second
dialect cannot be born without typing one of those glyphs.

The buffer is the caller's for the same structural reason the walk in §4d is not: a line is at most
eight runs and the ceiling is a property of the dialect, not of a repo. Both doors write at most
`cap` and answer the true length, which is §4's retry protocol at a size that never needs the retry.

### What picks the convention is the FAR side

A Rust type's shape does not decide this; the Swift owner's does. `QpController` and
`RecoveryIdrPolicy` are the same size, hold the same kind of state and sit in the same crate, and
they cross differently. `QPController` is a Swift `struct: Equatable` whose owner takes a copy out,
folds a report into the copy and writes it back — a handle there would alias two values the type
system says are separate — so it crosses as a pure fold, `(config, state, verdict) -> state`.
`RecoveryIDRPolicy` is a `final class` held by one owner and mutated in place, which is what a handle
already models.

A by-value crossing has one obligation a handle does not: **every field the next fold reads has to
travel**, including the ones that look like bookkeeping. `clean_streak` IS the quantiser law's memory,
and a controller rebuilt without it sharpens on every clean report instead of one per interval. That
is a `restored(config, q, clean_streak)` on the wrapped type, sanitising and clamping like any other
untrusted input — never a replay of the fold inside the door, which would be arithmetic, and
arithmetic is what a door may not have.

The rate law (`abr`) is the same convention at 16 fields, and it is where the obligation shows its
teeth: `rtt_inflated_streak` is what makes one noisy report harmless, `prev_smoothed_rtt_millis` IS
the drain gate, and the estimate's `sample_count` is the two-fold warmup that stops the first jitter
sample reading as a rise. Its `restored` also shows what sanitising must NOT be — it re-establishes
the bounds floor-last (`floor.max(cur.min(effective_ceiling()))`) rather than with `clamp`, because a
ceiling under the encoder minimum leaves the floor above the ceiling, and `clamp` asserts its bounds
are ordered. **A panic crossing the C boundary aborts the process** (the release profile is
`panic = "abort"`), so a hostile record has to land on a legal state. Its defaults cross too, through
`slopdesk_abr_config_default()`, so the far side spells them once and the near side falls back to
fields of that record rather than to literals of its own.

The presentation depth (`pacer_depth`) is where "every field the next fold reads" stops being
scalars. Its promote window, its demote dwell and its dense-flow gate all read TIMES rather than
counts — never "how many lates" but "how many inside the last second" — so the three RINGS travel,
as fixed-capacity arrays sized at the capacities the folds already cap at. Carrying the counters
instead would have been a different policy that agreed only while nothing aged out. Where a ring's
KEPT size is a tunable, it is capped to the carried capacity on the way back in, because a ring that
kept more than the crossing carries would silently lose its oldest entry on every trip. The rings
also cost the crossing its free equality: a C array is a TUPLE in Swift and a tuple that long has no
`==`, so `slopdesk_pacer_depth_eq` is an entry of its own — the one comparison the near side cannot
spell for itself.

That door also settles where env knob NAMES live. It takes a KEY and a VALUE and answers the config
that results, so a caller with a whole environment map walks it one pair at a time and the far side
recognises its own knobs. Nine optional strings in one call would have worked equally well and kept
the names on the near side, which is the same law written twice.

The decoder's admission (`decode_admission`) is where the by-value fold meets a payload, and the
answer is that the payload does not cross. Its sequencer's law reads a frame id and one keyframe bit
and nothing else — never a compressed byte — so the door takes an id and answers with ids: which are
releasable now, in RELEASE order, and which a keyframe has made obsolete. The near side keeps its own
frames in a bag keyed by id and honours those two answers IN THAT ORDER, release then forget, so a
duplicate keyframe that was already held finds its removal a no-op. Passing the frames themselves
would have copied the whole compressed buffer in and out per completion for a law that does not look
at it. **The test is not how big the value is, it is whether the far side READS the part that is
big.** Where it does not, the boundary lands where the law's own inputs end. Where it DOES, the
answer is the other convention entirely: the audio jitter stage (`audio_jitter`) holds a queue of
frames exactly the way the sequencer does, but its whole product IS the samples — it hands back a
steady stream of them, in an order it chose, split at offsets it chose — so there is no id it could
answer with, and it takes a HANDLE. The two ports landed the same day and are the clearest pair of
worked examples this document has: same shape, opposite answer, and the question that separated them
was never the size.

**A follow-up the audio half earned on 2026-08-23, and it is about WHERE, not how.** The stage was
right to be a handle and wrong about where the handle sat. Its door was mid-pipeline — fifteen
entries, because a Swift pump had to ask it for a priming latch, two sample budgets, a starvation
test and a shed bound, then move samples into a Swift ring for a Swift render callback. Every one of
those answers was correct in isolation; what could not be checked was their ORDER, which was a law
spelled on the near side out of doors and could be spelled wrong there without any door refusing.
The stage is now inside `slopdesk-audio-out`, which owns the ring (`rtrb`) and the output stream
(`cpal`) as well, and the door above it has two verbs a caller cannot misorder: here is frame N, and
play. **A handle with a large surface is a law you moved without moving its sequencing.** The
size question was still not the one that mattered; this time the one that mattered was how many ways
the near side could put the answers together.

The presentation queue (`present_queue`) is the third of the set and it falls on the sequencer's
side, one step further out: what it carries is not even an id the caller minted for a payload, it is
a handle the caller minted for a `CVImageBuffer` it goes on holding. The law picks which handle this
refresh shows and how much slack to keep; it never dereferences one. So the queue of waiting frames
crosses by value, sized at the depth cap the env gate already clamps to, and every fold answers with
a DROP LIST — the handles that fold made obsolete. That list is the obligation a by-value port of a
handle queue takes on: the near side is the one holding the images, and a count would tell it how
many died while leaving it to infer WHICH from an ordering it is precisely no longer keeping.

Its two outstanding SETS travel for the `pacer_depth` reason: a fold reads WHICH ids are held and
declared-lost — the run at the expectation, the holes it steps over, the flush order — and a count
answers none of that. Both valves clamp to the ceiling the carried capacity is proved against, so no
legal setting is ever truncated, and the sets became fixed arrays inside Rust too rather than trees:
the per-frame path allocates nothing and the whole sequencer stays a value that copies. The flush's
ordering sorts by hand for the `panic = "abort"` reason above — `distance_wrapped` is only a total
order over a span shorter than half the id space, and a library sort that validates its comparator
would abort where a selection sort over sixty-five ids simply answers.

So Rust owns the object and Swift holds an opaque token:

- `slopdesk_replay_new` / `slopdesk_video_packetizer_new` / `slopdesk_block_store_new` /
  `slopdesk_idr_policy_new` return an opaque `*`; exactly one `_free` per `_new`; NULL is inert at
  every entry point, so a failed `new` cannot become a crash in `deinit`. Where inertness has to
  mean something rather than nothing, it means the SAFE answer — a null policy suppresses the
  keyframe rather than granting one.
- **No two calls on one handle may overlap.** The mutators take `&mut` through the pointer, so a
  concurrent call is aliasing UB, not a lost update. The Swift owner serialises under the lock it
  already held for the value type it replaced — including for calls that look read-only, because
  the producers below write the handle's slots.

  **One handle is written for the opposite, and it says so in its own doors:**
  `SlopDeskCursorSampler`. Its doors take `&`, not `&mut`, and its state sits behind two mutexes,
  because two threads calling it is the DESIGN rather than a caller's mistake — the 120 Hz cursor
  position sample runs off the main thread precisely so a main-thread window raise cannot freeze the
  pointer, while `AppKit` will only answer what shape is displayed ON the main thread. There is no
  lock the caller could hold that would serialise those two without reintroducing the freeze.

  What makes it an exception rather than a hole: the locks are two so the cold path never blocks the
  hot one, the PNG render happens with neither held, and nothing else may be assumed shareable. A
  handle without that note in its own header block is not one — the rule stays the default and this
  is a documented, tested departure from it, with a test that runs both paths concurrently.
- Answers still come back through `(out, cap) -> needed`. **Nothing is allocated on one side and
  freed on the other**, so §4's "no free function" survives intact.

A producer fills one of three **slots** on the handle and returns its item count; the caller reads
items out one at a time. Peak memory stays at one message rather than a second copy of the whole
replay, and no list encoding exists to get wrong.

| slot | filled by | read with |
| --- | --- | --- |
| messages | `messages`, `replay`, `rechunk_snapshot` | `result_count` / `result_seq` / `result_len` / `result_copy` |
| blob | `snapshot_source`, `ring_fold_source` | `blob_len` / `blob_copy` |
| seqs | `snapshot_source`, `ring_fold_source`, `ring_seqs` | `seqs_count` / `seqs_copy` |

Adoption runs the other way through a fourth, staging slot: `input_clear`, `input_push` per message,
then `adopt_snapshot_replay`.

The packetizer has one slot and one producer, for a reason §4 cannot cover: the answer's SIZE is
what the call decides. How many parity fragments a tier adds is the logic being asked for, so the
caller cannot size a buffer up front and `(NULL, 0)` cannot mean "ask first" — asking would
packetize the frame, and packetizing it twice would advance both counters twice. So
`slopdesk_video_packetizer_raw` packetizes, parks the flattened datagram list, and returns its
length; `slopdesk_video_packetizer_answer` copies it out under §4's convention, as often as the
caller likes.

| slot | filled by | read with |
| --- | --- | --- |
| answer | `packetizer_raw` | `packetizer_answer` |

The reassembler answers a VERDICT tag and parks the detail behind it, which is the same idea with a
different shape: `ingest` returns incomplete / completed / dropped / stale, and a completed frame's
id, latched wire bits and AVCC come out of the frame slot afterwards. Two of its readers are worth
their own sentence, because both are about what a scalar cannot say. `next_needs_retransmit` answers
how many fragments the request names, and 0 IS the absence — a request naming nothing is not one, so
no second "did it answer" call exists to get out of step. `next_dropped_frame` writes its id through
an out param and answers `bool`, because every `u32` is a legal frame id and no value could have
meant "none".

| slot | filled by | read with |
| --- | --- | --- |
| frame | `reassembler_ingest` completing or dropping | `frame_id` / `frame_flags` / `frame_avcc` |
| retransmit | `next_needs_retransmit` | `retransmit_frame_id` / `retransmit_frags` |

### The callback, which is the same convention inverted

The cold-replay scrollback cleaner is screend's `sanitize` verb, and the dialling is on the Swift
side, so it enters as a C function pointer: `(ctx, in, in_len, out, cap) -> needed`. It is the only
re-entrant path across this boundary. Rust sizes the first buffer at input + 4 KiB slack and writes
into uninitialised capacity — `vec![0; n]` there would zero 64 MiB before the answer overwrote it —
so the retry path is correct rather than travelled.

**Two rules keep this from becoming the general case.** A third convention is a design change, not a
patch; and a handle whose entry points started deciding things would be the domain logic leaking
into the shim, which §5 forbids for exactly the same reason.

### The shape that crosses as its own bytes

`slopdesk_ws_apply_intent` is the intent applier, and it is the one door whose argument and answer
are both a whole document. A `WorkspaceTopology` is a split tree — sessions, tabs, per-pane specs,
two rings — and there is no `#[repr(C)]` flattening of it that is not a second grammar somebody has
to keep in step with the first.

It does not need one. **The topology already has a byte encoding: the document's own.** The cells go
in as the flat `(SlopDeskWsEntry, blob)` pairs `slopdesk_ws_encode_snapshot` already takes, and the
result comes back as an encoded snapshot the caller reads with `slopdesk_ws_decode_snapshot`. Every
byte on that path is a codec both sides already run against a host's push, so there is nothing new
to keep in step — and `rust/slopdesk-ffi/tests/snapshot_codec_parity.rs` is what lets that be said
out loud, because the encoder the caller reaches (`slopdesk_workspace::state_codec`) and the decoder
this door uses (`slopdesk_wire::document::codec`) live in two crates that do not depend on each
other.

Its two closures flatten the way §4's do: the project-key lookup as `(pane, span)` pairs into the
SAME blob the entries span, and the identity source as a small pool of pre-minted UUIDs
(`slopdesk_ws_minted_ids_per_intent()`, sized by the crate that spends them — a pool one short
REPEATS an identity rather than failing). The verdict is `WorkspaceIntentStatus`'s byte, which is
the wire's and therefore frozen, read out of `slopdesk_ws_intent_status(index)` rather than written
down a second time.

The evidence the port is behaviour-identical is that all 49 cases in
`Tests/SlopDeskWorkspaceModelTests/WorkspaceIntentApplierTests.swift` — written against the deleted
Swift original — passed unchanged the first time the door was wired in. That suite stays where it
is: it is the boundary's own test, not a mirror of `apply.rs`, and a dozen of its cases have no
counterpart there.

### The same bytes again, and the predicate that did NOT become a crossing

The workspace state FILE (`slopdesk_ws_state_file_encode` / `_decode`) is `apply_intent`'s shape a
second time and for the same reason: what goes in is a document, what comes back is a document, and
the document's own encoding already exists. Nothing new travels — the cells are the flat
`(SlopDeskWsEntry, blob)` pairs, and a decoded file is an encoded snapshot the caller reads with the
decoder it already runs against a host's push.

What it adds is the third entry, and the argument for it is what did NOT cross. The interesting half
of a state file is not the JSON, it is the FILTER: which cells may touch the disk at all. Persisting
the entry map wholesale restores `commandRunning = 1`, `agentState = working` and a liveness of
`attached` for a pane whose child exited weeks ago — a workspace of fake-live rows, busy dots
spinning for nothing — so two answers to it do not conflict, they RENDER, and neither logs anything.
That rule reads a KIND and a FIELD and **nothing else**: not the object id, not the value, not the
rest of the document. So it crosses as `slopdesk_ws_state_file_is_persisted(kind, field)`, the shape
`slopdesk_ws_key_is_topology` already has one section down, and the near side's filter loop is a loop
rather than a decision — every branch inside it is behind the door. Handing the whole state over to
have it handed back minus some rows was the alternative, and it would marshal every byte of a
document twice to ask a question about two of them.

**The refusal taxonomy crosses as bytes the ARMS own.** A load can fail three ways and the caller's
answer differs across them, so `FileError::code()` lives on the enum in `slopdesk-wire` and
`slopdesk_ws_state_file_status(index)` merely exports it — a door that invented the numbering would
be §5's "no error mapped to a different error", and it would be the second place the taxonomy is
written down, which is the whole thing this port removes. The version a mismatched file CLAIMED
rides in an `int64_t *` written on that arm ONLY and left untouched otherwise, because every `i64` is
a version a hand edit can type and none of them could have meant "not about a version" — the
presence rule of §4b, at the width of a word.

The port found a drift the same way the agent one did, and it is on the ENCODE side: the two writers
were never byte-identical. Foundation's `JSONEncoder` escapes `/` as `\/` unless asked not to, and
base64 values are full of slashes; it also writes no trailing newline where
`slopdesk_workspace::json` writes one. Both readers accept both spellings, so nothing breaks — the
cost is one whole-file diff on the first save after the port, and it is recorded here rather than
"fixed" quietly, because the file on disk is the evidence anyone debugging a lost workspace reads.

### The door that stopped being a door, because the answer had nowhere left to go

A Claude Code hook body is three discriminants and five optional strings (session id, tool, tool-use
id, label, prompt), all written by whatever forked the agent's hook. `rust/slopdesk-hookevent` reads
it, and for a while it had a door of its own: a §4 answer of `[u8 hook][u8 notification][u8 kind]
[u8 present] [u16 BE len]×5 [bytes]×present`, where `present` was a bitmask because **ABSENT and
EMPTY are different answers here** — a body that sent no `session_id` must not read as one that sent
`""`, since the empty string is a session, and attributing a record to it attributes the record to a
PANE rather than to nobody. That is exactly the confusion the attribution exists to prevent (a
nested `claude -p` that inherited `SLOPDESK_PANE_ID` driving the pane's own status), and a zero
length cannot carry it, so a bit did.

The bitmask rule stands wherever an optional string crosses, and nothing crosses that way any more:
the last carrier of it, `SlopDeskAgentSpan`, retired with the foreground-job staging handle below.
Keep the rule where the next optional string appears — a zero LENGTH is not an absent VALUE. The DOOR
does not. When the fusion moved
(`rust/slopdesk-agent`'s `detector`), a hook body stopped needing to become a Swift value at all: it
crosses as raw bytes into `slopdesk_agent_detector_hook`, which parses and folds it in one call.
What the old door answered was a value whose only consumer was the next call across the same
boundary — so it was deleted, module and all, on the rule that a door nothing calls is a second way
to ask what a live door already answers.

What made the port worth doing was never the encoding. The body was read TWICE over: a typed
`HookPayload` enum modelling the JSON in one target, and a `mapToHookEvent` adapter a module away in
another turning a payload into the event the status machine folds. Splitting an event's IDENTITY
from its MEANING is what let the two drift — a payload case could gain a field the adapter never
read, and the rules that decide a pane's status (`AskUserQuestion` is a BLOCK, an interrupt is a
FINISHED TURN, the idle nudge is not a raised hand) lived nowhere near the case they governed. One
crate holds both halves now, and `scripts/check-supervisor.sh` fails if a second reading appears —
including a Swift file that reaches for a standalone parse door again.

### The door only one platform has

Every other entry point is on every slice. `slopdesk_git_status` is not: it is declared inside a
`TARGET_OS_OSX` region of `slopdesk_ffi.h`, compiled behind `cfg(target_os = "macos")`, and its
crate is a target-gated dependency. Behind it is a vendored `libgit2` — a C library the size of the
rest of the archive — and the only caller is hostd, because a client on either platform RECEIVES
the git status as a metadata reply and never computes one. Building that library into the two iOS
slices would cost every phone build the compile and every phone archive the bytes for a door
nothing on that platform can reach.

The hazard a platform gate introduces is that it is spelled THREE times — the header's `#if`, the
module's `cfg`, and the manifest's `[target.'cfg(…)'.dependencies]` — and two of the three can stop
agreeing without any compiler noticing. `build-ffi.sh` closes that: it reads the symbols out of the
region's `MACOS-ONLY BEGIN`/`END` markers and requires them PRESENT on the macOS slice and ABSENT
from the other two. A `cfg` that stops matching the header fails whichever direction it drifted —
a phone archive that quietly grew a C library, or a macOS door Swift can no longer link.

What a platform-gated door does NOT buy is isolation from its C library's linker needs. A Rust
staticlib is one object per crate, so the object holding this door also holds every other
`slopdesk_*` entry point: any executable calling any of them pulls libgit2's members in and needs
`iconv`, `Security` and `CoreFoundation` at link time. `Package.swift` says that once as
`ffiCLibraries` and every `CSlopDeskFFI` dependent carries it. Weigh that before linking the next C
library through this boundary — the gate keeps the BYTES off the phone, not the flags off the graph.

### The answer that is a REPLY, because the near side only forwards it

`slopdesk_git_status` set a shape three later doors took: it answers the metadata reply's own
payload, not a record. `slopdesk_pane_process_list` and `slopdesk_pane_port_list` are the same
argument at a different verb — hostd's `MetadataResponseBuilder` holds no opinion about either list,
it puts the bytes in a frame — so a `SlopDeskProcessInfo *` would cross the boundary only to be
encoded one line later by a Swift function that already exists for the golden vectors.

What settles it is §4's own test: **what picks the convention is the FAR side.** The far side of a
process list is a client that decodes it; hostd is a relay in the middle. So the seam that used to
be `func processes() -> [MetadataCodec.ProcessInfo]` is `func processes() -> Data`, and the builder's
arm is `reply(requestID, .ok, query.processes())`. The Swift encoders did not become dead — the
golden-vector generator and the codec's round-trip tests still call them, which is exactly why the
fake in `MetadataResponseBuilderTests` encodes: the assertions still read the values back out, and
what they now pin is that the builder forwards bytes it did not touch.

The third door is the exception that shows the rule. `slopdesk_pane_working_directory` answers a
STRING, because hostd genuinely uses it: it is the confinement root every path-carrying verb is
checked against before any query runs. A caller that consumes an answer gets the answer; a caller
that forwards one gets the frame.

There is a second, smaller reason these three are doors at all rather than a fork of
`slopdesk-probe`. Everything behind them is anchored to a PTY master fd hostd holds, and handing a
descriptor across an `execve` to save four Darwin calls is the trade §1 exists to refuse. The port
scan still SPAWNS — `lsof`, twice — but it spawns from the linked side, through the same bounded
`slopdesk_probe::run::capture` the forked probe uses, which is what retired the third spelling of the
15 MiB opaque cap that §8's ratchet used to have to reconcile.

### The answer that is a NESTED shape, walked once

`slopdesk_styled_lines` renders a finished command's captured bytes as the styled lines a person
reads — lines of runs, each run a style plus its text. That is two levels of variable count, which
§4's flat `(offset, length)` pairs do not express, so the answer is a WALK: a count, then that many
groups, each a count and that many `[13-byte header][text]` records.

The walk is the whole contract. Nothing is indexable and nothing is seekable — the caller reads
forward exactly once, and a length that would leave the buffer is a shape disagreement between the
two sides rather than bad input, because the pass itself never refuses. `rust/slopdesk-ffi`'s own
tests walk it too, and assert the cursor lands exactly on the end: a layout pinned on one side only
is a layout nothing pins.

A colour's ABSENCE is a `kind` byte of `0` rather than a reserved palette slot. The surface's
default is not a colour the stream named, and encoding it as one would paint a pane's own background
over text nothing coloured — §4b's rule about presence flags, at the granularity of a run.

What made the port worth doing is that the Swift it replaced was a SECOND VT GRAMMAR: a hand-rolled
escape skipper, a hand-rolled SGR decoder and a hand-rolled string-sequence scan, sitting beside the
`vtscan` module that already owned all three for the replay passes. Two grammars over one byte
stream is how a sequence one side skips and the other prints becomes a bug nobody can localise. All
45 tests written against the deleted Swift passed unchanged the first time the door was wired in.

### The fold whose answer is a whole document, and the reply that is deliberately empty

The pane LIVENESS half (`rust/slopdesk-ffi/src/workspace_liveness.rs`) is the first family here
where the input and the output are the SAME shape: a document goes in as flat
`(SlopDeskWsEntry, blob)` pairs, a policy runs over it, and the next document comes back as an
encoded snapshot the caller reads with `slopdesk_ws_decode_snapshot`. Three doors fold that way —
`slopdesk_ws_merge_pane_liveness`, `slopdesk_ws_mark_pane_dead`, `slopdesk_ws_reconcile_panes` —
and the other two read one record (`slopdesk_ws_pane_liveness_entries`,
`slopdesk_ws_pane_liveness_read`).

Two things about it are worth stating as convention rather than as detail.

**The record crosses as a `#[repr(C)]` struct, not as its own encoding.** A liveness record is 26
fields of which 7 are strings, and encoding it would have put a SECOND codec beside the document's
own — the drift class §8 is about. So the strings ride as §6 spans into the same blob the cells
already occupy (one pointer per tick, not one per string), and every `Option` scalar carries the
presence flag §4b requires rather than a sentinel. The struct's field order is widest-first, so the
layout has no padding for the hand-written header to transcribe.

**A fold that did not move the document answers `0`, and does not encode.** This is §4's "no
answer" used for its literal meaning: there is no NEW document, and the caller — which reads
`changed` before the bytes, because that is the only correct order — was going to discard them. It
is not a micro-optimisation. Reconcile runs on a 500 ms backstop whose usual outcome is "nothing
happened", so the alternative is encoding a whole workspace twice a second in order to throw it
away. `folded()` in the module's own tests asserts the empty reply, so the contract is pinned on
the side that can see it.

## 4c. What the boundary costs, measured

### What ONE crossing costs — the number to price everything else against

**A crossing is about a nanosecond. What costs is the marshalling.** Measured from Swift against the
real shipped `SlopDeskFFI.xcframework/macos-arm64` — scratch harness, NOT in the tree, `swiftc -O`,
two runs agreeing to 0.02 ns:

| what is called | ns per call, from Swift |
| --- | --- |
| a bare scalar door — **the floor** | **1.0** |
| a door returning a small struct by value | **1.0** |
| a door taking a flags word | 3.5 |
| a door + two `Array(String.utf8)` allocations | 100.8 |
| a door + a `Data` allocation | 227.5 |

Two hundred times between the first row and the last, and **none of that spread is the boundary** —
it is allocation, `String`→`[UInt8]` conversion and buffer copying on the near side. The C call
itself never leaves the first row.

⚠️ **So a crossing COUNT is not, by itself, a reason to build a door.** `n` crossings of a scalar
door is `n` nanoseconds: an audit finding of "1,700 crossings per keystroke" is 1.7 µs and refutes
itself, while "one string door per log line at 400 lines/s" is 40 µs/s and is real. When a
whole-answer door is worth building, what it buys is the per-member **allocation** or
**re-derivation** it deletes — never the crossings on their own. The settings-page port earned its
keep on ~166 re-filters and ~330 allocations, not on its 166 crossings.

This is why the 2026-08-22 sweep's own top-ranked finding did not survive contact with a benchmark:
a reassembler drain probe pair, ranked #1 at ~3,600 "wasted" crossings a second, prices at 4.98 ns
per datagram against the 190–204 ns `ingest` on the *same* datagram — 2.5% of the call before it, and
9 µs/s in total, or 0.0009% of a core. The ranking was by crossing count; the crossing count was the
wrong unit. **Rank by allocations.**

### The ring buffer, measured against the Swift it replaced

A/B against the deleted Swift implementation, release build, 32 KiB chunks, 64 MiB ring
(the benchmark was scratch and is NOT in the tree — it would have been a second implementation):

| path | Swift (deleted) | Rust handle | |
| --- | --- | --- | --- |
| append + ack, 20k chunks (640 MiB) | 531 ms | **446 ms** | Rust faster |
| `retained_bytes(above:)`, 1M probes | 28.9 ms | **27.7 ms** | parity |
| warm reconnect replay, ×2000 | 2.9 ms | 19.4 ms | +8 µs per reconnect |
| cold reattach replay, distilled, ×20 | 193 ms | 784 ms | **+30 ms per reattach** |

The hot path — append per PTY chunk, and the lag probe that runs per ack — is at parity or better.
The cold-reattach number is a real regression and is recorded as one: it is one memcpy of the
history through the callback (in, then out) plus one out of the message slot. Context for the size
of it: the compose step on that same reattach path renders at a measured 17.9 MiB/s, so a 64 MiB
history spends ~3.5 s there. 30 ms is 0.85% of an operation that already dominates the reattach.

**The fix, when it is worth doing, is to delete the callback rather than optimise it.** `sanitize`
is `rust/slopdesk-screend`'s library function; linking it into the shim removes both memcpys AND the
64 MiB AF_UNIX round trip that BOTH implementations pay today, which would put the cold path well
ahead of the Swift original. It is not in this change because it also removes screend's
absent-engine identity policy and grows the artifact — a decision of its own.

### The two terminal loops that a crossing COUNT accused, and the number that acquitted them

A ranked audit of every loop-shaped call site in `Sources/` put the terminal-mode tracker and the
⌘-link scan near the top, on the shape of their call pattern: `1 + n` crossings per PTY chunk for an
array the caller discards, and `4 + n` per link scan inside a body that re-runs on output. Both were
measured before anything was built, and **both refute**. The entry exists because the refutations
are the same refutation, and it is the one this section is for.

Priced by the rule two subsections up. Scratch release benchmarks, M-series host, NOT in the tree —
the door pipeline timed in Rust against the same corpus the in-tree `TerminalLinkScanBenchTests`
uses, and the Swift marshalling timed under `swiftc -O` with no door in the loop at all, because
marshalling is what was on trial:

| link scan, 50-row viewport | µs | share |
| --- | --- | --- |
| the scan itself (`link_scan` + free) | 152.2 | 98.2% |
| `flatten(rows)` — the `[String]` → blob the boundary takes | 0.64 | 0.4% |
| 50 × `String(decoding:)` out of the arena | 2.09 | 1.3% |
| `_counts` + `_take_arena` | 0.05 | 0.03% |
| **50 × `link_scan_link` — the `n` the audit named** | **0.13** | **0.08%** |

The ratio holds at every size: over 2 000 scrollback rows the record reads are 5.3 µs of 6 000. So
batching them into one whole-answer door — the idiom `slopdesk_ws_rail_disambiguated_labels` and
`slopdesk_block_statuses` exist to demonstrate — would remove **0.08% of the call**, and add a fifth
entry point to a family that already has four. It is not worth doing, and the reason generalises: a
record door earns its place when each per-member crossing RE-DERIVES or RE-ALLOCATES something, the
way the settings-page port did. Here each one copies a nine-field `#[repr(C)]` value out of a `Vec`
the scan already built.

The tracker's discarded array is the same finding one register cheaper. `slopdesk_mode_tracker_consume`
answers a COUNT, and the Swift face reads a parked event only when that count is non-zero — so the
`_ =` at the call site pays for nothing at all on the hot path:

| `consume` on a 3 177-byte chunk | marks | door | the discarded `[TerminalModeEvent]` |
| --- | --- | --- | --- |
| ground content (the overwhelming case) | 0 | 0.172 µs | **0 ns** — an empty Swift array allocates nothing |
| a chunk bracketing one command | 4 | 0.455 µs | 142 ns, once per COMMAND |

So there is no silent-consume entry point, because the shipped one already is silent whenever it has
nothing to say. **A `1 + n` that short-circuits at `n = 0` is a `1`.**

What the measurement DID find is next door to where the audit pointed, and it is worth more than
either port would have been. Ground-state chunks carry no `ESC` at all, so deciding that *is* what
`consume` costs — and the skim that three comments across two languages called a `memchr` was
`window.iter().position(…)`, which does not vectorise, because its early exit is per element. It ran
the hot path at **3.0 GB/s**. Testing sixteen lanes at a time with the classic zero-byte identity —
safe Rust, no dependency, in a crate that forbids `unsafe` — runs at **18.2 GB/s**, and takes the
whole door from **1.12 µs to 0.172 µs per chunk, a measured 6.5×**, on what the audit correctly
called the hottest terminal path in the repo. `slopdesk-terminal`'s `tracker::skim` carries the
differential that pins it against the byte loop it replaced, at every length across the lane
boundary and every needle position within each.

**The lesson for the next audit: rank by the WORK a loop repeats, not by the crossings it makes.**
Every entry above this one bought something a crossing count could not see — a whole table
re-filtered, a title re-scored, a document re-encoded. A loop whose per-iteration crossing is a
scalar or a small `#[repr(C)]` record read out of storage the call already built is not a finding,
however many times it goes round.

### The scorer, measured against the Swift it replaced

`slopdesk-fuzzybench` is in the tree and is not a second implementation — it is a harness that runs
the door over every Swift path in the package (1333 candidates × 16 queries) and diffs the result
against the real `fzf --filter` binary. Release build, same corpus, same machine:

| path | ns per candidate | |
| --- | --- | --- |
| Swift `FuzzyMatcher` (deleted) | 5766 | |
| `slopdesk_fuzzy_score` (score + positions) | 3443 | 1.7× |
| `slopdesk_fuzzy_rank` (score only) | 2388 | **2.4×** |

Both doors: match-set identical to `fzf` on 16/16 queries, top-1 exact 16/16, 0 strict score
inversions over fzf's own order. This is the shape the boundary is cheapest in — a call per candidate
whose arguments are two short byte spans and whose answer is a scalar or twelve bytes — and it is
worth noting *why* the door beats the Swift it replaced rather than merely matching it: the DP is
`i32` in a flat `Vec` against Swift's `Int` in an `Array` with retain/release on the closure captures,
and the score-only path deletes fzf's phase 4 outright.

### The whole-document fold, measured

The liveness fold re-encodes and re-decodes the entire document on every call, which is the one
thing about that family worth measuring rather than asserting. Scratch release benchmark of
`slopdesk_ws_reconcile_panes`, NOT in the tree, on an M-series host — a document of N panes each
carrying its topology half and a fully-populated liveness half, reconciled against a capture of the
same N panes:

| panes | cells | settled (answers `0`) | moved (encodes) |
| --- | --- | --- | --- |
| 1 | 20 | 2.6 µs | 3.3 µs |
| 8 | 160 | 21.4 µs | 26.4 µs |
| 24 | 480 | 69.5 µs | 84.3 µs |
| 64 | 1280 | 216.6 µs | 261.5 µs |

The caller's cadence is a 500 ms backstop plus discrete session and agent-status events, coalesced
at depth 1. A 24-pane workspace therefore spends ~0.014% of a core on the settled path, and the
decode of the input cells — not the encode of the answer — is the bulk of it: the encode is the
~15 µs difference between the two columns, which is exactly what answering `0` saves.

One caller-side note the numbers do not show: `wsBytes` probes with a 4 KiB buffer, and a moved
24-pane answer is 16 KiB, so the MOVED path runs the door twice. That is the §4 retry working as
designed and it is still ~170 µs, but it is the first place to look if this ever shows up in a
trace.

### The retry that is not a second COPY but a second SEARCH

§4's retry is cheap when the door already holds its answer and the second call only copies it out.
It is not cheap when the door **derives** its answer by walking something large, because then the
retry re-walks it. `slopdesk_find_matches` is the case: it builds its answer by scanning every row of
the scrollback, so a short first guess costs a whole second scan of the buffer. Its fixed 128-record
guess meant that any query matching more than 128 rows paid for two full scans on every keystroke —
**3.52 ms per pane per keystroke instead of 1.83 ms.**

The fix is not a bigger constant. It is that the caller usually knows: typing NARROWS, so the
previous keystroke's match count is an exact upper bound after the first character
(`TerminalSearchController.recompute()` carries it; `GlobalSearchController.run` carries the widest
count across panes). A guess derived from the last answer beats any guess derived from a hunch.

So the rule §4 states — "guess generously, retry is the backstop" — needs a rider: **price the
retry by what the door does, not by what it returns.** A door that re-derives should either be given
a guess the caller can justify, or answer its size in a form that is cheaper than its content. The
same sweep found the opposite mistake in the same module elsewhere: a null-output PROBE, which is a
guaranteed double derivation rather than a merely possible one, and is banned for exactly this
reason.

### The null-output PROBE, and the four doors where it doubled real work

§4 makes `(NULL, 0)` a supported way to ask a door for its length, and for a door whose rule is a
table lookup that is the honest way to ask — `slopdesk_panel_simulator_key_code` and
`slopdesk_input_mode_reset` probe on purpose and should keep doing so. For a door whose rule is
WORK, the probe is not a size question at all: it runs the whole rule, throws the answer away, and
then runs it again. It is the retry above with the "merely possible" removed.

Four doors were being probed this way. Measured from Swift against the shipped `macos-arm64` slice,
`swiftc -O`, two runs agreeing:

| door | probed | guessed | what it was doing twice |
| --- | --- | --- | --- |
| `slopdesk_git_status` | 53.4 / 57.7 ms | 25.7 / 27.0 ms | libgit2 walks the worktree — per FSEvents tick per watched repo |
| `slopdesk_plaintext_strip` | 646 / 629 µs | 302 / 310 µs | the VT grammar over a 183 KB pane capture, per agent read |
| `slopdesk_annexb_to_avcc` | 501 / 475 µs | 265 / 234 µs | a 300 KB keyframe rewritten, PER FRAME |
| `slopdesk_annexb_split` | — | — | the same walk over the same buffer, per access unit |

What makes this class worth its own entry is that **no test can see it**. Both calls agree; every
answer is correct; the suites are green either way. The only trace is a git line that lands a beat
late and a phone mirror that drops frames on a busy host — which reads as a device problem, not as a
doubled call. `check-supervisor.sh` bans the probe by name on these four and separately requires
each fixed site to still carry its first guess, because a regression that deletes the guess is the
same regression arriving by a different edit.

### The loop-shaped crossing — a cost class, and mostly a false alarm

A door asked once per member of a collection the far side already holds contiguous is a defect no
test can be red about: every answer is correct, both sides are self-consistent, and the only trace is
the frame rate. A sweep on 2026-08-22 found thirty-seven of them and none had ever been reported.

**Then they were priced, and most of them evaporated.** Read §4c's first table before this list: at
1 ns for a scalar door, a loop of `n` scalar crossings costs `n` nanoseconds and is not a defect at
all. What survives pricing is a loop whose body **allocates** or **re-derives**:

1. **The positional walk that re-derives.** The settings page crossed as a group count, then a title,
   a timing and a row count per group, then six doors per row: `1 + 3G + 6R`. The crossings were
   never the problem — each of those doors re-derived the *whole page* to reach one member, filtering
   the flat table into a fresh list and then that group's rows into a second, so laying out Appearance
   did ~166 filters and ~330 allocations to read 23 `&'static` rows. **If the near side wants the
   whole thing, the whole thing is what crosses.**
2. **The repeated marshalling of one unchanged answer.** A held-modifier key-up encoded the same
   `InputEvent` three times to send it three times: three `Data` allocations at ~227 ns each where
   one would do. Read the gate once, encode once, send the same bytes N times — ~455 ns a gesture,
   and the code now does what its own comment already claimed.
3. **The answer nobody reads.** `for chunk in chunks { _ = tracker.consume(chunk) }` pays an
   allocation per chunk for a return value assigned to `_`. The fix is a side-effect-only entry
   point, not a batched door.

And the counter-rule, which did most of the work here: **a loop is not worth a door until the
arithmetic says so.** Of the sweep's top-ranked cluster, four of five findings were refuted on
measurement and every refutation held. The #1-ranked site cost 4.98 ns against a 190 ns call on the
same datagram. The blob chunker caps at 42 chunks and its whole achievable win was ~15 µs against a
*deliberate* 42 ms inter-chunk pace. Each of those doors would have bought a rounding error and a
permanent second way to ask one question, which `check-ffi-doors.py` penalises for the reason §8
gives. When the far side does keep both forms, say in the header which one a row asks and which one a
list asks — `slopdesk_block_statuses` sits beside `slopdesk_block_status` on exactly that basis.

What does NOT flatten, even when the pricing says widen: bytes that have to land in a buffer of their
own on the near side regardless. A retained replay history runs to 256 MiB, so folding every
message's payload into one delivery buys `n` saved crossings with a whole extra copy of the history.
The metadata crosses whole (`n + 2` from `3n + 1`); the payloads stay per-message.

### Where the sweep's real defects turned out to be: NOT at the boundary

Worth recording plainly, because the sweep was a *crossing* audit and its three biggest findings were
not crossings at all. All three are the same shape — **a value that reads like a field and is in fact
a projection** — and all three sat behind a `var` or a computed property, so nothing in the type
system, the tests or `make lint` could see them.

1. **`HostWorkspaceMirror.topology`, read once per sidebar ROW.** It copies the entire entry map and
   re-runs `WorkspaceTopology.init(entries:)` over every cell. Measured in a scratch `swiftc -O`
   harness, the dictionary copy alone is 6.4 µs at 12 panes and 23.9 µs at 48; the per-cell walk takes
   those to 10.3 µs and 37.9 µs, which is a FLOOR — the real projection also rebuilds every split
   tree, spec, MRU and closed tab. `SidebarRowPresentation.reading(...)` reached it through
   `store.syncInputArmed` once per row, so a sidebar of R rows paid R projections per render pass:
   ~126 µs at 12 rows, ~1.8 ms at 48. **O(P²), and the largest number in the whole audit.** The fix is
   `WorkspaceStore.mirroredTopology`, memoized on `workspaceMirrorRevision` — the key `tree` already
   trusted. No door would have helped; the crossings inside it are nanoseconds.
2. **`WorkspaceBindingRegistry.allBindings` as a computed `var`.** `resolvedChordTable` walked it
   once per key event and called `binding(for:)` per row, each of which read it again: **86 fresh
   85-element arrays per keystroke**, each retaining four strings per element. 128 µs of pure
   allocation per key event, on the global `.keyDown` monitor and on `TerminalKeyInterceptor`'s
   default resolver — every key typed into any pane. A stored `let`, a `byAction` index and a held
   chord table take it to 5.0 ns.
3. **The settings catalog rebuilt per query.** Same shape one register down: the filter re-marshalled
   every row's strings to answer a question about which rows survive.

The lesson for this document is not "memoize things". It is that **the pricing table cuts both
ways**: it refuted two-thirds of the sweep's crossing-count findings, and the budget those findings
would have spent went to three defects that a crossing count could never have surfaced. Rank by
allocations and re-derivations, and the ranking finds the same defect whichever side of the boundary
it happens to be on.

## 4d. The descriptor convention, tried and rejected

§4 copies its arguments. That is wasteful for one that is large and read once, and the FEC boundary
is where it stopped being theoretical: flattening a frame's eight 1200-byte fragments into one span
measured **0.51 µs**, against **0.24 µs** for the parity computation it was feeding. The marshalling
cost more than the codec. The obvious fix is to pass descriptors instead —

```text
u32 count | for each: u64 address | u64 length      (u64::MAX = absent)
```

— 132 bytes rather than 9.6 KB, with the callee reading each fragment where Swift already has it.
It was built, measured and reverted. **It cannot be done in O(1) stack, and this path needs O(1).**

`withUnsafeBytes` guarantees its pointer only for the body of its closure, so describing N fragments
means N NESTED closures with the call made from the innermost. A large HEVC keyframe packetizes into
thousands of fragments, and the production send and receive paths run on threads with ~512 KB
stacks. `Tests/SlopDeskVideoProtocolTests/RustFECLargeFrameStackTests.swift` pins exactly this: it
runs `parity` and `recover` over 3000 fragments on a deliberately 512 KB stack, and the descriptor
build died there with SIGBUS. That test predates the Rust port — the Swift codec had the same bug
once — which is the useful part of the story: the shape is a trap independent of which language is
underneath.

Escaping the pointer out of the closure is not the way around it. A `Data` of 14 bytes or fewer
stores its bytes INSIDE the struct, so the address would point into a temporary; the guarantee
Swift declines to give is one it genuinely cannot.

What survived from the attempt is on the ANSWER side, which has no such constraint because the
callee owns its own allocation: `slopdesk_video_fec_recover` now answers with the REPAIRS — a list
as long as the data list in which only the holes this call closed carry bytes — rather than handing
back a copy of every fragment the caller already had. That is where the measured win actually was.

## 5. Why the `unsafe` is a crate and not an attribute

`rust/slopdesk-ffi` is the second of the three crates permitted to write `unsafe` (`docs/51` §6.15
covers the first, `rust/slopdesk-posix`; `rust/slopdesk-gfsimd` is the third, and
`docs/DECISIONS.md` carries the measurements that bought it). They are separate because their
obligations are: posix argues about syscalls; ffi argues about one question repeated — *is this
`(ptr, len)` live for the duration of this call?* — and gfsimd argues about one narrower question
still, *does this 16-byte load stay inside its chunk?*, which does not name a language boundary at
all. Swift answers ffi's at the call site with `withUnsafeBytes`, whose scope is exactly this call,
and the Swift wrapper is the only caller.

Everything past the marshalling runs in a crate that `forbid`s unsafe. So a bug in the domain logic
cannot be a memory bug — it is a wrong answer, which tests catch.

Two rules keep that true, both gated in `check-supervisor.sh`:

- **No `extern "C"` outside `rust/slopdesk-ffi`.** A C entry point in a domain crate would put
  argument marshalling next to the logic it marshals — how a pointer bug becomes a terminal bug —
  and would force that crate off `forbid`.
- **No decision in `src/lib.rs`.** No branch that means something, no default that encodes policy,
  no error mapped to a different error. If a change here needs a paragraph about terminals, it
  belongs in the wrapped crate, where the compiler still forbids unsafe.

## 6. The Swift side

`Sources/SlopDeskTransport/AltScreenCutScanner.swift` is the reference shape and is deliberately
boring: two nested `withUnsafeBytes` and nothing between them, since those scopes *are* the safety
contract; a first guess at the size, generous by an order of magnitude; a retry that exists to be
correct rather than to be used. The public signature is unchanged from the Swift implementation it
replaced, so its callers and its tests did not move — which is what makes "delete the original in
the same change" a diff a reviewer can check.

### Where the line falls when the module is a vocabulary

`SlopDeskAgentDetect` forced the question the other two ports did not have to answer: an agent's
status is an `enum` a SwiftUI `switch` reads, so *something* stays in Swift. The line, and it is
gated:

- **The case list stays, for the cases a view still reads.** `AgentKind`, `ClaudeStatus`,
  `AgentScreenState`, `AgentStatusKind`. Declaring the same cases twice is not two implementations —
  it is one vocabulary in two type systems, and marshalling an enum through C would buy nothing.
  `ClaudeSignal` and `ClaudeHookEvent` were on that list until the fusion moved: no `switch` in a
  view ever read them, and once the detector's doors took the raw input, the only thing left for a
  Swift signal case to do was be rebuilt on the far side. They are gone.
- **Every table and every walk moves.** The alias table, the wrapper basenames, the keystroke
  classes, the rollup rank, the display labels, the temporal hold's counters, the job-identify
  ladder, the 900-line status machine. `ClaudeStatus.urgency` moved for exactly this reason: it
  looks like a property and is really a total order the wire depends on.
- **A one-line identity predicate stays.** `isBlocked` is `self == .needsPermission`; routing that
  through C would add a boundary crossing to restate the case list.

The case lists are then a CONTRACT, because what crosses is a discriminant. `check-supervisor.sh`
compares the Swift case counts against `AgentKind::ALL` and `ClaudeStatus::ALL`, so an enum that
grows or reorders a case fails the build rather than reporting `working` for `blocked`.

`PaneLiveness` is the same line drawn one level up, and it is worth naming because nothing was
deleted and the port is still complete. The Swift `struct` stays: it is what `PaneLiveness+Capture`
builds off a live `MuxChannelSession`, what `HostWorkspaceMirror` publishes and what a view reads —
a vocabulary by the rule above. What went is every BODY behind it. `entries()`, `init?(paneID:)`,
`merge(paneLiveness:)`, `markPaneDead(_:)` and `reconcile(captured:)` are now argument marshalling
around `slopdesk-wire`'s `document::liveness`, and the ~25-line classify-and-reap loop that used to
live in `HostWorkspaceDocument` is gone with them. Every public signature is unchanged, so
`LoopbackWorkspaceDocument` and the ~25 `merge(paneLiveness:)` call sites in the host tests did not
move — which is the same "a diff a reviewer can check" property, in a port whose file count is
unchanged.

### Two shapes the agent module added

**One string buffer, not one pointer each — retired, and worth reading for why.** A foreground job's
process carried three optional strings and a hook event carried six; six `(ptr, len)` pairs is six
nested `withUnsafeBytes` per call, so the caller concatenated into one buffer and passed
`(offset, len, present)` spans into it. Both halves are gone now — the hook body goes over raw, and
the job is not assembled across the boundary at all — so no door takes a span today. The rule the
shape encoded is the part to keep: an out-of-range span reads as ABSENT because this is untrusted
input, and `present == false` (`nil`) is not `present == true, len == 0` (the empty string).

**A staged handle for a shape too big to flatten — and the question that dissolved it.** A foreground
job is a pgid plus N processes, each with three optional strings and a whole argv, so it was built
across the boundary one item at a time: `job_new` → `push_process` / `push_argv` → `identify` → read
the answer slot → `free`, plus a C function pointer calling back for symlink resolution. Six doors and
a trampoline, all because SWIFT owned the syscalls that produced the job.

It owns none of them now (`rust/slopdesk-posix/src/proc.rs`), so both halves of the question live on one
side and `slopdesk_pty_foreground_agent` asks it in a single call — N+1 crossings per poll became one,
and the resolver callback became a direct call. **Before staging a shape, ask which side is producing
it.** Staging is the right answer for a shape the CALLER genuinely owns — the replay buffer's input
slot still is one — and the wrong answer for a shape the caller only assembled because it was holding
the wrong end of the port.

**A slot mask, where one fold owes several answers.** The pane detector's folds owe up to four
messages of three different shapes. A single flat answer buffer encoding all four would be a second
wire format nobody asked for, so a fold returns a BITMASK naming the slots it filled and the named
slots are read back off the handle one at a time (`slopdesk_agent_detector_emit_*`). The emission
lives on the handle until the next fold replaces it, which is why the Swift face reads it
immediately and unconditionally rather than lazily. A fold on a null handle answers 0, which is
indistinguishable from a fold that owed nothing — and that is the correct answer for both.

### What it cost

Nine Swift files, 2,152 lines → 1,236, of which ~260 is the marshalling. The 135 tests in
`SlopDeskAgentDetectTests` are unchanged and now exercise `rust/slopdesk-agent`.

The FUSION followed on 2026-08-17: `ClaudePaneDetector` went 617 lines → 300, of which none is
policy. It found a divergence the same way the first pass did — the two dedupe anchors are NOT
symmetric, and only reading both sides against the tests made that legible. A never-emitted STATUS
stream and a status of none are different frames, so that anchor compares optionals; a never-emitted
INTENT stream and a cleared intent are the same silence, so that one collapses both sides to the
empty string. Writing the second the way the first reads gave a pane that never had an intent an
empty type-36 clear frame, telling every client to blank a row it had never filled.

The port found a live bug, which is the honest argument for doing it: `process::basename` used
`rsplit('/').next()` where Swift used `split(separator:).last`, so `/usr/local/bin/claude/` — a
trailing slash, which is just untidy spelling of an exec'd path — read as NOT claude in Rust and as
claude in Swift. Two implementations had disagreed for a month and neither side could see it. It is
now one function with the Swift test's own case pinned to it.

## 7. Adding an entry point

1. Write the logic in a domain crate. It stays `forbid(unsafe_code)`.
2. Add the wrapper to `rust/slopdesk-ffi/src/lib.rs` — marshalling only — with a test that calls
   it through the raw pointers the way Swift does.
3. Declare it in `include/slopdesk_ffi.h`. Nothing else to list: `build-ffi.sh` reads
   `REQUIRED_SYMBOLS` out of the header and checks every slice carries them, so a header that
   drifts from the library fails at `make ffi` rather than at app link.
4. If the domain crate is new to the shim, give it a `path = "../…"` edge — that is what puts it in
   the stamp's closure (§3).
5. Write the Swift wrapper, **delete the Swift implementation it replaces**, and leave that
   module's existing tests pointing at the same public signature.
6. **If step 5 could not delete it, pin it** — see §8. A port that lands beside its original with no
   pin is the single most reliable way this repo has produced bugs.
7. `make ffi && make lint && make test`.

## 8. The drift class, and why the ratchet has never caught one

Every cross-language bug this project has found has the same shape: **a decision implemented in both
languages, where the two disagree, and the disagreement is invisible because only one side is on the
hot path.** The table below is the catalogue. Most rows were live defects when found; the rest agree
today and are held together by nothing but the week they were written in. (There is no count in this
sentence on purpose — the one that used to be here said "eight" while the table said ten, which is
the same defect this section is about, one register up.)

| Pair | Who was right | What the user lost |
| --- | --- | --- |
| `WorkspaceIntent.encode` vs `intent::put_blob` | Rust | a frame that mis-splits at the decoder |
| `SplitNode+Codable` unknown `axis`/`id` | Rust | **the entire workspace**, to one typo |
| `persist::decode_raw_node` id-less splits | Swift | two dividers moving as one |
| `TreeWorkspace.normalized` vs `workspace::normalized` | — | launch-time and gesture-time repair disagree — **ported 2026-08-20** |
| the 15 MiB opaque cap, spelled **three** times | — | a silently truncated `git diff` rendered as complete — **ratcheted 2026-08-22**; `slopdesk-probe` is a spawned `[[bin]]`, so a door was never available and the gate's own doctrine picks the ratchet |
| `templates::repaired` vs `TemplateNode+Codable`, and the two built-in tables | — | agrees today — **pinned 2026-08-20**; the row said "a security rule written twice" and was wrong |
| `persist::derived_split_id` vs `SplitNodeID()` | Rust | divider weights reset on every relaunch |
| `detectionText` vs `detect::detection_text` | Rust | dead Swift, plus a third spelling of the join |
| `PaneSpec+Codable` `userRenamed` vs `decode_spec` | Rust | **the entire workspace**, to a non-boolean flag |
| `VideoEndpoint`'s synthesized `Codable` vs `decode_video` | Rust | **the entire workspace**, to a hand-edited window id |
| `ScreenPaths.requestSocket` vs `screenwire::socket_path` | Rust | screend "not running" for any process with its own `$TMPDIR` — **ported 2026-08-22** |
| `SupervisorPaths.controlSocket` vs `superd::paths` | Rust | the same silence, plus a `SLOPDESK_SUPERD_DIR` hostd had never heard of — **ported 2026-08-22** |
| `CodeBridgeServer.contains` vs `MetadataResponseBuilder` vs `files::read_session` | — | **three** answers to "is this path confined", disagreeing on `..`, on the root itself and on `/` — **ported 2026-08-22** |
| `completions::SUBCOMMANDS` vs `printUsage()` vs the dispatch `switch` | — | six verbs that tab-completed and then exited 2 — **ported 2026-08-22** |
| `AndroidLogLevel` vs androidd's level array | Rust | five letters against six: `Fatal` was a filter the menu could not produce — **ported 2026-08-22** |
| `qp_control`/`recovery_idr` defaults vs their Swift faces | — | eleven tuned numbers that would encode at the old operating point in silence — **ported 2026-08-22** |
| `TreeWorkspaceDefaults` vs the seeded pane names | — | a fresh-workspace shape test passing against a default the crate stopped producing — **ported 2026-08-22** |
| `TerminalPreferences.CursorStyle.displayName` vs `settings_catalog` | — | one setting, two words ("Hollow" / "Block (hollow)"), a scroll apart on one page — **ported 2026-08-22** |
| `CodeSidebarPageDressing`'s `@font-face` vs `codeseed`'s seeded stack | — | agrees today; a disagreement falls silently through to the system mono — **ratcheted 2026-08-22**, and the near side became `slopdesk-codepanel` on **2026-08-23**, so the gate now compares two Rust crates that still deliberately share no code |
| `NewTabPosition.insertionIndex` vs `session::NewTabPosition` | Rust | the Swift copy answered only its own four test cases; ⌘T has always gone through `tree_ops` — **ported 2026-08-22** |
| `PaneKind.canReceiveText` vs `PaneKind::can_receive_text` | — | half a classification asked through a door and half transcribed: a third kind splits the broadcast recipient set from the restore filter, both suites green — **ported 2026-08-22** |
| `PortValidation.port` vs `listen::port` | — | a range predicate in Rust and the cast in Swift, agreeing only because `u16`'s range happens to BE the accepted range — **ported 2026-08-22** |
| `session::VideoPaneModes` vs `PaneSpec`'s latched modes | Swift | five public fields with no methods, no callers, no tests and no re-export, beside a Swift comment asserting no counterpart existed — **deleted 2026-08-22** |
| `WorkspaceStateCodec.decodeBool`/`encodeI32` vs `state_codec`'s | — | `!= 0` and `UInt32(bitPattern:)` composed on the near side from doors written for exactly that and left uncalled for a month — **ported 2026-08-22** |
| `CommandCompletionNotifier`'s bucket defaults vs `notify::RateLimiter` | — | the anti-flood burst and refill rate as a Swift default argument, of which the looser spelling is always the one that runs — **ported 2026-08-22** |
| `SessionTemplateEngine.launchBytes` vs `templates::keystrokes` | Swift | the two disagreed on a whitespace-only cwd — Swift read it as "no directory", the crate gated it untrimmed and emitted `cd '  '` — **ported 2026-08-22**, and the emptiness rule now has one author |
| `VideoEncoder.qpCeiling` vs `adaptive_qp::adaptive_max_qp` | — | two rules whose TAILS were one rule: the same linear ramp between a sharp and a coarse quantiser, one driven by the change fraction and one by the budget's bits per pixel, so a side-by-side reading found them plainly different and was right about everything except the last step — **ported 2026-08-22** |
| `WorkspaceKey.objectIDBytes`/`<` vs the wire document's `BTreeMap` order | — | the emission order derived a second time; two orders never disagree loudly, they RE-EMIT — a snapshot stops being byte-deterministic and a diff churns on map iteration order, which reads downstream exactly like a real change — **ported 2026-08-22** |
| `RailRowsMemo.titledByProcess` vs `rail_title::title_rung` | — | a Swift transcription of the title chain's escape order whose own doc comment said "Mirrors `RailRowsBuilder.rowTitle`" — a comment as the only thing holding two implementations together — **ported 2026-08-22** |
| `HostServiceProcess.searchDirectories` vs `toolchain::locate_tool` | Rust | the two agreed on the ORDER and had quietly stopped agreeing on what makes a candidate executable: `FileManager.isExecutableFile` is `access(X_OK)`, which is TRUE for a DIRECTORY, so a directory wearing a tool's name on `PATH` reached `posix_spawn`; `docs/46` had named the Swift copy canonical and the Rust one "mirrored" — **ported 2026-08-22** |
| the device panels' row predicate, spelled **six** times | — | `localizedCaseInsensitiveContains` over "does any field of this row hold what was typed", in `AndroidPresentation` twice and once in each of the four simulator views — only ONE of the six was ever reached by a test, which is this class in its purest form: the copy a test holds is not the copy the other shell runs — **ported 2026-08-22** onto the door the keybindings editor already had |
| `StaticIDRDecider.shouldReencode` vs `recovery_routing::StaticIdrDecider::should_reencode` | — | the quiet window, the recovery override and the synthetic-only heartbeat, written twice, with the Swift copy the one on the host's per-timer-tick path — **ported 2026-08-22**; the four anchors are the whole state, so they cross as scalars and the Rust half stopped being unreachable |
| `AgentBadgeGates.allOn` / `CommandBadgeGates.allOn` vs `badge::Gates::ALL_ON` | — | one all-on baseline asserted independently by two Swift structs and never consulted by the ungated ladder, so no input could reach both — **ported 2026-08-22** |
| `AudioJitterBuffer.pull(frameCount:)` vs `audio_jitter::pull_frames` | — | was **UNREACHED PORT — the Rust half has no caller**, and the drift is moot now: the near side that would have called it is gone. `rust/slopdesk-audio-out` drives the stage, and Swift asks for a PLAYER — **ported 2026-08-23** |
| `VideoClientSessionLogic.route(channel:data:mediaFlowing:)` vs `client_session::route_datagram` | — | **UNREACHED PORT — the Rust half has no caller.** The six-way table and the drop-vs-ignore split, written twice |
| `SimulatorScreenLayout`'s hand-rolled clamp vs `slopdesk_panel_clamped_device_point` | Rust | a drag off the right edge of a 200-point frame reported `x = 200` into a surface whose columns are `0..<200`, so the host scaled it off the far side of the framebuffer; the Android lane had gone through the door since the door existed and the simulator lane spelled it TWICE — **ported 2026-08-22**, confirmed by probe before anything was touched: `(9999, 9999)` answered `(200.0, 400.0)` by hand and `(199, 399)` by the rule |
| `VideoPreferences`' four QP/FEC defaults vs `qp_control` and `adaptive_fec` | — | `26`, `40`, `1`, `5` as literals directly beneath the doc comment forbidding literals there, against doors that already vended every one; a retune leaves Settings SHOWING the old number, and "reset to default" then WRITES it into the overlay as an explicit override — the gesture meant to get out of the daemon's way is the one that pins it to a value nobody chose — **ported 2026-08-22** |
| `EnvConfig.int`/`.double` and two private copies vs the reject rule | — | the same validate-then-default written three times, of which the generic pair had ZERO production callers; `FPSGovernor`'s copy also read `ProcessInfo.processInfo.environment` directly, bypassing the settings overlay, so every governor tunable set in Settings was written, persisted, shown as active and never read — **ported 2026-08-22** to `slopdesk_abr_validated_int`/`_double`, which is the REJECT reading and deliberately not the quantiser CLAMP |
| `AudioStreamDecoder.decodePCM` vs `audio_wire::decode_pcm_s16le` | — | the same loop byte for byte, down to the same ragged-tail drop, with the Rust half reached by nothing but its own tests; the pair cannot be caught disagreeing, because a full-scale sample is `-1.0` either way and a drifted normalisation is just audio slightly quieter than it should be — **ported 2026-08-22**, the Vec-returning Rust form deleted rather than kept beside the in-place one |
| `ScreenClient.exchange`'s length prefix vs `screenwire::encode_reply` | — | four untrusted bytes shifted together by hand, checked against a 64 MiB ceiling re-spelled one file over, deciding how much this process allocates on a peer's say-so, while the encoder for that exact layout was already Rust's — **ported 2026-08-22**, and `ScreenWire.maximumFrameBytes` stopped being the second spelling of the ceiling with it |
| `SupervisorFrame.read`'s `count != .max` vs `slopdesk_supervisor_body_length`'s refusal | — | **a live ONE-language defect, not a drift**: the door refused correctly and the guard never fired, in any build, for any input — **fixed 2026-08-22**, and it is in this table because it was found while porting the row above it and because it is the reason that row's door refuses the way it does |

**A correction to "the far side is a separately-shipped binary, so a door is not available."** That
sentence appears twice in this section, and it is only half a rule. It is a claim about the FAR side,
and it says nothing whatever about the near one.

It is right about the opaque cap: hostd **forks** `slopdesk-probe`, so both ends of that pair are
processes, no linked artifact is involved, and a ratchet really is the only instrument. It was wrong
about the screend frame ceiling, where the same words were used to justify spelling 64 MiB in Swift.
screend is a separately-shipped binary, yes — and hostd's client end is *linked Swift over the same
wire crate*, encoding its requests through a door a few lines above the line that spelled the ceiling
by hand. The ceiling, the length-prefix width and the header width are `slopdesk_screen_constant`
now, and screend's copies are pinned by a cargo test inside `slopdesk-screenwire` rather than by a
`sed` of its source line.

**The rule, stated so it cannot be misread again: a door is available whenever the side that is
DOUBLING the rule can link the crate. Ask it of that side, per boundary, never of the pair.** A wire
crate shared by a daemon and a linked client has two boundaries, not one, and they take different
instruments: the daemon's copy is held by the crate's own tests, and the client's copy stops existing.
"Both ends must be able to link it" is a much stronger condition than anything the port needed, and it
is the condition that sentence was silently being read as.

What is left for the ratchet changes shape with it, and that is the tell that the port was the right
call: the gate no longer asks *"do the two numbers agree"* — a question that only has an answer while
there are two numbers — but *"is there still only one"*.

**The template row was stale in both directions, and how it was stale is itself the lesson.** It
named a *security* rule — the literal `cd` line that must never reach the token parser — and that
rule has not been doubled since `templates::keystrokes` crossed as `slopdesk_ws_launch_keystrokes`;
`LaunchPresetEngine.keystrokes` is a wrapper with no logic in it, and its own doc comment says so.
Meanwhile the things that WERE doubled went unnamed: the layout repair (`TemplateNode::repaired`
against `TemplateNode.init(from:)`) and the two built-in tables, whose fixed UUIDs exist precisely so
a re-seed matches an existing row rather than appending a second copy of it — sixteen bytes per row,
in two languages, which nothing in this repo could have compared. A row in this table is a claim with
no gate behind it, exactly like the comments the last bullet of this section warns about, and it
decayed the same way: the port moved and the row did not.

Both halves are now pinned by `SessionTemplateRepairDifferentialTests` (below). What is deliberately
NOT ported, so the next reader does not have to re-derive it: the preset EXPANSION —
`LaunchPresetEngine.plan` — stays in Swift. It copies three fields of a preset into two pane specs
and defers its one real rule to `keystrokes`, which already crosses, so a door for it would marshal
a whole preset to compare two spellings of an assignment. The Swift `SessionTemplate` decoder is
likewise staying: it is `Codable` and it is what the device-preferences file is made of, so this is
`docs/55` §7 step 6's case rather than an unfinished port, and the differential is the whole of what
is owed.

**This paragraph used to say `templates::plan` and `TemplatePane::keystrokes` "have no caller and
stay that way", and that reading of its own rule was wrong.** It correctly refused to build a door
and then let the far half sit there anyway — a Rust `plan`, a `LaunchPlan` and a `PaneLaunch` reached
by nothing but their own two tests. An unreached port is not a safer half-measure than an unported
one, it is a worse one: the pair could not be caught disagreeing, because no input ever reached both
copies, and neither `dead_code` (it cannot see a `pub` item in a library crate) nor
`make lint-ffi-doors` (it audits doors, and this was not one) could see it either. It had already
drifted — `TemplatePane::keystrokes` hardcoded `None` for the cwd and so could not emit the `cd` line
its Swift counterpart takes a directory in order to write. All four were deleted on 2026-08-22.
**"Do not port this" and "keep an unreachable copy of it" are different instructions**, and the
second is never what the first meant.

### The two unreached ports left open, and the hazard one of them is already carrying

Two rows above are marked UNREACHED PORT rather than ported. Both are left that way deliberately —
neither is on a path where the cost has been measured — but an unreached port is a debt, not a
resting state, so what the next person needs is written here rather than rediscovered.

⚠️ **`pull_frames` has already drifted, and the drift is an overflow.** Swift allocates
`max(0, frameCount) * channels`; Rust takes `frame_count: usize` and writes `vec![0.0; frame_count *
self.channels]`. A negative frame count is a benign empty array on one side and, converted at a
boundary that does not exist yet, a wrapped `usize` on the other — an allocation the machine cannot
serve, from an argument the Swift copy was written to absorb. **Neither side can catch the other**:
no input reaches both, both suites are green, and the clamp is not a rule either half states out
loud, it is a `max` inside an allocation. Whoever builds `slopdesk_audio_stage_pull_frames` under §4's
length-then-fill starts by deciding whose clamp is the rule — and the answer has to be one of them,
not "the caller will pass a sane number", because the caller is the diagnostic surface and the
diagnostic surface is where a negative number comes from.

`route_datagram` wants §6's arena treatment and not a scalar door, which is why it is still open:
its `RoutedDatagram` carries decoded payloads, so the shape that crosses is a variable list of
records with bytes hanging off them — `slopdesk_link_scan`'s handle-over-arena, not
`slopdesk_recovery_should_escalate_to_idr`'s seven scalars. A scalar door for the six-way tag would
be the wrong half: the tag is the cheap part, and porting only the cheap part is how a pair ends up
agreeing about the routing and disagreeing about the payload.

### The pair that is not cross-LANGUAGE at all

⚠️ **The scalar field codec is written twice in RUST.** `slopdesk_wire::document::codec` and
`slopdesk_workspace::state_codec` are two implementations of the same encoding, in two crates that do
not depend on each other, and `rust/slopdesk-ffi/tests/snapshot_codec_parity.rs` pins only the
snapshot GRAMMAR — it never touches the scalar leaves. They agree today (`encode_i32` reaches the
same bytes via `to_be_bytes` against the `u32` cast; `encode_uuid_list` via `try_from().unwrap_or`
against `.min()`), with one already-divergent shape: `encode_string` clamps by two different
implementations, `clamp_utf8` against a hand-rolled boundary walk-back.

Found 2026-08-22 and **pinned the same day** by `rust/slopdesk-ffi/tests/scalar_codec_parity.rs`:
every leaf that exists on both sides, in both directions — identical bytes out of the two encoders,
and each decoder reading the other's bytes to the same value. Three arms are worth naming because a
round-trip test could not have reached them:

- **the refusal widths.** Two codecs can agree perfectly on well-formed input and still disagree
  about a truncated field — which is exactly what a peer of another version writes. Every leaf is
  swept at every width from 0 to 20 and both sides must refuse the same ones.
- **the non-canonical bool.** Both must read "any non-zero byte is true". A side spelling it `== 1`
  answers false for every byte a peer sends that is neither 0 nor 1, while the other answers true,
  and *no decode fails on either side*. All 256 bytes are compared. This is the arm the break-test
  used, and it is the only one that fired.
- **the two clamps.** `encode_string` still has two implementations — the wire half walks forward
  through `char_indices`, the workspace half walks backward from the limit — held against each other
  at every limit from 0 to past the end, over strings whose multi-byte scalars straddle every offset
  in that range, plus an assertion that whatever they agree on is still valid UTF-8. Agreement alone
  would not catch a clamp that cut mid-scalar on *both* sides at once.

The pair is not collapsed to one implementation, and that is the honest state rather than the
finished one: the arrow points wire → workspace and `state_codec` is below the fork, so neither can
`use` the other without a cycle, and merging them is a crate-graph change with its own argument to
make. `slopdesk-ffi` is the only crate that depends on both, which is why the differential lives
there and can only live there.

It is in this section because **every argument above applies unchanged when both copies are Rust** —
the drift class is "one decision, two implementations, nobody diffs them", and the language boundary
was only ever the most common place for that to happen, never the cause. A reader who takes this
section to be about Swift will not look here.

### The pair that drifted because the two halves asked the SAME question of different inputs

The encoder's quantiser ceiling and the adaptive per-frame quantiser both interpolate linearly
between a SHARP end and a COARSE end. `adaptive_qp::adaptive_max_qp` had done it in Rust since the
crate landed, driven by the per-frame change fraction; `VideoEncoder.qpCeiling` did it in Swift,
driven by the budget's bits per pixel per frame. Neither knew the other was there, and nothing could
have told them apart by name: one takes a *fraction of the picture that changed*, the other a
*density of bits the link affords*, and only after both are normalised onto the band is it visible
that the remaining arithmetic is one line spelled twice.

That is the shape §8 warns about, arriving by a route the ratchets were not watching. The usual
drift pair is one rule and two transcriptions of it. This was two rules whose *tails* were the same
rule, so a reviewer comparing the two functions side by side would have found them plainly
different — and been right about everything except the last step.

It went through `slopdesk_video_qp_ceiling`, which mapped the density onto the band and handed the
interpolation to `adaptive_max_qp` unchanged, while the six hardware-tuned numbers that had
surrounded the Swift copy — the sharp quantiser, the two density knees, and the drop-relief attack,
hold and decay — arrived on `slopdesk_video_qp_ceiling_config_default`. **Both doors are gone as of
increment 92, and their absence is the better end state rather than a regression.** The whole
encoder state machine moved to `slopdesk_video::encoder_state`, which calls `encoder_ceiling`
directly; a door exists to let the OTHER language ask, and there is no longer another language
asking. The fold this section is about is untouched — it is one ramp in one module, which was always
the point — and `hevc-codec-is-rusts` in `rust/slopdesk-invariants` keeps it from being respelled in
Swift, where `check-supervisor.sh`'s section 1 used to.

Folding the two together introduced exactly one behavioural question, and it is worth recording
because it is the general one: the Swift rounded the *interpolated ceiling*, the shared ramp rounds
the *interpolated offset* and adds it to the sharp end. Those are the same number only if rounding
distributes over that addition, which it does here because the sharp end is an integer — but "it
does here" is not an argument, so `rounding_the_sum_agrees_with_rounding_the_ramp` sweeps the whole
band and proves it, rather than asserting it at three points.

The refusals answer the COARSE end rather than a sentinel, because there is nothing a sentinel could
be mistaken for: a degenerate picture, cadence or budget, an inverted band or an inverted pair of
knees all mean *the encoder should coarsen rather than drop a frame it cannot fit*, which is the
safe reading and also the only reading the caller could act on.

### The pair whose cost was the argument AGAINST fixing it

CoreGraphics puts two phase fields on a scroll event and gives them different encodings. The scroll
field is a bit set — began 1, changed 2, ended 4, cancelled 8, a finger merely resting 128 — and the
momentum field is a plain ordinal, so ITS end is 3. A three is a *changed* in one field and an *end*
in the other, and nothing about either number says which field it came from. `NSEvent.Phase`, which
is where both are read from, is a THIRD encoding again: its ended is `1 << 3`.

Those ten numbers were spelled in four places across two languages — a private block of constants in
`client_gestures`, the reprojector's `of_platform`, the phone's touch translation, and the Mac
client's view — and two of the four read different sets of them.

This sweep initially declined to fix it, and the reasoning is worth recording because it was wrong
in an instructive way. §4c prices a crossing at about a nanosecond and warns that a crossing COUNT
is not a reason to build a door; the Swift being replaced here was five branches, so the port buys
nothing and the honest measurement said so. But §8 is not §4c. A rule two languages spell
differently is a defect at zero calls per second, and the pricing table's answer — that the door and
the branches cost the same — is not an argument against the port, it is the observation that the
port is FREE. The cost analysis was correct and irrelevant. When those two sections point in
opposite directions, §8 wins, because §4c is about which shape to give a crossing and §8 is about
whether there may be two answers at all.

The mapping is now `client_gestures`'s, the reprojector reads the same constants rather than
matching literals, and the mask crosses as its raw bits. Passing the bits verbatim rather than a
case index is the point and not an economy: an index would need a table on the Swift side to
produce, which is the table the door exists to remove.

Verified rather than asserted, which a free port can afford: the two entries were differentially
checked from Swift against the deleted Swift verbatim, over all 256 masks × both fields — 512
comparisons, zero mismatches, twice, through the linked release archive. The `NSEvent.Phase` bit
values the mapping assumes were read out of the live framework at runtime rather than copied from a
header, and all six agree.

### The knob that was found by the gate written for its neighbours

The encoder's `SLOPDESK_MAX_QP`, `_CONST_QP` and `_CRISP_QP` each hand-rolled a parse that REJECTED
an out-of-range value to the knob's default, where `slopdesk_qp_clamped_int` — which every other
quantiser knob already goes through — CLAMPS it. One rule, two answers, and the pair had been
*documented* rather than resolved: `QPController.envInt`'s comment says clamping is "deliberate, and
distinct from" the other reading, which is the shape §8 calls the argument that lets a pair live for
a year.

It resolves toward clamping, because rejecting silently INVERTS the request. `SLOPDESK_MAX_QP=0`
asks for the sharpest ceiling the encoder has and answered 51, the coarsest — the opposite end of
the scale, with nothing said. Clamping answers 1, the nearest thing that was actually asked for, and
it is the reading every other knob already gives. Presence still decides whether const-QP engages at
all, so an absent knob is still off; text that is not a number at all still leaves it off, because
inventing an operating point for a typo is the sin the ceiling port had just finished removing.

The part worth carrying: writing the ratchet found a FOURTH knob. `SLOPDESK_COMPACT_QP` sat ten
lines from the other three with the same `[1, 51]` range and the same hand-rolled reject, and it was
in neither the brief nor the sweep's own reading of the file. The gate ran against the shipped tree,
failed where it was expected to pass, and the failure was correct. A ratchet that fires on the tree
it was written for is usually a bug in the ratchet; occasionally it is the rest of the defect.

Then a FIFTH, one file over: `SLOPDESK_AQP_MAX` in `WindowCapturer`, same range, same reject. It is
why `VideoEncoder.envQP` is not `private` — there is no version of "one rule" where the fifth caller
gets its own copy for living in another file, and a helper's access level is a weaker constraint
than that.

**What was not folded then is folded now, and both premises of the paragraph that scoped it out were
wrong.** It said `EnvConfig`'s generic `guard let v = Int(s), v >= lo, v <= hi else { return def }`
was "this same reject rule for roughly a dozen knobs across several targets", and therefore that
flipping it to the clamp was a tree-wide *behaviour* change too big to ride along.

The count was not a dozen. It was **zero**: the generic pair had no production caller anywhere in
`Sources/`, only two tests of its own. There was nothing to flip, no behaviour to change, and the
scope-out was protecting a cost that did not exist. Both accessors are deleted.

And the reject rule it named is not a second implementation of `clamped_int_from_env` at all — it is
the second READING, and both readings are wanted. The real surface was two private copies, in
`LiveCongestionController` and `FPSGovernor`, and those knobs are rates and fractions rather than
quantiser ordinals. The whole argument for flipping the encoder's three is that a quantiser ordinal
has a meaningful nearest legal value; a malformed rate does not. `SLOPDESK_ABR_LOSS=900` clamped is a
controller that treats every frame as catastrophic loss forever. Rejected, it is the default and a
knob that did nothing, which is the answer a user can act on.

So the tree carries both, each with exactly one author:

* **CLAMP** — `slopdesk_qp_clamped_int`, `qp_control.rs`, for the `[1, 51]` quantiser ordinals.
* **REJECT** — `slopdesk_abr_validated_int` / `_double`, `congestion.rs`, for rates and fractions.

The `_double` form also rejects the non-finite, which no clamp can express: NaN compares false
against both bounds, so a clamp passes it straight through into the controller's arithmetic.

`FPSGovernor`'s copy carried a second defect on top of the duplication, and it is the one a user
would have reported as "the setting does nothing": it read `ProcessInfo.processInfo.environment`
directly rather than through `EnvConfig`, so it never saw the settings overlay. Every governor
tunable set in the settings sheet was written, persisted, displayed as active — and never read.
`LiveCongestionController`'s copy went through `EnvConfig` and so was merely duplicated, not deaf.
Both now resolve the same way and parse through the same door.

**The generalisation, because this is the second scope-out in this section to have been wrong about
its own size:** a scope-out is a claim with no gate behind it, exactly like a row in the table above,
and it decays the same way — except that it decays *faster*, because it is written at the one moment
nobody is going to check it, and its whole function is to stop the next reader from looking. This one
asserted a caller count it had never counted. **When a decision to defer rests on a NUMBER, count it
before writing the paragraph.** A scope-out that names its evidence can be re-checked in a minute; one
that names an impression buys the pair a year.

### The refusal that could not be heard: `size_t`, and the guard that never fired

`SupervisorFrame.read` asks `slopdesk_supervisor_body_length` for its body length and guarded the
door's refusal with `guard count != .max`. That guard has never fired, in any build, for any input.

Swift's ClangImporter maps `size_t` onto the **signed** `Int`, not onto `UInt`. So the door's
`usize::MAX` refusal arrives as `-1`, while `.max` in that position infers `Int.max`. The two are
different values and always were, and an over-cap header therefore fell straight through to
`readExactly(socket:count: -1)`.

Measured rather than reasoned about, with a scratch SwiftPM target on 2026-08-22 — a C function
returning `(size_t)-1`, called from Swift, printing its static type and its value:

```
static type: Int   value: -1
v == .max ? false
```

The guard is `guard count >= 0` now, and `check-supervisor.sh` bans the other spelling in both files
that read a `size_t` off a door.

**Neither language could have caught this, and that is the part worth carrying.** The Rust half
refused correctly and has a test proving it. The Swift half has tests proving it reads a well-formed
frame. Both suites are green, in perpetuity, because the defect lives in the TYPE MAPPING between
them — the one place neither suite has a fixture for. This is the drift class with the two
implementations removed: one implementation, one caller, and a disagreement about what a value means
that only appears at the boundary.

**The rule for anyone adding a door that answers a size.** `0` and "greater than `cap`" are the two
refusals §4 gives you, and both survive the signedness change, because both are meaningful as
non-negative numbers. An all-ones sentinel does not: it is the one refusal whose meaning depends on
how the callee's type was imported, and the caller's obvious guard against it compiles, reads
correctly, and is dead code. **Prefer a refusal the type system cannot silently reinterpret.**

This is why `slopdesk_screen_body_length`, added the same day for the identical question one lane
over, refuses with **`0`** instead. It can afford to: a reply of zero bytes is not a thing on the
screend wire, so `0` is unrepresentable as a real length and `> 0` is the whole check a caller needs.
The supervisor lane cannot take the same refusal — an empty body IS legal there — which is why it
keeps the sentinel and gets a ratchet on the guard instead. **The asymmetry is deliberate: where a
door can pick the refusal that needs no knowledge of the crossing, it should, and where it cannot,
the guard is the thing that gets pinned.**

### The argument that let two of these live for a year: "a name, not a policy"

Both rendezvous addresses carried the same note above the copy, and it was a good argument: a client
has to FIND the socket before it can say `hello`, so the address cannot be learned from the thing it
addresses, so the two ends necessarily agree by construction. **A name, not a policy.**

Half of it was true, and the false half is the interesting one. The NAME is shared by construction —
neither `slopdesk-screend.sock` nor `slopdesk-superd.sock` ever drifted. Which DIRECTORY the name
sits in is a *policy*: a precedence over environment variables, an emptiness filter, a last resort.
That was written out on both sides, and the two were not the same policy. The daemons resolved
`$…_SOCKET` → (`$SLOPDESK_SUPERD_DIR` →) `$TMPDIR` → `/tmp`; the clients resolved the override and
then `NSTemporaryDirectory()`, **which on Darwin does not read `$TMPDIR` at all** — it answers
`confstr(_CS_DARWIN_USER_TEMP_DIR)` whatever the environment holds. Measured, not reasoned. So every
process with a `TMPDIR` of its own had the daemon binding one path and the client dialling another,
with nothing on either side able to say so: the daemon simply looked like it was not running. hostd
had also never heard of `SLOPDESK_SUPERD_DIR`, so the gate script's private superd was reachable by
nothing.

The pair agreed in practice for one accidental reason — launchd sets `TMPDIR` to exactly the
directory that call returns, and the fixtures set the outright override — so the only two paths
anyone ever exercised were the two where the disagreement cancels.

**The generalisation: a constant crossing by construction is safe; the RULE that produces it is not,
and "we both know the name" is not the same claim as "we both compute the same path".** When a shared
identity is anything other than a literal — a precedence, a filter, a default — it is a rule, and the
rule crosses. The environment lookup stays on the near side in both ports, because the Swift faces
take their environment as a parameter and their tests pass dictionaries in; what crossed is the
precedence, the emptiness filter and the fallback, which is the half that had drifted.

**The direction is not consistent ACROSS families, and that is the point.** Rust is right in most
rows and Swift in one. So this is not "the port is behind" — it is drift in both directions between
paired implementations nobody diffs. Where a module got ported it got ported *well*; the failure is
entirely downstream of that, at the moment the port lands and the original stays.

**Within the decoder family, though, it is perfectly consistent, and that is a sharper finding.** Rust
repaired and Swift threw at every single site: `axis`, `id`, `children`, `weight`, `userRenamed`, and
all three repairable `VideoEndpoint` fields. That is not eight coincidences. `persist.rs` was written
as a **repair pass** and Swift's decoders were written as **parsers**, and the difference is one design
decision that only one language ever made. So the useful question about a pair is rarely "did someone
make a mistake here" — it is *"were these two written to answer the same question at all?"* A parser
and a repairer agree on every well-formed input and disagree on every malformed one, which is exactly
the input class no test covers and every hand-edited file eventually produces.

Three sites in that sweep had **no Rust counterpart** when this was written — `Session.activeTabIndex`,
`specs`, `detached` — because `persist.rs` stopped at the spec and the node. Swift answered them the
way a repair pass would, and the comments there said so, so that the obligation would be visible from
the Rust side when `persist.rs` grew to the session and file level.

**It has since grown to exactly there, and it did inherit them.** `persist.rs` now owns the session and
the whole file; `Sources/SlopDeskWorkspaceModel/Codec/WorkspaceFile.swift` asks through
`slopdesk_ws_workspace_file_{encode,decode,status,minted_ids,max_panes}` and the Swift `Codable` decoders
those three sites lived in are deleted. The three answers were inherited rather than re-derived, which
is what this paragraph was for.

⚠️ **This paragraph was itself the anti-pattern above.** It is a comment in one language's docs naming
the *other* language's behaviour, and it went stale the moment that behaviour changed — silently, the
way every pair in this section goes stale. It is kept, rewritten, rather than deleted: a section
cataloguing drift that had quietly drifted is the cheapest possible demonstration that the catalogue
needs the same discipline as the code. The rule it argues for is unchanged; the example is now its own.

One limit of the ratchet worth stating, because it was found the hard way: the gate bans the **pairing**
`decodeIfPresent(…) ?? default`, since `decodeIfPresent` is correct where absence and unreadability are
both faults. **Deleting the `??` therefore silences the gate without fixing the defect** — the throw is
still there and the file is still lost. A pattern ban can see a shape, never an intent.

**Why `check-supervisor.sh` never caught any of them.** Read what it pins, and it pins it well:
`compare_abi_enum` over four enum→byte maps, the intent op numbers, "did this Swift file come back",
"does `SplitLayoutSolver.swift` still `import CSlopDeskFFI`". Every one of those is **a name or a
number**. It has no mechanism for *"these two functions produce the same output on the same input"*,
so drift is invisible in exactly one direction — the behavioural one — and **every instance in the
table is behavioural.** (This paragraph said "all eight" while the table said ten: the count was
written once and the table grew twice. A number restated beside the thing it counts is the same defect
this section is about, one register up.)

The `WorkspaceIntent.swift` / `intent.rs` pair is the proof. The gate is on that exact file pair. It
diffs the op-byte map, and the blob bug was six lines away.

**So a vocabulary pin is not a pin.** When a port cannot delete its original in the same change — a
decoder still needed at launch, a constant a second language must agree on, a repair pass whose door
does not exist yet — the obligation is a **differential test**: same inputs to both sides, assert the
same output. The candidates are pure functions over small values with no I/O, which is most of what
crosses here, and a differential suite over `templates.rs` and `persist.rs` alone would have caught
three of them.

**The first one exists (2026-08-20): `TreeWorkspaceRepairDifferentialTests`.** It is worth reading for
the shape rather than the subject. Two things it does that a normal suite does not:

- **It walks a vocabulary the crate exports instead of naming cases.** `PaneKind` has two cases today,
  so `kind == .desktop` and `PaneKind::is_video` select the same panes — a test naming them would agree
  forever while the predicate quietly stopped being one. It loops `0..<slopdesk_ws_pane_kind_count()`,
  so a third video-ish kind fails in the suite rather than in a restored workspace. Same argument for
  `slopdesk_ws_normalize_pass_count()`: `compare_abi_enum` holds the two byte MAPS against each other,
  which catches a reorder and a renumber but *not a pass the crate adds*, because a map Swift never grew
  still agrees with itself. **A vocabulary pin needs a COUNT as well as a map**, and that is general.
- **It drives both doors on one input and asserts they converge** — repair-then-close against
  close-then-repair. That property is what the `TreeWorkspace` row was violating, and it is checkable
  without knowing what either door does.

A door with no caller is how the second half gets lost: `slopdesk_ws_normalize_pass_count` shipped dead
and `make lint-ffi-doors` caught it, which is the ratchet doing exactly its job. **A differential suite
is not finished until every door it justified is one the suite calls.**

**The second one (2026-08-20): `SessionTemplateRepairDifferentialTests`.** It is the first written for
a pair that is still DOUBLE — the precedent pins two doors onto one Rust rule after the Swift copy was
deleted; this pins two languages, because `SessionTemplate` is `Codable` and its decoder is how a
person's saved layouts come back. Three doors were cut for it and all three are called from it:
`slopdesk_ws_template_repair`, `slopdesk_ws_built_in_templates`, `slopdesk_ws_built_in_launch_presets`.
Two things it adds to the shape:

- **A layout crosses as a PRE-ORDER byte stream** — tag, payload, children — because a `TemplateNode`
  has no `#[repr(C)]` flattening and no JSON in this graph to borrow. It is `slopdesk_ws_solve_layout`'s
  encoding a second time, and the grammar is written down ONCE in `slopdesk_ffi.h`, with both encoders
  written against that paragraph rather than against each other: a codec whose only proof is its own
  round trip agrees with itself however both halves are wrong. Its lengths are `u32` rather than the
  wire's `u16` for one reason worth carrying to the next such door — `put_length_prefixed_str` CLAMPS at
  64 KiB, and a differential that passes because both sides truncated the same title is worse than none.
- **The convergence property is the two LANGUAGES, in both orders.** Repair-here-then-there against
  repair-there-then-here, over a corpus that is deliberately almost all malformed: empty splits,
  one-child splits, nesting past the cap, and combinations. Two rules that disagree anywhere cannot
  commute everywhere, so it fails on a divergence a pairwise assertion could only see input by input.

It also settled the `MIN_WEIGHT`/`MAX_DEPTH` anti-pattern named below: `slopdesk_ws_max_depth` exists
now and `SplitNode.maxDepth` asks for it, so the two numbers that had one meaning are one number. And
it settled a recorded divergence that turned out to be **prose only** — Swift's comment called the depth
cap a rejection where the crate's called it a repair, which described a parser beside a repairer over
two implementations that agree case for case. Both comments say the same true thing now, and the suite
is what says it rather than either comment.

Two anti-patterns this class has already produced, both worth recognising on sight:

- **A constant transcribed where a door already exists.** `WorkspaceIntent.swift:99` asks
  `slopdesk_ws_intent_limit(0)` rather than restating 512 — that is the idiom. The 15 MiB cap is
  spelled three times in two languages and holds a load-bearing *inequality* across the boundary (the
  probe must read `cap + 1` so the builder's truncation signal survives). `MIN_WEIGHT` was asked
  through a door while `MAX_DEPTH` sat beside it transcribed as a bare `12` — one of those two was
  wrong, and it was fixed on 2026-08-20: `slopdesk_ws_max_depth` exists and `SplitNode.maxDepth`
  asks for it. The 15 MiB cap is still spelled three times.
- **A comment that names the other language's behaviour, and goes stale.** These are the
  highest-signal artifacts in the repo — `put_blob`'s comment is how the first defect was found — and
  they are also the most dangerous when wrong, because they tell the next reader the pair agrees. A
  comment asserting a cross-language fact is a claim with no gate behind it. Write them, and treat
  editing one side as an obligation to re-read every such comment on the other.
