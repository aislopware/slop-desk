# 66 — The inspector's client store becomes a projection

`docs/65` moved `WorkspaceStore`'s decisions to Rust and left the state where it was for exactly one
store. This is that store. It is a smaller subject than `docs/65` and a sharper one, because the
violation here is not "a decision lives on the wrong side" — every decision crossed already — it is
the one thing `CLAUDE.md` bans outright and this tree still has: **the same eight types declared in
two languages**.

## 1. The mirror, named exactly

`rust/slopdesk-inspectord/src/event.rs` declares `InspectorEvent`, `ToolCard`, `TodoItem`,
`SubagentNode`, `ThinkingMarker`, `MessageEvent`, `SessionInfo` and `WorkflowMarker`, and derives
`Serialize` **and** `Deserialize` on every one. `Sources/SlopDeskInspector/InspectorEvent.swift`
declares the same eight as `Codable`, with a hand-written `init(from:)` on `ToolCard`. Two
declarations of one document, and two deserialisers for it.

`docs/54` §4 calls this wire "the two-ENDS exemption to the one-implementation rule". That claim is
TRUE of the frame and FALSE of the event, and the file that carries it says so in its own words:
`InspectorCodec` encodes tag 3 and decodes tags 1–2 while `wire.rs` does the mirror — one capability
per end, each written once. The EVENT is not that shape. Both ends deserialise it, from the same
bytes, into the same eight types. The exemption was claimed for the frame and then quietly extended
to the payload the frame carries.

The cost is not hypothetical. The same file records what it already cost once: `ToolCard.input` used
to be a JSON tree this target modelled itself, and it answered DIFFERENTLY from
`slopdesk-inspectord`'s flattening for every integer past `2^53`, because the Swift decoder made
every JSON number a `Double` before either rendering ran. That divergence was fixed by asking the
crate with the RAW bytes. This stage finishes the same thought: if the raw bytes are what makes the
answer exact, the decode belongs where the bytes are read.

## 2. What is actually left in Swift, measured

Every RULE crossed in earlier passes. `InspectorStoreRules` is the face of
`slopdesk_workspace::inspector_store` (the five caps, the tree walk, the empty-state gate);
`PendingToolSummary` is the face of `slopdesk-inspectord`'s `tool_render`; `InspectorCodec` and
`InspectorFrameDecoder` are faces of the crate's `wire`. What remains is three things:

- **The taxonomy** — `InspectorEvent.swift`, 267 lines of `Codable` DTOs. The mirror above.
- **The decode** — one `JSONDecoder().decode(InspectorEvent.self, from: json)`, plus `rendered`
  grafting the crate's two answers back onto the tree the decode just built.
- **The state** — `InspectorViewModel`'s thirteen stored properties, three dictionary indices and the
  upsert/evict bookkeeping over them. This is the `docs/65` shape exactly: the decisions are asked of
  Rust one at a time (`overflow(_:count:)`, `subagentTree(_:cards:)`, `hasRenderableActivity(…)`) and
  the answers are applied to values Swift holds — which means every one of them is marshalled ACROSS
  the boundary on the way in, per call, so a fold can be told how much to drop.

The marshalling is the tell. `PendingToolSummary.scent(todos:)` packs the whole todo list into
length-prefixed fields and hands it over on every read, because the list lives on the wrong side. It
is not a face over a rule; it is a rule reaching back for state it should already own.

## 3. What the client actually reads, measured

The whole live surface, across `SlopDeskMacUI`, `SlopDeskPhoneUI` and `SlopDeskClientCore`, is three
readings at six sites:

| reading | sites |
| --- | --- |
| `feedState == .live` | `SidebarRowReading`, `MacPeekReply`, `PhonePeekReplyCardView` |
| `toolCards.last(where: { $0.status == .pending })` → `PendingToolSummary.line(card:)` | `MacPeekReply`, `PhonePeekReplyCardView` |
| `todos` → `PendingToolSummary.scent(todos:)` | all three |

Nothing else has a reader outside this target's own tests: not `subagentTree`, not `messages`, not
`thinkingCount` / `lastThinking`, not `unknownLineCount` / `recentUnknownLines`, not
`evictedToolCardCount`, not `droppedReplayEventCount`, not `hasRenderableActivity`, not the main
`toolCards` timeline itself beyond that one `last(where:)`.

**That is substrate, not dead code, and the distinction is recorded so nobody re-litigates it.**
`DECISIONS.md` deleted `SlopDeskInspector/InspectorViews` along with the rest of the SwiftUI chrome;
the store is what those views read, kept because the panel is a shipped decision (`DECISIONS.md`:
"structured view = the read-only inspector") whose surface has not been rebuilt in UIKit/AppKit yet.
So it PORTS, with its tests, rather than being deleted — deleting a shipped feature's substrate is a
product call and not this campaign's to make. What it does NOT get is a Swift projection door per
field: the doors this stage opens are the ones the table above names, and the rest of the state is
reachable from Rust's own tests, which is where its assertions now live.

## 4. Where the fold goes, and why not the obvious place

Into **`slopdesk-inspectord`**, as a new `store` module beside `event.rs`, and
`slopdesk_workspace::inspector_store` moves there with it.

`slopdesk-workspace` looks like the natural home — the rules are there today, with every other
client-side surface rule. It is the wrong one, for a reason that is about crate edges rather than
taste: the fold's input is `InspectorEvent`, so wherever the fold lives must see that type. Putting
it in `slopdesk-workspace` means `slopdesk-workspace` depends on `slopdesk-inspectord`, which drags
a DAEMON crate — tailer, server, replay log — under the crate every client surface rule imports, and
onto all three FFI slices. Declaring the type a second time in `slopdesk-workspace` instead would
trade a cross-LANGUAGE mirror for a cross-CRATE one, which is the same defect with better syntax.

`slopdesk-inspectord` has no such problem in the other direction. It depends on `serde` and
`serde_json` and nothing else — no tokio, no slopdesk crate — and `slopdesk-ffi` already links it
into the macOS, iOS and iOS-simulator slices for the splitter and `tool_render`. The rules move to
meet the type, not the other way round.

`slopdesk_workspace::inspector_store` is emptied by that move, and `rust/slopdesk-ffi`'s
`inspector_store.rs` folds into `inspector.rs`: the store handle and the frame it is fed from are one
subject once the state is on one side.

## 5. The shape

A handle, as `docs/59` §2 and `docs/65` §2 shape one:

- `slopdesk_inspector_store_new` / `_free` — one per `LivePaneSession`, lifetime the pane's.
- `_apply(handle, bytes, len)` — one event's **raw JSON**, as it came off the frame. Not a decoded
  struct marshalled field by field: raw, because that is what makes an integer past `2^53` exact, and
  it is the same argument `tool_render` already won.
- `_reset(handle)` — what `consume()`'s entry does today, as an OPERATION rather than a list of
  properties a future field can be forgotten from.
- `_revision(handle)` — the monotonic counter a UIKit/AppKit reader diffs against, the way
  `workspaceMirrorRevision` is diffed.
- The three readings from §3, and nothing else. The pending-tool one carries THREE fields, not two —
  the collapsed row draws the name and the summary, the expanded one draws the full display.

Swift keeps `InspectorViewModel` as a `@MainActor` class holding the handle, plus `feedState` — which
stays because it is about the `NWConnection`'s lifetime, and that seam is `docs/65` §5's parked one
(`NWByteChannel`, `SerialFeedGate`, `BoundedInputPipe`). `@Observable` goes with the state it
tracked: there is no SwiftUI left to track it, and the two overlays already read on demand.

`InspectorEvent.swift` and `InspectorStoreRules.swift` are deleted whole, and so is
`PendingToolSummary.swift`: `scent(todos:)`'s packing and `TodoItem.Status.ffiByte` exist only to send
state back across, and `line(card:)` was already a field lift. `PendingToolLine` survives it — a
value the views render in three places — and moves beside the model that vends it.

`InspectorWireMessage.event` carries `Data`, not a decoded tree, and `CodecError` loses
`malformedBody` with the parse that threw it: a body that does not decode is now `apply`'s `false`.

## 6. What must cross as an explicit operation

Four behaviours are load-bearing and none of them falls out of "port the fields":

- **Reset-on-replay.** An iOS resume re-subscribes `fromSeq: 0`, so the host replays the entire
  history into the SAME store. Cards and agents self-dedupe by id; the monotonic counters do not, and
  without the reset every resume doubles "N thinking steps" and re-appends the message timeline.
  `_reset` is that, named once.
- **`historyTruncated` is latest-wins.** A re-replay re-sends the current drop count; accumulating it
  would claim a growing hole that is not there.
- **serde's tolerance must equal `decodeIfPresent`'s.** `ToolCard.init(from:)` defaults `status` to
  `.pending` and both rendered strings to `""`, because the daemon sends neither. `slopdesk-inspectord`
  already carried the whole taxonomy with those defaults and `golden_events.rs` already replayed the
  pinned corpus through it, so this crossed before the pass rather than during it.
- **A reset that undoes nothing must not report a change.** A subscribe is the one call made without
  being told anything, so an unconditional revision bump would announce a change on every reconnect of
  an idle pane. It bumps only when an accumulator actually carried something.
- **The eviction index rebuild.** After a drop-oldest the surviving cards' positions all shift, and a
  later upsert of a retained id must still resolve in place. In Rust this is the same rebuild, but it
  is now on the same side as the cap that caused it.

## 7. The differential

As `docs/64` and `docs/65`: the consumers are the proof.

- **One change, the same one, at all six call sites in §3.** Each stops SEARCHING a collection it was
  lent — `toolCards.last(where: { $0.status == .pending })`, `scent(todos:)` — and starts reading the
  answer: `vm.pendingLine`, `vm.todoScent`. That is the whole diff; the surrounding `.live` gate, the
  two-tone splice and the expand/collapse cut are untouched. A diff BEYOND that means the boundary
  moved, which is the failure this standard catches.
- **Migrations, not rewrites.** `InspectorViewModelStateTests`, `PendingToolSummaryTests` and
  `InspectorEventGoldenVectorTests` assert what is now Rust's, so they move to Rust with the same
  inputs and the same expected answers. A changed expectation is a transcription error.
- **`InspectorResilientDecodeTests` stays, and splits.** The unknown-tag half is still framing and is
  asserted where it was. The malformed-BODY half moved one layer in WITH the parse: the stream now
  hands the garbage over like any other body, and `apply` returning `false` is what costs that one
  event. Same inputs, same guarantee, asserted at the surface that now decides.
- **`InspectorTransportTests` asserts what its layer owns.** It cannot assert what a body says any
  more, so it asserts that the bytes between the length prefixes arrive whole, in order and unaltered
  — which is also what pins the one copy `nextMessage` still makes out of its reused scratch buffer.
- **`InspectorGlueTests` stays Swift.** Its subject is the channel and the `Task` lifetime — a
  re-subscribe after a flap, a cancelled teardown, a keep-alive that must not reach the fold. Its
  READS move onto the handle, and the four cases whose only subject was fold SEMANTICS (upsert by id,
  arrival order, todos-replace, subagent attach) are covered by the store's own tests against the same
  bodies, so they go rather than being re-asserted through a narrower window.
- **`inspectorEvents` keeps its reader.** The Swift golden replay is deleted with the decoder it
  drives; `rust/slopdesk-inspectord/tests/golden_events.rs` already replays that key against the same
  corpus, so `slopdesk-gate golden`'s frozen-key check stays satisfied. Verified before the sweep,
  not after.
- **The ratchet gains a claim.** `the_inspector_frame_has_one_spelling` now bars the ten taxonomy type
  names from `Sources/`, with its own break-test. Its doc's "two-ENDS document" reading of the event
  was wrong and is corrected there.

## 8. One pass

Rust store and its migrated tests first, the doors second, the Swift sweep third, gate once. That
order is a dependency list, not a schedule — there is no intermediate state worth building, because
the store has exactly one owner before the pass and exactly one after, and the only way to have two
is to stop halfway. A red tree in the middle is expected.
