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

One Rust handle — `slopdesk_ws_core_*` over `rust/slopdesk-workspace`'s existing modules — owns ALL
of Kind A. Not one handle per bullet above: the bullets share the `workspaceMirrorRevision` key, and
a memo whose invalidation key lives in a different handle is a second place for the key to drift.
`VideoSlotLedger` folds into it rather than staying a sibling, for the same reason.

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

## 3. The stages, in the one order that ends green

Each stage deletes Swift and ends with a green `just quick`, so any one of them can be the last one
that lands that day. The order is chosen so that no stage needs a bridge to hold the build up —
`demolish in one pass` applies WITHIN a stage, not across the whole file at once.

1. **The dial gate.** Five bits and two deciders, with no callers outside the store and its own
   tests. Smallest complete state machine in the file; it proves the handle shape end to end.
2. **The save-generation guard + the two debounce schedulers.** The `Task` stays Swift; the
   "is this generation still current, should this write happen at all" decision crosses.
3. **The launch-adopt arm and the cache provenance.** One subject: which host's picture this run may
   honestly show, and which layout it may offer.
4. **The rings, sets and walk memories.** Clipboard, recent commands, close-undo, switcher MRU,
   sync-input, attention walk, block bookmarks. Mechanical once 1–3 have set the idiom.
5. **The geometry inputs and neighbour resolution.** `lastSolvedLayout` / `lastContainerBounds` /
   `liveDividerWeight`, and the directional `move(_:)` that reads them.
6. **The projection memos and `tree`.** LAST, and only after the measurement in §2 — everything
   above changes what the revision has to invalidate, so pinning the memo first would pin it wrong.
7. **`VideoSlotLedger` folds into the core handle**, and the sibling `StoreVideoSlots.swift` goes.

## 4. What this stage explicitly does NOT do

- **It does not move `PaneSessionHandle` or `LivePaneSession`.** Those own `Task`s whose lifetime is
  the pane's and whose cancellation is Swift's; they are the runtime half by definition.
- **It does not touch `WorkspaceMirrorBox`.** The mirror is already a Rust handle
  (`slopdesk_ws_mirror_*`); this stage consumes it, it does not redraw it.
- **It does not change any public method name or signature on `WorkspaceStore`.** As in `docs/64`,
  the consumer files are the differential: a diff in `SlopDeskMacUI` / `SlopDeskPhoneUI` means the
  boundary moved, not the implementation.

## 5. The backlog this stage parks, deliberately

- **`Sources/slopdesk-corevectors/main.swift` (919 lines) is a Swift BINARY**, which the standing
  rule bans outright. It is parked rather than ported because a Rust generator would emit the corpus
  through Rust and diff it against Rust: the corpus exists to catch a `#[repr(C)]` field reorder or a
  length in the wrong unit as SWIFT sees it, and porting the generator deletes exactly that. The
  resolution is a target-kind change, not a language change — `executableTarget` → a test target
  `slopdesk-gate golden` invokes — and it belongs in its own change.
- **`SerialFeedGate` (113), `NWByteChannel` (87), `BoundedInputPipe`** — the store seam in miniature,
  and they will read differently once §3's idiom exists. Re-triage them after stage 4, not before.
