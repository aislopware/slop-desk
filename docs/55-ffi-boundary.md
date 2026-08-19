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

The bitmask rule stands wherever an optional string crosses — it is why `SlopDeskAgentSpan` carries
a `present` flag next to its length. The DOOR does not. When the fusion moved
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

## 4c. What the boundary costs, measured

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

### Two shapes the agent module added

**One string buffer, not one pointer each.** A foreground job's process carries three optional
strings, and a hook event used to carry six. Six `(ptr, len)` pairs is six nested `withUnsafeBytes`
per call. Instead the caller concatenates into one buffer and passes `(offset, len, present)` spans
into it — one pointer, one lifetime, one scope. The crate bounds-checks every span, because this is
untrusted input; an out-of-range span reads as absent. `present == false` is `nil`;
`present == true, len == 0` is the empty string, and the crate tells those apart. The hook half of
that no longer crosses — the body goes over raw — so `slopdesk_agent_job_push_process` is the door
that holds the rule now, and `rust/slopdesk-ffi`'s own tests hold it there.

**A staged handle for a shape too big to flatten.** A foreground job is a pgid plus N processes, each
with three optional strings and a whole argv. `job_new` → `push_process` / `push_argv` per item →
`identify` → read the answer slot → `free`. Same staging pattern as the replay buffer's input slot,
for the same reason: one item at a time, and no list encoding to get wrong.

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
hot path.** **Ten** pairs are known. Seven were live defects when found; the other three agree
today and are held together by nothing but the week they were written in:

| Pair | Who was right | What the user lost |
| --- | --- | --- |
| `WorkspaceIntent.encode` vs `intent::put_blob` | Rust | a frame that mis-splits at the decoder |
| `SplitNode+Codable` unknown `axis`/`id` | Rust | **the entire workspace**, to one typo |
| `persist::decode_raw_node` id-less splits | Swift | two dividers moving as one |
| `TreeWorkspace.normalized` vs `workspace::normalized` | — | launch-time and gesture-time repair disagree — **ported 2026-08-20** |
| the 15 MiB opaque cap, spelled **three** times | — | a silently truncated `git diff` rendered as complete |
| `templates.rs` vs `SessionTemplate`/`LaunchPreset` | — | agrees today; a security rule written twice |
| `persist::derived_split_id` vs `SplitNodeID()` | Rust | divider weights reset on every relaunch |
| `detectionText` vs `detect::detection_text` | Rust | dead Swift, plus a third spelling of the join |
| `PaneSpec+Codable` `userRenamed` vs `decode_spec` | Rust | **the entire workspace**, to a non-boolean flag |
| `VideoEndpoint`'s synthesized `Codable` vs `decode_video` | Rust | **the entire workspace**, to a hand-edited window id |

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

Three sites in that sweep have **no Rust counterpart yet** — `Session.activeTabIndex`, `specs`,
`detached` — because `persist.rs` stops at the spec and the node. Swift now answers them the way a
repair pass would, and the comments there say so, so the obligation is visible from the Rust side when
`persist.rs` grows to the session and file level. It inherits three answers it did not choose; better
that it inherits them knowingly than re-derives them differently.

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

Two anti-patterns this class has already produced, both worth recognising on sight:

- **A constant transcribed where a door already exists.** `WorkspaceIntent.swift:99` asks
  `slopdesk_ws_intent_limit(0)` rather than restating 512 — that is the idiom. The 15 MiB cap is
  spelled three times in two languages and holds a load-bearing *inequality* across the boundary (the
  probe must read `cap + 1` so the builder's truncation signal survives). `MIN_WEIGHT` is asked
  through a door; `MAX_DEPTH` sitting beside it is transcribed. One of those two is wrong.
- **A comment that names the other language's behaviour, and goes stale.** These are the
  highest-signal artifacts in the repo — `put_blob`'s comment is how the first defect was found — and
  they are also the most dangerous when wrong, because they tell the next reader the pair agrees. A
  comment asserting a cross-language fact is a claim with no gate behind it. Write them, and treat
  editing one side as an obligation to re-read every such comment on the other.
