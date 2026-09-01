# DECISIONS vol-10 — 2026-08-14 … 2026-08-15

> Volume 10 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## The link scan crosses as an arena, and its two bounds are a gate (2026-08-14)

`rust/slopdesk-terminal`'s `link` was 813 lines of tested Rust nothing could reach, against a
515-line Swift twin driving three overlays. It is one implementation now, and the shape it crosses
in is the interesting part.

**The answer does not fit in a value.** A scan returns a list of records each carrying up to two
strings, and neither the record count nor the total text length is knowable before the scan runs —
so §4's "return the bytes NEEDED, caller retries with a bigger buffer" cannot start: there is
nothing to size. So the result crosses as an ARENA parked behind a handle: `slopdesk_link_scan`
takes every input at once, runs the scan, and hands back an owned result; `counts` says how much
there is, `link` reads one record, `take_arena` copies the one flat string buffer under §4's rule,
`free` ends it. The handle carries no policy and no history, which is what keeps the Swift face the
free function all ten call sites already call — the handle never escapes `detect`, so two overlays
scanning at once share nothing to race on.

**Rows cross as one blob plus a length each, not an array of pointers.** The caller has to build
something contiguous for the boundary either way; one buffer is one allocation and one bounds rule
instead of `row_count` of each. The custom scheme list takes the same shape.

**Two width entries, because one of them is called per column.** `text_cells` answers for a string;
`scalar_cells` answers for one Unicode scalar. `ViLineMotion` and `HintLabelAssigner` walk a line
cell by cell, and a string-only door would have made them build a one-character `String` per column
to ask about a scalar already in hand. `link::char_cells` was renamed `scalar_cells` and made `pub`
for exactly that; `cluster_cells` still calls it, so there is one table. On the Swift side
`displayCellWidth(of: String)` lends its bytes with `withUTF8` rather than copying them into an
`Array`, since a native string is already contiguous UTF-8.

**The bounds are spelled twice, so they are checked.** `MAX_MATCHES_PER_ROW` (512) and
`MAX_SCAN_COLUMNS` (4096) exist as a `pub const` the scan enforces and a `public static let` the
call sites read. A drift between them is an anti-hang bound or an overlay flood that no test would
see, so `check-supervisor.sh` compares the two numbers rather than trusting a comment — alongside a
gate that the classify/trim/normalise functions and the East-Asian width TABLE stay deleted. That
last one is matched on the scalar/character parameter, because `ViLineMotion.cellWidth(_:at:)` is a
caller of the door, not a second table.

The port is proven the way the others were: `TerminalLinkDetectorTests` and the six other suites
that reach the detector are unchanged, and 129 of them pass against the door.

The cost was measured, not assumed — `TerminalLinkScanBenchTests` against the deleted Swift file
timed the same way. The scan is **4.2–4.3× faster** at every size (a 50-row viewport 855 → 203 µs, a
2000-row scrollback 33910 → 7950 µs), because Swift's per-`Character` grapheme breaking was most of
the old cost, and `displayCellWidth(of: String)` is 3.7× faster because `withUTF8` lends the bytes.
`displayCellWidth(of: Character)` is **~30 ns/call slower** and stays that way: the overhead is a
call that cannot inline across the boundary, and the only way to remove it is a second copy of the
width table in Swift — the thing this port exists to delete. Its callers walk one line per
KEYSTROKE, so ~6 µs lands on a 16-millisecond budget while ~650 µs comes off the per-frame scan
beside it. A per-frame caller would get a batch entry that answers a whole row's widths at once, not
a table.

## The command blocks cross whole, and the door says where an upsert landed (2026-08-14)

`rust/slopdesk-terminal`'s `blocks` was 706 lines of tested Rust nothing could reach, against
`TerminalBlockModel.swift`'s 483 lines doing the same work for real: the ring and its 64-block
bound, the ordered insert that tolerates a late lower index, the eviction that takes the oldest
block's first-seen stamp with it, the bookmark set with its FIFO cap and its restore-is-not-an-edit
rule, the status a block derives from `complete` and `exitCode`, the duration label, the
jump-to-failed walk, and the coalescing and generation rules behind an output request. One
implementation, and it is Rust's.

**One handle, for the ring AND the request registry**, because a reset touches both in an order that
matters: the blocks die and every in-flight request has to be answered "unavailable" or a
continuation is parked forever. `reset` does both and PARKS the stranded indices for
`take_stranded` — a SLOT, not the usual size-then-fill pair, because a destructive operation cannot
be asked its size first. Writing the test for that is what found the bug: the first shape drained
the pending set on the sizing call and handed back an empty list on the second.

**`status`, `duration_label` and `adjacent_failed` take FIELDS, not a handle.** `isFailed` is read
per row per render and the jump walk runs over whatever list the caller projected, so neither needs
the store, and making them need it would mean a test could not ask the question without building
one.

**What stayed in Swift is what cannot cross**: the CALLBACKS a resolved request fans out to, and the
SF Symbol and label strings a row displays. The callback bag is a bag, not a rule — the door decides
send-versus-coalesce and owns the generation; this side only remembers who to call.

**The door answers WHERE an upsert landed, and that is the whole performance story.** `blocks` is an
`@Observable` array, so it has to live in Swift, and the first shape rebuilt it from a projection
after every update. Measured at `-O` against the deleted model, that cost ~8 µs per upsert no matter
how the rebuild was arranged — scratch buffers kept between calls, a per-row byte diff against the
previous arena, one `memcmp` over the whole arena, every buffer lent once up front. ~8 µs is simply
what an array of 64 string-bearing structs costs to build in Swift. So `slopdesk_block_store_upsert`
now returns `{replaced, position}`: a known index replaces its slot with exactly the block the
caller passed, so the caller writes that one slot and reads nothing back. The in-place upsert — the
one that arrives on every output-length growth of a running command — went 7.08 µs → **0.48 µs**,
and the evicting one 19.86 → 10.33 µs, the filtered query 2.25 → 0.06 µs. Three per-render reads
(`isFailed`, `durationLabel`, `adjacentFailed`) are a fraction of a microsecond SLOWER across 64
rows, being calls that cannot inline across the boundary; the alternative is a second Swift copy of
"completed with a non-zero code", which is the drift the port removes.
`TerminalBlockStoreBenchTests` carries the table.

The caps are spelled twice and therefore checked: `maxBlocks` (64) and `maxBookmarks` (256) against
`MAX_BLOCKS` and `MAX_BOOKMARKS`, compared numerically by `check-supervisor.sh` alongside a gate
that the Swift ring, bookmark order and generation counter stay deleted. A drift in the first would
make the client hold a block superd already evicted.

## The far side picks the convention: the quantiser folds, the recovery policy holds (2026-08-14)

`rust/slopdesk-video`'s `qp_control` and `recovery_idr` were both written and both tested, and both
had a live Swift twin that ran instead — the constant-QP AIMD in `QPController.swift` and the
delivery-keyed IDR admission in `RecoveryIDRPolicy.swift`. They cross now, through one door module,
`rust/slopdesk-ffi/src/rate_control.rs`, and the twins are faces.

**They take opposite conventions, and what picks is the SWIFT side's ownership, not the Rust side's
shape.** `QPController` is a `struct: Equatable` whose owner takes a copy out of the session, folds a
report into the copy and writes it back, and compares the whole thing against `nil`. A handle there
would let two copies the type system says are separate alias one allocation, so the quantiser crosses
as a pure fold: config and state in, state out, nothing allocated on either side.
`RecoveryIDRPolicy` is a `final class` on purpose — one token bucket, one keyframe ring, one owner
mutating it in place — which is exactly what a handle models, so it is one.

**The fold needed the wrapped crate to grow a way back in.** A by-value crossing has to restore state
that `new` deliberately zeroes: `clean_streak` IS the law's memory, and a controller rebuilt without
it sharpens on every clean report instead of one per interval. So `QpController` gained `restored`
and `clean_streak()`, which sanitise and clamp on the way in like any other untrusted input — a
streak is held at the last value the fold can actually be in, because `decide` resets it the moment
it reaches the interval. The alternative was to replay the streak through `decide` inside the door,
which is arithmetic, and arithmetic in the door is the thing the door is not allowed to have.

**What stayed in Swift is where the knobs come from.** `SLOPDESK_QP_*` and `SLOPDESK_IDR_*` resolve
through `EnvConfig` — environment, then the settings overlay — so a GUI setting can beat an
environment variable, and that overlay is Swift's. The door is handed the resolved text and parses
it, CLAMPING an out-of-range knob rather than rejecting it, and never reads an environment of its
own. `Verdict` also stayed: a Swift `switch` needs cases, and mapping five constants onto five cases
is the only decision either face makes.

The 24 Swift tests that pinned both laws were left exactly as they were and pass unchanged, which is
the parity evidence — they now drive the Rust through the face. `check-supervisor.sh` pins the ten
entries, the `deinit` that frees the handle, and the state a re-implementation would grow back
(`cleanStreak`, `recentKeyframes`, a token bucket), scoped to the video host: a token bucket is a
shape rather than a law, and `NotificationRateLimiter` in SlopDeskWorkspaceCore is its own.

## The rate law crosses whole: state in, state out, every field (2026-08-14)

`LiveCongestionController` (617 lines) and the `NetworkEstimate` it folds (in `VideoSessionLogic.swift`)
were the last of the video host's control laws still spelled in Swift, each carrying a comment saying
it "mirrors `LiveCongestionController::decide_with_config` byte-for-byte" — which is to say, two
implementations of one law, kept in step by hand. They are now faces over
`rust/slopdesk-ffi/src/abr.rs`, and the mirror comments are gone with the mirror.

**Both cross BY VALUE, and the whole record travels every call.** Both are Swift `struct`s their
owners copy out, fold into and write back, so the rule the quantiser established applies again: a
handle would alias two values the type system says are separate. What the crossing must carry is
every field the NEXT fold reads, not the fields a reader finds interesting. `rtt_inflated_streak` is
what makes one noisy report harmless; `prev_smoothed_rtt_millis` IS the drain gate, without which a
backlog flushing out walks the rate to the floor; `sample_count` is the two-fold warmup that stops
the very first jitter sample reading as a rise. A crossing carrying only the public readings would
be a different control law that agreed on the easy cases. So `Equatable` is spelled out over all of
them — a C struct synthesises nothing, and a field missing from `==` would let two controllers that
disagree on the next report compare equal.

**The wrapped crate grew `snapshot` + `restored` rather than the door growing arithmetic**, exactly
as `QpController` did. `restored` re-establishes what `new` guarantees — a ceiling of at least one, a
floor inside the encoder minimum, a target between them — and it does it FLOOR-LAST (`floor.max(cur
.min(effective_ceiling()))`), never `clamp`: a ceiling under the encoder minimum leaves the floor
above the ceiling, which `new` already permits and answers by returning the floor, while `clamp`
asserts its bounds are ordered and would panic. A panic crossing the C boundary aborts the process,
so a hostile snapshot must land on a legal state, not kill the host.

**The defaults are spelled once, on the far side.** `slopdesk_abr_config_default()` vends them and
every `SLOPDESK_ABR_*` static falls back to a field of it, so a default can no longer be changed in
one language and not the other. What stayed in Swift is the part that is genuinely the host's:
resolving each knob through the overlay-aware `EnvConfig` (validate-then-default, so a GUI setting
beats an environment variable), naming the ten branches for the `abr: actuate` debug line, and
holding the state between reports. `effective_slack_millis` stays a free-standing entry because the
frame-rate governor consults the SAME rule — the two controllers cannot be allowed to drift apart on
what "inflated" means.

The 94 Swift tests over these two types were left exactly as they were and pass unchanged, which is
the parity evidence. `check-supervisor.sh` pins the eleven entries, the five branch functions a
re-implementation would grow back (`decideInner`, `applyDecrease`, `appLimitedDecay`, `increaseStep`,
`utilizationPermitsRamp`), the estimate's three EWMA weights — which no env reads and nothing hands
across, so a Swift copy could drift for a whole release unnoticed — and the count of defaults read
from the door.

## The frame-rate axis crosses by value; the ladder is derived, not carried (2026-08-14)

`FPSGovernor`, `EncodeCadenceGate`, `SelfHealCadence` and `EncodeLoadPacer` — the whole of
`FPSGovernor.swift` — are now faces over `rust/slopdesk-video`'s `fps_governor`, through
`rust/slopdesk-ffi/src/frame_rate.rs`. Both governors are Swift `struct`s their owners copy, so both
cross by value, state in and state out, exactly as the rate law does.

**The LADDER does not cross.** It is a function of the base rate and the floor, both of which travel
inside the record, so carrying it would be carrying a derivation — and a derivation that crossed
could come back disagreeing with the numbers it came from. A caller that wants to SEE the rungs asks
for them: `slopdesk_fps_ladder` fills a buffer under §4's out-and-capacity convention, and four rungs
is the whole answer, so the buffer is sized once at construction. `restored` snaps a rate that
arrives BETWEEN two rungs down onto the rung at or below it, because every path in the law reads the
rate against the ladder and a value no ladder names would step to a rate no cadence can be regular
at. An average that arrives non-finite reads as UNSEEDED — the state the governor refuses to act in,
which is the safe answer and the one `new` starts from.

**One rule is shared rather than mirrored.** `slopdesk_fps_congestion_evidence` takes the BITRATE
law's `SlopDeskAbrConfig`, not a config of its own, so the frame-rate axis and the rate axis read one
`effective_slack_millis`. Had it kept a local copy of the inflate factor, the frame rate would step
down on evidence the rate controller ignored — and nothing would have said so.

The 38 Swift tests over these four types were left exactly as they were and pass unchanged; the
golden corpus, which replays the bytes-EWMA fold, is byte-identical. `check-supervisor.sh` pins the
twelve entries, the ladder/cadence/budget arithmetic a re-implementation would grow back (scoped to
the video host, since a frame interval is a shape rather than a law and the loopback harness computes
its own), and the fact that the congestion predicate still passes `LiveCongestionController.config`.

## The presentation depth crosses by value, rings and all (2026-08-14)

`PacerDepthPolicy` and `OwdLateDetector` — the whole of the client's depth axis — are now faces over
`rust/slopdesk-video`'s `pacer_depth`, through `rust/slopdesk-ffi/src/pacer_depth.rs`. Both are Swift
`struct`s the `FramePacer` copies out, folds into and writes back under its lock, so both cross by
value, state in and state out, the way the rate law and the frame-rate axis already do. `FramePacer`
itself stays Swift: it is CADisplayLink, CoreVideo and QuartzCore, which is the one thing that
justifies staying.

**The RINGS travel.** That is the whole design question here. A promote window, a demote dwell and
the dense-flow gate all read TIMES rather than counts — the question is never "how many lates" but
"how many inside the last second" — so a crossing that carried the counters would be a different
policy that agreed only while nothing aged out. The three rings cross as fixed-capacity arrays,
sixteen arrivals, fifteen intervals and four lates, which are the capacities the folds themselves cap
at; `interval_ring_size` is capped to the carried capacity when the state is rebuilt, because a ring
that KEPT more than the crossing carries would lose its oldest entry on every trip. The baseline's
two bucket minima travel for the same reason: a detector that agreed on its verdicts but not on those
would diverge on the next sample.

**The environment is applied one PAIR at a time.** The caller holds a whole `[String: String]` and
every band lives on the far side, so the door takes a KEY and a VALUE and answers the config that
results — `slopdesk_pacer_depth_config_apply`, `slopdesk_owd_late_config_apply`. The alternative,
nine optional strings in one call, keeps the knob NAMES on the near side, which is the same law
written twice; the names now live in `pacer_depth.rs` beside the bands they open. The knobs are
independent, so the dictionary's arbitrary iteration order cannot change the answer. One behaviour
moved while the names did: an integer knob now parses SIGNED and clamps, so `-1` lands on the nearest
end of its band instead of silently keeping the default — which is what every other knob already did,
and what the Swift original did.

**Equality is the door's.** A C array is a TUPLE on the Swift side and a tuple that long has no
equality, so `slopdesk_pacer_depth_eq` is the one comparison the near side cannot spell for itself.

The 33 Swift tests over the two types were left exactly as they were and pass unchanged, and the
golden corpus — which pins the detector's per-sample deviations and the policy's interval/threshold
bit patterns — is byte-identical. `check-supervisor.sh` pins the sixteen entries, the rings and
promote/demote branches a re-implementation would grow back (scoped to `Sources/`, since the tests
name the state they drive), and the absence of any `SLOPDESK_DEPTH_*` or `SLOPDESK_OWD_LATE_*`
literal in the shipping code.

## The gradient detector crosses by value, window and all (2026-08-14)

`TrendlineEstimator` and `TrendSampler` — the client's one-way-delay GRADIENT path, which is what
buys the rate law its early cut — are now faces over `rust/slopdesk-video`'s `trendline`, through
`rust/slopdesk-ffi/src/trendline.rs`. A Swift `struct` its owner copies out, folds into and writes
back, so it crosses by value like the rate law, the frame-rate axis and the depth policy before it.

**The regression WINDOW travels.** The verdict is a least-squares slope over the window's samples,
and running sums that dropped the evicted point arithmetically would be a different sequence of
roundings — the trend's bits are pinned both on the wire and in the golden corpus, so the samples
themselves cross, as a pair of parallel fixed-capacity arrays. The capacity is two hundred, which is
the CEILING of `SLOPDESK_TREND_WINDOW`'s own band: every window a legal config can ask for fits with
nothing truncated, and the ninety percent of the array a default twenty-sample window leaves unused
is three kilobytes of stack per fold at sixty folds a second, which is not a cost worth a second
convention.

**The law's constants do NOT cross as state.** The smoothing coefficient, the threshold's bounds and
gains, the sustain time and the idle-reset gap are asked for once through
`slopdesk_trendline_constants`, because no fold changes one — carrying them in the record would have
made a fixed number look like something a caller could move.

**Out-of-band is rejected here, not clamped.** The depth policy's knobs move an operating point along
an axis, so a value past the end of a band lands on the end. These two reshape the detector's
geometry, so a typo keeps the default — which is what the Swift original did, and the door now says
so once rather than in both languages.

The 17 Swift tests over the two types were left exactly as they were and pass unchanged, and the
golden corpus — which pins the smoothed delay, the modified trend, the threshold, the state and both
packed wire fields as bit patterns — is byte-identical. `check-supervisor.sh` pins the eleven
entries, the OLS accumulators and threshold gains a re-implementation would grow back, and the
absence of any `SLOPDESK_TREND_*` literal in the shipping code.

## The decoder's admission crosses by value, hold sets and all (2026-08-14)

`DecodeFrontier`, `DecodeGate`, `DecodeSequencer` and `DecodeAdmissionBudget` — everything that
stands between a reassembled frame and VideoToolbox — are now faces over `rust/slopdesk-video`'s
`decode_admission`, through `rust/slopdesk-ffi/src/decode_admission.rs`. Three of the four are a
handful of scalars and cross the way the rate law, the depth policy and the gradient detector do.
`DecodeGate` stays a Swift `final class`, because its single owner mutates it in place across the
decode loop, but the record it wraps is still a by-value fold — a five-scalar handle would have
bought an allocation and a lifetime for nothing.

**The sequencer moves IDS, and Swift keeps the bytes.** This is the new boundary shape, and the
reason for it is that the ordering law never reads a compressed byte: it is a function of frame ids
and one keyframe bit. Threading `ReassembledFrame` through the door would have copied the whole AVCC
payload in and out on every completion — about 10 µs a frame at 75 Mbps, for a law that does not
look at it. So the door takes an id and answers with ids: which are releasable now, in RELEASE
order, and which a keyframe has made obsolete. Swift keeps its own frames in a bag keyed by id and
honours the two answers in that order, release then forget, so a duplicate keyframe that was already
held finds its removal a no-op. The Rust type lost its `BTreeMap<u32, ReassembledFrame>` in the same
change — carrying payloads it never inspected was incidental, and no Rust caller wanted it.

This is NOT the `RetransmitRing` question deferred elsewhere. There the bytes ARE the product — the
ring exists to hand a frame back — so a port has to answer who owns the allocation. Here the bytes
are never the product, so the boundary lands where the law's own inputs end.

**The two outstanding SETS travel.** Which specific ids are held and which are declared-lost is what
the next fold reads: the run at the expectation, the holes it steps over, the flush order. A count
answers none of those. Both cross as fixed-capacity arrays, and both valves now CLAMP to a ceiling of
sixty-four — which is what the capacities are proved against, and an order of magnitude past the
retransmit grace the valves are actually derived from. Patience past that point is a pane frozen for
a second, which no gap is worth. Inside Rust the sets became arrays too: no allocation on the
per-frame path, and the whole sequencer stays a value that copies.

**The flush sorts by hand.** `sort_by` over `distance_wrapped` is a comparator that is only a total
order over a span shorter than half the id space. The valves guarantee that, but a library sort that
validates its comparator would ABORT if they ever did not — and an abort is what a panic crossing the
shim becomes. A selection sort over at most sixty-five ids on a path that trips rarely is total by
construction.

The 37 Swift tests over the four types were left exactly as they were and pass unchanged, and the
golden corpus is byte-identical. `check-supervisor.sh` pins the seventeen entries, the hold set and
flush branches a re-implementation would grow back, and the valve and cap literals that would put a
band in two languages at once.

## The audio jitter stage is a handle, samples and all (2026-08-14)

`AudioJitterBuffer` — every buffering decision between the audio decoder and whatever plays — is now
a face over `rust/slopdesk-video`'s `audio_jitter`, through `rust/slopdesk-ffi/src/audio_jitter.rs`.
It takes the HANDLE convention, and it is worth writing down next to the port that landed the same
day and took the opposite one.

**The two ports are the same shape and the opposite answer, and the test is what the LAW reads.**
Both hold a queue of frames. The decode sequencer never looks at a compressed byte — its law is a
function of frame ids and one keyframe bit — so its door moves ids and Swift keeps the payloads. This
stage's whole product IS the samples: it exists to hand back a steady stream of them, in an order it
chose, split at offsets it chose. There is no id it could answer with that would let the caller
reconstruct the answer, so the samples live where the decisions are. Rust owns the stage, Swift holds
an opaque token, and samples cross once each way through `(ptr, len)`.

**What that costs, measured against what it replaces.** Swift used to retain the decoder's `[Float]`
and never copy it. Now each push memcpys about 10 ms of audio — 3.8 KB at 48 kHz stereo — which at
the ~100 Hz push cadence is under 0.4 MB/s, or a few microseconds of CPU per second. There is no
arrangement that avoids it without putting the reorder law back on the near side, which is the thing
being deleted.

**The SPSC hand-off ring stays Swift, on purpose.** `AudioSampleRing` is raw storage partitioned by
two atomic counters, and it exists so a real-time render callback never blocks on the producer. It
belongs to the runtime that owns the audio unit, and the Rust module's own header says so. What DID
cross is the pump's arithmetic — the two sample budgets, the starvation test and the combined-depth
shed — so the stage's policy and the pump's budget can no longer drift apart. `check-supervisor.sh`
pins the sixteen entries, the one `_free` in the owner's `deinit`, the block list and play frontier a
re-implementation would grow back, and the absence of any door entry for the ring itself.

The 65 Swift audio tests were left exactly as they were and pass unchanged.

## The presentation queue folds by value, waiting frames and all (2026-08-14)

`FramePacer` no longer holds a jitter buffer. Which decoded frame each refresh shows, how much slack
to keep, when to hold and when to re-prime is now `rust/slopdesk-video`'s `present_queue`, reached
through `rust/slopdesk-ffi/src/present_queue.rs`. The Swift keeps the display-link wiring, the
render callback and the two depth controllers — AppKit, telemetry and policy that already lived
elsewhere — and one bag of `CVImageBuffer`s keyed by handle.

**By value, and this is the third worked example of the rule, not a new one.** The queue is the big
part of the value and the near side never reads it: it reads a handle to present and a list of
handles to release. The law never dereferences a handle, so nothing is gained by moving images
across — the decoder's buffers stay exactly where they are. The waiting frames therefore cross as a
fixed-capacity array sized at the depth cap the `SLOPDESK_JITTER_MAX` gate already clamps to, which
makes the crossing 288 bytes and the whole pacer state a value that copies.

**A by-value port of a HANDLE queue owes its caller a drop list.** Every fold answers with the
handles it made obsolete: homeostasis's trim on a present, the hard cap's eviction on a submit. A
count would say how many died and leave Swift inferring WHICH from a queue order it is precisely no
longer keeping — which is the mirror state the port exists to delete. That obligation is why
`PresentOutcome` gave up its `dropped: usize` for a `PresentStep` carrying the handles.

**Two depth doors, because there are two controllers.** `set_live_depth` carries the promote rule (a
deeper buffer re-primes, or the slack frame it asked for never gets built); `adopt_live_depth` does
not. The older arrival-jitter controller re-recommends on every frame and every underrun, and
re-priming that often would hold the picture where the user can see it. The two controllers are
mutually exclusive upstream, so the two rules never both apply to one pacer — but they are two rules,
and one entry point pretending otherwise would have been a silent behaviour change.

Also deleted: the Swift spellings of the deadline schedule, the half-tick lookahead, the tick-rate
band, the render cap's 0.5 ms slack, the playout ceiling and the 60-sample recompute cadence — every
one of them a number that was written down twice. `check-supervisor.sh` pins the twelve entries, the
lockstep timestamp array and priming latch a re-implementation would grow back, and the literals.

The 43 Swift pacer tests were left exactly as they were and pass unchanged.

## The HEVC parameter sets are spans, not a second walk (2026-08-15)

`HEVCParameterSets` was a line-for-line Swift copy of `rust/slopdesk-video`'s
`hevc_parameter_sets` — same three type numbers, same six-bit shift under the forbidden zero bit,
same split-then-classify loop, same last-one-wins rule. It is now a face over that module through
`rust/slopdesk-ffi/src/hevc_parameter_sets.rs`.

**Spans, because `NALUnit` already crosses that way.** A keyframe access unit is most of a frame and
Swift is holding it, so the door answers WHERE the three sets sit and the payloads are copied once,
inside the borrow that has the pointer. `extract_spans` is the new shape in the crate; the owning
`extract` is written in terms of it, so there is still one walk.

**An incomplete set is one answer, not three.** A format description built from two of the three
would configure the decoder wrong, so the entry answers false and leaves the caller's record
untouched rather than handing back a partial set. An empty unit's missing type crosses as a presence
flag, never a sentinel type number.

The 10 Swift tests over this type and `VideoDecoder`'s parameter-set caching were left exactly as
they were and pass unchanged.

## The scroll reprojection folds by value (2026-08-15)

`ScrollReprojector` was the last Swift half of `rust/slopdesk-video`'s `scroll_reproject` — the same
band clamp, the same integrator, the same ease-out and the same rest epsilon, written twice. It is
now a face over that module through `rust/slopdesk-ffi/src/scroll_reproject.rs`, and the stale
comment claiming "the former Rust core is retired" is gone with it.

**By value, and the class stays.** The state is seven scalars: two knobs, an offset, a velocity and
a decay flag. Nothing here is big, so nothing is worth a handle — the pane holds one reprojector by
reference the way it always did, and the reference is Swift's while the state is the law's.

**An advance answers both, because the caller needs both.** The tick produces the offset the
renderer sets AND the state the next tick folds. Splitting them into two entries would make the near
side call twice and invent a rule about which order is correct.

**The arithmetic is the point.** The separate multiply and add that must never fuse, the clamp
applied in its fixed order, the geometric ease-out that SNAPS to exactly zero inside the rest
epsilon — a second implementation would disagree in the last bits and, worse, would asymptote
instead of settling. check-supervisor bans a Swift `exp(`, `applyDecay` or band literal for that
reason.

The three `FramePacerReprojectionTests` were left exactly as they were and pass unchanged.

## The scroll resampling folds by value (2026-08-15)

⤵️ **SUPERSEDED (2026-08-27) in its CROSSING only — every law below still holds.** The injector moved
whole into `rust/slopdesk-ffi/src/injector.rs` (docs/60), which put the resampler on the same thread
that posts. So there is no crossing left to make by value: `ScrollResampler.swift` and the six
`slopdesk_scroll_resampler_*` doors it was a face over are deleted, and `check-supervisor`'s door list
for that path became a stay-deleted ban. The 14 Swift resampler tests went with them — `scroll_resample.rs`'s
own suite is the one that runs now. The fixed-pair ingest, the flush-before-End ordering and the
carried truncation are unchanged; they are simply no longer reachable from Swift.

`ScrollResampler` was the injector's Swift half of `rust/slopdesk-video`'s `scroll_resample` — same
spread, same lag cap, same flush-before-the-End rule, same carried sub-pixel fraction. It is now a
face over that module through `rust/slopdesk-ffi/src/scroll_resample.rs`, and the type stays a Swift
`struct` because that is how `InputInjector` holds it: a value on the near side, a value on the far
one, which is the convention the far side is entitled to pick.

**An ingest answers a FIXED PAIR, not a list.** The law's own branches bound the answer at two: a
marker, and at most one residual flush in front of an ending marker. That bound is now a crate
constant (`MAX_INGEST_EVENTS`) the shim's array is sized from, so the crossing needs neither an
allocation nor a length rule — the same reason the present queue's capacity is a constant rather
than a negotiation.

**The flush ordering is the part worth pinning.** A residual drained AFTER an End marker is a
`Changed` at phase 2 following a phase 4, which corrupts rubber-banding in AppKit and Chromium
alike. One implementation cannot disagree with itself about when to flush; two can.

**The truncation carries.** `drain` emits whole pixels and keeps the fraction, which is what makes
the integer outputs sum to the float input to under a pixel per axis per gesture. A second
`rounded(.towardZero)` in Swift would quietly leak that fraction, so check-supervisor bans it here.

The 14 Swift resampler tests were left exactly as they were and pass unchanged.

## The swipe recogniser is one law, and both processes read it (2026-08-15)

`SwipeNavRecognizer` was a 559-line Swift mirror of `rust/slopdesk-video`'s `swipe_recognizer` —
same three decision points, same field-tuned thresholds, same graduated slow-tier surface, same
27-entry allow-list. It is now a face over that module through
`rust/slopdesk-ffi/src/swipe_recognizer.rs`.

**This is the mirror that mattered most.** Every other port removed a duplicate that only had to
agree with itself. This one is run by TWO processes: the host's injector decides whether a flick
fires ⌘[ / ⌘], and the client's peel planner predicts that decision over the same event stream so
the overlay can fill without a round trip. Two implementations would not merely duplicate the rule —
they would let the overlay promise a navigation the host then declines, which is the one failure the
feedback exists to prevent.

**By value, because both holders are values.** Sixteen scalars and flags, held inside a Swift
`struct` on each side. `RecognizerState` is the crate's own carried form, and the threshold family is
taken as given on restore rather than re-derived from `fire_travel` — deriving it twice is how two
passes come to disagree.

**The trace line is an answer, not state.** It is recorded AT a decision and popped straight after,
so it crosses written into the caller's buffer by the same ingest that produced it, rather than
riding in a record that would then have to own a string. A restored recogniser has none pending.

**The allow-list crosses as one newline-separated answer.** A bundle id cannot contain a newline, so
the near side unpacks with a split rather than running the comma-and-trim parse a second time. An
EMPTY span means absent, not the empty string — without that distinction a null frontmost app
matched the empty entry an empty extension list produced, which the door's own test caught.

The 83 Swift recogniser and peel-planner tests were left exactly as they were and pass unchanged.

## The blob reassembly is a handle, bytes and caps and all (2026-08-15)

`BlobAssembler`, `BlobImageValidator` and `BlobChunker` were a line-for-line Swift mirror of
`rust/slopdesk-video`'s `blob` — same per-kind caps, same four-partial bound, same disagreeing-count
discard, same magic bytes, same FNV-1a. They are now faces over that module through
`rust/slopdesk-ffi/src/blob.rs`.

**A handle, so the Swift type became a class.** This is the audio-stage case, not the present-queue
one: the assembly's whole product IS the bytes, and they accumulate across many calls — up to four
partial blobs, each up to its kind's cap. A by-value record would copy the accumulator on every
chunk of every blob, which is the opposite of what the crossing rule asks for.

**A completed blob crosses in two steps.** The near side cannot know the length until the chunk that
finishes the assembly arrives, so the fold reports it and one take copies the bytes out. A take that
did not fit leaves the blob in place and reports the length again, so a caller that sized wrong
retries rather than losing it. The alternative — a fixed buffer sized to the kind's cap — would make
every caller carry a megabyte to receive an icon.

**The chunker answers one chunk at a time.** A list of variable-length payloads has no natural
crossing shape, so the door answers chunk `i` and the crate's whole-list `encoded_chunks` is written
in terms of the same per-index split. One split, two shapes.

The 10 Swift blob tests were left exactly as they were and pass unchanged.

## The window feed reassembles once, in chunk order (2026-08-15)

`WindowFeedAssembler` was a Swift mirror of `rust/slopdesk-video`'s `window_feed` — same four-
generation bound, same 512-record cap, same disagreeing-count discard, same chunk-order
concatenation. It is now a face over that module through `rust/slopdesk-ffi/src/window_feed.rs`, and
a handle for the reason the blob assembler is: the accumulator is a list of records with three
strings each, held across chunks and across generations.

**The records cross in the control decode's own shape.** Flat rows naming `(offset, length)` spans
in one arena — the same `SlopDeskControlRecord` the decode already answers with, so the near side is
holding exactly this shape when a chunk arrives and a fold costs it the marshalling an encode
already does. Inventing a second flat record type for this door would have been the duplication in a
different disguise.

**Chunk order is the part worth pinning.** Arrival order is not chunk order — that is the whole
point of a reassembler — so a second concatenation loop that forgot it would silently reorder the
window list on every lossy renewal, which reads as the feed "jumping" rather than as a bug.

The 57 Swift window-feed tests were left exactly as they were and pass unchanged.

## The keepalive cadences and the stall threshold are one record (2026-08-15)

`KeepaliveTiming` said so itself — "Native Swift twin of `slopdesk_core::keepalive`" — and
`StreamStallPolicy` spelled its own 3-second default. Both now read `slopdesk_keepalive_timing()`.

**One record, not five entries.** The five numbers are one argument: the stall threshold is sized to
tolerate two lost host heartbeats, and the reaper tick is what makes the worst-case reclaim
`idleTimeout + reaperTick`. Five separate doors would let a caller read one and reason about it
alone, which is exactly the drift the shared constants exist to prevent.

The 27 Swift keepalive and stall tests were left exactly as they were and pass unchanged.

## The four smallest send-path decisions are Rust, not Swift (2026-08-15)

`StaticFrameSuppressionDecider`, `StillnessCrispDecider`, `LiveBitratePolicy` and
`CaptureRegionFailureRecovery` each had a full Rust twin — `frame_gate`, `live_bitrate`,
`capture_recovery` — and each was still deciding in Swift. All four are now faces.

**Being small is the argument FOR porting them, not against.** A rule that is one `guard` over six
flags, a count-and-latch, a multiply-and-round, and a three-rung ternary are exactly the shapes that
get re-typed at the call site rather than called. The suppression rule is the sharp case: it is
conjunctive on `!`-of-every-obligation, so a future obligation added on one side only produces a
host that suppresses a frame the client is blocked waiting for — a freeze with no error anywhere.
The obligations therefore cross as ONE record with a field per flag, so adding one is a field on
both sides or it does not compile.

**The stillness decider folds; nothing here is a handle.** Its whole state is a count and a latch,
so each step hands the door the two numbers it was last given. §4b's test — does the far side read
the part that is big — has no big part to read here at all, and a handle would buy an allocation
per capture session for nothing.

**The density knob is parsed by the door, not by Swift.** `SLOPDESK_BPP` outside `(0, 1]` is a typo
rather than an intent, so it falls back to the default instead of being clamped — one reading, on
the side that owns the arithmetic the budget feeds. The multiplies stay separate and the rounding
stays half-away-from-zero, because the budget is what the encoder's QP ceiling is sized against.

The Swift tests for all four were left exactly as they were and pass unchanged.

## The four host accumulators are handles (2026-08-15)

`LTRController`, `RecoveryRequestDeduper`, `IdleReapDecider` and `RetransmitRing` each had a full
Rust twin — `ltr`, `recovery_dedupe`, `idle_reap`, `retransmit_ring` — and each was still
accumulating in Swift. All four are now handles.

**The LTR gate is why this one mattered.** A `ForceLTRRefresh` may only reference a long-term
reference the client demonstrably holds. Two nets enforce that: the controller's own "has anything
been acked" gate, and VideoToolbox's contract. A second copy of the gate that drifts open by one
line collapses the stack to one net and issues a refresh against a reference the client never
had — persistent corruption until the next IDR, with no error anywhere to trace it to.

**§4b's test, answered on the handle side four times.** Each of these holds something large across
many calls that the near side barely reads back. The LTR map is sixty-four mappings and production
reads only `hasAckedToken`; the dedup window is a ring of whole datagrams and the answer is one
bool; the reaper holds a record per flow and answers a short list of ids. The retransmit ring is the
sharp case — it exists BECAUSE it is large, so folding it by value would copy the whole send history
on every frame. A repair crosses in two steps instead: the selection reports its shape, one take
copies out only the fragments the NACK named.

**The Swift ring was also subtly worse, and that is now gone.** It selected fragments by reading a
byte at a fixed offset into each datagram, guarded by a length check. The crate decodes the fragment
header, so a truncated datagram is skipped rather than mis-selected, and the selection cannot drift
when the wire header moves.

**The reaper's key is concrete now.** It was generic over the flow id; the door is keyed on the
`UInt32` channel id the mux lanes actually use. A generic key would have to be interned into
something the door understands, and that interning table would be a second identity rule — the very
thing the port exists to remove. The only production instantiation was already `UInt32`.

**What deliberately stayed Swift.** `VirtualDisplayRecreateGate` keeps its `NSLock`: its whole job is
to serialise concurrent mint lanes, and a lock is not a rule. The rule it protects — `shouldAttempt`
— is the crate's.

## The aspect geometry is Rust, bit-exactly (2026-08-15)

`Geometry.swift` said so in three separate comments — "byte-identical to
`geometry::VideoRect::intersection_area`", "byte-identical to
`geometry::aspect_fit::displayed_video_rect`", "byte-identical to `geometry::aspect_fit::view_point`"
— and was still computing all three itself. It now calls them.

**A comment claiming byte-identity is the strongest possible argument for deleting the copy.** These
are the numbers a click lands on. `viewPoint` is the exact inverse of the input encoder's
`normalize`, and it is what places the local cursor overlay; if the two drift by one ULP the overlay
sits beside the click it is drawn for. The Swift copy was carrying three separate `keep mul+add
separate — FMA breaks bit-exact golden parity` comments to hold that line by hand, on a compiler
under no obligation to obey them.

**The vocabulary stays Swift; the arithmetic does not.** `VideoPoint`/`VideoSize`/`VideoRect` remain
Swift structs — they bridge to `CGPoint`/`CGSize`/`CGRect` and that bridge is the reason they exist.
Each grew one `crossing` property naming the record it hands the door. `Double.maximum` and
`Double.minimum` are gone from the file entirely, which is what the supervisor now checks: they were
only ever there to imitate `f64::max`'s NaN-ignoring behaviour, and imitation is what got deleted.

**The VD throttle went with it, minus its lock.** `VirtualDisplayRecreatePolicy.shouldAttempt` and
`VirtualDisplayTerminationPolicy.channelsToDisconnect` are `capture_recovery`'s. `VirtualDisplay-
RecreateGate` keeps its `NSLock`, because serialising concurrent mint lanes is this side's job and a
lock is not a decision.

## The peel mirror is Rust, so it agrees with the fire it predicts (2026-08-15)

`SwipePeelPlanner` was the last Swift half of a gesture whose other half was already ported. The
recogniser it wraps has crossed by value since `swipe_recognizer` landed — precisely because the
host's injector and the client's overlay must reach the same verdict over the same events — and yet
the layer that turns those verdicts into a chip kept its own copy of when to show, how far to fill
and when to ratchet. It now calls `swipe_peel`.

**A mirror that disagrees is worse than no mirror.** The whole point of the client-side planner is
feedback while the fingers are still down: the chip promises a navigation the host has not fired
yet. If the mirror shows at a different travel than the host commits at, the affordance lies — it
fills and then retracts on lift, or it never appears for a swipe that fires. Two implementations of
the show fraction are two answers to "is this gesture live", and the user sees the difference.

**The ratchet is the part that could not survive a second copy.** `glass_progress` holds the maximum
the on-glass segment reached, so a momentum tail whose dominance collapses cannot walk the chip
back. A re-implementation that simply tracked the live candidate looks correct in every test that
lifts at peak, and drops the chip mid-commit on every real swipe that decelerates. It is banned by
name in the supervisor for that reason.

**The history gate crossed as a verdict code, not as a status.** `SwipeNavStatusMessage` already
flattens itself for the boundary; `peelGated` hands the door that flat record plus one verdict code
and gets a code back. The alternative — exposing the C status type through the client module so the
planner could call the door directly — would have made a protocol type's private wire representation
public to satisfy a caller in another module.

**The near side stays a `struct`.** Doc 55 §4b's test asks whether the far side reads the part that
is big; here nothing is big. The planner is a mirrored recogniser and four scalars, fully read on
every event, and it is held inside a view's state where a value type is what the surrounding code
expects.

## The host mux routes, stamps and byes from one law (2026-08-15)

`VideoMuxRouter`, `MuxFlowTable` and `UnboundLaneByeDecider` were three Swift deciders with three
complete, separately-tested Rust twins — `mux_routing` and `mux_flow`. They now call them.

**All three guard the same failure, which is why they moved together.** A datagram from a session
that no longer exists must never reach one that does. The router answers it per lane, the flow table
answers which flow a reply rides so a rebind cannot cross two clients' streams, and the bye policy
answers whether a dropped datagram's sender deserves to be told. Split across two languages, the
three answers could drift independently; a lane the router considers retired while the flow table
still holds its stamp is exactly the shape of a leak that survives every unit test.

**The flow crosses as an id, and that is the whole shim.** A flow on the near side is an
`NWConnection`, which the crate cannot hold and should not try to. It crosses as an opaque
`uint64_t` — the object's identity — and the Swift face keeps the id → object registry so it can
turn a reaped id back into the connection to `cancel()`. That registry is NOT a second copy of the
table: it holds no rule. It is pruned by asking `slopdesk_mux_flows_tracks`, so which side of the
table an id still lives on is answered once, by the side that knows.

**The reap asks its caller back rather than taking a snapshot.** Rule one of the reap needs to know
whether an expired stamp's lane got admitted inside its window, and that answer lives in the router,
which the transport holds separately and which the tests replace with a fake. So the predicate
crosses as a C callback plus a context pointer. A snapshot would have to be taken before the sweep
it feeds — the one ordering the rule forbids, because rule 2's reference set must be built AFTER
rule 1 has dropped the stale stamps.

**A reap consumes what it reports, so it is lent at full size.** The two-call size-then-fill shape
every other door uses is wrong here: the first call would perform the reap and the second would find
nothing. The tracked-flow count is an exact upper bound on what one tick can close, so the buffer is
lent at that size in a single call. `removeAll` is the same shape for the same reason.

**`Decision.drop(reason:)` kept its string.** The crate's verdict is `DropEmpty`; the near side's
enum carries a human-readable reason the transport logs. The code is what crosses, and the reason is
re-attached on this side — the alternative was to move a log string onto the wire, which is not a
decision and does not belong in the law.

## The host window feed lists, packs, pushes and paces from one law (2026-08-15)

Four Swift files — `WindowFeedSnapshotBuilder`, `WindowFeedCache`, `WindowFeedChunkPacker`,
`WindowFeedSubscribers` — against one complete crate module, `window_feed_host`. They now call it.

**The inclusion verdict is the one that had to be single.** The picker and the feed both ask it, and
its own doc comment already said so: "the ONE inclusion policy, so the two surfaces can never
drift." It was still spelled in Swift. Two copies of an exclusion list is a window that appears in
the picker and not in the rail, or the reverse — and the list is not a heuristic anyone can
re-derive: "Cua Driver" is on it because an automation agent's transparent full-display overlay is a
real, on-screen, layer-0 window with nothing in it.

**The AX evidence gate and the structural skeleton are the two rules a re-implementation gets
wrong.** An off-screen window is listable only on accessibility evidence, because the full
enumeration is thick with phantoms that report exactly what real windows report; a copy without that
gate drowns the rail in tab caches. And WHICH flag bits count as structural is the entire coalescing
contract — a copy that called a title change structural would put any window being typed into
permanent 4 Hz burst. Both are banned by name in the supervisor.

**The cache is a handle; the push policy is not.** The cache holds a record list AND the datagrams
that list packs into, and the near side reads one reply out of it per subscribe — §4b's test, met.
The policy is two optional timestamps read whole every tick, so it folds by value, and the crate
grew `state()`/`restored()` for it the same way `swipe_peel` and `frame_gate` did.

**The pure builders answer twice; the reap does not.** A snapshot and a chunk list are
variable-length products with strings in them, so they follow §4: the call reports the shape it
would write, a second call writes it. Recomputing costs a pass over at most sixty-four rows at four
times a second — cheaper than a handle holding an answer nobody asked for. The subscriber reap is
the opposite case and is lent at the table's own size in one call, because it CONSUMES what it
reports.

**Truncation is by scalar now, not by grapheme.** The Swift dropped whole `Character`s; the crate
drops whole scalars. Both honour the rule that matters — a truncation is always valid UTF-8, never a
replacement character on the client — and they differ only for a cluster straddling the cap, where
the crate leaves the cluster's leading scalars. That is the crate's documented choice and it is now
the only one.

**One record marshalling, not four.** `HostWindowRecord` crosses as `SlopDeskControlRecord` rows
naming spans in one arena — the codebase's single flat record type. Three call sites need that
flattening and a fourth was about to be written, so it moved to `HostWindowRecordRows.swift` and the
client's assembler lost its private copy. The supervisor checks that the copy stays gone: four
hand-rolled row layouts is how arena offsets drift into each other.

## The client mux pools its flows and re-arms its loops from one law (2026-08-15)

Three Swift files went, and one of them went because it existed twice.
`Sources/SlopDeskVideoHost/Mux/UDPReceiveLoopPolicy.swift` and
`Sources/SlopDeskVideoClient/Mux/UDPReceiveLoopPolicy.swift` were byte-identical, and each carried a
comment saying the other existed: "Client + host live in separate modules and each owns an identical
copy; the behaviour contract is the agreement, not a shared Swift type." That is a contract kept by
reading. A datagram loop is a datagram loop — the re-arm question is "is the connection alive", and
the backoff is one exponential — so both now call `mux_flow.rs` through the `mux_client` door, and
the ONE Swift face lives in `SlopDeskVideoProtocol`, the module both ends already import.
`UDPSendPathPolicy` followed it: same shape, same module, and its verdict is read by the same loop.

**The pool is a handle; the flow objects are not.** `VideoFlowPool` holds a lane set per endpoint
plus the id allocator, and the registry asks it one id at a time — §4b's test, so it is a handle. But
a flow on the near side is an `NWConnection`, which the crate cannot hold and does not want to. So
the registry keeps `[String: VideoMuxClientFlowing]` — objects only, no rule — and the pool answers
the two facts that map acts on: must this acquisition BUILD a flow, and must this release CLOSE one.
The same split as `MuxFlowTable`'s id registry, one round earlier, and for the same reason.

**The seed stays on this side.** The lane allocator is seeded from a per-process random base,
because two distinct clients streaming the same host window each used to count from 1, and the
host's reply-flow maps are keyed by the bare channelID — so the second client's lane hijacked the
first's video and cursor replies. The crate stays deterministic, so the base is injected: Swift draws
the random `UInt32`, `VideoFlowPool::new` masks it into the seed band and floors it past zero. The
randomness is exactly the part a deterministic crate cannot own.

**Two behaviours are now stricter, both toward idempotence.** Releasing a lane the pool never
handed out used to still call `unregisterLane` on whatever flow was pooled for that endpoint; it now
answers `SLOPDESK_LANE_UNKNOWN` and touches nothing. And `nextBackoff` takes its count as a
`UInt32(clamping:)`, so a negative count reads as zero — an immediate re-arm — rather than as the
`guard consecutiveErrors > 0` fall-through it was.

The corpus lost its strangest import along the way: `slopdesk-corevectors` had to write
`import enum SlopDeskVideoHost.UDPReceiveLoopPolicy` because the host module also exports a TYPE
named `SlopDeskVideoHost`, making the twin impossible to qualify. One type, no disambiguator.

## The CLI is linked, and stops being written twice (2026-08-15)

`rust/slopdesk-cli` was finished, tested and then left unlinked for two days on a rule stage 16 had
recorded: *a port ships over a socket, never FFI*. That rule is void — CLAUDE.md now reads "a port
ships over a socket, **or as a linked library — pick by lifetime**" — and by that test the CLI is
not a socket port at all. It starts, does one thing and exits. Nothing outlives its caller, nothing
`execve`s it, no second process dials it. It is in-process by necessity, which is what a linked
library is for, and it is now linked: `SlopDeskCLICore` is the face, and the flag grammar, the five
completion scripts, the config-file rules, the six output tables and the version banner are the
crate's.

**Rows cross as JSON text, and that is not a cop-out.** They ARRIVE as JSON — the control socket
answers NDJSON — and they leave as JSON or as a table, so decoding them into a flat record on the
way through would mean writing a schema for six lists and re-encoding it on both sides. The crate
already parses JSON for exactly these bytes, and its own manifest gives the reason: a pane title or
a cwd path is something a foreign program drew into a PTY, and hand-rolling an unescaper for that is
the classic place to be wrong.

**The keybind grammar is asked back.** `config validate` checks a file against the grammar the app
actually honours, which is a Swift parser the crate has no business depending on — so it crosses as
a `@convention(c)` callback with its context, the way the mux reap's admitted-lane question already
does. The verdict then tracks exactly what the launch bridge will honour, rather than a second
grammar that agrees today.

**The version NUMBER stays in Swift, deliberately.** `docs/49` names six version sites and
`bump-version.sh` owns all six because no gate can see most of them. A seventh, in Rust, would be
one the bump script does not know about and `package-release.sh` would not catch, because that gate
asks the built CLI binary. So the number is passed in and the crate owns only the banner's shape.

**Three more twins went with it.** `JumpResolver`, `WatchClaudeOutcome` and `WatchProgress` had live
Rust counterparts in three different crates — `slopdesk-workspace::jump`, `slopdesk-agent::watch`
and `slopdesk-wire::osc` — and each is now a face. The watch bytes matter most: they are built by
the same crate the host's sniffer parses them with, so the wrapper can no longer emit a sequence the
host would drop, and `WatchNotificationMarker` reads the sentinel from `osc.rs` rather than spelling
it a second time in `SlopDeskProtocol`.

**`FolderFrecency` came along because a jump reads it.** It scored and ranked in Swift while
`frecency.rs` did the same in Rust, and the jump resolver sat between them. The database now crosses
by value — a record array plus one arena of path bytes, §4b's fold — and the ranking answers the
caller's OWN indices rather than copying the paths back: a rank is a permutation of what was just
lent, and re-crossing the strings to say so would be the one wasteful thing in an otherwise-free
call.

`build-ffi.sh`'s `INPUT_CRATES` gained `rust/slopdesk-cli` in the same change. A linked port has one
failure mode a socket port does not — an artifact older than its sources, green tests and all — and
the staleness gate only sees the crates it is told about.

## Three small rules stop being written twice (2026-08-15)

Small is exactly why they are worth naming. A placement that is two multiplies, a parser that is
one split and an arrangement that is one line are the shapes that get re-typed at a call site
instead of called — and each of these three had a failure mode the type checker cannot see.

**The cursor overlay must land on the pixel the input encoder targets.** `ClientCursorCompositor`'s
placement math mapped the host position through the forward render transform while
`cursor_overlay.rs` did the same in Rust, and the two are only equal while nobody contracts a
multiply-add. They are one function now, next to the `view_point` the input path inverts, so the
cursor the user sees and the coordinate the host receives cannot drift at any zoom or in any
letterbox. The `is_placeable` guard came with it: a non-finite component raises an uncaught geometry
exception that kills the process, so that check is now the same one on both sides, and the
logical-size fallback that was written inline TWICE in the same file — once for `NSCursor`, once for
the layer bounds — is one call.

**The progress parser and the progress builders are one grammar.** `ProgressOSCParser` read
`9;4;<state>[;<pct>]` in Swift while `osc.rs` both wrote and read it in Rust. The parser now sits in
the same door as the builders whose output it reads back, which is the point: `slopdesk watch`
prints a spinner and the host's byte reader turns it into a control message, and a second copy of
the grammar between them is how a spinner starts surviving the command that raised it.

**The windowList arrangement crosses as flags, not windows.** The rule reads exactly two facts about
each window — is it on screen, does it carry a title — so those two arrays go over and the answer
comes back as indices into the caller's own list, the same shape `slopdesk_folder_ranked` uses. The
generic Swift signature is unchanged, so callers still hand it their own window type and their own
accessors; only the ordering moved.

## A client video session decides once (2026-08-15)

`VideoClientSessionLogic.swift` held the client's whole lifecycle — the state machine, the
hello-retry cadence, the reconnecting-scrim latch — beside `rust/slopdesk-video`'s `client_session`,
which held the same one. The Swift half is a face now.

**The machine crosses BY VALUE, because the near side reads all of it.** Six scalars and two
rectangles, every one of them read on the Swift side (`state`, `streamID`, `captureSize`,
`windowBoundsCG`, `mediaFlowing`, `requestedWindowID`), and the Swift type is a `Sendable` struct
that callers copy. §4b decides this, not convenience: a handle behind a copied struct is two owners
aliasing one allocation. So the record rides in and out of every call and value semantics survive.

**A transition commits only when its answer fits.** The two-call shape — measure, then fill — would
apply a MUTATING call twice. Each entry point therefore steps a copy, measures, and writes the
machine back only once all three lent buffers are big enough. A call that did not fit is not a
transition, so calling again with the reported shape repeats the same one rather than adding a
second. That is what makes the ordinary lent-buffer protocol safe for a machine that moves.

**A control message crosses as its bytes.** `SendControl` carried a typed `VideoControlMessage` that
the runtime did exactly one thing with: encode it. The effect now carries the encoded datagram, so
the hello that opens every session is minted by the same crate the host parses it back with, and the
runtime just puts bytes on the wire. The client tests assert on those bytes through the Swift codec,
which pins the two encoders to the same output on the one message nothing else would catch.

**The router did NOT come with it.** `ReceivedDatagramRouter` answers typed values —
`FrameFragment`, `WindowGeometryMessage`, `AudioChannelMessage` — decoded by the Swift codec, which
is still Swift. Moving the router before the codec would cross four decoded types to save one
`switch`; it moves WITH the codec or not at all.

## The pane pans, scales, adopts and snaps by one set of rules (2026-08-15)

Six rules in the same Swift file — the edge-pan gate and its clamp, the layer-to-decoded scale, the
pre-decode triage, the frame-gated resize adoption, the drag debounce, the 1:1 snap — sat beside
`client_view.rs`, which held all six. Each is two or three sizes wide, which is exactly why they get
re-typed at a call site instead of called, and each has a failure the type checker cannot see: a pan
gate and a clamp that disagree about the ZOOM leave a zoomed-in window's overflow unreachable or only
half reachable; an adoption gate that accepts an in-flight old-size frame mis-scales the cursor for a
beat; a debounce that mints an epoch on a CLIENT-side snap echoes a resize request that re-triggers
the snap, a feedback loop with the host's window inside it.

**The debounce rides as a record, and the absent sizes carry a flag.** Four fields, all of them read
on the Swift side, so §4b makes it a value rather than a handle — the same call the state machine
makes. `ResizeDebounce::restored` is how it gets back in: replaying the epoch through
`note_requested` would be a loop over a counter that only grows. The optional previous decoded size
crosses as a value plus a presence flag for the reason the stall verdict's stamps already do — "no
frame has arrived" and "the last frame was zero by zero" are different states and only one of them
means adopt.

**The defaults moved with them.** `minDelta = 8` and `settleInterval = 0.2` were Swift literals over
a crate whose `Default` already spelled the same pair, and `epsilon = 0.5` shadowed `SNAP_EPSILON`.
The Swift `init()` now asks for the crate's, so "settled" cannot come to mean two things.

## check-supervisor's `spells` was matching nothing (2026-08-15)

`spells` piped a comment-stripped file into `grep -q`, and `grep -q` exits the instant it matches —
`sed` then dies of SIGPIPE, and under `set -o pipefail` the pipeline reports failure. A spell that
was FOUND read as not found. Every existing caller was a BAN, which expects no match, so the helper
had never been asked a question whose answer it could get wrong. The first presence check written
against it failed on code that was plainly there. It matches from a here-string now.

## A pane's master crosses as an owned duplicate, not a second lookup (2026-08-15)

superd answered `spawn` by inserting the pane and then asking the map for its master fd by name. The
two steps are not one decision, and the gap between them is where a pane can stop existing: the
reaper's first act on a child's death is to remove the pane and drop its master, and a child like
`/bin/sh -c "exit 0"` is usually already dead by the time the reply is being assembled. The lookup
lost that race two ways, both silent. It found nothing — `.ok()` turned that into "no descriptor",
the reply still went out with status `ok`, and hostd raised `missingDescriptor` for a child that had
really run (this is what made `testRapidSpawnShutdownChurnDoesNotLeakFDs` flaky under load). Or it
found a `RawFd` the reaper had already closed and the kernel had since reissued to another pane's
master, a journal file, an accepted socket — and hostd would have adopted that, wired it to the pane,
and reported nothing wrong.

`Registry::spawn` and `Registry::adopt` now return `(PaneRecord, OwnedFd)`, the duplicate taken while
the function still holds the master outright, and `master_fd(pane_id)` is deleted rather than left
for the next caller. `frame::write` takes a `BorrowedFd` instead of a `RawFd`, which is the same fix
made structural: "the descriptor is open for the length of this `sendmsg`" stops being a comment.
The connection handover path was already correct — it borrows the accepted `UnixStream` across the
send — and now says so in its type.

## The click lands where the cursor is, and the latch is a bitmask (2026-08-15)

`InputEventEncoder.normalize` was a second copy of the render transform's inverse, and it is the one
piece of client math a copy gets subtly WRONG rather than loudly broken: a click that lands near the
pixel under the cursor instead of on it reads as a remote machine that feels off, not as a bug
anybody files. It is golden-pinned for exactly that reason, and it now folds through
`client_input.rs` — as does the event tag, whose only content is that it WRAPS rather than traps.

**The mapping crosses flat, with a flag.** `PointerMapping` is a two-variant enum and C has none, so
both arms ride one record beside `has_crop`. Not a sentinel: an all-zero crop is a degenerate
actual-size viewport, which is a different answer from "there is no crop", and only one of the two
takes the aspect-fit path the golden vectors pin.

**`ModifierLatchTracker` became a `u64`.** The vocabulary is nine keycodes, 54 through 63, so the
whole tracker is a bitmask — no allocation per pane, and nothing for two copies of a `Sendable`
struct to alias (§4b). The rewrite also closed a real hole: the `Set` accepted keycodes that are not
modifiers at all, latched them, and would have synthesised a bare key-up for them on the next focus
loss. Only a HELD modifier can be owed a release, which is now one rule where there were two — Caps
Lock is refused because it is not in the vocabulary, not by a special case beside it.

**`CursorShapeRequestTracker` crosses through lent buffers.** It holds a set and a map keyed by
host-assigned shape ids, and nothing bounds them: the host mints an id per distinct rendered cursor
bitmap, so an app with animated cursors keeps minting. That rules out a fixed record, and being a
value-copied `struct` rules out a handle (§4b), so the two lists ride in and out as `(ptr, len)`
pairs — ids ascending, stamps parallel. The buffers are lent one longer than what is held, which is
the most any step can add (an arrival caches one id, an ask records one stamp), so the write always
fits and there is no measure pass. The answer is adopted only when it did fit: a step that could not
write is not a decision, and acting on its `send` would put an ask on the wire the tracker has no
record of — the flood the interval exists to prevent.

**Two Swift tests were passing because this machine is quick.** `testRapidSpawnShutdownChurnDoesNotLeakFDs`
found the superd fd race above. `testPrewarmWithMissingExtensionsSpawnsWhenTheInstallLands` asserted
"no child has booted yet" against a install task running on another queue — true only while the CLI
had not returned, which under a full `make test` it already had. The fake CLI now blocks until the
test opens it, so the window is a fact rather than a hope.

## The scroll hint is one encoding, and it is spelled once (2026-08-15)

Scroll reprojection has two halves in two processes. The host measures the true per-frame content
shift between captured frames and normalises it — a signed value in TEN-THOUSANDTHS of the frame
extent, plus the moving-content band in the same units — and the client turns that back into a
velocity for the reprojector and a mask for the renderer. The scale, the confidence gate, the
saturation and the band's inclusive-row-to-exclusive-edge step were spelled TWICE, once in
`WindowCapturer.measureScrollOffset` and once in `VideoWindowPipeline.applyHostScrollOffset`.

Two spellings of one encoding is the failure mode nothing catches. Change the host's rounding, or
the `+1` on the band's bottom row, and every scrolled frame warps by a hair against a client that
still decodes the old way: no test fails, no frame is dropped, the remote machine just feels
slightly wrong. So both halves moved into `scroll_reproject.rs` as `ScrollHint` — `measured(...)`
encodes, `velocity(fps)` and `band()` decode, `SCALE` and `MIN_CONFIDENCE_MILLI` are named once —
and `check-supervisor.sh` now fails if either Swift file respells `10000.0`.

The band crosses as a value plus a PRESENCE flag, not a sentinel. An empty span at the top of the
frame is a degenerate band, and the client's rule for "the host measured no band this tick" is to
KEEP the last one so the decay eases out still masked — a rule a `(0, 0)` cannot express.

`reprojectionPhase` moved with it, as `ScrollPhase::of_platform`. It reads the momentum code before
the finger code because momentum is the later half of one gesture: a frame carrying a stale finger
`ended` under a live momentum `continue` is coasting, not stopped. That mapping had drifted into
being reachable only from a test — one more reason it belongs where the phases are defined.

## The park math goes back to Rust, and Swift keeps only CoreGraphics (2026-08-15)

`WindowPlacementMath` — where a remoted window lands on the virtual display, and whether it actually
fit once the app was done with it — carried a comment saying a Rust twin had "mirrored this" and was
"now reabsorbed". That reabsorption was made under the old ruling; under the current one a pure
arithmetic rule stays in Swift only if SwiftUI or AppKit requires it, and this one requires neither.

It is now `window_placement.rs`, and the split is drawn where the semantics actually live. What
CoreGraphics DEFINES stays on the near side: `CGRect.width` standardises (returns `|size|`) while
`CGSize.width` is a raw stored field, so the clamp is asymmetric, and the face reads each through
the accessor that defines it. What is merely arithmetic crossed: the ordered comparison and the
half-point tolerance. The far side never abs's anything — it is told which side it is holding.

The ordered comparison is the reason the vectors are bit patterns. `display < window` is false for a
NaN operand, so a NaN window size passes through; a minimum that "ignores NaN" would hand back the
display's extent instead. Both answers are the same width for every finite input, and the corpus is
the only thing that can tell them apart.

`windowPlacement` / `windowFits` were frozen with nothing reading them for a long time — pinned by a
sentence that named a crate and a test that had both been deleted. A Swift suite revived the pin
earlier; the port adds the crate-side replay of the same 19 cases, so each side pins the half it
owns. `check-supervisor.sh` now fails if the tolerance or the clamp reappears in Swift.

## The keybind grammar is Rust, and the CLI stops asking Swift for it (2026-08-15)

`config validate` had a shape worth naming: the crate walked the file, and for every line it called
a C function pointer BACK into Swift to ask "is this value a keybind?". The reason was sound — the
validator's verdict must track the grammar the app actually honours, and the grammar was Swift — but
the result was a round trip across the door per line, and a seam where two languages had to agree.

`KeybindGrammar` is now `rust/slopdesk-terminal/src/keybind.rs`, so both ends of that round trip are
the same side. `config.rs::validate` still TAKES the grammar as a parameter — the file's shape and a
value's grammar are genuinely separate questions, and its own tests use a stand-in — but the door
supplies `keybind::parse_line` rather than a pointer back into Swift, and `SlopDeskKeybindValidFn` is
gone from the header.

A binding crosses as a record plus three runs — base key, payload, argument — interned into one
arena the caller lends: measure, then fill. A record whose runs did not fit comes back invalid,
because a half-written payload would put bytes on a pane the user never wrote. An absent argument is
a FLAG, not an empty run: the grammar refuses `goto_tab:`, so "no argument" and "an empty one" are
different answers and only one of them can arise.

What stays in Swift is `KeyChord`'s canonicalisation. The far side answers the base key as the user
lowercased it; the alias fold (`leftarrow` → `left`) and the canonical modifier order happen in the
same initialiser a DISPATCHED chord goes through, which is exactly what makes a parsed chord and a
dispatched one key the same map entry. Moving that fold would have split it in two.

The Swift suite was rewritten rather than kept: restating each escape and each refused base key
beside the crate's own cases is the cross-language mirror fixture the one-implementation rule
forbids. It now pins the CROSSING — the whole line, the arena round trip, the canonicalisation — and
the grammar's cases are pinned once, where the grammar is.

## The terminal config text is emitted once, in Rust (2026-08-15)

`TerminalConfigBuilder` turned a `TerminalPreferences` into the libghostty config text the client
hands `ghostty_config_load_string`, and every rule in it was a rule about libghostty: which key a
preference actuates, which value is skipped rather than emitted blank, whether a hex string is a
colour, and — load-bearing — what ORDER the lines arrive in. `background` after `theme` is what makes
the explicit colour win; the palette after `foreground` is what makes the theme's sixteen entries win
over both; `font-feature` rides EVERY build because a font that ships ligatures turns them on itself,
so "ligatures off" has to say so. None of that is SwiftUI or AppKit, so none of it stays in Swift:
the emitter is `rust/slopdesk-terminal/src/config.rs` now, reached through
`slopdesk_terminal_config_string`.

A second emitter is the failure mode this closes. It would not fail a test — it would quietly hand
libghostty a different terminal, one key or one line-order apart, and the user would see a font that
does not thicken or a selection that inverts. `check-supervisor` therefore bans a libghostty config
line, a hex validator, a number formatter and a per-line byte estimate from the Swift file, the way
it bans the keybind vocabulary.

The preferences cross as the RAW VALUES they persist as — `primary-only`, `macos-like`,
`block_hollow`, `dlig` — not as codes. The enums are `Codable` and bound to the UI, so they stay
Swift; but which libghostty key one of them actuates is a libghostty fact, and it is written once, on
the far side. A raw value the crate does not know takes the branch that emits nothing, which is what
a preference from a build that is not this one deserves. `baseFeatures`, `syntheticTokens`,
`disablesFace` and `thickens` are gone from `TerminalFontSettings` for that reason. The one exception
is `LineHeightMode.adjustCellHeightPercent`, which stays: `CodeFontSync` reads the percent too, so
the mode resolves on the near side and the CLAMP and the formatting are the far side's.

Two dozen strings do not cross as two dozen `(ptr, len)` pairs. They cross as one record of named
`(offset, length)` runs into a single blob the caller interns — the keybind door's shape, widened —
and the answer comes back through the same measure-then-fill lending every text door here uses. The
two LISTS, the user's keybind lines and the palette's sixteen entries, cross as their own arrays of
runs rather than as one delimited blob: a delimiter is a thing a value could contain and a count is
not.

The control block crosses as a value plus a presence flag, not as a block of switches all off.
Absent emits none of those lines at all, which is what keeps a build from a caller that has no
controls byte-for-byte the build from before controls existed — the guard the Swift suite has always
carried, and the reason `has_controls` is a field rather than an inference.

A NaN cell-height multiplier resolves to the UPPER bound, not the lower and not `nan%`. That is what
`Double.minimum`/`.maximum` did, and `f64::min`/`f64::max` are the same IEEE operations, so the port
is exact. It is deliberately NOT `f64::clamp`, which propagates a NaN input — the one answer that
must never reach libghostty.

The Swift suites were kept, not rewritten. Unlike the keybind grammar, whose cases were restated on
both sides, these tests already asked their question through the whole builder — the exact default
output, the ordering probes, the validate-then-drop palette — so every one of them is a crossing test
already, and the byte-for-byte default-output guard now pins the port itself.

## The config file has one reader, and a CRLF file binds what it says (2026-08-15)

`slopdesk config validate` exists to answer which lines of `~/.config/slopdesk/config.toml` the app
will actually honour — that is why it validates against the keybind grammar rather than against a
generic `key = value` shape. But the LINE reader was spelled twice: once in `slopdesk-cli`'s
`config.rs` for the validator, once in Swift's `KeybindConfigLoader` for the client. A comment in the
crate said "mirror the loader's lenient quoting", which is the one-implementation rule being broken
out loud.

They disagreed on one byte. The crate trimmed a carriage return; Swift's `.whitespaces` does not
include one. So in a file written with CRLF endings every `keybind` value ended in `\r`, the keybind
grammar refused it as part of the base key, and the line was dropped — by a validator that had
already printed the file as clean. `classify_line` is now the single reader and `keybind_value` is
the loader's reading of it; the validator maps the same classification to its messages.

The Swift split was the other half of the same bug, and it was worse: a CRLF pair is ONE Swift
`Character`, so `split(separator: "\n")` never matched it and a CRLF file arrived as a single line
that bound NOTHING at all. The split now names both separators, which is exactly what the far side's
`split('\n')` over bytes does — there the `\r` stays on the line and the reader trims it.

`defaultConfigURL` went through the door too. `slopdesk config path` and the client were computing
the same XDG path from the same two variables in two languages. What stays in Swift is the `nil`:
with neither variable set there is no home to build a path under, and a loader declines to guess one
rather than reading a file at an invented location — the CLI, which must always print something,
passes a fallback instead. That is a policy about whether to look, not about where.

## A number is spelled once, and `toEnv` stays where its readers are (2026-08-15)

`EnvBridge.formatDouble` and the config emitter's `format_size` asked the same question — what a
user types for this number — and answered it twice, in two languages, differing only in the limit at
which an integer stops being written as one (`1e15` against `1e9`). Two rules that must agree and
have no way to notice they don't. The rule is now `config::number_text(value, limit)`, and the limit
is an argument: the config text asks at `CONFIG_INTEGRAL_LIMIT`, the env overlay through
`slopdesk_settings_env_number_text`, which carries `ENV_INTEGRAL_LIMIT` so no Swift file spells a
limit at all. Above `1e15` the two sides print an integral value differently — Swift's `String(_:)`
reaches for an exponent where Rust writes the digits out — and both parse back to the same `Double`,
which is the only property a `SLOPDESK_*` value has to have.

The rest of `EnvBridge.toEnv` does NOT move, and the reason is not effort: every read site of the
keys it writes (`SLOPDESK_QP_SHARP`, `SLOPDESK_VD`, `SLOPDESK_PLAYOUT_MS`, …) is Swift — no `rust/`
file names one. Porting the write half alone would open a new cross-language seam rather than close
one, which is the opposite of what the one-implementation rule asks for. It moves when its readers
do.

The measure-then-fill dance around a text door had three spellings in the same module by then, and a
measure that disagrees with its fill is a truncated answer that reads as an empty one. `lentText`
asks and fills, once.

## One named-key table, and `space` was never meant to be off it (2026-08-15)

A chord has spellings a config file may use and one spelling it is stored under, and those were two
tables in two languages: `is_valid_base_key`'s `matches!` said what parses, `KeyChord.canonicalKey`
said what each folds to, and `mapKey` restated the aliases a third time. Kept in step by hand, they
drifted exactly the way that arrangement drifts — `space` was refused by the grammar while `mapKey`
resolved it and the dispatcher produced it (⌃⇧Space enters Vi mode), so a chord the app can deliver
was one no config file could ask for. The rows are `NAMED_KEYS` now; `is_valid_base_key` and
`canonical_base_key` are both read off them, the near side folds through
`slopdesk_keybind_canonical_key`, and `mapKey` lost its alias branches because a chord reaches it
already folded.

`canonical` — the order-stable identity two equal chords share — moved with it, to sit beside the
`parse_chord` it inverts. A writer that drifts from its reader emits a chord the config file cannot
express, and a round-trip test over all sixteen modifier combinations now says it doesn't.

`EnvConfig` does NOT move, and not for lack of trying: it is the interposition point ~192 Swift
`static let` sites resolve through, and its parse rules ARE Swift's (`Int(_:)`, `Double(_:)`,
`RawRepresentable`). There is no second implementation to close — porting it would mean reproducing
Swift's numeric parsers in Rust exactly, which manufactures a cross-language risk where none exists.

## The off-screen rescue asks for a step rather than taking a trait (2026-08-15)

`OffScreenWindowMintRescue` and `mint_rescue.rs` were the same decision tree written twice, and the
tree is the load-bearing part: capture size is locked from the minted handle's frame, the Dock
restore reports intermediate frames that already claim to be on screen, and a mid-animation mint
crops the pane permanently because the geometry watcher installs only after the mint. A second copy
of that does not fail a test — it crops a stream.

Moving it hit the reason it had not moved: every effect the rescue needs SUSPENDS on the near side —
two `SCShareableContent` enumerations, an AX call that hops to the MainActor, a sleep — and the
crate took a trait of them, which no C ABI can call back into and wait on. So the tree stopped
calling and started ASKING: `begin` opens a rescue, its `step` names the one effect the caller owes,
`advance` takes what came back. The state crosses by value, seven scalars, and its `step` field is
both what to do next and where the rescue is — no two stages ask for the same step, so nothing else
has to cross. No window handle crosses at all: Swift keeps the two it might mint from and the far
side names which, so the rescue reasons about a window with no way to touch one.

An observation that answers a question the machine did not ask is not an answer, and the rescue
refuses on it — the same terminal answer it gives a window it cannot restore, so a caller that drives
the protocol wrongly falls back to the picker rather than minting something arbitrary.

## The discovery keeps its gate in Swift, and takes its schedule from Rust (2026-08-15)

`VideoWindowDiscovery` had the one-shot discovery written twice — once for windows, once for
displays — and `mux_client_pool`'s `OneShotDiscovery` was a third copy that nothing ever reached.
Only one of the three parts had a reason to cross.

The SCHEDULE did: when each resend goes out is arithmetic, and the Swift loop had no answer for an
interval of zero or less, which is not a schedule but a spin that sends as fast as the CPU allows
until the deadline. It comes from `request_send_offsets` now, and each wait is to an absolute
instant so a slow send cannot walk the plan later than it was planned.

The GATE did not. Which reply answers which request is `if case let .windowList(w) = msg` — one act
that both tests the message and takes the list out of it — and the message is decoded on this side,
through the codec door, into Swift values. Crossing the gate would have added a door without
removing a spelling, and would have re-crossed records the decode door had just produced. So the
unreachable Rust half was deleted rather than wired up, and the five behaviours its tests pinned —
first reply wins, a resend's echo is ignored, someone else's reply does not land, an empty answer
resolves the picker — moved to a Swift suite against the box that actually implements them.

Writing that suite found the bug the missing pin had been hiding: `ReplyBox.finish()` only marked
the box resolved if a waiter was already parked. The sender is a `Task`, so the deadline can pass
before `firstReply()` is reached — with an empty schedule it always does — and the waiter that
arrived afterwards then saw neither a result nor a resolution and parked forever. The picker hung on
a discovery that had already given up.


## The motion coalescer answers a plan, not events (2026-08-15)

`InputMotionCoalescer` and `input_routing::coalesce_motion` were the same rule in two languages, and
the Rust one had no consumer at all — the whole run rule, the class boundary, and the scroll sum
existed twice with only 14 golden vectors pinning either. The rule is arithmetic over an ordering,
which is exactly what belongs on the far side, so the Swift half is now a face.

What blocked the obvious door is the `.text` arm. Events cross as `SlopDeskInputEvent`, one flat
record with no room for a string — encoding gets around that by taking the bytes alongside, which
works for ONE event and not for a batch of them, where each would need its own span and the answer
would need to hand every span back. But the coalescer never invents an event: a surviving move or
drag IS the run's last input, and a merged scroll is the run's last input with its deltas replaced
by the run's sum. So the answer is a PLAN — one `{source, dx, dy}` slot per output — and Swift
applies it to the events it is already holding. Nothing that has no home in the flat record ever
leaves this side, and a text event's bytes are not even read to key its run, because a text event is
a barrier whatever it says.

`coalesce_motion` did not stay a second statement of the rule: it is now `coalesce_plan` applied to
its own input, so there is one fold and the crate's own tests exercise the same code the door does.
The pin that makes the split safe is the round trip — a batch rebuilt from the plan equals the batch
the fold answers, for both settings of the scroll knob.

A record the door cannot rebuild — an unknown `message_type`, a button outside 0..2 — counts as a
BARRIER rather than being dropped or merged. Swift builds these records from its own enum so the
case is unreachable in this build, but the conservative answer is the one that cannot lose an event
or reorder one across a click.

## The raise rule is read once, and the router that folded it is gone (2026-08-15)

Raising is the expensive half of injecting — six to ten synchronous accessibility calls the input
consumer awaits before the click is posted — so the four predicates deciding it were worth getting
to one place: a button-down always raises, a mouse-up re-arms the latch, a scroll is exempt even
armed and does not satisfy the latch, everything else raises only when armed. They were four Swift
statics and four Rust functions nothing reached.

They cross as one call. `slopdesk_input_raise_flags` answers all four as bits of one word, because
they are one reading of one event and four separate doors could be asked about four different
events. The frontmost-app policy crosses beside it, with the pid as a value plus a presence flag —
a pid that means "none" is a pid that can also match a target by accident.

`route_input` did NOT cross, and was deleted rather than wired up. It folded three decisions that
each already have exactly one home: the streaming gate is the session actor's (and carries a trace
the actor logs, which is not a pure decision at all), the decode is a door, and the raise rule is
the door above. Swift's `InputDatagramRouter.route` composes the three and is what the tests drive;
the live path never called either router, so folding them would have added a third spelling of a
decision the actor makes inline. The three behaviours the Rust tests pinned — a corrupt datagram
drops, a non-streaming session ignores before decoding, a decodable one carries the raise verdict —
are the Swift suite's, and they now reach the same Rust rule through the doors.

## The two input folds cross by value, not as handles (2026-08-15)

`InputButtonBalance` and `ScrollCoalescePlanner` were the last two Swift↔Rust mirrors on the input
path, and both are STATEFUL — which usually argues for a handle. Here it argues the opposite. The
ledger is held under the injector's lock, CARRIED across a reconnect by the session, and folded on
its own thread by the tests; the accumulator is an actor field and a test's local. Every one of
those owners copies. A handle they copied would be two ledgers by the second copy, silently, with
both halves looking right — so the state crosses instead (`docs/55` §4b).

That is affordable because both states are small and closed. The ledger is twelve bits: three
buttons the wire admits, and nine modifier keycodes. Its modifier bit is a key's POSITION in
`modifier_keys::HELD_MODIFIER_KEY_CODES`, which is why `InputModifierKeys` now takes that table
through a door rather than spelling it — a table spelled twice would be a ledger that means one
thing on one side and another on the other. The accumulator is six numbers and a scroll template,
and a scroll is all scalars precisely because a summed emit is the planner's own event.

The accumulator's answer is a plan, like the coalescer's, and for the same reason: a passed-through
event is NAMED so its `.text` payload stays on the Swift side, while a summed emit is carried whole.
Its door also commits the state ONLY when the answer fits, so a caller that lent too little may
retry without folding the run twice — Swift lends `2 * count + 2` and never has to.

What did not move: `plan(run:now:)`'s clock. `now` is the caller's `systemUptime`, sampled once per
run, and a door that read a clock of its own would fold on a different one than the caller's gate
was armed against.

## The swipe-nav operating point is a handle, and the allowlist face is gone (2026-08-15)

The host's `SLOPDESK_SWIPE_NAV*` family is parsed ONCE, in `rust/slopdesk-ffi`'s `swipe_nav_config`,
and `SwipeNavHostConfig` is a face over the handle it answers. Where the input ledger and the scroll
accumulator cross by VALUE, this one is a handle for the two reasons `docs/55` §4b names together:
it carries an allowlist EXTENSION — a set of bundle ids read out of the environment, which no fold
of scalars holds — and its owner is a process-lifetime namespace that never copies it. A handle is
the wrong shape exactly when something duplicates it, and nothing here does; nothing frees it
either, because the parse outlives every caller by construction.

Every environment value crosses as a `(pointer, length)` pair where NULL means UNSET, which is not
the same as an empty string: `SLOPDESK_SWIPE_NAV=` is a value a user can set, so a present value's
buffer is kept non-empty on the near side rather than collapsing to the NULL address an empty
`Array` would lend. A value that is not UTF-8 reads as absent, the default every switch answers to
anyway. The history read crosses as `has_history` plus two flags, because UNKNOWN is what makes the
client fail OPEN rather than show a dark chip, and no pair of bits can say it.

Deleted in the same change: Swift's `SwipeNavPolicy` and the four doors it was the only caller of
(`slopdesk_swipe_navigable_apps`, `_extra_apps`, `_fire_travel_from_env`, `_is_navigable`). They
answered the allowlist, its extension and the travel knob APART from any operating point, which is
precisely what let the fire path and the status push read the environment twice — the drift this
module exists to prevent, and one whose symptom is a committed chip and its haptic promising a
navigation the host silently swallows. Their Swift tests moved into `swipe_recognizer.rs` beside the
list they pin: the 27-entry floor, the pre-release channels of every browser, and the
reject-to-default (never clamp-to-bound) travel cases.

The one knob the face still reads alone is the master switch, and only where the fire path exits
BEFORE it knows a target app; every other caller asks the eligibility question, which carries it.

## The client's gesture policies cross in three shapes (2026-08-15)

`client_gestures` had no consumer; now the four Swift files it mirrors are faces over it. The
interesting part is that one module crosses three different ways, each picked by `docs/55` §4b
rather than by taste:

**Predicates cross as arguments.** `forwards_pointer` and `is_background_click` are two booleans in,
one out. Nothing to own.

**The pinch planner and the scroll-route pinner cross BY VALUE.** Both are stateful — a residual, a
pin — and both are owned by a SwiftUI view, which the framework copies whenever it pleases. A handle
two copies shared would be ONE accumulator serving two gestures: a pinch bleeding steps into the
next, or a coast routed by a gesture that already ended. So the state crosses as what it IS (one
`double`; one `bool` plus its presence flag) and every door answers the new state beside its
verdict. This is the same reading that made the input ledger and the scroll accumulator values, and
it is worth stating in the negative: a handle is not the safer default, it is the wrong shape the
moment anything duplicates its owner.

**The zoom-reset denylist is a handle**, for the swipe-nav config's reason: it carries a runtime
extension SET out of `SLOPDESK_PINCH_ZERO_UNSAFE_APPS`, which no fold of scalars holds, and its
owner is a process-lifetime namespace that never copies it. A NULL app name is a desktop pane and
fails OPEN — a pane streaming a whole display cannot know its frontmost app.

Deleted with the port: Swift's own step threshold and per-event cap, its phase-code comparisons (1,
128, 8, 3 — which phase begins or ends a gesture is the pin's rule, not a transcription of
CoreGraphics), the `"Xcode"` denylist and its `extraUnsafe` parse, and `VideoWindowView`'s
`pinchZeroExtraUnsafe` — the view now asks a question instead of holding half its answer.

## The paced-send schedule crosses; the sleeps do not (2026-08-15)

`send_pacing` had no consumer, and `VideoSendLane` spelled its own chunk loop. The split is by what
each side is for: Swift's structured concurrency owns the SLEEPS, the consumer task and the abort
generation; `send_pacing` owns what decides — the chunk boundaries, their ABSOLUTE deadlines, and
whether a job may skip the lane entirely.

The datagrams never cross. A chunk names the caller's own array by index — the motion coalescer's
shape — so a frame's hundreds of kilobytes stay where they were packetized, and the plan is
measured with a null buffer and then filled.

What the port actually fixed is a duplicated rule the code documented rather than removed: the
session computed `gapNanos == 0 || outgoings.count <= chunkFragments` to choose the inline path, and
the lane computed the same expression again to decide to send in one shot. The comment at the first
said it "mirrors the lane's own one-shot test" — a drift risk stated as a promise, and the drift
would have been an inlined frame paced differently from how the lane would have paced it. There is
one test now; `trySendInline` takes the whole job and asks the door, and the session's `singleShot`
local is gone.

Also deleted: `rust/slopdesk-video`'s `packetize_lane`. It was the second copy of a COMPOSITION —
peek the frame id, packetize, tag the channel — whose heavy half is already single-sourced in Rust
behind the packetizer handle, and whose remaining content is a Swift actor hop (which is the whole
point of the lane) plus a one-line channel tag. Wiring it up would have moved a `map` at the cost of
crossing every datagram a second time; the peek-and-assign atomicity it advertised is already held
by the actor that owns the handle.

## The host session machine crosses by value, and the handshake is decided once (2026-08-15)

`client_session` already carried the CLIENT's half of the hello negotiation. `session_state` is the
host's, and it crosses the same way for the same reasons — which is the point: the two ends of one
handshake should not disagree about what a hello means.

The machine crosses BY VALUE. Nine scalars (the state, the negotiated size, the target and its
kind, the stream-id counter and the last one minted, the range flag, the last applied resize
epoch), all read on the near side, owned by an actor field Swift copies on every `mutating` call —
`docs/55` §4b's reading, unchanged. A handle here would be two machines by the second copy.

A transition MUTATES, so the measure-then-fill shape would apply it twice. Each door steps a COPY,
renders the answer, and writes the machine back only once every lent buffer is big enough; a caller
that lent too little gets the shape it should have lent and a machine that has not moved.

The resolvers are ANSWERS, not callbacks. The law asks three questions of the actor — what capture
size this window settles on, what a resize clamps to, what a display target sizes to — and exactly
ONE can be asked per message, decided by the message's own variant. So the near side pre-resolves
that one and it crosses as a size plus a presence flag, where ABSENT is the reject the closure
spelled as `nil`. The closures stay in Swift because each reads live AppKit state; their signature
is unchanged, so the actor and all six host test files needed no edits. A `helloAck` crosses as its
ENCODED BYTES (the `client_session` precedent): putting it on the control channel is the only thing
the actor does with one, and it is minted by the same crate that parsed the hello it answers.

The audit that followed the wiring is where the value was. Three rules were spelled in BOTH
languages and are now asked: the resize clamp (`SizeNegotiation.clamp` → `_clamp_capture`), the
stale-epoch test (`epoch <= lastApplied`, which the machine ALSO applies inside its resize
transition — two spellings of one rule, one of them reachable from the actor), and both
`UserStreamSettingsPolicy` bands, whose Swift `fpsCapRange`/`bitrateCeilingRange` constants are
deleted because nothing on this side ever read a band, only the clamped answer. The golden vectors
for `sizeNegotiation` and the epoch test came back byte-identical, which is what proves the two
clamps had not already drifted.

The actor's OWN control sends — a resize ack it just actuated, a content mask it just measured, the
goodbye — do NOT round-trip through an effect. The law mints none of them, so they go straight out
through one `sendControl` helper rather than being laundered through a state machine that has no
opinion about them.

## One key vocabulary, whichever grammar names it (2026-08-15)

Two tables mapped a key name to PTY bytes: `send_keys`'s, behind the `<Token>` grammar that launch
presets, session templates, a re-run and a text drop carry, and `ControlKeyMap`'s in Swift, behind
the agent-control `write` verb's comma-separated `--key C-c,Enter` list.

They had already drifted, in both directions. `C-?` was DEL in Swift and `C-_`'s byte in Rust
(0x3F masked with 0x1F is 0x1F, which is a real key, just not that one). `C-Space` was NUL in Swift
and refused in Rust, because the fold only takes a single character and `space` is five. The
function keys, the paging keys, `Insert`, the `A-` Alt alias and the `bspace`/`ic`/`dc`/`ppage`/
`npage` tmux spellings existed only in Swift. `M-Enter` resolved to ESC + CR in Swift and to nothing
in Rust, because only Swift's meta chord resolved a NAME before falling back to a character.

The two spellings are two ways of naming a key, not two vocabularies, so the union is the table now
and `key_token` is where both grammars read it. A preset can say `<F5>` — that is a behaviour
change, and a deliberate one: an unrecognised marker stays literal, so `<F5>` used to reach the PTY
as five characters, which is not something anyone wrote on purpose.

`C-?` and `C-Space` are spelled out beside the fold rather than being folded, with the reason at
the code: they are the two names where the ASCII arithmetic gives an answer that is wrong rather
than absent, which is the kind of bug a mask hides.

The Swift table is deleted, and so are the Swift tests that pinned its vocabulary — a second set of
expectations on the near side is the mirror fixture that let the tables drift in the first place.
What stays in Swift is what the `write` verb owns: joining a token list in order, and refusing the
whole request at the first unknown token so a typo never sends a partial key sequence.

## One VT grammar for plain text, read two ways (2026-08-15)

`vtscan` exists because the replay-hygiene passes had each hand-rolled the same escape skimmer. Two
more machines were still spelled in Swift, in the agent-control path: `ANSIStripper`, which renders
a pane's output as the text a `wait --until` regex is matched against, and `WaitMatcher`'s
`csiEnd`/`stringCommandEnd`, which decide where a chunk arrived cut mid-sequence so the tail can be
held back for the next one. Their doc comments named each other — "matching `ANSIStripper.skipCSI`"
— which is the drift risk stated as a promise, the same shape the paced-send lane had.

They are `slopdesk-sanitize::plaintext` now, one grammar with two questions asked of it: `strip`
renders a whole buffer, `holdback_start` names where an incomplete tail begins. A test feeds a
stream one byte at a time through both and asserts it renders what the whole buffer does, which is
the promise the comments used to make.

`plaintext` is NOT one of the seven replay passes and `sanitize` does not call it. A replay pass
keeps a faithful terminal stream and removes only churn, because the client renders what survives;
this removes every sequence and every Nerd-font private-use glyph, because a regex is not a
terminal. It lives in that crate to share the scanner, not the purpose.

The one real difference between the two readings is the terminator policy, so it is NAMED rather
than duplicated: `vtscan::Terminators` replaces the `bel_terminates: bool` parameter. A replay pass
treats an unterminated body as a head-cut artifact and passes it through verbatim, because there IS
a next chunk; a render has no next chunk once the caller's carry budget is spent, so a bare `ESC`
ends the body it broke and a trailing lone `ESC` is consumed rather than emitted as text. Both are
right for their caller, and now both are spelled once.

## The reset backstop is built from the set the strip pass reads (2026-08-15)

`ScrollbackTranscripts.sanitizeSuffix` is what a restore appends when the replay passes did NOT run
— a raw journal tail, or a run with the transform disabled. It exists precisely to catch what the
passes missed, and it spelled all fourteen of `inputmode`'s tracked modes out as a Swift string
literal, with nothing connecting the two lists. A mode added to `TRACKED_MODES` would have been
stripped by the pass and silently missing from the backstop for the path where the pass never ran.

`inputmode::reset_suffix()` builds it by iterating that array, so the set is spelled once. What is
NOT in the array stays written out, and the code says why for each: the alt-screen leave comes
first because a reset that lands on a TUI's screen is one the main screen never sees, and the
alt-screen pass owns that mode anyway; the kitty keyboard pop-and-clear, the rendition reset and the
cursor show are not input modes this pass tracks.

The byte ORDER changed — `?1l` now sits with the other tracked modes rather than after the kitty
sequences, because that is its position in the array. Independent `DECRST`s commute, nothing pins
the literal, and the test that consumes the constant reads it rather than restating it.

## One shell word, wherever a path is typed into a live shell (2026-08-15)

POSIX single-quoting — wrap in `'…'`, rewrite each embedded quote as `'\''` — was written EIGHT
times: seven Swift copies (`ShellQuoting`, `LinkActionPolicy`, `PasteTransform`, `LaunchPreset`,
`CLIInstaller`, `WorkspaceControlBackend`, `CodeBridgeTerminalRouter`) and once privately in
`templates.rs`. It is four lines, which is exactly why it kept being retyped rather than reached
for.

Two of the copies argued for themselves in their own doc comments, and both arguments were wrong in
the same way. One called itself the ONE source of truth while four other Swift spellings sat beside
it. The other declined to widen hostd's dependency graph for four lines — but `SlopDeskWorkspaceModel`
is a leaf hostd, the workspace core and the client UI all already link, so the face costs no edge at
all. `ShellQuoting` moved there, and the rule is `shell_quoting::single_quoted` in Rust.

`PasteTransform.shellEscaped` was NOT the same rule: it leaves a word a shell would not act on
unquoted, so a pasted `file.txt` lands in the prompt looking like the path. That is `shlex.quote`,
and the difference is real — so it is NAMED (`shlex_quoted`, one flag on the door) rather than
duplicated. The safe set is `[A-Za-z0-9_@%+=:,./-]`, deliberately without `~` or `{`: a shell
EXPANDS those, and stopping expansion is the whole point.

`SlopDeskClientUI` gained an explicit `SlopDeskWorkspaceModel` dependency. It was already transitive
through `SlopDeskWorkspaceCore` — the declaration is what a direct `import` needs, the same
rationale as the Protocol / Inspector / Transport entries beside it.
