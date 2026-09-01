# DECISIONS vol-09 — 2026-08-13 … 2026-08-14

> Volume 9 of 14 of the decision log. The index, and the rule for where a new ruling goes, is [DECISIONS.md](../DECISIONS.md).

## The workspace's SOLVERS cross; its DOCUMENT does not (2026-08-13)

Stage 32 deleted six Swift files in `SlopDeskWorkspaceModel` against `rust/slopdesk-workspace` —
`SendKeysParser`, `FocusResolver`, `TabOrdering`, `CanvasGeometry`, `CanvasNonOverlap`, `CanvasSnap`.
The line is the same one stage 31 drew for agent detection, and it lands in a different place here
for a reason worth writing down: **262 files import this module.** A `SplitNode` or a `Canvas` is
what SwiftUI diffs to decide what to redraw, so the value types are the app's vocabulary and stay
Swift. What crossed is the half that DECIDES — where focus lands, where a dragged pane may rest,
what order the sidebar's sections come in, which tab survives a close.

**The closures flattened rather than trampolined.** Three of these rules take a
`(TabID) -> String?` in Swift and a `Fn(TabId) -> Option<String>` in Rust. Calling a Swift closure
back from Rust per element would have been the one thing in the boundary that is not a value copy;
instead the caller evaluates it once per id and hands over `(id, span)` pairs into one strings blob —
stage 31's encoding, reused unchanged.

**Two answers stay Swift on purpose.** `bucketedByProject<Element>` is generic over its element and
cannot cross, so the generic bucketing stays and calls the Rust comparator: the ORDER is the rule,
the bucketing is a container shuffle. `paneProjectKey`/`tabProjectKey` walk a `Session`, which is the
document — they stay until stage 33 moves `PaneSpec`.

**One behaviour narrowed, deliberately.** `sectionPrecedes` used Foundation's
`localizedStandardCompare`; the crate's `natural_compare` is case-insensitive with numeric digit runs
but does NOT fold diacritics, so `Café` and `Cafe` are distinct rather than adjacent. Section headers
are directory basenames, where that is a rounding error — but it is a real difference, and
`check-supervisor.sh` now fails if `localizedStandardCompare` reappears in this module's code (doc
comments are stripped first, so naming the retired collator to explain the narrowing is still legal).

**The tuning constants are exported, not transcribed.** `slopdesk_ws_non_overlap_default` and
`slopdesk_ws_snap_default` hand the crate's own defaults to Swift. The snapper's gutter and the
slide's gutter have to be the same number for a gutter-snapped box to already sit at the non-overlap
boundary; twelve literals repeated across the boundary would be twelve chances for that to stop
being true.

Cost: 2,051 Swift lines → 1,317, of which ~154 is the shared bridge. Every pre-existing Swift test
is unchanged and now exercises the crate — 138 canvas tests and 13 tab-ordering tests among them,
which is the bit-exactness check `CLAUDE.md`'s float rule demands.

### Amendment — the tree crosses in BOTH directions (2026-08-13)

`SplitNode+Ops` answers trees, not scalars, so the pre-order walk the layout solver introduced is now
a two-way primitive (`WsTree` on the Swift side, `encode_tree`/`decode_tree` in the shim). Still not
the persisted JSON: these ops run on a gesture, and a parse per frame is the regression that vetoes a
port. The decode is total over hostile input on both sides — a walk claiming more children than it
carries is refused rather than trapped on.

Two answers are deliberately distinguished where a single one would have been simpler. `SIZE_MAX`
means the op did not APPLY, which is not a tree of zero nodes: closing a pane that is not there must
leave the arrangement standing, where an empty answer would close the tab. And `mapLeaves` stays
Swift — its rule IS the caller's closure, so it is a container walk rather than a decision.

The crate mints nothing (`identity.rs`), so the three ops that create a split take the fresh
`SplitNodeId` as an argument and Swift mints it at the call site. The public Swift signatures are
therefore unchanged for their 262 importers while the rule underneath them moved.

### Amendment — the arrange commands moved DOWN before they moved across (2026-08-13)

`Canvas::aligning`/`distributing`/`tidied` lived on the plane in both languages, reading `item.id` and
`item.frame` and writing `item.frame` — and nothing else. Exporting the plane itself was never an
option (a `Canvas` carries specs, groups and z that none of these rules consults, and it is what
SwiftUI diffs), so the rules were first extracted into `canvas_arrange` as functions over `(id, rect)`
pairs. `Canvas` now delegates to them and so does the shim: ONE implementation with two callers,
rather than a crate method and an FFI copy of it.

Each answers only the frames that MOVED. A caller applies the answer by lookup, so a pane nobody
named is untouched by construction rather than by a copy that happened to reproduce it.

One behaviour was narrowed deliberately, as with `sectionPrecedes` before it: panes sharing a leading
edge exactly used to keep whatever order `items` happened to be in during a distribute, and now break
the tie by id. The spread is a function of the SET either way, which it was not before.

This file did not shrink — 511 → 532 lines, the arithmetic replaced by marshalling and by the
paragraphs above. The win here is not size; it is that "aligned to a shared edge" has one home.

### The workspace's OPS do NOT cross — only the algorithms inside them (2026-08-13)

`WorkspaceTreeOps` (1,222 lines) and the crate's `tree_ops` (1,500) mirror each other op for op, and
that mirror is NOT going away. Every one of those functions takes a `TreeWorkspace` and answers a
`TreeWorkspace` — sessions, tabs, titles, specs, focus — and marshalling that document across the
boundary on every keystroke is precisely the per-frame cost `CLAUDE.md` says vetoes a port. The
document stays Swift, as it has since stage 32.

What crossed instead is the one part of a re-tile that is an ALGORITHM rather than bookkeeping: the
tiler. `tree_ops::rebuild` became `pub`, and the Swift `rebuild`/`flatSplit`/`tiled` trio (~80 lines
of index arithmetic) is now one call. The workspace-level `applyLayout` around it — locate the tab,
clear the zoom, install the tree, normalize the specs — stays where the document is.

Two consequences worth naming. The main-\* layouts take the FIRST leaf as the large one, so "which
pane is active" is decided by the caller ORDERING the leaves and never crosses at all. And because
the crate mints nothing, the split identities are minted Swift-side into a pool the tiler draws from;
`n + 1` entries cannot run dry for `n` leaves, so the pool has no failure mode to handle.

This is the line for the rest of stage 33: an op that shuffles the document stays, an algorithm
inside one moves — after being lowered in the crate to a function over what it actually reads.

### The state codec's SCALAR layer crosses, for safety rather than speed (2026-08-13)

Every other port in stages 31–33 was justified by "the rule should have one home". This one is
justified by what the code DOES: `WorkspaceStateCodec`'s scalar layer decodes bytes that came off a
socket, and its safety property is strictness — a value of the wrong length is a DROP, never a lenient
prefix read. That property has to hold identically on both ends, because a mis-numbered field that
decodes leniently succeeds into something plausible: a `grid` of `(0, 0)` letterboxes a pane to
nothing, and a truncated `lastExitCode` reports a clean exit for a process a signal killed.

`state_codec` is the one crate module written for the far end rather than for the plane. Absence is
carried by an out-parameter and a bool, never by a sentinel: `-1` is a real exit code and
`0xFFFFFFFF` is its encoding, so no in-band answer could have meant "not a value of this kind".

Two things stayed Swift on purpose. `decodeString` is `String(data:encoding:)` — Foundation's UTF-8
validation is the same validation, and round-tripping bytes through the boundary to learn what
Foundation already knows would be cost without a property. And `encodeString`'s clamp takes its limit
as a PARAMETER, because a rename is clamped tighter than a title and the limit belongs to whoever
knows the field.

The file grew 555 → 588 lines. As with `Canvas+Ops`, the win is not size — it is that "a wrong-width
field is a drop" is now one implementation instead of two that could drift apart silently.

### Amendment — the snapshot and diff parse crosses too (2026-08-13)

The scalar layer went first; the STRUCTURAL layer is where the risk actually was. `decodeSnapshot`
and `decodeDiff` read a count and a length, both chosen by whoever is on the other end of the socket,
and every bound has to be checked against the bytes actually remaining before any capacity is
reserved. That is now `state_codec`'s `Reader`, where nothing panics and every read is `Option`.

A decoded value crosses back as a SPAN into the buffer the caller handed in, never a copy. A snapshot
is hundreds of entries and arrives on every attach; copying each value into a second blob would
double the work for no property. Rust's lifetimes make that safe to state — `Entry<'a>` borrows its
buffer, and the borrow checker rejected the first version of the round-trip test for freeing the
bytes while the entries still pointed at them. That is the class of bug this port exists to remove,
caught in the port itself.

`decodeDiff`'s entry point writes BOTH counts even when a buffer was too small, so one probing call
sizes both halves and a diff that is mostly deletes never costs a retry for the sets it barely has.

`maxEntryCount` is exported, not transcribed. It is a REFUSAL threshold, so two copies would be two
ideas of what counts as an absurd document — and the smaller one would reject states the other
happily sends.

### The layout decoder's recursion was REMOVED, not capped again

`decodeLayoutNode` was recursive, and its depth cap was load-bearing: the comment said so — the cap
was the stack-safety mechanism. That makes a number chosen for documents ("no sane layout nests past
twelve") the only thing between a socket and a stack overflow, and the two reasons for it cannot be
tuned independently. Raising the cap for a legitimately deep board would be raising the crash floor.

`state_codec::decode_layout` walks the flat encoding with an explicit frame stack: a node fills one
slot of its parent's frame, a split with children opens a frame of its own, and completed frames
close in a loop. A thousand-deep hostile nesting is now refused by the counter rather than by the
process dying, and the cap goes back to being a statement about documents only. The test asserting
that is `a_deeply_nested_layout_is_refused_without_a_stack_to_overflow`.

The two refusals stayed two refusals. `decode_layout` answers `Result<_, LayoutError>`, and the entry
point carries `depth_exceeded` as a FLAG beside the `SIZE_MAX` sentinel rather than folding both into
it — the same "absence is a flag, never a sentinel" discipline the scalar decoders use. A tree past
the cap is a well-formed document this build declines to hold; an unknown tag is a bug or an attack.
Telling a person "corrupt" about the first would be a lie that every round-trip test still passes.
The Swift tests caught exactly that when the first port collapsed them, which is why the gate now
pins `depthExceeded` in the Swift file.

### `ByteReader` is gone, and with it the last hand-written parse in the model

`decodeDetachedPanes` and `decodeVideoTarget` were the last two field values read in Swift, and they
were the reason the file still carried a `ByteReader` at all. Both are now `state_codec`'s, so the
cursor, the `appendBE` loop and the sixteen-way uuid unpack were deleted rather than left as a second
reader nothing calls — a dormant parser is still a parser, and the next field added would have found
it and used it.

The video target's strings come back as SPANS into the buffer Swift lent, not copies. A pane record
carries two of them and arrives with every pane; the decoded `&str` borrows the input, so the offset
is found by pointer arithmetic inside the slice rather than by re-walking the format. Swift reads
them inside the same `withUnsafeMutableBufferPointer` scope that produced them, which is the same
lifetime discipline the snapshot's entries already use.

Both sentinels stopped at the boundary. The wire spells "no origin tab" as the all-zero uuid because
the pair is fixed-width, and "not on a display" as a presence byte because display `0` is the main
display — the crate translates both into `Option` before anything crosses, so neither side has a
second idea of what absence looks like. `display_zero_is_a_display_and_not_an_absence` is the test.

The fixed-width ENCODERS crossed at the same time, and for the plainer reason: `encode_u32` existed
in both languages. They carry no probe-and-retry, because the width is known before the call.

### The document's crossing cost is now MEASURED, and it vetoes the whole-document port

`CLAUDE.md` allows only a measured regression to veto a port, and the ruling that kept
`WorkspaceTreeOps` in Swift had never been measured — it was an argument about marshalling, which is
exactly the kind of claim that is usually wrong. `WorkspaceMarshalBenchTests` runs the real path:
`WorkspaceTopology.entries()` → `encodeSnapshot` → `decodeSnapshot` → `WorkspaceTopology(entries:)`,
all of it shipped code, the codec legs already in Rust.

On this Mac Studio:

| shape | entries | project | codec | ingest | total |
| --- | --- | --- | --- | --- | --- |
| 1 session, 3 tabs, 3 panes | 45 | 115 µs | 238 µs | 68 µs | 0.4 ms |
| 3 sessions, 5 tabs, 4 panes | 244 | 702 µs | 1,744 µs | 396 µs | 2.8 ms |
| 6 sessions, 8 tabs, 6 panes | 1,042 | 4,043 µs | 6,683 µs | 1,852 µs | 12.6 ms |

A 120 Hz frame is 8,333 µs. The middle row is an ordinary workspace, and 2.8 ms of it would be spent
marshalling on every frame of a divider drag; the bottom row misses the frame entirely. The
assumption held, and it is no longer an assumption.

What this does NOT say is that the tree ops stay Swift forever. The rules inside them already cross —
every `SplitNode` op delegates to `split_tree`, and the tiler to `tree_ops::rebuild` — bounded by ONE
TAB's pre-order walk rather than by the document. The Swift that remains in `WorkspaceTreeOps` is a
walk over the document's own value types to find the tab, which is the part the measurement says must
not cross.

The host has its own copy of these ops in `slopdesk-wire`'s `document::apply`, over
`slopdesk_workspace::tree_ops`, and that is deliberate rather than a drift: the host decides what the
document BECOMES and the client draws an optimistic overlay of the same gesture, so the two run the
same rules from opposite ends. Collapsing them into one would mean the client waiting a network round
trip to see its own keystroke land, which is a product decision and not a port.

### The field vocabulary is pinned across the two languages

`rust/slopdesk-wire/src/document/fields.rs` and `WorkspaceFields.swift` are the same 45 numbers
written twice, and the Rust file's own header explains why that is dangerous: nothing in the codec
maps through the constants, every value is length-prefixed, and an unknown byte is kept verbatim. A
field renumbered on one side therefore decodes perfectly cleanly into the wrong meaning — the host
would write `pane/cwd` and the client would read it as `pane/projectKey` with no error anywhere.

`check-supervisor.sh` now extracts both tables and diffs them, comparing names case- and
underscore-insensitively (the two languages spell the same field `focusMRU` and `FOCUS_MRU`, and
neither spelling is wrong). Confirmed by renumbering `root/closedTabRing` to 60 and watching the gate
name the exact pair.

The INTENT VERBS are pinned the same way, for a sharper version of the same reason: an op byte is
the whole of what one end asks the other to do, so two ends numbering them differently is a client
asking for a rename and a host performing a close. 27 ops, both languages.

This does not make the duplication fine — it makes it survivable. The vocabulary is duplicated
because the host is Rust and the client is Swift and neither can import the other's constants; the
gate is what turns "two copies" into "one copy checked twice".

### The replay transform is a linked crate, and screend verb 7 is retired

`sanitize` — the seven-pass scrollback replay transform — used to be verb 7 on the screend socket.
It is `rust/slopdesk-sanitize` now: a dependency-free `forbid(unsafe_code)` crate that screend and
the app both link. It was reached from Swift as the `slopdesk_sanitize` door through the FFI
artifact until `a0d0aa54` retired the replay doors; hostd calls the crate directly now, and the door
was deleted with the last caller.

The rule that decided it is `CLAUDE.md`'s own — a socket is for a component that must outlive its
caller, be `execve`d, or be dialled by two processes — and `sanitize` is a pure function of its
bytes, so it is none of the three. The screen MODEL is all three, which is why the daemon stayed.

Living behind the socket cost three things, and only the first was a performance cost:

- A round trip over the whole retained ring in each direction, per pane, on a cold reattach — the
  one path where a person is watching a blank pane wait.
- The only re-entrant edge in `slopdesk-ffi`: a `slopdesk_distill_fn` C callback so the Rust ring
  could reach back through Swift to the daemon, carrying two `unsafe impl Send + Sync` promises
  about a pointer nothing in the repo could check. Deleting the callback deleted both.
- A documented degraded path. "screend is absent" meant a fully RAW replay, so a `?1002h` recorded
  inside a TUI replayed verbatim and armed the client's input reporting until the next prompt reset
  it. There is no "when screend is not there" for replay any more: the passes are in the binary.

`slopdesk-sanitize` is its own cargo workspace rather than a screend member because it is linked
into an iOS app, which wants `panic = "abort"` where the daemon insists on `unwind`; profiles are
workspace-global, so the two cannot share one. It keeps `indexing_slicing` DENIED, unlike screend,
which allows it for the grid — there is no grid here, only byte scanners over slices.

Verb 7 stays unallocated rather than being reused. A hostd built before the extraction still sends
a 7 meaning "clean this replay"; a daemon that answered something else would return a well-formed
reply of the wrong kind. `check-supervisor.sh` fails the build if either enum allocates it again,
verified by adding a `Ghost = 7` to each side in turn and watching the gate name that side.

### The FEC's NEON kernel comes back, in a third `unsafe` crate

`Sources/SlopDeskVideoProtocol/{GF256,ReedSolomonMatrix}.swift` and `Sources/CSlopDeskSIMD` are
deleted; the video forward error correction is `rust/slopdesk-video`, called through
`slopdesk_video_fec_parity` / `slopdesk_video_fec_recover`. That was the last C target in the tree
and the least safe code in it: `NeonGf` reached through the C target with `UnsafeBufferPointer`,
`withUnsafeTemporaryAllocation` and a `swiftlint:disable force_unwrapping`, and both the encoder and
the decoder passed raw `UnsafeMutableBufferPointer` accumulators around — on the path that parses
hostile UDP off the network.

**The port was tried twice without a vector kernel, and both attempts failed on speed.** The first
inherited the flat 256-entry multiplication table; the second replaced it with a bitsliced `u64`
multiply that folds `x * c` over `c`'s bits with per-lane carry containment, written branchless and
unrolled to eight fixed steps so LLVM would vectorise it. Both landed at roughly twice the Swift,
and the second was within noise of the first. That is not a tuning gap. A table lookup is a GATHER,
which no autovectoriser will touch, and bitslicing trades it for about five operations per byte
where `vqtbl1q_u8` does sixteen bytes in four. The algorithm the fast path needs is a 16-byte table
shuffle, and on stable Rust `vld1q_u8` / `vst1q_u8` take raw pointers.

So the kernel came back as `rust/slopdesk-gfsimd` — two byte-region loops, their scalar twins, and
nothing else. It takes its lookup tables as arguments, so it does not know it is doing GF(2^8): the
field, the tables and the codec all stay in `slopdesk-video` under `forbid(unsafe_code)`. Its
differential suite runs 256 table pairs across lengths that straddle the 16-byte chunk, at four
alignments, inside guarded arenas, and `make miri` runs the same suite under Miri — which is what
actually reads the loads and stores. `CLAUDE.md`'s rule is now three crates, not two, and the bar
the third cleared is the bar for a fourth.

**The other half of the gap was marshalling, not arithmetic.** With the kernel in, the codec was
fast enough that flattening the arguments cost more than computing on them: 0.51 µs to copy a
group's eight 1200-byte fragments into one span, against 0.24 µs of parity. Two fixes were tried and
only one survived, which `docs/55` §4d records in full:

- **Descriptors instead of a copy — REVERTED.** Passing `(address, length)` pairs moves 132 bytes
  instead of 9.6 KB, and it worked, and it is unshippable: `withUnsafeBytes` guarantees its pointer
  only inside its closure, so describing N fragments is N nested closures, and
  `RustFECLargeFrameStackTests` — which runs the FEC over 3000 fragments on a deliberately 512 KB
  stack, because that is the size of the production send thread's — killed it with SIGBUS. That test
  predates the port; the Swift codec had the same bug once. The shape is a trap independent of the
  language underneath. Measured, it also bought nothing on the encode path: the nesting cost about
  what the copy did.
- **`recover` answers with the REPAIRS — KEPT.** The answer is a list as long as the data list in
  which only the holes this call closed carry bytes, so a single-loss frame comes back as one shard
  and a run of four-byte absences instead of a copy of every fragment the caller already had. An
  answer has no lifetime problem, because the callee owns the allocation it is copied out of.

Measured on a Mac Studio, k = 8, 1200-byte shards, release build, µs per GROUP. The first three
columns are one group per call, which is what the original bench timed and therefore the only shape
the deleted Swift can still be compared against; the fourth is the same Rust at a 32-fragment frame,
which is the shape production actually calls.

| shape | Swift + NEON (deleted) | Rust, safe only | Rust, shipped | shipped, per frame |
| --- | --- | --- | --- | --- |
| encode m=2 | 5.46 | 9.83 | **2.66** | **2.16** |
| recover m=2, 2 holes | 5.03 | 12.22 | **4.30** | **3.74** |
| encode m=1 *(the wire)* | 0.643 | 1.28 | 1.29 | 1.03 |
| recover m=1, 1 hole | 1.59 | 3.45 | 2.54 | 2.14 |

The fourth column exists because hostd hands `parity(forDataFragments:groupSize:)` a WHOLE frame, so
the boundary's fixed cost — one flattened list, one answer buffer, one codec — is paid once per frame
while the per-byte cost scales with the groups. Timing a single group charges the entire fixed cost
to that group and reads ~25% pessimistic. It is not a like-for-like column: the Swift codec had
almost no fixed cost to amortise, so its own frame number would have moved much less.

The `m == 1` rows also show what the vector kernel did NOT fix. At `m == 1` the codec is a plain XOR
costing 0.24 µs, and everything above that is the crossing — which is why the descriptor and
repairs-only changes moved those two rows and the kernel barely did, and why `m == 2`, where there
is real arithmetic to do, is the column that halved.

**The residual `m == 1` regression is accepted.** It is 1.6 µs per encoded frame against a 33,333 µs
budget at 30 fps — 0.005% — and it buys the deletion of the last C target, the whole
`UnsafeBufferPointer` category on the network parsing path, and a multi-loss tier that is now 2.5×
faster than the code it replaced. `m == 1` is the shipped wire; `m >= 2` is opt-in through
`SLOPDESK_FEC_M`, and it is the tier that runs when the link is actually losing packets.

`slopdesk-video` stays `forbid(unsafe_code)` with exactly one dependency. `slopdesk-gfsimd` is its
own cargo workspace for the usual reason — profiles are workspace-global — and sits at `deny` with a
self-expiring `#[expect(unsafe_code, reason = …)]` at each of its two `unsafe` sites, so a block that
stops needing the exemption fails the build.

### The send path stops being Swift, and the FEC boundary disappears into it

**The FEC was never the expensive part.** With the kernel landed, a 32-fragment frame's parity cost
4.4 µs at `m == 1`. The same frame's `packetizeRaw` cost 32.7 µs — and 25.1 µs of that remained with
the FEC switched off entirely. So the measurement that mattered was the one nobody had taken: where
the other 25 µs went.

It went to `FrameFragment.encode()`. Splitting a 36 KB frame produced 31 payload `Data`s (one
allocation and one copy each), and each finished datagram was then a fresh `Data(capacity:)` grown by
eight `append` calls. Timed apart: 4.2 µs to build the fragments, 20.5 µs to encode them — 0.66 µs
per datagram, for a 19-byte header and a 1200-byte copy. A probe put the floor for producing 31 owned
`Data`s at all at 3.0 µs, so about 17 µs per inter frame was allocator and `append` overhead and
nothing else.

**And the replacement was already written.** `rust/slopdesk-video` had `packetizer`, `interleaver`,
`adaptive_fec` and `packetize_lane` ported and tested — 31,567 lines of crate, of which only `fec`,
`rs_matrix`, `gf256` and `blob_list` (about 1,900) were reachable from anything the product runs. The
other 94% was a cross-language mirror that no test could catch drifting, because nothing called it.
That is the state this repo's one-implementation rule exists to prevent, and it had accumulated one
stage at a time by porting ahead of linking.

**So the seam moved up one layer**, from the FEC to the whole send path. `VideoPacketizer` is now a
handle onto the Rust packetizer (§4b): the MTU split, the tier ladder's per-frame group size and `m`,
the parity, the interleave and the 19-byte stamp all happen on the other side, and what comes back is
one flattened list of finished datagrams. The FEC boundary is gone from the send path — not made
cheaper, gone: parity is computed where the fragments already live, so there is nothing to marshal.
`packetize` (the `[FrameFragment]` entry the tools and tests use) is now a *decode* of those
datagrams, which inverts the old relationship on purpose: the wire form is what the packetizer
produces, and a second construction path here is exactly what would drift.

Measured on a Mac Studio, release build, µs per FRAME:

| shape | before | after |
| --- | --- | --- |
| inter 36 KB, m=1 *(the wire)* | 32.7 | **12.2** |
| inter 36 KB, no FEC | 25.1 | **10.5** |
| inter 36 KB, m=2 | 61.9 | **25.3** |
| IDR 400 KB, m=1 | 349 | **137** |
| IDR 400 KB, m=2 | 680 | **280** |

**Why the answer crosses by value, again.** The datagrams total ~41 KB for an inter frame and are
copied twice — once into the caller's buffer, once as Swift slices it into `Data`s. That sounds like
the thing to optimise until you price the alternative: `Data(bytes:count:)` from a pointer costs
~97 ns, while `Data(count:)` plus a fill costs ~333 ns, so handing the datagrams over one slot at a
time — the shape `ReplayBuffer` uses — would be *slower* than flattening all of them and slicing.
The send lane needs owned `Data`s regardless, because a queued job outlives the call that made it.

**What was deleted.** `packetizeFragments`, `makeFragment` and the m-aware parity ladder inside
`FramePacketizer.swift`; `FragmentInterleaver.swift` and its tests, whose last caller outside the
packetizer was `slopdesk-loopback-validate` reordering by hand after asking for an un-interleaved
frame — a tool reproducing the host's composition instead of driving it, which is what a mirror looks
like before it drifts. It now passes `interleave:` through. `check-supervisor.sh` pins both: the
Swift packetizer must still call the three handle entry points, must not grow the two builders back,
and the interleaver's two files must stay gone.

`PacketizeLaneTests` lost its instrument in the move — `GatedFEC` pinned "mid-packetize" by blocking
inside a Swift `FECScheme` that the packetizer no longer calls. The keystroke-latency contract it
guarded is real, so the test was rewritten to pin ORDER rather than a gate: `inject` must complete
before the pump does, which the pre-fix inline shape cannot satisfy however long the test waits.

### The receive path follows, and the hostile-input guards stop existing twice

The send path's port left the symmetric half in Swift, which is the half that matters more. The
reassembler is where UDP with no authentication beyond the mesh is parsed: a crafted `fragCount`
makes assembly build a per-frame array before anything checks it, a `fragIndex >= fragCount` can
never complete a frame, and a `frameID` that jumps the loss frontier by millions would strand the
stream forever if the resync rule were not exactly right. Those guards existed in both languages.
Two copies of a guard is worse than two copies of an algorithm — an algorithm that drifts produces a
wrong picture, a guard that drifts produces a reachable allocation.

So `FrameReassembler` is a handle now, on the same convention. It holds frames under construction, so
it is the memory case; and a verdict depends on everything it has been shown rather than on the
datagram in hand — a frame is lost only once a NEWER frame arrives while a hole remains — so it is
the state-is-the-answer case too. `ingest` answers a tag and parks the frame behind it.

**The header crosses as seven scalars, not as its nineteen bytes.** The client's router already
decodes every video datagram to read `frameID` and `hostSendTsMillis` for the one-way-delay
telemetry before it decides where the datagram goes, so passing the bytes would decode them twice.
That leaves `FrameFragment`'s codec in Swift on purpose: moving it means moving `route`, and a seam
half-moved is the state this stage exists to get out of.

Measured on a Mac Studio, release build, µs per FRAME — every fragment ingested, the clean path and
the one-data-hole path (which is the one that runs when the link is actually losing packets):

| shape | before | after |
| --- | --- | --- |
| inter 36 KB, m=1 *(the wire)* | 11.9 | **8.5** |
| inter 36 KB, m=1, one hole | 18.9 | **10.5** |
| inter 36 KB, m=2, one hole | 22.0 | **13.4** |
| IDR 400 KB, m=1 | 120 | **95** |
| IDR 400 KB, m=1, one hole | 182 | **117** |
| IDR 400 KB, m=2, one hole | 198 | **142** |

This is the client's CPU, on the weaker of the two ends, and the loss path — the one the FEC exists
for — is where it gained most.

**One public member did not survive:** `frontierJumpRejectedCount`, telemetry with no reader in
`Sources/` or `Tests/`. Rust keeps the counter; nothing asks for it, so nothing crosses for it.

`check-supervisor.sh` pins the shape rather than the behaviour, because behaviour pins would keep
passing while a second implementation drifted: the Swift reassembler must still call `ingest`,
`frame_avcc` and `free`, and must not grow `maxFrontierJump`, `resyncStreak`, `resyncClusterWindow`
or `frontierJumpCandidates` back. Its four test files stay — they drive the public API, which is now
the boundary, so they became boundary tests without changing a line.

### The wire layout stops being written twice, and a dead scheduler arm goes with it

The two paths met at nineteen bytes that both languages spelled out. `FrameFragment.encode()`
appended seven fields in big-endian order and `decode(_:)` read them back through `VideoByteReader`;
`rust/slopdesk-video`'s `fragment` did the same, and was the module every ported piece around it
already used. Nothing failed — the golden vectors pinned the bytes, so both copies stayed correct.
That is exactly the state the one-implementation rule names: a layout that only drifts the day
someone moves a field, and then drifts silently, because a byte-identity test compares each side
against the golden file and never against the other side.

So the codec is Rust's, and `FrameFragment` stays Swift. **Data is not a second implementation; a
codec is.** The struct and its `Flags` are read by the mux header codec and the golden generator, and
moving them means moving `MuxFrameFragmentHeader` — a seam of its own, not a rider on this one.

**Decoding answers a header and an OFFSET, never a payload.** The caller just handed the datagram
over; copying the payload back would move every byte of every frame across twice for nothing. Swift
slices its own buffer at `payload_offset` and rebases it, as the byte reader it replaces did — a
`Data` with a nonzero `startIndex` indexes differently and retains the whole datagram, and neither
belongs in a value handed to the reassembler. Nobody spells 19 on the Swift side any more except the
MTU budget that subtracts it.

Inside `rust/slopdesk-video`, the parse split in two rather than being copied: `FrameFragmentHeader::
decode` borrows the payload out of the datagram, and `FrameFragment::decode` is that plus a
`to_vec`. One parse, two ways to take the answer — so the boundary allocates nothing at all on the
receive side.

Measured on a Mac Studio, release build, over a 36 KB frame's 32 datagrams. The "before" column is
the deleted Swift shape, re-created verbatim in a standalone `-O` build to price it:

| | before | after |
| --- | --- | --- |
| `decode`, per datagram | 193 ns | **149 ns** |
| `decode`, per frame | 6.2 µs | **4.8 µs** |
| `encode`, per frame | 19.8 µs | **8.4 µs** |

Decode is the one that matters — it runs per datagram on the client before the router knows where
the datagram goes — and it is the smaller gain, because a 19-byte parse is mostly the `Data` the
payload comes back in. Encode more than halves, and has no production caller left, which is the
other half of this change.

**`VideoSendScheduler.scheduleFrame([FrameFragment])` is deleted.** The send path has produced
finished datagrams since the packetizer moved, and `scheduleFrameRaw` schedules them; `scheduleFrame`
parsed and re-encoded bytes that were already bytes. It had no caller outside
`VideoSendSchedulerTests`, which is what dead production code looks like when a test keeps it
breathing. Both tests now drive `packetizeRaw` → `scheduleFrameRaw`, which is the path the host runs.

`check-supervisor.sh` pins the shape: `FramePacketizer.swift` must call
`slopdesk_video_fragment_encode` and `slopdesk_video_fragment_decode`, must not grow
`appendBE(header.…)` back, and `scheduleFrame(` must not reappear.

### The FEC ladder stops being decided twice

`AdaptiveFECPolicy` and `rust/slopdesk-video`'s `adaptive_fec` held the same decision: the wire
tier's group size, the hysteretic level ladder with its asymmetric up/down thresholds, the 240-report
relax dwell, the sticky window a dropped frame opens, and the parity-`m` ladder beside it. Both
correct, both tested, and both read by the *same* wire — which is what makes this one worse than the
codecs that came before it. **A drifted threshold does not fail a test. It de-syncs a running host
from a running client, on the exact link that was already losing packets.**

So the ladder is Rust's, and `AdaptiveFECPolicy` is the boundary to it. Six entry points and no
handle: every one is a function of its arguments, and the tier decision only *looks* stateful — the
state IS the answer, so `TierState` crosses whole, by value, in and out. Three scalars are cheaper
to copy than an object is to own, and a value the host keeps in its own session struct cannot drift
from a counter living somewhere else.

**The env still resolves in Swift, and only the lookup.** `SLOPDESK_FEC_M` and `SLOPDESK_FEC_K` come
through `EnvConfig`, which reads the process environment *and* the settings overlay a GUI toggle
writes — that lookup is the app's. What the string MEANS is not: parse, default, clamp, and the
joint `k + m <= 255` field bound now happen once, on the other side. A missing variable and an
unparseable one already resolved alike, so absence needs no flag of its own — the pointer is NULL.

**The ladder's numbers are vended, not copied.** `slopdesk_adaptive_fec_constant(index)` answers the
default tier, the three parity tiers, the dwell, the sticky window, the default `k` and the `m`/`k`
bounds — the same shape `slopdesk_agent_hold_constant` already uses. A constant written on both
sides is the smallest possible version of the drift this whole change is about.

**One defect fell out of the port, from a test that no longer exists.** The first cut answered the
OFF tier as group size `0`, on the reasoning that a group of zero data shards is no shape at all.
It is a shape a *caller* can ask for: `groupSize(forTier:default:)` passes the caller's own default
through, so a caller whose default was 0 would have been told its own answer meant OFF. The absence
is the return value now, with the size written through an out param — the same shape
`next_dropped_frame` uses, and for the same reason.

**`RustAdaptiveFECParityTests.swift` is deleted.** It carried a verbatim copy of the Swift ladder as
its oracle and fuzzed the public API against it. That is precisely the cross-language mirror fixture
the one-implementation rule names: with one ladder there is nothing to diff, and a test that keeps
the deleted logic alive to compare against is keeping the second implementation alive.
`AdaptiveFECPolicyTests` still pins every behavioural value, and the `adaptiveTier` /
`adaptiveGroupSize` golden vectors still pin the wire.

Measured on a Mac Studio, release build. This is not a hot path and the port does not pretend to be
a win:

| | before | after |
| --- | --- | --- |
| `nextTierState`, per stats report | 2.4 ns | 6.2 ns |
| `groupSize(forTier:)` | folded to 0 by the optimiser | 2.8 ns |

A call that cannot inline costs about four nanoseconds more than a branch that can. The decision
runs once per client NetworkStats report — 20 a second — so that is ~80 ns per second of session,
and `groupSize` has no per-frame caller left at all: the packetizer and the reassembler resolve the
tier inside Rust, and what remains in Swift is the golden generator and the loopback tool. Parity is
the bar the rule sets, and this clears it with room; what it buys is that the threshold table exists
once.

`check-supervisor.sh` pins the shape: `AdaptiveFECPolicy.swift` must call the four decision entry
points and the constant vend, must not grow `levelForTier`, `tierForLevel`, `targetLevel`,
`mLevelForTier`, `tierForMLevel` or `mTargetLevel` back, and the differential fixture must stay
deleted.

### The recovery channel stops being a second decoder

`Sources/SlopDeskVideoProtocol/RecoverySignaling.swift` held its own copy of the client→host
recovery codec — the seven message bodies, the trailing-byte rejection, the NACK cap, the escalation
clock, the redundancy fan-out and the loss-observing window — beside `rust/slopdesk-video`'s
`recovery`, which had all of it already. The codec is the half that cannot be allowed to drift: the
host's request deduper keys on the RAW datagram bytes, so a decoder that tolerated one extra byte
would let suffix-varied copies of a single logical request each decode identically while slipping
the dedup, and answer one loss with two forced IDRs. Two decoders means that property has to hold
twice.

It crosses as one flat `#[repr(C)]` message rather than a tagged union: a C union would have to be
kept in step with the Rust enum by hand on both sides, which is the drift the port exists to remove.
Decode answers a VERDICT rather than a bool — `OK` / `TRUNCATED` / `MALFORMED` — because the caller
had two error cases and collapsing them would have turned a short datagram into a hostile one.

The loss window is the interesting shape. The ring of timestamps is DATA and stays in Swift; only
the pruning law is Rust's. The first cut passed the ring in and got a new ring out, and that cost 14×
what the Swift in-place mutation had: two calls (one to size the answer, one to fill it), a fresh
array per event, and a `Vec` allocated inside the shim to hold a window that was about to be thrown
away. The shape that works is ONE buffer, rewritten in place: the answer is never longer than the
argument plus the event being recorded, so the caller appends the spare slot itself and the law
compacts, shifts and appends inside it. `note_in_place` is that law, and
`LossObservationWindow::note_event` is the same function over its own `Vec` — the method is not a
second copy of the rule, it is a caller of it.

Measured on a Mac Studio, release build, per message:

| | before | after |
| --- | --- | --- |
| stats encode | 1164.3 ns | 217.2 ns |
| stats decode | 247.4 ns | 119.4 ns |
| NACK decode | 139.5 ns | 209.8 ns |
| loss-window note | 9.6 ns | 17.5 ns |

Two of those are regressions and neither is hidden. The NACK decode pays for an owned `Vec<u16>`
built inside `RecoveryMessage::decode` and then copied into the caller's buffer — one allocation and
one copy the old byte reader did not make. Removing it means a slice-decoding entry point beside the
owning one, which is more surface than 70 ns on a path that runs once per fragment-loss burst is
worth. The window note is 8 ns above a call that inlined to nothing; it runs once per unrecovered
frame or FEC recovery. Both sit far under the noise of the thing they are reacting to, which is a
lost packet.

`encodeRequestFragments` / `decodeRequestFragments` are gone: they were the NACK body split out for
tests, and the tests now go through the message.

**`RustRecoveryPolicyParityTests.swift` is deleted**, for the reason
`RustAdaptiveFECParityTests.swift` was: it fuzzed the public API against a verbatim copy of the
Swift policy, which is the deleted implementation kept alive as an oracle. `RecoverySignalingTests`
and `CodecTests` still pin every behaviour, and the `recovery` golden vectors still pin the wire.

### The mux prefix is laid down once, and it got faster doing it

`Sources/SlopDeskVideoProtocol/Mux/VideoMuxHeaderCodec.swift` wrote the four-byte lane prefix by
hand — `Data(capacity:)`, `appendBE`, `append` — beside `rust/slopdesk-video`'s `mux_header`, which
had the same four bytes. Four bytes is exactly the size of thing that gets written twice and drifts
once, and this one fronts EVERY datagram on the video flow in both directions on both ends. So does
its sibling: `MuxFrameFragmentHeader` is 19 bytes, the same width as the plain fragment header and a
different layout — one spends its last four on `hostSendTsMillis`, the other its first four on the
lane. Reading either with the other's decoder parses cleanly and produces nonsense. Two decoders for
that pair is two chances to line them up wrong.

The framing does NOT allocate on the Rust side. `encode_into` writes the answer into the buffer the
caller already owns, because the answer is the payload with four bytes in front — an owning encoder
would copy the whole datagram a second time to prepend a lane, and then Swift would copy it again
coming back. `encode` and `encode_media` are wrappers over `encode_into`, so a Rust caller and a
Swift caller lay the same bytes down through the same four lines. Splitting answers an OFFSET, the
shape §4 of `docs/55-ffi-boundary.md` describes: 0 means the datagram was too short, unambiguous
because a payload can never start at offset 0.

`has_tag` is a flag rather than a second entry point. The bare lane prefix and the media-socket
`[lane][tag][payload]` differ by one byte in one place; two symbols would be two chances to pick the
wrong one.

Measured on a Mac Studio, release build, over an MTU-sized 1200-byte payload:

| | before | after |
| --- | --- | --- |
| `encodeMedia` | 400.9 ns | 145.6 ns |
| `decode` | 173.9 ns | 133.2 ns |

The encode win is the intermediate buffer disappearing — `Data` grown by three appends against one
`Data(count:)` filled in a single pass. The decode win is a four-byte big-endian read that no longer
goes through a byte-at-a-time throwing reader. Both directions of the highest-frequency codec in the
system got cheaper, which is the case the rule does not even require.

`check-supervisor.sh` pins it: the Swift file must call all five entry points, must not grow
`appendBE` or `VideoByteReader` back, and must not respell either header width — `slopdesk_mux_constant`
vends both.

### Input events are parsed once, on the path where a bad parse posts a syscall

`Sources/SlopDeskVideoProtocol/InputEventCodec.swift` called itself "the single source of truth for
the wire format" in its own doc comment, while `rust/slopdesk-video`'s `input_event` carried the
same seven message types. Of every codec in the system this is the one that least tolerates two
readings of a byte: the host decodes an input event off an unauthenticated UDP socket and then POSTS
it into the window server. A non-finite coordinate that survives the decode reaches the injector's
trapping `Int32(Double)` and takes the host down. The finite check is a decode guard for that
reason, and a guard is not a guard if there are two of it and only one is right.

It crosses as one flat `#[repr(C)]` struct with `message_type` saying which fields carry meaning,
for the reason the recovery message does: a C union would have to be kept in step with the Rust enum
by hand on both sides. Decode answers a verdict — `OK` / `TRUNCATED` / `MALFORMED` — because a short
datagram and a hostile one are different things to the caller. The text arm answers an OFFSET: the
bytes stay in the caller's datagram, already proven UTF-8 on the way through, so Swift builds its
string from the span with `String(decoding:as:)` rather than re-checking what was just checked.

Encoding tries the caller's stack first. The fixed-size arms — everything but `.text` — fit in 64
bytes, so the call that sizes the datagram is also the call that writes it, and only typed text ever
pays for a second pass. That number is not the layout and cannot be wrong in the dangerous
direction: too small is slower, never incorrect.

Measured on a Mac Studio, release build, per event:

| | before | after |
| --- | --- | --- |
| `mouseMove` encode | 292.2 ns | 170.6 ns |
| `mouseMove` decode | 94.4 ns | 13.4 ns |
| `scroll` encode | 332.0 ns | 203.8 ns |
| `scroll` decode | 154.6 ns | 18.2 ns |

The decode side is where the byte-at-a-time `VideoByteReader` was: five `Double`s read one byte at a
time through a throwing accessor, against four aligned big-endian loads. Seven to eight times, on
the path that runs once per pointer sample for as long as a drag is held.

`check-supervisor.sh` pins the three entry points and refuses `appendBE`, `VideoByteReader` and
`readFiniteFloat64` coming back into that file.

### The three metadata wires join the rest, and the span stops being copied twice

`WindowGeometryCodec`, `SwipeNavStatusCodec` and `AudioWireCodec` each had a Rust twin in
`rust/slopdesk-video` and each parsed its own bytes in Swift anyway. They ship together, through one
shim, because they share a shape — a small message off the same untrusted mesh — while what each one
GUARDS is different, and the guards are the reason to move them:

* a geometry coordinate ends up in a `CALayer` frame, where a NaN is an uncaught
  `CALayerInvalidGeometry` and a dead client;
* the swipe status drives an affordance that must never promise a navigation the host would refuse,
  so the type byte is checked and not assumed — the cursor socket carries three message types;
* an audio datagram declares its own payload length, the classic over-allocate lever. The cap, the
  bounds check and the exact-consumption check are decode guards, not the caller's manners.

**The span is copied once, inside the borrow that validated it.** The first cut wrote what every
other decode here wrote — `data.dropFirst(offset).prefix(length)` and then `Data(...)` — and the
audio decode came out 21% SLOWER than the Swift it replaced. Two intermediate `Data` values, each
retaining the parent buffer, to describe bytes that were about to be copied once anyway. Copying out
of the `withUnsafeBytes` that already had the pointer took audio decode from 191.8 ns to 108.3, and
the same edit applied to `FrameFragment.decode` — the hottest decode in the system — took it from
149 ns per datagram to 116. The port paid for a fix on a path it was not even about.

`AudioChannelMessage::decode` is now `decode_parts` plus a `to_vec`: the guards live in the
borrowing form, and both the owning Rust caller and the boundary run them.

Measured on a Mac Studio, release build, per message (a 640-byte audio frame, a bounds message):

| | before | after |
| --- | --- | --- |
| geometry encode | 367.4 ns | 198.1 ns |
| geometry decode | 125.5 ns | 14.3 ns |
| audio encode | 416.2 ns | 356.4 ns |
| audio decode | 158.0 ns | 108.3 ns |

`check-supervisor.sh` pins all three files to their entry points, refuses `appendBE` and
`VideoByteReader` in any of them, and refuses the audio cap and the swipe flag bits being spelled in
Swift code again — prose may still name them, since a doc comment is not what the decoder reads.

### The cursor socket and the AVCC split answer a span, not a copy

`CursorCodec`, `CursorShapeCodec` and `NALUnit` were the last three files in
`SlopDeskVideoProtocol` that laid out bytes by hand, and all three had a Rust twin. They ship
together because they share the one thing that decided their boundary shape: each has a payload big
enough that copying it to describe it would BE the cost — a cursor PNG, and an IDR's NAL units,
which are most of a frame.

So neither payload crosses. The shape decode answers `bitmap_offset` / `bitmap_length` into the
datagram the caller already holds, and `slopdesk_nal_split` answers a `SlopDeskNalSpan` array —
`(offset, length)` pairs — under §4's convention, with a 16-span stack scratch so every real frame
is one call. `nal_unit::split` in `rust/slopdesk-video` was refactored to sit on a new
`split_ranges`, which is the same single walk: the borrowing form and the span form cannot disagree
because one is built from the other.

`join` is the exception and takes the §4d blob list, because its argument is a run of separately
allocated payloads and there is no other shape for that — the same marshalling `FECScheme` already
uses, reused rather than re-invented. An absence in that list answers 0 rather than a short buffer:
a missing NAL unit is a frame that cannot be built, not a frame with a hole.

**The type byte is checked on the routing side AND the decode side.** Three message kinds share the
cursor socket; the Swift router still peeks the first byte, because routing is not byte layout, but
each arm then refuses a flat message that came back as the other type. The swipe-nav status keeps
its own entry point — same socket, different wire, different stakes.

`CursorShapeMessage::decode` is now `decode_parts` plus a `to_vec`, the shape the audio wire
established: the guards live in the borrowing form and both callers run them.

Measured on a Mac Studio, release build, per message (a 900-byte cursor PNG; a 40 KB AVCC buffer of
three units):

| | before | after |
| --- | --- | --- |
| cursor update encode | 1.02 µs | 119.4 ns |
| cursor update decode | 141.6 ns | 15.2 ns |
| cursor shape encode | 835.0 ns | 240.7 ns |
| cursor shape decode | 226.2 ns | 121.7 ns |
| AVCC split | 1.13 µs | 1.08 µs |

The update is the fastest-moving message here — up to 120 Hz for as long as the pointer moves — and
it is now 8.6× cheaper to write and 9.3× cheaper to read. The split is parity, which is the honest
reading: at 40 KB the walk is a rounding error and the number is the `memcpy` both versions pay.

`check-supervisor.sh` pins all three files to their entry points, refuses `appendBE` and
`VideoByteReader` in any of them, and refuses the four widths a second speller would drift on — the
two type bytes, the 36-byte update, the 27-byte header and the 4-byte AVCC prefix.

### The control channel crosses through an arena, because a span into the datagram is not enough

`VideoControlCodec.swift` was the last codec in `SlopDeskVideoProtocol` still laying out bytes by
hand: 875 lines, 28 message arms, and a mirror of `rust/slopdesk-video`'s `video_control` kept in
step by review. It is also the widest surface the two could drift on, and the one where a drift is
quietest — a window feed silently one row short reads as a host that closed a window.

Every earlier seam on this path answered with an OFFSET into the caller's own datagram: the fragment
payload, the mux prefix, the input-event text, the geometry title, the audio span, the cursor
bitmap, the NAL spans. That convention does not reach here, for two reasons:

- **Five arms carry a LIST** — `windowList`, `systemDialogList`, `displayList`, `contentMask` and
  `windowFeedSnapshot`, the last with three strings per record. There is no single span to point at.
- **Titles decode LOSSILY.** `String::from_utf8_lossy` on a malformed title produces U+FFFD, whose
  bytes are not in the datagram. An offset into the input cannot name them.

So both directions share one flat byte ARENA, and every string field names its `(offset, length)`
inside it. Decode fills the arena; encode reads from one the Swift side built. It is symmetric, it
keeps the lossy repair down in `rust/slopdesk-video` where it always lived, and it is still true
that no allocation crosses the boundary.

The message itself is a flat `#[repr(C)] SlopDeskVideoControl` with a named field per wire scalar —
not a C union. A union would have to be kept in step with a Rust enum by hand on both sides, which
is the exact drift this port removes.

**The decode scratch is a proof, not a guess.** A record costs at least 8 wire bytes, so
`count <= len / 8`; lossy repair grows a string at most threefold, so `arena <= 3 * len`. Both
scratches are stack allocations sized from the datagram. The `AGAIN` return is kept anyway, with a
heap retry behind it: the contract permits it, and a wrong guess must never truncate a window feed.

Measured on a Mac Studio, release build, per message (a feed chunk of 12 records, three strings
each, 1187 wire bytes — one datagram's worth, which is what the host actually sends):

| | before | after |
| --- | --- | --- |
| keepalive encode | 22.6 ns | 54.7 ns |
| keepalive decode | 9.8 ns | 29.7 ns |
| helloAck encode | 2.83 µs | 238.2 ns |
| helloAck decode | 498.0 ns | 42.9 ns |
| feed(12) encode | 22.11 µs | 9.31 µs |
| feed(12) decode | 20.32 µs | 4.08 µs |

The window feed is the message that matters — it is re-read on every host window change and it is
2.4× cheaper to write and 5.0× cheaper to read. `helloAck` is 11.9× / 11.6×: four `Float64`s appended
a byte at a time onto a growing `Data` was most of the old cost.

**The keepalive is a regression and stays one.** A bodyless message pays the boundary and nothing
else — a ~150-byte flat struct and an FFI call where the old code appended one byte. Sizing the
encode scratch from the message instead of allocating a fixed 48-byte `Data` and shrinking it took
it from 140.9 ns to 54.7 ns, and the remaining 32 ns is the boundary itself. It is sent once every
`KeepaliveTiming.keepaliveInterval` — five seconds — so the cost is 32 ns per five seconds, and
buying it back would mean a second convention for bodyless arms.

`check-supervisor.sh` pins `VideoControlCodec.swift` to the three entry points, refuses the four
byte-layout helpers (`appendBE`, `VideoByteReader`, and both length-prefix extensions) from
returning to it, and refuses the five budgets — the two chunk sizes, the title cap and the two blob
caps — from being spelled in Swift again. `slopdesk_video_control_constant` vends all five.

## PATH-1 crosses with its payload held apart, because a byte run is an OFFSET and not a copy (2026-08-14)

The terminal wire — 30 message types, the `.output` flood behind every keystroke — was the last
codec written twice. `WireMessage+Encode.swift` (396 lines) and `WireMessage+Decode.swift` (283)
are deleted; `Sources/SlopDeskProtocol/WireMessageCodec.swift` flattens a message onto a
`#[repr(C)]` struct and `rust/slopdesk-wire` lays out every byte. This is the debt stage 1 recorded
("the codec exists twice, which is the exact thing the rule forbids") paid off for the message
table. Framing, the mux layer, metadata and the workspace channel still owe it.

**TWO ADDRESS SPACES, on purpose.** The `text_*` spans are offsets into an ARENA the way
`video_control`'s are — a title, a cwd, a label, and an encode has to write them down somewhere. The
`blob_*` span is an offset into the DATAGRAM ITSELF. Six arms end in an opaque byte run, and that
run is the one field on this wire big enough for a copy to be felt, so the decode answers WHERE it
sits and the encode takes it as its own argument. The two fields have opposite costs, so they get
opposite conventions.

**One parser, told to elide.** Answering "where does the run sit" without a copy could have meant a
borrowed mirror of the enum — `WireMessageRef<'a>`, ~250 lines of the same table a second time,
which is the thing this whole port exists to stop. Instead the existing decode table threads a
`(&mut Range<usize>, elide: bool)` pair: `decode_leaving_opaque_run` returns the message with an
EMPTY run and the range it occupied in the caller's datagram. A test sweeps every variant and
asserts `payload[run]` equals what the copying form returned, so a header width cannot drift between
the two forms — an off-by-one there would decode every scalar correctly and hand back a payload
shifted by a byte.

**Three copies became one, and that is the whole 32 KiB story.** The first cut went through
`WireMessage::encode() -> Vec<u8>` and copied a 32 KiB `.output` payload three times: into the
message, into the encoder's `Vec`, out of that `Vec` into the caller's buffer. `ByteWriter` grew a
second sink — a buffer the CALLER lends, where a write past the end is counted rather than
performed, so the §4 "bytes needed" answer still works — and `encode_with_run_into` takes the run
beside the message. Same table, same arms; the six opaque arms read the run from the parameter
instead of from the enum. The Rust side of a 32 KiB frame is 683 ns, of which ~550 is the memcpy
that has to happen.

**The allocation is picked by size, because the two `Data` shapes cross over.** Measured here:
`Data(count:)` on a frame of 14 bytes or fewer never reaches the allocator at all (~5 ns against
~113 ns for a `malloc`) because the bytes live inside the `Data` value; above that,
`Data(bytesNoCopy:deallocator:)` carries ~20 ns of heavier representation but skips the zeroing
pass, which only pays for itself once that pass is longer than 20 ns. The crossing is at 4 KiB. At
32 KiB the zeroing costs as much as the encode (1.18 µs against 632 ns), and an `ack` — the message
this wire sends most — is 13 bytes.

Measured on a Mac Studio, release build, per message. "Before" is the deleted Swift rebuilt verbatim
as a standalone `swiftc -O` binary, so it is that code's number and not a memory of it:

| | before | after |
| --- | --- | --- |
| `output` 1 KiB — encode / decode | 1.32 µs / 923.5 ns | 222 / 566 ns |
| `output` 32 KiB — encode / decode | 1.35 / 4.37 µs | 874 ns / 3.00 µs |
| `ack` — encode / decode | 236.0 / 209.1 ns | 84 / 299 ns |
| `title` — encode / decode | 449.0 / 439.5 ns | 426 / 542 ns |
| `wireByteCount`, 1 KiB / 32 KiB | 40.9 / 26.7 ns | 82 / 82 ns |

**Three rows are regressions and they are kept.** `wireByteCount` is ~2× slower and flat in the
payload size: 22 ns of it is the FFI call, the rest is flattening a ~190-byte struct that the answer
then ignores. It is charged once per consumed message by receive-side flow control, where 45 ns
against a 566 ns decode of the same message is noise. `ack` and `title` decode pay the same
flattening in the other direction. Buying any of them back means a second sizing table in Swift,
which is the drift this change removes — the encode rows it would be traded against are 1.5× to 5.9×
the other way.

`SlopDesk.swift` stops spelling the wire version and the frame ceiling and asks
`slopdesk_wire_constant` for both, which is what makes `check-supervisor.sh`'s new pins total:
`WireMessageCodec.swift` must call all four entry points, may not grow `appendBE` or
`BigEndianReader` back — the framing and metadata layers still own those, so the pin is this file
rather than the target — and neither it nor `SlopDesk.swift` may spell a session id's width, the
16 MiB ceiling, or a `protocolVersion` literal.

## The framing crosses as a HANDLE, and the payload stops being copied on the way in (2026-08-14)

`FrameDecoder.swift` (133 lines) is now a handle over `rust/slopdesk-wire`'s `FrameDecoder`: the
buffering, the read cursor that replaces a per-frame memmove, the lazy head compaction and the
fail-stop on a lost byte-boundary are all one implementation again. What is left in Swift is the
handle, `deinit`, and the mapping from a verdict to a `SlopDeskError`.

**A handle, because a frame arrives in pieces.** Half a length prefix in one `recv` and the rest in
the next is the NORMAL case, so the decoder has to remember what it has been shown; copying that
state across per chunk would copy the frame under construction — up to a 16 MiB `.output` — on every
read. Same convention as `replay` and the reassembler: one free per new, no overlapping calls.

**The opaque run is FETCHED, not handed over.** A decoded message's payload lives in the decoder's
own buffer, which the caller cannot index and which moves when the head is compacted. So `next`
answers with the run's length and PARKS it, and `run` copies it into the caller's buffer once,
straight out of the decode buffer. The park holds until the next `next` on the same handle.

**A message decoded into too small an arena cannot be put back.** The frame is off the stream by
then. So it waits in the handle and the retry finds it parked — and the retry is not a guess either:
the `AGAIN` verdict reports the arena size that would have fit. A test drives a 400-byte title
through an 8-byte arena and asserts the frame survives.

**Two copies removed, and the second one was the interesting one.** The first was structural: the
Swift decoder buffered a chunk, then sliced each frame's payload into a fresh `Data`, then decoded
that slice. The second was a mistake this port would have shipped: `build` took the run as a span
into a buffer and copied it, so a run fetched into its own `Data` was copied straight back out
again. Handing `build` the run as a `Data` — copy-on-write, so passing it on costs a retain — took
a 32 KiB `.output` decode from 3.58 µs to 1.44 µs on its own.

Two smaller things fell out of measuring rather than reasoning:

- **The deferred compaction is taken in `append`, not in the next `next`.** The eliding decode must
  not compact while it is answering with a span into the buffer, so the compaction is put off — but
  put off to the next `next` it moves a whole freshly-appended frame instead of the empty tail a
  just-drained buffer has. Taking it at the top of `append` restores the empty tail. Worth ~200 ns
  on every second 32 KiB frame.
- **`Data.append` on an EMPTY `Data` is nearly free** and `Vec::extend_from_slice` never is, which
  is why the Rust side of this seam is not automatically cheaper and had to be measured.

| | before | after |
| --- | --- | --- |
| `output` 1 KiB decode | 923.5 ns | 367 ns |
| `output` 32 KiB decode | 4.37 µs | 1.44 µs |
| `ack` decode | 209.1 ns | 216 ns |
| `title` decode | 439.5 ns | 386 ns |

`check-supervisor.sh` pins `FrameDecoder.swift` to the five handle entry points and refuses the
buffer itself from coming back — `readOffset`, `compactConsumed`, `readPrefix` and a `private var
buffer`. A second READER of a stream is not a second implementation; a second BUFFER of it is, and
it is exactly how a cursor and a fail-stop drift apart.

`BigEndian.swift` stays: the mux layer and the metadata codec still lay out their own bytes, and
they are the next two stages.

## The mux layer crosses whole — envelope, framing, credit and table (2026-08-14)

The layer above the terminal frame went the same way and for the same reason: `rust/slopdesk-wire`'s
`mux` module already held every one of these — the envelope's bytes, the streaming splitter, the
three flow-control state machines, the channel table — and the Swift beside it was the second
implementation the one-implementation rule forbids. 926 lines of it, of which 19 stay.

Four shapes, picked by what the state is rather than by taste:

- **The envelope is flat-plus-arena**, exactly like `WireMessage`: a `#[repr(C)] SlopDeskMuxFrame`
  with the cwd named as an `(offset, length)` into an arena, and `channelData`'s payload passed
  WHOLE as its own argument. `encode_with_payload_into` writes into a lent buffer, so a 32 KiB
  channelData is memcpy'd once rather than three times.
- **The framing is a HANDLE**, because half a length prefix in one `recv` and the rest in the next
  is the normal case. `next_frame_leaving_payload` answers where the payload sits and parks it;
  Swift copies it out once, straight from the decode buffer.
- **The three policies cross BY VALUE.** A credit window, a receive accountant and a bounded queue
  are two `i64`s each and allocate nothing, so the state fits in the call: the caller holds the
  struct and the entry point reads and writes it in place. A handle would have cost a `new`/`free`
  per channel per direction and bought nothing. `FlowCreditPolicy::restored` and its two siblings
  exist for exactly this, and they clamp the way `new` clamps so a caller cannot restore a window
  the type could not have produced.
- **The channel table is a HANDLE**, because a map plus an eviction ring cannot cross in a call
  without copying every entry. Its states cross as ordinals with a fifth value, UNKNOWN, for an id
  the table has no entry for — a distinction that has to survive the crossing, since an unknown id's
  frame is dropped where a closed id's is a late frame on a channel that really existed.

`MuxRouter` and `HostChannelRouter` became `final class` and lost `Sendable` on the way, which is
the honest reading: they were `Sendable` structs only because the table underneath them was a value.
Neither is used outside tests — production routes through `MuxNWConnection`, which holds its two
tables directly.

| | before | after |
| --- | --- | --- |
| `channelData` 32 KiB encode | 1.42 µs | 902 ns |
| `channelData` 32 KiB streaming decode | 2.65 µs | 1.54 µs |
| `channelData` 32 KiB one-shot decode | 826.2 ns | 883.6 ns |
| `channelOpen` encode | 750.3 ns | 236.1 ns |
| `channelOpen` decode | 356.4 ns | 167.9 ns |

The one-shot decode is the one kept regression, ~7%, and it is the crossing itself on a path already
dominated by handing the payload on. It is also not the path production takes: `MuxNWConnection`
holds a `MuxFrameDecoder`, and that path is 1.7× faster.

One thing measured the wrong way round first. Copying the payload eagerly into the buffer that gets
handed on — the trick that won on the terminal decode — LOST here, 1.16 µs against 883 ns, because
`Data(someDataSlice)` shares the slice's backing rather than copying it. The eager copy is a copy
the caller may never need; on the streaming path, where the bytes live in Rust's buffer, there is no
such choice and the copy is real.

`MuxChannelClass` stays in Swift. It is 19 lines with no arithmetic in it — two names for two bytes,
the same shape as `MuxFrameType` and `MuxCloseReason`, which the envelope port also kept as the
Swift-facing labels. `check-supervisor.sh` pins the four envelope entries, the five framing entries
and five of the policy entries, and refuses the arithmetic itself from coming back: `pendingCredit
+=`, `remaining -=`, `outstanding +=`, a `states[` subscript, `terminalRing`. A window clamped in
two languages is two windows, and the one that drifts low stalls a channel forever rather than
failing.

## The twelve metadata payloads cross, and only the clipboard elides (2026-08-14)

`MetadataCodec.swift` was 841 lines of hand-rolled big-endian parsing over payloads
`rust/slopdesk-wire`'s `metadata::codec` already encoded and decoded, byte for byte, with 350 tests
on it. The second implementation went; the file is 920 lines of Swift face and no reader. Every
public value type and every signature is unchanged, so no consumer moved.

Four crossing shapes, again by what the payload is:

- **A list is RECORDS plus one ARENA.** `SlopDeskMetadataProcess` & co. are fixed-size `#[repr(C)]`
  structs whose text fields are `(offset, length)` into a single flat byte buffer. One allocation
  per direction, not one per string.
- **Git status is a HEAD plus a companion array**, sharing that one arena — branch, remote and repo
  root sit in it beside the 128 file paths.
- **The scalar payloads cross BY VALUE** — vitals, endpoint, disposition, font spec. A font spec's
  size crosses as its bit pattern (`size_bits: u64`), because the rule is bit-exact floats and a
  `Double` that round-trips through a decimal is not the same `Double`.
- **The clipboard ELIDES.** A clip runs to 12 MiB, so `decode_clipboard_set_leaving_content` answers
  WHERE the run sits rather than copying it into the arena, and encoding lends the caller's bytes
  straight through. This is the only payload where that is worth a second address space — and it is
  a second address space: on a clipboard decode the `content` offset is into the PAYLOAD, while
  every other text offset in the same struct family is into the arena.

**A decode needs no probing call.** The payload bounds both buffers: the arena can never exceed
`payload.count`, and a list can hold no more than `payload.count / fixedBytesPerEntry`. So Swift
sizes both up front and calls ONCE, and the §4 AGAIN verdict becomes a `preconditionFailure` — it
cannot happen without the bound being wrong. `slopdesk_metadata_constant(3..7)` vends the per-entry
widths so the divisor is never respelled in Swift; `check-supervisor.sh` refuses the numbers coming
back.

Encoding used to pay for the size pass twice — encode to a `Vec`, measure, encode again. Every
payload gained an `encode_*_into(&mut ByteWriter<'_>, …)` in the wire crate, and the owned `encode_*`
delegates to it, so the §4 sizing pass now allocates and copies nothing: writes past the end of a
lent buffer are COUNTED, not performed.

| | before | after |
| --- | --- | --- |
| process list ×64 encode | 24.86 µs | 5.33 µs |
| process list ×64 decode | 5.84 µs | 3.13 µs |
| dir listing ×256 encode | 64.32 µs | 21.22 µs |
| dir listing ×256 decode | 26.23 µs | 12.76 µs |
| git status ×128 encode | 37.87 µs | 13.11 µs |
| git status ×128 decode | 20.69 µs | 11.01 µs |
| porcelain fold ×128 | 140.7 ns | 129.8 ns |
| clipboard 4 MiB encode | 85.65 µs | 86.25 µs |
| clipboard 4 MiB decode | 85.08 µs | 86.00 µs |

("before" is the deleted Swift rebuilt verbatim as a standalone `swiftc -O` binary, not a memory of
what it cost.) The clipboard is a wash to within noise, which is the answer the eliding decode was
for: at 4 MiB the number is the memcpy and nothing else, and it did not grow.

Two findings paid for most of the encode column, and neither was in the Rust.

**The arena must be `[UInt8]`, not `Data`.** `Data.append` per text field cost ~3–4× at 256 dir
entries; `Array.append(contentsOf: string.utf8)` plus one `withUnsafeBufferPointer` at the end does
not.

**`files.enumerated()` retains.** The fold was the one *measured regression* — 140.7 ns → 508.3 ns —
and it survived two wrong fixes: narrowing the FFI to take CODES rather than records got it to
250 ns, and table-driving the Rust fold with a `const AXES: [u8; 256]` changed nothing, which is
what proved the cost was not in Rust at all. Iterating an array of structs that contain a `String`
copies — retains — every element. `for slot in 0..<files.count { codes[slot] = files[slot].statusCode }`
ends at 129.8 ns, faster than the Swift it replaced. A regression is a veto only after it is chased
to its cause; this one had three causes stacked, and none of them was the crossing.

`MetadataVerb` stays in Swift — 22 verbs and 4 statuses, a name table with no arithmetic, the same
category as `MuxFrameType`. `check-supervisor.sh` pins the 26 entry points by NAME rather than by
call, because half of them cross as a function REFERENCE into a shared `encode`/`decode` helper and
never appear followed by a paren.

## The workspace CHANNEL crosses too, and the roster flattens rather than nests (2026-08-14)

The five payloads inside `workspaceRequest` (17) and `workspaceEvent` (37) — subscribe, presence,
intent, intentResult, roster — were a second implementation of `rust/slopdesk-wire`'s `workspace`
module, which already held every layout and every clamp. 466 lines of hand-rolled big-endian went;
the Swift is a face over the crate now, with every public value type and signature unchanged.

Three shapes, and one of them is new:

- **By value** where the payload is fixed-size. A presence update and an intent result are two ids
  and a handful of scalars, so the `#[repr(C)]` record IS the crossing and nothing is interned.
- **Record plus arena** where it carries text — a subscribe's label, a roster client's label.
- **Eliding** for an intent's arguments, which are opaque here and run to the frame cap.
  `decode_leaving_args` answers WHERE they sit in the caller's own payload, so Swift copies them
  once, out of the buffer it was already holding.

**The roster flattens.** It is panes each holding attachments, and a nest cannot cross without a
pointer per pane. It crosses as THREE flat arrays — clients, panes, attachments — with each pane
naming its run `(offset, count)` into the attachment array. That is the arena's trick applied to
records instead of bytes, and it is why the roster needs no handle and no second call. The decode
writes all three counts BEFORE it fills any array, so a caller that under-sized is told all three
sizes at once rather than one per retry.

| | before | after |
| --- | --- | --- |
| subscribe encode | 897.5 ns | 266.9 ns |
| subscribe decode | 675.7 ns | 252.6 ns |
| presence encode | 621.7 ns | 104.2 ns |
| presence decode | 497.9 ns | 71.9 ns |
| intent 4 KiB encode | 513.0 ns | 204.6 ns |
| intent 4 KiB decode | 462.3 ns | 262.9 ns |
| intentResult encode | 228.9 ns | 102.2 ns |
| intentResult decode | 235.6 ns | 69.1 ns |
| roster 8×16 encode | 24.17 µs | 5.07 µs |
| roster 8×16 decode | 22.82 µs | 3.47 µs |

("before" is the deleted Swift rebuilt verbatim as a standalone `swiftc -O` binary.) Nothing here
regressed, so nothing had to be argued for. The roster is the one that matters under load — it is
broadcast WHOLE to every client on any change, never diffed — and it is 4.8× / 6.6×.

`lend`, `records_of` and the byte pool moved up into `slopdesk-ffi`'s `lib.rs` on the way, because a
second door wanting them is what makes them boundary mechanics rather than metadata's private
business. Each door still names its own `(offset, length)` struct: the pair belongs to that door's
vocabulary, and the shared pool only counts bytes.

The four name tables — `WorkspaceRequestVerb`, `WorkspaceEventKind`, `WorkspaceIntentStatus`,
`WorkspaceClientKind` — stay in Swift, on the `MuxFrameType` reasoning: names for bytes, no
arithmetic. `check-supervisor.sh` diffs their 15 distinct `NAME=byte` pairs against
`rust/slopdesk-wire/src/workspace.rs` (15, not 16: `presence` is verb 2 AND kind 2, and agreeing on
both is the point), pins the 11 entry points by name, refuses `BigEndianReader` / `appendBE` /
`clampUTF8` / `readUUID` / `readBytes(` from coming back, and refuses the label cap, the record cap
and the three per-record floors from being respelled — `slopdesk_workspace_constant` vends them.

`BigEndian.swift` does NOT go with this change, which the plan had assumed it would.
`FileTransferCodec`, `InspectorWire` and fourteen test files still read through it. It is no longer
the wire's parser, only a helper the remaining Swift codecs share, and it goes when the last of them
does.

## PATH 4's client end stops being written twice (2026-08-14)

The 2026-08-13 entry above says `FileTransferProtocol.swift` + `FileTransferCodec.swift` +
`FileTransferFrameDecoder.swift` "became one `rust/slopdesk-dropd/src/client.rs`". Half of that was
true: `client.rs` was written, exported and tested. The other half never happened — the three Swift
files were still there, still the live client, and `client.rs` had no non-test caller in the tree.
The same capability existed twice, in two languages, which is the one thing the one-implementation
rule names outright. This is that deletion.

The door is `rust/slopdesk-ffi/src/file_transfer.rs`. A request crosses as its type byte plus the
scalars any frame could carry and ONE borrowed blob — a name for an offer, a body for a chunk — so
`Request::Chunk` is never built to encode a chunk. A reply crosses as a flat record plus a small
arena for the one string it can hold. The frame splitter crosses as a HANDLE, `MuxFrameDecoder`'s
shape, because half a length prefix in one `recv` and the rest in the next is the ordinary case;
`FileTransferFrameDecoder` went from a `struct` to a `final class` for it, and sizes the arena by
what the splitter has BUFFERED — a string inside the next frame cannot outrun the bytes already
held, so one call always suffices and there is no probing round trip.

The first cut was a **measured regression** on the one path that matters, and the veto held until it
was gone. A 256 KiB chunk frame cost 9.71 µs in Swift and 17.94 µs across the door: the §4 sizing
call built the whole frame to learn its length and threw it away, then built it again, then copied
it out — three passes over the body where Swift made two. Two changes fixed it and then some.
`chunk_frame_len` answers the sizing call from arithmetic, and `write_chunk_frame` writes into the
caller's buffer, so the body is copied exactly once, from where the caller holds it to the buffer
that goes to the socket. And that buffer is handed over UNINITIALIZED — `Data(count:)` zero-fills
every byte the encoder is about to overwrite, which is the second pass; above 4 KiB the codec
`malloc`s and returns `Data(bytesNoCopy:)`, below it `Data`'s own storage is cheaper than the
`malloc`/`free` pair. `write_chunk_payload` is the single writer both the borrowing and the owning
path go through: the owned `Request::Chunk` resizes and delegates, paying a zero-fill the borrowing
path does not, which is the right way round — a caller who already chose to own the body is not the
one uploading a gigabyte.

|  | before | after |
| --- | --- | --- |
| offer encode | 727.4 ns | 412.1 ns |
| chunk 256 KiB encode | 9.71 µs | 4.94 µs |
| finish encode | 133.2 ns | 94.4 ns |
| accept decode | 27.4 ns | 11.1 ns |
| failed decode | 187.5 ns | 192.7 ns |
| split one frame | 153.9 ns | 101.4 ns |

`failed` decode is the wash, and it is the one that allocates a Swift `String` on both sides of the
change. Everything else is 1.4× to 2.5×, including the chunk the veto was about.

`§10 of check-supervisor.sh` was a Swift↔Rust byte-table diff and could not stay one — there is no
second table left to diff. It now pins the eight door entries on both sides, refuses `appendBE` /
`struct ByteReader` / `BigEndianReader` from growing back under `Sources/SlopDeskFileTransfer`,
refuses the four constants from being respelled in `FileTransferProtocol.swift`, and keeps the
type-byte agreement as a Rust↔Rust check between `client.rs` and `protocol.rs` — narrower than it
was, since the two are one crate, but they are still edited apart. That check counts what it found
and fails on anything but five request types: the chunk's byte moved into `write_chunk_payload` on
the way, and an extraction that silently covered four of five would have read as "covered".

The Swift tests kept their hand-assembled dropd bytes and changed what they claim. They no longer
pin the layout — the crate does — they pin the MAPPING across the door: which case becomes which
type byte, which field lands in the scalar slot and which in the borrowed blob, which verdict comes
back as which Swift error. A swapped `fileSize`/`transferId` type-checks and rides through the
crate's own round-trip test untouched; it shows up as the wrong bytes there.

## The inspector's FRAME moves too, and the event JSON stays where it is (2026-08-14)

The last hand-rolled Swift codec with a Rust mirror. `InspectorWire.swift` held a length-prefix
reader, a big-endian writer, a tag switch, a cap check and a cursor-and-compact splitter;
`rust/slopdesk-inspectord/src/wire.rs` held all five as well, for the daemon's own end. Both were
right, which is the failure mode: nothing failed when they stopped agreeing.

**The line is drawn at the JSON.** The door — `rust/slopdesk-ffi/src/inspector.rs` — answers WHICH
frame arrived and WHERE its body sits, never what the body says. `InspectorEvent` stays a Swift
`Codable` type and a Rust `serde` type, and that is not the rule being bent: an event is a document
the daemon writes and the client reads, which is the two-ENDS shape. Crossing a rich, still-evolving
schema field by field to avoid a JSON parse the channel pays once per turn would buy nothing and
cost the schema's freedom to change.

`wire.rs` gained the split that made this possible. `next_message` became `next_payload` plus
`decode`, so the splitter is one implementation serving two granularities — the daemon parses into
its model, the client hands the bytes to `JSONDecoder`. `decode_client` is the client end's tag
policy in the crate that owns the tags: tag 1 answers a RANGE rather than a value, tag 2 is the
keep-alive, and tag 3 — the client's own control, arriving from the daemon — is refused as unknown,
the mirror of the tolerance `decode` extends in the other direction.

**`peek_payload_len` exists because the first cut lost frames or re-zeroed the backlog.** A handle
splitter has to answer "how big is the next payload?" before the caller commits a buffer, and the
first version answered it with `buffered_len` — the whole backlog. On the shape that matters, a
reconnect replaying the daemon's history as one chunk packed with small frames, that is the backlog
allocated and zeroed once per frame in it: a measured 843 → 1017 µs for 200 frames. The fix is a
peek that reads the prefix WITHOUT consuming, and a fifth verdict, `AGAIN`, that says how many bytes
were needed and leaves the frame where it is. The Swift decoder keeps one buffer, starts it empty
and grows it once to 4 KiB, so a stream of ordinary events never allocates again.

|  | before | after |
| --- | --- | --- |
| subscribe encode | 181.4 ns | 134.8 ns |
| keepAlive decode | 105.4 ns | 38.5 ns |
| event decode (1 KiB JSON) | 4.01 µs | 4.02 µs |
| split one frame | 179.7 ns | 66.0 ns |
| replay 200 frames | 848 µs | 827 µs |

Event decode is parity and always was going to be: it is `JSONDecoder` with a few hundred nanoseconds
of framing around it. It reaches parity rather than regressing because `Data.SubSequence` IS `Data`,
so the body now goes to the parser as a view onto the caller's own payload — the copy the old code
paid to build a `Data` from a slice is gone.

**The cost this port has that the others did not: `slopdesk-ffi` now links `slopdesk-inspectord`,
which brings `serde` and `serde_json`.** The static archive went 26 MB to 29 MB. It is gitignored,
it is an input rather than a source, and the linker drops what no entry point reaches — but it is a
real widening of the client's dependency graph, and the alternative was worse: factoring the framing
into a crate of its own to keep serde out would have put a third file between two ends that belong
next to each other, to save an archive nobody ships.

`§12 of check-supervisor.sh` follows §10: the eight door entries on both sides (seven with a Swift
caller — `_buffered` is the crate's own drained-and-compacted assertion), no `appendBE` / `readPrefix`
/ `readBESeq` / cap / tag respelled in the Swift face, and the tags and the cap pinned where they are
now spelled once. `decode_client`'s two arms are pinned by name, because a client end that grew a
third arm would be reading a frame the daemon never sends it.

## The last big-endian helper in `Sources/` becomes a test fixture (2026-08-14)

`Sources/SlopDeskProtocol/BigEndian.swift` was the shared `appendBE` / `BigEndianReader` pair every
hand-written Swift codec used to reach for. After the wire, the mux envelope, the metadata payloads,
the workspace channel, PATH 4's client end and the inspector's frame all crossed into Rust, a grep
for its two symbols under `Sources/` matched exactly one file — itself. Its only remaining callers
were six suites under `Tests/SlopDeskProtocolTests`.

So it moved rather than being deleted: `git mv` to `Tests/SlopDeskProtocolTests/BigEndianFixtureBytes.swift`,
following `Tests/SlopDeskVideoProtocolTests/VideoWireFixtureBytes.swift`, which made the same trip for
the same reason. In a test a hand-spelled big-endian body is the POINT — a fixture that built its
bytes by calling the encoder would be asserting that the encoder agrees with itself. In `Sources/` the
same helper is the seed of a second implementation of a wire, and it never arrives as a codec; it
arrives as "just this one field".

`check-supervisor.sh` now fails on a declaration of `appendBE` or `BigEndianReader` anywhere under
`Sources/`, and separately on the fixture file going missing — the pin has two ends because the point
is *where* these bytes may be spelled, not that they may never be.

No measurement, because nothing shipped changed: this is a file moving between targets, and
`SlopDeskProtocol` compiles with one fewer source file in it.

## The capture path's three measurements cross, and the fold gets faster on the way (2026-08-14)

`FrameHasher`, `ScrollShiftEstimator` and `AdaptiveFrameQP` are gone from
`Sources/SlopDeskVideoProtocol`, replaced by one `FrameMeasurement.swift` that holds no arithmetic
at all. The fold, the mode-hash background exclusion, the informative-row scoring, the band, the QP
ramp and every plane guard are `rust/slopdesk-video`'s — written in the 2026-08-13 stage and unused
until now — reached through a new `rust/slopdesk-ffi` door, `video_frame`.

**This is the one door that does not take bytes.** Every other entry point here borrows a `Data` the
caller owns; these borrow an address inside a Core Video mapping, because that is the only form the
pixels have. `docs/55` §4 has the shape written up: the length is not given but computed as
`stride * rows` with a `checked_mul` on the Rust side, a plane and its stride cross as one value so
they cannot be mismatched, and the answers come back by value as small `#[repr(C)]` records.

**The regression the rule is for, and what it turned out to be.** The first working version was 27%
SLOWER on the frame hash — 219 → 278 µs per 1080p frame — while the other two measurements were
already several times faster. That is the *measured regression* `CLAUDE.md` names as the only veto,
so it was diagnosed rather than argued past, and it was two separate copies of the same mistake in
`StreamHasher`'s main loop:

- `consume_block(&mut self, block: &[u8; 32])` copied every block to the stack on the way in. Three
  megabytes moved per frame to hash three megabytes. 278 → 259 µs.
- Taking it as a plain `&[u8]` instead fixed that and cost the other half: with the length unknown
  at compile time the `chunks_exact(8)` lane walk stays a runtime loop. A `&[u8; 32]` — borrowed,
  fixed-size, converted with a `try_from` that only re-states a check `chunks_exact(32)` already
  made — unrolls it into four loads. 259 → 214 µs.

| per 1080p frame | Swift | Rust |
| --- | --- | --- |
| frame hash | 219.0 µs | 214.2 µs |
| scroll shift (quantized, ±270 rows) | 3046.1 µs | 912.6 µs |
| adaptive QP | 2143.5 µs | 284.1 µs |

The two estimators are 3.3× and 7.5× because the Swift built its row-hash arrays through a
`StreamHasher` whose 32-byte carry was a heap `[UInt8]`, and paid for one per row — the reason the
Swift also carried a second, allocation-free `hashRow` entry beside it. In Rust the carry is a
`[u8; 32]` field, so there is nothing to avoid and there is one entry.

**The hash pins moved to the face, and everything else went.** `FrameHashValuePinTests` keeps the
absolute 64-bit constants the Swift original produced and drops the pointer-vs-array differential:
there is one entry now, so there is nothing to hold in step with it. Those constants are the only
oracle this hash has — it is xxHash64-SHAPED but its fifth lane prime is the repo's own, so
`xxh64sum` will disagree with it forever — and they passing unchanged over the door is the proof the
Rust fold is bit-identical. `ScrollShiftEstimatorTests` lost its `rowHashes`-vs-`hashNV12` internals
test and kept the behaviour the port was made for: exact hashing misses a noisy scroll, quantized
hashing finds it, and a uniform or random frame still reports nothing.

`ShiftEstimate::confidence_milli` was added to `slopdesk-video` rather than written in the door,
because "how a confidence is reported as an integer" is a fact about the estimate and the caller's
gate is an integer comparison against it. The door converts an address to a slice and a band to two
`i32`s, and decides nothing.

§ of `check-supervisor.sh` pins the four door entries, the three deleted files, and — repo-wide —
that no `StreamHasher`, `hashRow`, `rowHashes`, `borrowPlane`, `estimateVerticalShift`,
`changedFraction` or `adaptiveMaxQP` grows back under `Sources/`. Each is small, pure and
framework-free, which is exactly the shape a "tiny local helper" takes.

## The four pure policies cross, and the two dead mappings just go (2026-08-14)

`YCbCrConversion.coefficients`, `CoordinateMapping.windowPoint`, `AdaptivePlayoutPolicy.stepMs` and
`StreamStallPolicy.evaluate` are now faces over `rust/slopdesk-video`, reached through the new
`video_policy` door. Each is a handful of arithmetic with no state behind it, which is the whole
reason they were the last four: nobody ports a five-line function, they reimplement it in place.

**Two of them are pinned as IEEE bit patterns, and that is the argument.** `coordWindowPoint` and
`ycbcr` are emitted into `golden/golden_vectors.json` as raw `f64`/`f32` bit patterns. A Swift copy
of either agrees with the Rust until a compiler fuses the multiply and the add, or until someone
writes `255.0 / 219.0` without the `Float` annotation and an `f64` intermediate narrows on the way
out. Then a click lands a pixel off, or the whole picture shifts a code value, on ONE machine — with
every test still green. `make golden` staying byte-identical after the port is the proof the door
carries them intact, which is a stronger check than any assertion either side could hold.

**`StreamStallPolicy` had no Rust twin, so one was written.** `stream_stall.rs` is the first module
in this port that was not already implemented twice: `Liveness`, `StreamVerdict` and `verdict`, with
the idle-skip branch (frames are absent BY DESIGN, so only the heartbeat counts) and the inclusive
`>=` at the threshold that keeps a caller polling on a tick boundary from sitting one sample short
forever. The two optional stamps cross as a value plus a presence flag rather than a sentinel time,
because "no frame has EVER arrived" and "the last frame arrived at time zero" are different states
and only one of them can be a stall.

One behaviour changed, deliberately. Swift's `max` returns `x` when the comparison is unordered, so
a NaN `lastFrameAt` beside a genuinely stale heartbeat propagated NaN and reported `.live` — a
frozen stream reading as healthy because one stamp was unreadable. Rust's `f64::max` is NaN-ignoring,
so the good stamp survives and the stall is seen. No test pinned the old result.

**`cgRectToCocoa`, `backingScaleFactor(forWindowBoundsCG:)`, `windowPoint(pixel:)` and `ScreenInfo`
were deleted rather than crossed.** They had no caller anywhere under `Sources/` — only their own
tests — so crossing them would have built a door for nobody. The Rust twins stay: they are the
single implementation of doc 18 §B's multi-monitor fix, tested, and deleting them would drop a
documented capability rather than a duplicate, which is not what this port is for.
`AdaptivePlayoutPolicy.Config`, `.targetSeconds` and `.stepSeconds` went the same way — internal
rungs of a ladder whose only public step now crosses whole.

§ of `check-supervisor.sh` pins the four door entries per file, that no `targetSeconds`,
`stepSeconds`, `cgRectToCocoa`, `backingScaleFactor` or `ScreenInfo` grows back under `Sources/`, and
that `YCbCrConversion.swift` never spells a BT.709 coefficient again.

## The terminal-mode grammar crosses, and two dead oracles go with it (2026-08-14)

`TerminalModeTracker` is now a face over `rust/slopdesk-terminal`'s `tracker`, reached through the
new `terminal_mode` handle door. It is the first port in this series where the Rust crate already
existed in full — 2 925 lines across five modules — with **zero** reverse dependencies: no daemon
linked it, no door reached it, `INPUT_CRATES` did not cover it. It had been written and left
unwired, which is the most expensive shape a port can stop in: two grammars, and nothing making them
agree.

**Three implementations were live at once.** The Swift tracker; a frozen pre-fast-path Swift copy
(`Tests/.../Support/LegacyTerminalModeTracker.swift`) kept as the differential oracle for the memchr
skim; and the Rust. The frozen copy is precisely the "test fake" the one-implementation rule names —
it existed to be a second machine — so it went with the port, along with the fast-path suite that
compared them. The skim is still pinned, by a stronger oracle: chunk-size-1 bypasses the scan
entirely, so replaying every vector whole and byte-at-a-time and demanding identical events pins the
fast path to the transition table without a second machine to drift from.

**A fourth grammar was found and deleted.** `Tests/SlopDeskHostTests/Support/HostCommandStatusSniffer.swift`
— 275 lines of byte-at-a-time OSC 133 parsing — was a frozen oracle for `HostTitleBellSniffer`,
which no longer exists. Nothing in the repository referenced either. A frozen oracle for an oracle
that is gone is not coverage; it is a fourth place for the grammar to be subtly different.

**The corpus key was frozen but unread, and is the port's proof now.** `golden/golden_vectors.json`
has carried 16 `terminalModeTracker` cases — every alt-screen mode, every OSC 133 mark and exit-code
shape, sequences split across chunks, a DCS spoof, invalid UTF-8, an unterminated OSC — and
`golden-check.sh` listed the key as "pinned by its own XCTest suite". **No suite read it.** They were
emitted by the Swift original, so `TerminalModeGoldenVectorTests` replaying them through the door is
exactly the differential this port needed: same bytes in, same events and same final mode out, case
by case, plus per-byte chunking invariance on all 16. A pin that looks like coverage and enforces
nothing is worse than no pin, and this one is live now.

The exit code crosses as a value plus a presence flag, for the reason `video_policy` gives: a command
that finished 0 and a `;D` mark carrying nothing parsable are different facts, and only one means
success. `INPUT_CRATES` in `build-ffi.sh` grew `rust/slopdesk-terminal`, so an edit to the grammar
now makes the artifact stale rather than silently shipping the old one.

§ of `check-supervisor.sh` pins the eight door entries, that the frozen copy stays deleted, that no
`oscEscape`/`stringConsume`/`handleCSI`/`handleOSC` state machine grows back under `Sources/` or
`Tests/`, and that the corpus replay suite keeps reading the key.

## The dedup ring crosses INSIDE the input box, not beside it (2026-08-14)

`InputBoxModel` is now a face over `rust/slopdesk-terminal`'s `inputbox`, through the new `input_box`
handle door — the second half of the same crate the terminal-mode tracker came from, and the last of
`SlopDeskClaudeCode`'s logic. `InputDedupRing.swift` is **deleted**, not ported to a door of its own.

**Why the ring has no door.** It was `public` and had two dedicated test suites, so the obvious move
was a second handle beside the model's. But nothing outside `InputBoxModel` ever built one: the ring
is only correct in the presence of the tracker, because the alt-screen flip that switches the box
from **A** (a shell command line, where echo is meant to show) to **B1** (a compose overlay, where it
must not) is the *same* flip that clears a half-matched echo, and the record-then-echo ordering has
to hold across both. A second entrance would have put that coupling back on the Swift side of the
boundary, restated in a place no gate could check it. The ring crosses as the model's interior; its
own behaviour — the eviction that *flushes* a held-but-unconfirmed run rather than eating it, the
newline normalisation, the per-byte-chunking invariance — is pinned by `dedup.rs`'s 16 tests, which
are a superset of the 16 Swift ones deleted with it.

**The existing Swift suite is the differential.** `InputBoxModelTests`' 10 cases were written against
the Swift implementation and were not touched by this change; they pass verbatim against Rust. That
is the same shape as the terminal-mode corpus replay, one level up: a test that predates the port and
does not know it happened is the only kind that can prove the port.

**The state crosses as one record, not five getters.** `slopdesk_input_box_state` answers mode,
affordance, running flag and last exit code together, because they are answers to the same question.
A caller reading them one at a time could ingest a chunk between two of them and render a mode from
before it beside an exit code from after. The rendered bytes are a SLOT for a reason the marks are
not: the ring may *add* bytes to a chunk — a run it had been holding on behalf of an earlier one and
has now given up on — so the count is not knowable before the call, and re-running the filter to
learn it would consume the chunk twice.

§ of `check-supervisor.sh` pins the eight door entries, that `InputDedupRing.swift` stays deleted, and
that no `InputDedupRing`/`expectedEchoBytes`/`stepFilter` grows back under `Sources/` or `Tests/`.

## Ten of the thirteen frozen golden keys were pinned by a sentence (2026-08-14)

Porting the terminal-mode tracker turned up one unread golden key. Auditing the rest turned up nine
more, and one of them had already gone wrong.

`golden-check.sh` splits the corpus in two: `EMITTED_KEYS`, regenerated by `slopdesk-corevectors` and
byte-diffed on every run, and `FROZEN_KEYS` — in the corpus, not emitted, and, said the script,
"pinned by their own XCTest suites". **That sentence was the entire guarantee for ten of the
thirteen.** `terminalModeTracker` was replayed by nothing. `inputMotionCoalesce` did not appear
anywhere in the repository outside the corpus itself. The capture, virtual-display and
window-placement keys were covered by three notes in the generator saying their logic "lives solely
in the Rust core (`slopdesk_core::…`, reached via the C ABI)" and that "`golden_parity` validates the
core against the frozen corpus" — there is no `slopdesk_core` crate and no `golden_parity` test, and
the math is Swift in `SlopDeskVideoHost`. `VirtualDisplayGeometryTests` looked like the missing
reader for three keys, but it names them in `// MARK:` headings above assertions written by hand and
never opens the corpus at all, which is the most convincing shape this failure takes.

**One had drifted, exactly as an unread pin does.** `6281fae2` (2026-07-15) deliberately changed
`VirtualDisplayPlanner.refreshRates` so a VD advertises the `min(120, 2 × fps)` oversample mode that
kills the capture beat — `refreshRates(60)` went from `[60, 30]` to `[120, 60, 30]`. It updated the
hand-written suite beside the code and left the corpus alone, because nothing read it. Three of the
five `vdRefreshRates` cases have recorded a superseded law ever since. The four other reviving suites
passed on the first run — 80 cases across eight keys, bit patterns and all — so the drift is one key,
not a rot.

**The pins are live, and the claim is now a gate.** Five suites (`WindowPlacementGoldenVectorTests`,
`VirtualDisplayGoldenVectorTests`, `CaptureRegionGoldenVectorTests`,
`InputMotionCoalesceGoldenVectorTests`, and `TerminalModeGoldenVectorTests` from the port before
this) replay their keys through the live implementations. `golden-check.sh` then checks what it used
to assert: every frozen key must be named by a file that ALSO mentions `golden_vectors` or
`GoldenCorpus`, so a `// MARK:` heading does not count and a deleted suite fails the gate by name.

Why revive rather than delete: these vectors are bit patterns, and what they hold is exactly what a
port has to preserve — the `!(targetArea > 0.0)` NaN-faithful guard, the `/ ppi * 25.4` operand order
that must never become an FMA, the ordered ternary min that `Swift.min` would get wrong, the strict
`>` in the retarget gate, and the trailing-edge guarantee in the motion collapse. Rewriting any of
this in Rust without them would be a rewrite, not a port. The terminal-mode port is the proof: its
16 frozen-but-unread cases became the differential that made the port checkable.

`vdRefreshRates` is left SKIPPED with the drift named in the skip message, because refreshing a
frozen vector is the corpus owner's call and `CLAUDE.md` forbids regenerating over the file. The
assertion under the skip is the one that should run once those five cases are refreshed.
