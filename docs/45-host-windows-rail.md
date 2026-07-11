<!-- PROPOSAL (2026-07-11) — not yet implemented. Output of the multi-agent design round for the
     right-hand host-windows sidebar (3 independent designs x 3 adversarial critics -> synthesis).
     Binding user directive baked in: rows anchor on app icons; window-content imagery only at
     legible size (large on-demand peek), never inline row thumbnails. -->

# Host Windows Rail — Definitive Design Spec

The right sidebar that mirrors the host machine's desktop. Synthesized from three designs and nine critiques; every critical/major flaw is resolved inline, every contested call adjudicated.

---

## Adjudicated calls (where critics disagreed with designers)

1. **Ordering:** stable, never z-order — sections alphabetical by appName; rows within a section in first-seen order. Focus changes restyle rows, never move them. (Kills the row-shuffle-under-cursor flaw in designs 2/3.)
2. **Click grammar:** single-click acts (focus-if-streamed, open-if-not), matching the left rail; select-then-double-click and all double-click semantics are dropped.
3. **Streamed marker:** trailing accent tab-ordinal micro-text, NOT the raised card — raised card stays reserved for selection/keyboard cursor, preserving the shared Slate vocabulary.
4. **Phase 1 ships with icons:** the zero-wire monogram phase is cut (violates the binding app-icon directive; co-deploy policy makes old-host fallback dead code). Phase 1 includes wire types 16–18 and client-local icon resolution.
5. **Delta vs snapshot:** generation-anchored FULL snapshots win (design 3's spine); deltas rejected — idempotent, latest-wins, no sequencing machinery on lossy UDP.
6. **Subscribe = poll:** one message (`windowFeedSubscribe` carrying `knownGeneration`, sent every 2 s) serves as Phase-1 poll, Phase-2 subscription keepalive, AND the loss-healing resync anchor. Phase 2 is host-only work; client wire code never changes.
7. **Palette first:** Open Quickly host-window rows ship in Phase 1, not Phase 5 (this user lives in ⌘⇧O; palette ≫ panels).
8. **Title is volatile:** excluded from memo fingerprint AND leafIdentity; live-read in the leaf. Same for dimensions and flags. leafIdentity = `windowID|bundleID` only.
9. **Frontmost-on-host cue:** kept, as `.medium` title weight only (quietest possible cue, real supervision info); focus-only changes never burst the feed and never reorder.
10. **Peek trigger:** Space / context menu only at launch; hover-dwell deferred pending hardware evaluation. Peek card mounts via OverlayHostView (in-column placement is physically impossible at 240 pt).
11. **Blob transport:** ONE shared `blobChunk` reply type + one shared reassembler for icons and previews (two request types, since icon requests must carry the bundleID string).
12. **Hover trailing slot:** verb hint (`OPEN` / `FOCUS · 3`), not dimensions — dimensions move to tooltip and peek caption (240 pt row can't carry both).
13. **Hostname header / footer:** cut. Header is `HOST`; the left rail's footer already owns connection truth. No second footer, no counts duplication.
14. **Minimized rows:** listed (completeness goal #1), dimmed in place — never re-sorted to the bottom, no `MIN` suffix text; tooltip disambiguates minimized / other-Space / hidden-app.
15. **Raise-on-Host:** cut from scope entirely (type-9 `focusWindow` is session-bound; a new verb + lane plumbing isn't worth it yet).

---

## 1. Design thesis

The left rail answers *"what am I working on here"*; the right rail answers *"what is alive on the host."* It is a **supervision instrument, not a picker**: a calm, complete, app-grouped inventory of every host window where each row is one click from becoming a pane, and every already-streamed window points back at its pane.

Shape follows three forces:

- **Mirror-twin anatomy.** Same ground surface, 40 pt strip, instrument-voice header, search plate, 32 pt rows at radius 7 — the workspace reads as one continuous chrome band: ground | lit face | ground. Zero new visual vocabulary; the panel's only chroma is its data (app icons).
- **Stability is the UX.** A list scanned 50 times a day must have muscle-memory geography. Nothing reorders on host focus flips, title churn, or refresh ticks. State is expressed by restyling in place (weight, dimming, accent ordinal), never by motion or position.
- **The host owes this feature almost nothing.** One cheap `CGWindowListCopyWindowInfo` differ (2.5 ms measured), 0 Hz with the panel collapsed, generation-gated snapshots so unchanged desktops cost 5 bytes per 2 s. `SCShareableContent` (21 ms + replayd) stays hello/mint-only. The media path is untouched by construction.

Per the binding taste ruling: rows anchor on **app icons**; window content exists only as a large (320 pt) on-demand peek, one window at a time, appearing only fully formed.

---

## 2. Information architecture

### Sections
- One section per host application. `SlateSectionHeader`: appName uppercased, trailing window count (instrument small 10, `Text.tertiary`, shown only when count > 1).
- Section order: **alphabetical by appName, case-insensitive** — deterministic across sessions (honest, unlike "first-appearance" which resets to the first poll's order anyway). Sections never reorder while mounted; new apps insert alphabetically with a 0.15 s opacity fade.
- Within a section: **client first-seen order** (initial snapshot seeds in received order, which is z-order — thereafter position is frozen; new windows append with fade-in). Minimized windows keep their position, dimmed.

### Row fields (one row per host window)
| Field | Source | Treatment |
|---|---|---|
| App icon 16 pt | bundleID → local `NSWorkspace.urlForApplication(withBundleIdentifier:)`; host fetch fallback (Phase 3) | leading slot; static `macwindow` glyph in `Text.icon` until resolved — no monogram, no loading animation |
| Title | record title, appName fallback when empty | body 13, `Text.primary`, lineLimit 1, truncation `.middle`; `.medium` weight iff host-focused window |
| Streamed marker | client-derived | trailing tab ordinal, instrument small 10, `Slate.State.accent` |
| Dimensions, display, minimized-state | record | tooltip + peek caption ONLY (`Ghostty — ~/work · 1512 × 982 · Display 2 · Minimized`) — never row filler |

Single-line 32 pt rows only. No subtitles, no per-row close affordance (you can't close host windows from here; absence is the design).

### Row states
- **Available:** icon + title. Nothing else.
- **Streamed in a pane:** accent tab ordinal trailing. Derived client-side: `Set<UInt32>` of streamed windowIDs recomputed once per tree change — matched via the **live binding** (`RemoteWindowModel.active` windowID after revalidateBinding), falling back to spec `appName` only (never persisted title — titles churn; a title match would misclassify restored panes and mint duplicates). O(1) set lookup per leaf.
- **Host-frontmost window:** title `.medium`. Exactly one row; restyle only, never reorder, never burst the feed.
- **Minimized / hidden-app / other-Space:** title `Text.secondary`, icon 50% opacity, in place. Tooltip disambiguates.
- **Excluded entirely:** system-dialog windows (SystemDialogMonitor owns those panes), system apps and <80 pt windows (reuse `pickerSummary` policy, extracted to a pure function).

### Disconnect / reconnect
- `.reconnecting` or `.disconnected` with cached data: last snapshot stays rendered at 40% opacity, clicks disabled. No toast, no scrim, no footer — the left rail's footer owns the connection story.
- Never-loaded + disconnected: `SlateEmptyState` (typed cause, pinned copy).
- Reconnect: fresh snapshot **diffs in place** (row identity `windowID|bundleID`) — no clear-and-repaint flash. Host restart recycles all CGWindowIDs; the streamed-marker derivation reads live bindings, which `revalidateBinding`/`WindowRebind` heal, so markers self-correct.

### Empty states (`SlateEmptyState` typed causes)
- Seam nil → "Window discovery unavailable" (headless builds inert).
- Connected, zero windows → reuse the picker's screen-recording-permission copy.
- Filter miss → existing `windowFilterEmptyMessage` static.

---

## 3. Visual spec (MERIDIAN-compliant)

**Structure:** third **plain** `NSSplitViewItem` appended after `contentItem` at `SlopDeskSplitViewController.viewDidLoad` (line 110), retained as `hostRailItem` mirroring `sidebarItem`. `NSHostingController(HostWindowsColumn)`, `holdingPriority` 260, `canCollapse` true, `safeAreaRegions = []`. Never `.inspector`, never `sidebarWithViewController`. Store/chrome/connection/preferences passed explicitly through init (no environment inheritance). `FlatDividerSplitView` ground-tone divider, `themeDidChange` splitViewItems repaint loop, and OverlayHostView z-order all cover it for free.

**Width:** new token `Slate.Metric.hostRailWidth = 240` (min 220, max 320), added to `SlopDeskClientApp.applyInitialWindowSize` chromeOverhead math.

**Panel anatomy** (VStack spacing 0 on `Slate.Surface.ground`):
1. 40 pt strip (`Metric.titlebarHeight`): `PlateIconButton(.sidebarRight)` top-**leading** (pad top 3, leading 8) — mirror of the left toggle; same choreography (hide instantly on collapse, fade back `Slate.Anim.standard.delay(0.25)`).
2. Header `HOST` — `Typeface.instrument(footnote 11, .semibold)`, tracking 1.2, `Slate.State.header`, padding h16 b6. No hostname, no count.
3. Search plate — byte-identical anatomy to `NavigatorColumn.searchField:131–158` (magnifier footnote 11 `Text.icon`, TextField body 13 with accent caret, `Surface.face` fill, `radiusSmall` 4, hairline `Line.subtle`), padded h8 b6.
4. `ScrollView { LazyVStack(alignment: .leading, spacing: 2) }` padded h8, `.scrollIndicators(.hidden)`.
5. No footer, no hairline.

**Row shell:** `SlateListRow`, height `heightRow` 32, radius `radiusTab` 7, inner spacing `space2` 8. Idle transparent. Hover → `State.hover` flat plate (`smallFade` 0.12 s), trailing overlay reveals the verb hint (`OPEN` or `FOCUS · 3`, instrument small 10, `Text.tertiary`). Keyboard cursor → hover plate + 1 px `Line.active` hairline ring, visible only while the panel has key focus. No raised card at rest anywhere in this panel. No shadows (MERIDIAN L5).

**Motion:** new rows fade in with `Slate.Anim.reveal` 0.15 s (opacity only, no layout animation, no slide); removals and field updates apply instantly. Nothing animates at rest. Cubic-bezier curves only; anything continuous would ride `TimelineView(.animation)` — nothing here does.

**Collapse toggle:** flag `hostRailCollapsed` (+ manual-override twin) on `WorkspaceChromeState`; read in `WorkspaceSplitRepresentable.updateNSViewController`; applied via `applyCollapse`'s idempotent guard with `setTerminalResizeSuspended(true)` **before** `animator().isCollapsed` (LOST-PROMPT rule). Default **collapsed**, persisted via a Defaults-backed `SettingsKey`.

**Peek card (Phase 4, the only window content anywhere):** mounted through **OverlayHostView** anchored to the row via anchor-preference handoff (composes above the AppKit split — a 320 pt card cannot live inside a 240 pt column). `Surface.raised`, `radiusCard` 8, 1 px `Line.card`; image 320 pt wide at true aspect (cap 220 pt tall, letterboxed on `Surface.face`); caption beneath in instrument small 10 `Text.secondary`: `GHOSTTY · 1512 × 982 · DISPLAY 2`. Appears **only fully formed** — no spinner, no skeleton, no placeholder; if the JPEG never arrives, nothing appears. Reveal 0.15 s, dismiss on Esc/scroll/focus-change.

`scripts/check-ds-leaks.sh` clean: no raw `frame(height:)` or `.font(.system(size:))` literals.

---

## 4. Interactions

- **Single-click / ⏎:** the one verb, state-aware and legible pre-click via the hover verb hint. Available row → `OverlayCoordinator.openRemoteWindow(summary)` → `WorkspaceStore.newRemoteWindowTab` — the sole sanctioned path (endpoint persisted for PANE REBIND, optimistic-open + `revalidateBinding` self-heal, `helloAck(false)` fallback, `liveVideoCap` gating all inherited; the rail never pre-blocks on cap — saturation shows the existing `.gated` placeholder). Streamed row → focus the existing pane (Open Quickly's `.focusPane` act; if streamed twice, the most recently visible pane wins, else tree order).
- **⌘-click / ⌘⏎:** deliberately open another pane of the same window (the sanctioned duplicate path). No double-click semantics.
- **Context menu** (mirrors the real key semantics): non-streamed → `Open in New Tab ⏎`, `Copy Window Title`; streamed → `Focus Pane ⏎`, `Open Another Pane ⌘⏎`, `Copy Window Title`; Phase 4 adds `Peek ␣`. No Raise-on-Host, no Open-in-Split at launch (deferred; the chooser pane already covers splits).
- **Keyboard:** panel focusable; ↑/↓ move the cursor across sections; ⏎ acts as click; ⌘⏎ duplicates; Space peeks (Phase 4); Esc dismisses peek → clears search → returns focus to the workspace. Type-to-filter routes into the search plate.
- **Search:** token-AND over appName+title via the pure `RemoteWindowModel.filtered` logic, run against the **non-observable snapshot held inside the memo class** — never live Observation reads (see §7; this closes the title-churn-through-search storm). Empty sections drop.
- **Palette parity (Phase 1):** Open Quickly (⌘⇧O) gains "Host Window" rows from the same `HostWindowFeed` — glyph = app icon, subtitle = appName, streamed rows act `.focusPane`, others open. OQ invocation triggers a one-shot refresh; the feed polls while OQ is open. New `BindingAction.toggleHostWindows` bound **⌘⇧R** (verified free since the Details panel removal, `WorkspaceBindingRegistry.swift:703`), rebindable, wired through `wireChromeToggles`' `installXxxToggle` closure; palette row `view.toggleHostWindows` titled by task ("Host Windows") with active-state dot; cheat-sheet row. Chord, palette row, titlebar hover-reveal button, and in-panel button all flip the ONE chrome flag.
- **No drag-to-create** (E21 WI-7 stands). No sort/group options, no settings knobs beyond the visibility toggle.
- **Surface consolidation:** the palette action "New Remote Window Tab" and the in-pane picker survive; Phase 3 re-skins both onto the shared `HostWindowListView` fed by `HostWindowFeed` (one list implementation, three surfaces). `AppLaunchMonitor` consumes the feed's snapshot when ≤3 s fresh (Phase 1), fully re-pointed in Phase 2 — one poll replaces two.

---

## 5. Wire protocol changes

Six additive `VideoControlMessage` types (16–21), all control tag 0, big-endian, house idiom (`lp` = UInt16-length-prefixed lossy UTF-8; bools/bit-flags decoded via masks; validate-then-drop; no `reserveCapacity` on untrusted counts; lengths checked before allocation). Version stays 1; both machines co-deploy. Unknown-type pin in `StreamCadenceCodecTests` moves 16 → 19 (Phase 1) → 21 (Phase 3) → 22 (Phase 4).

**Type 16 — `windowFeedSubscribe` (c→h), 5 B:** `[u8 16][u32 knownGeneration]` (0 = have nothing).
Sent every 2 s while (panel expanded OR Open Quickly showing) AND `AppConnection.status == .connected`, on ONE persistent collision-safe channelID per connection epoch. On activation: send immediately, retransmit at 500 ms until first answer, then settle to 2 s. This single message is the Phase-1 poll, the Phase-2 subscription renewal (host TTL 6 s), and the resync anchor: any generation mismatch → host re-answers the full snapshot. Worst-case staleness after total loss = one renewal interval.

**Type 17 — `windowFeedSnapshot` (h→c), chunked:** `[u8 17][u32 generation][u8 chunkIndex][u8 chunkCount][u16 recordCountInChunk]` + records.
Record: `u32 windowID | u16 widthPt | u16 heightPt | u8 flags | u8 displayIndex | lp bundleID | lp appName | lp title`. Flags: bit0 onScreen, bit1 minimized, bit2 appHidden, bit3 frontmostApp, bit4 focusedWindow. No PID, no iconID, no x/y position (drags generate zero traffic; WindowGeometryWatcher owns drag geometry). Record order = host z-order front-to-back (free data, never a client sort key).
**Packing is byte-budgeted, not record-counted** (fixes the overflow flaw): greedy-pack until the next record would exceed 1195 − 9 header bytes; title hard-truncated at 120 UTF-8 bytes on a boundary host-side. Real records ≈ 88–168 B → 7–13 records/chunk → 64-record cap = 5–9 chunks. Cap stays 64 post-filter (typical desktop < 40; revisit only on evidence). Chunks **dup-sent ×2 ~25 ms apart** (bye/streamCadence pattern; converts P(loss) → P(loss)²). Client assembles per generation; chunks of one generation must agree on chunkCount or the generation is discarded (pinned decode rule); latest fully-assembled generation wins; a lost generation heals at the next renewal from the host's cached encoded chunks — no per-chunk re-request machinery.

**Type 18 — `windowFeedCurrent` (h→c), 5 B:** `[u8 18][u32 generation]` — explicit "you're current" ack so the client can distinguish no-change from loss. Quiet steady state = 5 B up + 5 B down per 2 s.

**Type 19 — `appIconRequest` (c→h):** `[u8 19][u16 sizePx][lp bundleID]`. Retransmit 500 ms / timeout 3 s.

**Type 20 — `blobChunk` (h→c), the ONE blob reply:** `[u8 20][u8 blobKind][u64 blobID][u16 metaA][u16 metaB][u8 chunkIndex][u8 chunkCount][u16 byteCount][bytes]` (18 B header → ≤1177 B/chunk). Kind 0 = app icon (blobID = FNV-1a64(bundleID), metaA = pxEdge, PNG, total cap 32 KB); kind 1 = window preview (blobID = u64(windowID), metaA/metaB = pxW/pxH, JPEG q0.6, cap 48 KB). One shared reassembler + one shared re-request discipline (missing chunks after 300 ms → re-request whole blob once; host caches encoded bytes and single-flights per blobID, so re-requests are free). PNG/JPEG magic validated on reassembly; malformed blobs discarded and never poison the disk cache.

**Type 21 — `windowPreviewRequest` (c→h):** `[u8 21][u32 windowID][u16 maxWidthPx]` (client asks 640 px = 320 pt @2x). Preview chunks paced 1 datagram/ms.

**Lane admission rule, stated once:** EVERY new c→h session-less request type (16, 19, 21) is added to `payloadIsListRequest` (`NWVideoMuxDatagramTransport.swift:437`) and the `UnboundLaneByePolicy` exemptions, each with a lane-policy test — a missed site = silent bye-storms. Phase 1 retires the feed lane after each answer (pure request/reply, zero structural mux change); Phase 2 registers it in a `WindowFeedSubscribers` table (TTL 6 s, renewal-refreshed, reaper-tested) instead of retiring — the one structural transport change, isolated to videohostd.

**Golden discipline per type:** enum case + encode/decode in `VideoControlCodec.swift`; `vc()` entries in `Sources/slopdesk-corevectors/main.swift`; `bash scripts/golden-check.sh` with no `SLOPDESK_*` env; surgical hand-merge into `golden/golden_vectors.json` (never `>`-redirect); pin move; inert-type lists in host `VideoSessionLogic.swift:200` + client `VideoClientSessionLogic.swift:178`; `docs/20-wire-protocol.md` §9.2 rows + the additive-messages sentence. All wire work for a phase lands in one commit; both machines redeploy together.

---

## 6. Host-side feed architecture

All in `slopdesk-videohostd` (GUI glue) + pure logic in `SlopDeskVideoHost` (headless-tested; hang-safety rule 6 — no SCK/VT in unit tests).

- **Source of truth:** ONE `CGWindowListCopyWindowInfo(.optionAll)` per tick (2.3–2.6 ms measured). `kCGWindowIsOnscreen` partitions visible/not; windows absent from onScreen get a cheap per-window `AXMinimized` read + `NSRunningApplication.isHidden` (only the handful that need it — budgeted, typically <10) to disambiguate minimized/hidden/other-Space best-effort. bundleID via `NSRunningApplication(pid)` cached per PID; frontmost via `NSWorkspace.frontmostApplication`. **`SCShareableContent` is never polled by the feed** — it stays hello/mint-only.
- **Cadence:** Phase 1 — snapshot built on demand per subscribe, behind a **1 s TTL encoded-snapshot cache** (renewal retransmits, re-requests, and multiple clients are answered from cache — closes the enumeration-amplification flaw; supersedes per-channel ListAnswerGuard for this path). Phase 2 — 1 Hz `DispatchSourceTimer` differ while ≥1 subscriber, **0 Hz with none**; `NSWorkspace` didLaunch/didTerminate/didActivate kicks debounced 150 ms; 4 Hz burst for 3 s after **structural** changes only (window add/remove/minimize).
- **Generation bump set:** window-id set, title (**debounced 1 s** — terminal title churn is this product's steady state, not a pathology), size, flags. Title-only and focus-only changes coalesce at ≥2 s / ≥1 s respectively and never enter burst mode. Snapshot pushes coalesced ≥250 ms apart.
- **Queue discipline (closes the input-latency flaw):** decode happens on the transport receive queue; ALL feed work — enumeration, diffing, icon render (39.6 ms cold each), JPEG encode, blob chunking — hops immediately to a dedicated low-QoS serial queue. Nothing feed-related ever executes on the transport receive queue or any queue `InputInjector` touches. Phase-5 AXObservers get their own thread with `AXUIElementSetMessagingTimeout(0.25 s)` (one beachballing Electron app must not hang anything).
- **Icons:** `NSRunningApplication.icon` → 64 px PNG once per bundleID, host LRU 64 entries, single-flight per blobID.
- **Previews (Phase 4):** `SCScreenshotManager` one-shot (18–40 ms warm, ~70 ms cold, assume 2× on a loaded host), single-flight per windowID, host reuses a ≤1 s-old capture, absolute cap 2 captures/s, **skipped while any live session is in a high-motion burst** (host knows per-session cadence). Entry gate, not post-ship verify: perfbench pin — 3 live streams + peek hammering at cap, SCStream frame-interval p99 delta < 2 ms vs baseline, else previews drop to 1/s or stream-idle-only.
- **Pure/testable split:** `WindowFeedSnapshotBuilder` + `WindowFeedDiffer` + extracted `pickerSummary` inclusion policy in `SlopDeskVideoHost` (SystemDialogDetector template), differential-tested against the picker path; subscriber-table TTL logic unit-tested; videohostd owns only glue.

---

## 7. Client architecture

**New files**
- `Sources/SlopDeskClientUI/Columns/HostWindowsColumn.swift` — the panel (`#if os(macOS)` mount).
- `Sources/SlopDeskClientUI/Rail/HostWindowRowsMemo.swift`, `HostWindowLiveRow` leaf, shared `HostWindowListView` (compiles for iOS; reused by picker surfaces in Phase 3).
- `Sources/SlopDeskWorkspaceCore/Video/HostWindowFeed.swift` — `@MainActor @Observable` store behind a new closure seam in `VideoWindowSeam.swift` (`HostWindowFeedSeam.shared`; nil ⇒ inert, headless builds pass; UI modules never import SlopDeskVideoClient).
- `Sources/SlopDeskVideoClient/WindowFeedClient.swift` — renewal loop, chunk/blob assembly (assembly + image decode on a utility actor; only finished `NSImage`s published to MainActor with a single bump counter).
- Host: `Sources/SlopDeskVideoHost/WindowFeed/…` (pure) + videohostd glue.

**Changed:** `SlopDeskSplitViewController.swift` (third item + `hostRailItem` + `applyCollapse` line), `WorkspaceRootView.swift` (`updateNSViewController` read + `wireChromeToggles`), `WorkspaceChromeState.swift`, `WorkspaceBindingRegistry.swift` (⌘⇧R), `PaletteDataSource.swift`, `OpenQuicklyModel.swift`, `SlopDeskClientApp.swift` (chromeOverhead), `Apps/Shared/AppMain.swift` (seam wiring), `VideoControlCodec.swift`, `NWVideoMuxDatagramTransport.swift` + `UnboundLaneByePolicy.swift`, both inert-type lists, corevectors, golden vectors, `StreamCadenceCodecTests`, `docs/20-wire-protocol.md`.

**Publication discipline (diff-before-publish, explicit):** `WindowFeedClient` diffs each assembled snapshot off the render path. The `@Observable` structural array mutates only on structural change (id-set/section membership); volatile per-window fields (title, dimensions, flags) live in per-field dictionaries mutated only for windows whose value changed; `frontmostWindowID` is its own property. An unchanged snapshot publishes nothing.

**Memo + identity plan (the 3-part rule, applied):**
- `HostWindowRowsMemo`: plain non-`@Observable` `@MainActor` class in `@State`; structural fingerprint = ordered `(windowID | bundleID | section)` + filter string. **Title, dimensions, and flags are excluded** — they are volatile at this feature's cadences.
- Leaves keyed `.id("windowID|bundleID")`. Inside `HostWindowLiveRow`'s body: title, dimensions (tooltip), focused-weight (from `feed.frontmostWindowID`), dim-state, streamed ordinal (O(1) lookup in the streamed-window `Set` recomputed once per tree change), hover, and keyboard cursor are ALL live-reads. Nothing volatile ever passes through an init param (ca429f90 rule).
- **Search filters against the snapshot copy held inside the memo class**, never live Observation reads — typing plus title ticks must not re-run the panel body.
- Feed injected ONLY into `HostWindowsColumn`'s NSHostingController and `OpenQuicklyModel` — ContentColumn/video panes register no dependency; a snapshot tick structurally cannot invalidate or remount a pane.
- **Lifecycle gating is explicit, not `.task`-based** (SwiftUI teardown across an AppKit collapse is not a contract): the renewal loop starts/stops observing `chrome.hostRailCollapsed` + `AppConnection.status` + OQ visibility, SystemDialogMonitor-style.

**Headless test pins (RailRowsMemoTests style):** buildCount unchanged across title-only ticks; buildCount unchanged while typing in search during title ticks; feed idles when collapsed or disconnected (the 200 GB wifi-flap lesson); streamed-set derivation across windowID recycling; sectioning/ordering stability; chunk-assembly fuzz (mixed generations, disagreeing chunkCounts, max-length records ≤ 1195 B); lane-policy test per new c→h type. `bash scripts/check-ios.sh` gates every phase.

---

## 8. Performance budget

| Dimension | Budget | Mechanism |
|---|---|---|
| Host CPU, panel collapsed everywhere | **0** | no subscribers → no timer, no enumeration |
| Host CPU, Phase 1 open | ≤0.15% core | 2.5 ms CGWindowList per 2 s renewal, 1 s snapshot cache absorbs retransmits + N clients |
| Host CPU, Phase 2 feed | ~0.25% idle, ≤1% burst | 1 Hz differ + 4 Hz×3 s structural bursts |
| Host icon/preview work | never on receive/input queues | dedicated low-QoS serial queue; icons ~40 ms cold ×1 per bundleID; previews single-flight, 2/s cap, motion-gated |
| Bandwidth, quiet steady state | ~5 B/s each way | subscribe 5 B / current-ack 5 B per 2 s |
| Bandwidth, per desktop change | ~12–21 KB | 5–9 chunks ×2 dup-send |
| Bandwidth, title-thrash worst | ≤~10 KB/s transient | 1 s host debounce + ≥2 s title-only coalesce |
| Cold connect | ~6 KB (+2–6 KB per host-fetched icon, once ever) | local icon resolution makes wire icons rare; disk cache LRU 5 MB |
| Peek | ≤48 KB per explicit gesture | paced 1 datagram/ms; single-flight; never eager |
| Media path | **0 bytes, 0 code changed** | control tag 0 only; perfbench entry gate for Phase 4 |
| Client render | body rebuild only on structural change; title tick = ≤64 cheap leaf re-renders; pane invalidation = impossible | memo fingerprint + live-leaf + injection scoping |
| Latency: new window visible | ≤2 s (P1) / 150–400 ms typical (P2) / ~2–4 s honest worst under loss | renewal anchor + dup-send |
| Latency: click → pane | one store call (unchanged from picker) | same path |
| Latency: peek image | 120–250 ms LAN, or nothing | fully-formed-only contract |

---

## 9. Phased implementation plan (each independently shippable)

**Phase 1 — the rail, complete and icon-anchored (smallest lovable).**
Wire types 16/17/18 (request/reply semantics; lane retired per answer — zero structural mux change) + golden/docs/pin/lane-policy work. Host: pure snapshot builder on CGWindowList + 1 s encoded cache + generation counter. Client: third split item + chrome flag + ⌘⇧R + palette row + cheat sheet + chromeOverhead; full panel UI (alphabetical sections, 16 pt local-resolved icons with glyph fallback, search, streamed ordinals, click/⏎/⌘⏎/context menu, keyboard nav, dimmed disconnect, empty states); **Open Quickly host-window rows**; `HostWindowFeed` + memo/identity discipline + the full headless test pin list; AppLaunchMonitor opportunistically reads the feed when fresh. Deploy both machines.

**Phase 2 — push.** Host-only: `WindowFeedSubscribers` (TTL 6 s, no retire, reaper-tested), 1 Hz differ + NSWorkspace kicks + burst/coalesce rules, snapshot push ×2 on generation bump. Client wire code unchanged (renewal already the anchor). AppLaunchMonitor fully re-pointed. Typical latency drops to ~150–400 ms.

**Phase 3 — host icon fetch + surface consolidation.** Types 19/20 (icons through the shared blob reassembler), disk cache (bundleID+px, LRU 5 MB, magic-validated). `RemoteWindowPickerModal` + in-pane picker re-skinned onto `HostWindowListView` — the scoped iOS story (rows inside existing surfaces; no iOS column).

**Phase 4 — peek.** Type 21 + preview blobs; Space/context-menu verb; OverlayHostView card, fully-formed-only; host motion-gating + caps; **perfbench frame-interval entry gate before ship**.

**Phase 5 — polish.** AXObserver kicks (own thread, 0.25 s timeout; 1 Hz differ remains the mandatory backstop — AX is flaky on Electron), refined minimized disambiguation, hover-dwell peek evaluated on hardware (shipped only if it earns it), width persistence, optional Open-in-Split context item via split-with-spec tree op.

---

## 10. Risks, test obligations, and what we deliberately did NOT include

**Risks (each with its containment):**
- **Feed-lane lifecycle (Phase 2)** is the one structural mux change — contained by TTL+renewal idempotency, subscriber-table unit tests, and shipping it a phase after the UI proves out on request/reply.
- **Golden hand-merge across 6 types** — all wire work per phase in one commit; never `>`-redirect; pin moves enumerated per phase.
- **Missed `payloadIsListRequest`/`UnboundLaneByePolicy` site** = silent bye-storms — rule stated once (every c→h session-less type: 16, 19, 21), lane-policy test per type.
- **Title churn** — triple-contained: 1 s host debounce + ≥2 s title-only coalesce; title out of fingerprint/identity; search over snapshot copies. Pinned by buildCount tests.
- **Peek vs SCStream contention** — entry-gated perfbench pin, motion-gating, 2/s cap, single-flight, loaded-host measurement before enabling.
- **Ornament creep** — every future PR against this panel diffs against "at-rest zero ornament"; the icon slot never animates while loading; any NEW/badge/dot proposal is pre-rejected.
- **`kCGWindowName` empty for some apps** — appName fallback in the row; if common, one coalesced on-demand SCShareableContent resolve, never a steady poll.
- **Icon staleness after app updates** — accepted (icons are near-static); salt the cache key with icon-file mtime only if it ever bites.
- **Raised-card semantics** and the `.medium` frontmost cue need a pixel check on the macbook (user tests manually; ship the fix, don't ask).

**Deliberately NOT included (and why the user's taste says so):**
- **Inline per-row thumbnails** — binding directive: illegible snapshots are noise; icons anchor, content only at legible peek size.
- **Spinners, skeletons, pulsing dots, pills, badges, "NEW" markers, always-on activity indicators** — all previously rejected as tacky; state rides existing vocabulary (weight, dimming, accent ordinal, fade-in).
- **Hostname header, second connection footer, per-row dimensions at rest, PID/position wire fields** — filler that doesn't earn pixels or golden-pinned bytes.
- **Z-order or recency sorting, focus-driven reordering** — restless chrome; stability is the feature.
- **Drag-to-create** (E21 WI-7), **Raise-on-Host** (needs new lane plumbing for a marginal verb), **host selector** (multi-host deferred), **system-dialog rows** (auto-managed), **sort/group/cadence settings knobs** (no knobs), **double-click semantics** (races single-click), **SwiftUI `.inspector`** (kills video panes), **zero-wire monogram phase** (violates the icon directive for zero benefit under co-deploy policy).
