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

- **The case list stays.** `AgentKind`, `ClaudeStatus`, `AgentScreenState`, `ClaudeSignal`,
  `ClaudeHookEvent`, `AgentStatusKind`. Declaring the same cases twice is not two implementations —
  it is one vocabulary in two type systems, and marshalling an enum through C would buy nothing.
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

**One string buffer, not one pointer each.** A hook event carries up to six optional strings. Six
`(ptr, len)` pairs is six nested `withUnsafeBytes` per call. Instead the caller concatenates into one
buffer and passes `(offset, len, present)` spans into it — one pointer, one lifetime, one scope. The
crate bounds-checks every span, because a hook body is untrusted input; an out-of-range span reads as
absent. `present == false` is `nil`; `present == true, len == 0` is the empty string, and the machine
tells those apart.

**A staged handle for a shape too big to flatten.** A foreground job is a pgid plus N processes, each
with three optional strings and a whole argv. `job_new` → `push_process` / `push_argv` per item →
`identify` → read the answer slot → `free`. Same staging pattern as the replay buffer's input slot,
for the same reason: one item at a time, and no list encoding to get wrong.

### What it cost

Nine Swift files, 2,152 lines → 1,236, of which ~260 is the marshalling. The 135 tests in
`SlopDeskAgentDetectTests` are unchanged and now exercise `rust/slopdesk-agent`.

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
6. `make ffi && make lint && make test`.
