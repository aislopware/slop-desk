# 65 — Stage I: `WorkspaceStore` becomes a projection

`Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore.swift` is 3765 raw / **1463 code**
lines and calls no door at all. It is the largest single piece of undelegated non-UI Swift left in
the tree, and it imports no view framework — so by the standing rule it is an architecture bug, not
a floor. Forty-two sibling files sit beside it under `Store/`, most of them `WorkspaceStore+*`
extensions that reach into its stored state because an extension cannot hold any.

The previous port doc (`docs/64`) closed a MIRROR: two literals, one contract, delete one. This one
is not that shape. Nothing here is written twice — the store holds state Rust has never seen. What
is wrong with it is the BOUNDARY: decisions live on the near side of a seam whose other half is
already Rust, and the seam is drawn around a language rather than around a lifetime.

## 1. What is actually in there, by kind

Reading the state block and the init, every stored property falls into exactly one of three kinds.
The kind is what decides where it goes; nothing here needs a judgement call per property.

**Kind A — state PLUS the decisions over it.** Pure, testable, no `Task`, no `@MainActor`
requirement, no Apple type on the boundary. This is Rust's, and the tree already says so out loud in
one case: `videoSlots` is a `VideoSlotLedger`, a Rust handle, with the reason written on it — *"state
AND the decisions over that state … see its own doc-comment for why that earns a handle."* Kind A is
everything with that same shape and no handle yet:

- the projection memos — `treeProjection`, `topologyProjection`, `displayOrderProjection`, all three
  keyed on `workspaceMirrorRevision`, all three re-deriving a walk over the document;
- the **pane-dial gate** — `paneDialGate`, `dialConfirmedHostKey`, `lastFoldedDocumentFrames`,
  `paneDialHoldExpired`, `paneRedialAwaitsDocument`, plus `refreshPaneDialGate()` and
  `noteFoldedDocumentProvenance()`. Five stored bits and two deciders: a state machine wearing a
  class's clothes;
- the **save-generation guard** — `saveGeneration`, `savingEnabled`, `isCurrentSaveGeneration(_:)`.
  Its own doc-comment already says it "mirrors `FocusGenerationGuard`", which is the tell that the
  shape is a type and not a field;
- the **launch-adopt arm** — `armedBootstrapEnvironment`, `armedBootstrapShape`, `pendingLaunchAdopt`,
  `launchAdoptIntentID`;
- the **document-cache provenance** — `documentCacheSeedHostKey`, `documentCacheHostKey` and the
  "a connect to a different host clears it for the run" rule;
- the rings and sets the `WorkspaceStore+*` extensions walk — the clipboard ring, the recent-command
  ring, the close-undo slot, the pane-switcher MRU, the sync-input set, `attentionWalk`,
  `blockBookmarks`;
- the geometry inputs — `lastSolvedLayout`, `lastContainerBounds`, `liveDividerWeight` — and the
  neighbour resolution over them.

**Kind B — the runtime half.** Structured concurrency and Observation, both of which are Swift's
and neither of which has a Rust twin worth minting: `saveTask`, `documentCacheSaveTask`,
`teardownTasks` + `nextTeardownID`, `paneDialHoldBackstopTask`, the `makeSession` factory closure,
the `[PaneID: any PaneSessionHandle]` registry of live existentials, and `@Observable` itself.
`docs/59` already named this the document/runtime seam. Kind B stays Swift and gets SMALLER, because
today it is tangled with Kind A rather than sitting on top of it.

**Kind C — presentation requests.** One-shot flags a view consumes and clears: `pendingTabRename`,
`isInteractiveResizeActive`, `videoPromotionGeneration` (already "carries no logic at all, only the
last answer" — a projection of `VideoSlotLedger.generation`). Kind C stays Swift, on the façade, and
is the only Swift state a view is allowed to read directly.

## 2. The shape, and why it is not "one handle per property"

One Rust handle — `slopdesk_ws_core_*` over `rust/slopdesk-workspace`'s existing modules — owns the
Kind-A subjects that share the `workspaceMirrorRevision` key, because a memo whose invalidation key
lives in a different handle is a second place for the key to drift.

**Two corrections to §1, made after reading the crate rather than the store.** §1 was written from
the Swift side and over-lists; both corrections narrow the NEW Rust without narrowing the sweep.

- **Most of the rings, sets and walks have already crossed.** `RecentsRing` is a face over
  `store_rollup::push` — the one dedupe-to-front-and-cap the store runs at every ring — and the
  switcher, the attention walk, the close-confirm truth table and the launch/divider shape questions
  are `pane_switcher.rs`, `attention_fold.rs`, `close_confirm.rs` and `store_shape.rs` already. Their
  POLICY is Rust's; only the STORAGE is Swift, and moving storage across would add a crossing per
  mutation to relocate a decision that is already on the far side. That fights the crate's own
  convention — *the caller owns its values, Rust owns the policy over them* — so it does not happen.
- **`VideoSlotLedger` does NOT fold in.** The fold-in argument was the shared revision key, and the
  ledger does not share it: it carries its own promotion generation, deliberately, because
  `videoPromotionGeneration` moves only on slot-FREEING transitions while the mirror revision moves
  on every frame. `StoreVideoSlots.swift` is already a handle face with no decision left in it, which
  is the shape this stage is aiming AT. It stays.

What actually crosses new, then: the revision itself, the pane-dial gate, the save-generation guard
and the document-cache provenance rule.

**A third correction, made while writing the core.** §1 listed the launch-adopt arm as state to move.
Three of its four members are not: `armedBootstrapEnvironment`, `pendingLaunchAdopt` and
`launchAdoptIntentID` are owned by objects the core has never seen — an automation environment, a
staged topology, the mirror's pending set — and a copy of a fact whose owner is elsewhere goes stale
in the gap between the write that moves it and the call that remembers to push it. They cross as
ARGUMENTS on every gate call (`Inputs { channel, bootstrap_armed, offer_pending }`) rather than as
fields, which is the same convention §2's first correction names: the caller owns its values, Rust
owns the policy over them. `armedBootstrapShape` stays near-side for the same reason it always was —
it is the tree the window is already showing.

The Swift side becomes:

```swift
@MainActor @Observable public final class WorkspaceStore {
    private let core: WorkspaceCoreHandle        // every Kind-A decision
    private var registry: [PaneID: any PaneSessionHandle] = [:]   // Kind B
    private var saveTask, documentCacheSaveTask, paneDialHoldBackstopTask: Task<Void, Never>?
    public private(set) var pendingTabRename: TabID?              // Kind C
    var revision: UInt = 0    // the ONE Observation shadow every reader binds to
}
```

Every `WorkspaceStore+*` extension keeps its name and its signature and loses its body to a door
call. That is the measure of whether this landed: the extensions should read as marshalling, and a
reviewer should be able to ask "where is the decision?" and be answered "in Rust" every time.

**The `tree` property is the one to get right.** It is read dozens of times per frame by every
tracked arm in both shells, so it may NOT become a crossing per read. It stays a Swift memo — but
memoized against a revision the HANDLE owns, and rebuilt from one whole-topology delivery when the
revision moves. Same discipline as `docs/64`'s table: cross once per change, never per read. This is
the one place in this stage where a measurement, not a rule, decides the design, and it must be
taken before the extension bodies move.

**The measurement, taken.** On a 12-pane loopback document, 2 000 reads: **15.1 ms** memoized
(7.6 µs each) against **862 ms** crossing per read (431 µs each) — **57×**, and the crossing's cost
is per CELL, so the gap widens with the document. A read of the mirror's topology decodes the whole
document across the boundary and re-runs `WorkspaceTopology(entries:)` over every cell in it; a memo
hit is a counter compare. So the memo stays, and `Tests/…/TreeProjectionMemoTests.swift` keeps it
honest with a 10× floor — deliberately far looser than 57×, because a wall-clock ratio reads machine
load and the failure it exists to catch (the memo removed, or its key keyed on something that moves
per read) shows up as a ratio near 1.

**The revision has exactly ONE owner, and it is the core.** This is the part §3 says must not be
shipped half-done, so it is worth naming the shape that landed: every door that can move the gate
bumps the counter ITSELF (`WorkspaceCore::refresh_gate`), `bump_revision` is left as the door for
the changes the core cannot see — a frame folded into the mirror, the divider drag preview, this
device's own focus overlay — and the Swift `workspaceMirrorRevision` is now ASSIGNED from the core's
answer and never incremented. A counter added to in two languages is a memo key neither of them can
be held to.

## 3. One pass, not stages

This lands as ONE change. Not because it is small — it is the largest in the campaign — but because
staging it is the more expensive way to do it, and the reason is specific rather than stylistic.

Every Kind-A subject in §1 is keyed on the same thing: `workspaceMirrorRevision`, the counter that is
both the projection cache's key and the Observation shadow every reader binds to. Move the dial gate
alone and the revision has two owners for a while — the handle bumps it for the gate, the store bumps
it for everything else — and the memo in `tree` is now keyed on a number neither side fully controls.
That intermediate state is not a smaller version of the destination; it is a THIRD design, and it has
to be built, reviewed and then thrown away. Seven of those is six designs of pure waste and a
fortnight of a tree where the answer to "who decides this" is "it depends which stage we are in".

So: `rust/slopdesk-workspace` gains the whole core in one module, `slopdesk-ffi` opens its doors in
one block, and `WorkspaceStore.swift` and its forty-two `WorkspaceStore+*` siblings are rewritten in
one sweep against it. A red tree in the middle is EXPECTED and is not a signal to add a bridge — the
rule is to finish the sweep, not to keep `swift build` green through it.

That the NEW Rust is compact does not make the sweep smaller. Every extension is still read and
rewritten until "where is the decision?" answers "in Rust"; for the subjects §2 names as
already-delegated the rewrite is a trim rather than a port, and a trim that finds nothing to cut is
a file that was already done — which is an answer, not a skipped item.

**What the sweep actually found, recorded so the next pass does not redo it.** Every
`WorkspaceStore+*` file was read in full. `WorkspaceStore.swift` itself was read in full through the
cadence predicates and the git rules, and its back half by declaration survey with every body that
survey could not classify opened — which left `wireMaterializedLeaf` and `reconcileRegistry`, and
both turned out to be exactly what their names say: the first binds a materialized pane's sink
callbacks to store handlers, the second prunes eighteen `PaneID`-keyed near-side mirrors in lockstep
with the live leaf set. Wiring and bookkeeping over a UUID that never crosses; no decision in
either. Most are already
what this stage was aiming at: `+ReadOnly`, `+Desktop`, `+Keybinding`, `+FontScroll`,
`+FocusLanding`, `+Progress`, `+Templates`, `+TabOrdering`, `+Completion`, `+PaneSwitcher`,
`+PaneCycle`, `+CloseConfirmation`, `+Drop` and `+WorkspaceMirror` are marshalling and effects over
`MirrorFold` / `SupervisionFold` / `StoreRollup` / `TabOrderingEngine` / `DockTintPolicy` /
`PaneSwitcher` / `SessionTemplateEngine` / `WorkspaceTreeOps` / `BackgroundCompletionPolicy` /
`NotificationPolicy` / `CloseConfirmationPolicy` / `StoreGitCadence` / `WorkspaceBindingRegistry`,
and a trim there found nothing to cut. That is an answer, not a skipped item; the "no door in this
file" audit reports them as undelegated only because a file calls a FACE, not a door — and the same
heuristic mislabelled `+Attention` in this very pass, so it certifies nothing in either direction.
`shouldRefreshGitOnSnapshot` is the shape the rest of them already have: the two clocks and the two
sets stay near-side, and what crosses is the intervals and booleans `StoreGitCadence::refresh_due`
actually reads. Two files held real decisions and both crossed in this pass:

- **The seen-map's document rule** (`+CompletionEpoch`). Four UUID comparisons deciding whether to
  keep, adopt or empty this device's completion acknowledgements. The COMPARISONS stay near-side —
  they are identities the store owns — and what they mean crosses as
  `pane_facts::seen_document(DocumentIdentity, has_stored)`. `has_stored` is the load-bearing input:
  a first adopt is a restored map meeting the document it was written for, and clearing there would
  throw away every acknowledgement the previous run made.
- **The prompt-ordinal jump plan** (`+Blocks`). Absolute positioning built out of ghostty's RELATIVE
  binding: anchor past every prompt, then count forward in hops that fit its `i16` parameter. The
  chunking is a decision — a saturated single step lands short, chunked hops compose exactly — and it
  now lives in `slopdesk_terminal::blocks::jump_plan` with the two bounds beside it, so the `i16`
  ceiling is stated once rather than typed on both sides. Swift keeps the effect: issuing the
  actions.

Two were weighed and deliberately left, for the same reason stated twice — the crossing costs more
than the decision it relocates:

- `paneShowsBusyDot`'s reveal threshold. A single comparison against the setting it reads, and
  crossing it would put a `Double` over the boundary — the bit-exact-float rule's territory.
- `projectClosed(byRemoving:)` in `+CloseConfirmation`. It IS a rule (a project dies when its last
  terminal pane goes) and `close_confirm` is where it would live, but its inputs are two lists of
  project-key STRINGS, and no door in this set marshals a string list. Inventing that convention for
  one five-line set difference at one call site buys nothing; it goes across on the day a second
  caller needs the same shape.

What holds this honest is the same thing that held `docs/64` honest: no public method on
`WorkspaceStore` changes name or signature, so the consumer targets are the differential. The order
inside the pass is therefore not a schedule but a dependency list — write the Rust core and its unit
tests first, open the doors second, sweep the Swift third, and only then run anything.

**The one carve-out, stated up front so the finish line is not read as failed.** `docs/64`'s standard
was ZERO test-expectation changes, and it held there because that port moved data. This one moves
DECISIONS, and a handful of `@testable` tests reach past the public surface at the exact subjects
that cross — `isCurrentSaveGeneration(_:)` is `internal private(set)` and says in its own doc-comment
that it exists so "the production write path and the test assert the EXACT SAME logic". When the
logic is Rust's, the test that asserts it is a Rust unit test; it MIGRATES in this pass rather than
being rewritten in place. So the differential here is narrower and must be named exactly:

- **Zero changes** in every consumer target (`SlopDeskMacUI`, `SlopDeskPhoneUI`, `SlopDeskClientCore`)
  and in every behaviour suite that drives the store through its public methods. A diff in those is
  the boundary having moved, which is the failure this standard exists to catch.
- **Migrations, not rewrites**, for `@testable` tests whose subject is a Kind-A decision: the
  assertion moves to the Rust module that now owns it, with the same inputs and the same expected
  answer. A test that changes its EXPECTATION on the way across is a transcription error, exactly as
  in `docs/64` — the language it is written in may change, the answer may not.
- **Re-pointed reads, where the SUBJECT stayed Swift.** The superseded-debounce race in
  `LiveVideoCapTests` is Kind B — it is about a `Task` that raced past its own `sleep`, which has no
  Rust twin — so the test stays where it is and only its READS of the guard move to the handle. That
  needed one new door, `slopdesk_ws_core_save_generation`: the predicate a write path asks
  (`is_current_save_generation`) cannot answer an observer's question — *did this mutation move the
  guard at all* — without also claiming a generation, which would change the thing being observed.

## 4. What this stage explicitly does NOT do

- **It does not move `PaneSessionHandle` or `LivePaneSession`.** Those own `Task`s whose lifetime is
  the pane's and whose cancellation is Swift's; they are the runtime half by definition.
- **It does not touch `WorkspaceMirrorBox`.** The mirror is already a Rust handle
  (`slopdesk_ws_mirror_*`); this stage consumes it, it does not redraw it.
- **It does not change any public method name or signature on `WorkspaceStore`.** As in `docs/64`,
  the consumer files are the differential: a diff in `SlopDeskMacUI` / `SlopDeskPhoneUI` means the
  boundary moved, not the implementation.

## 5. The backlog this stage parks, deliberately

- ~~**`Sources/slopdesk-corevectors/main.swift` is a Swift BINARY**, which the standing rule bans
  outright.~~ **LANDED**, exactly as scoped: a target-kind change, not a language change. It is
  `Tests/SlopDeskCoreVectorsTests/` now — `CoreVectors.mint()` plus the one suite that calls it — and
  it was never a candidate for a port, because a Rust minter would emit the corpus through Rust and
  diff it against Rust: the corpus exists to catch a `#[repr(C)]` field reorder or a length in the
  wrong unit as SWIFT sees it, and porting the minter deletes exactly that. Two things the move
  bought that the executable could not: the suite asserts its own mint against the committed corpus,
  so a wire change is red under plain `swift test` rather than only under `just golden`; and the
  mint reaches the gate as a file (`.work/golden/corevectors.json`) instead of stdout, which is also
  the file a legitimate wire change merges FROM. The key sets stay typed in one language, in
  `rust/slopdesk-devtools/src/gates/golden.rs` — the suite names none of them, deriving its check
  from what it minted.
- **`SerialFeedGate` (113), `NWByteChannel` (87), `BoundedInputPipe`** — the store seam in miniature,
  and they will read differently once §3's idiom exists. Re-triage them after stage 4, not before.
