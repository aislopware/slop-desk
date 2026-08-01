# CLAUDE.md

Non-derivable facts + traps only. Product/architecture: `README.md`, `docs/00-overview.md`, `docs/DECISIONS.md`. Re-scoping → `docs/DECISIONS.md` first. Wire contract: `docs/20-wire-protocol.md` — update it after wire changes.

SlopDesk = low-latency remote coding (macOS host, macOS/iOS clients). Native Swift owns the wire (codecs, FEC, controllers, terminal mux). Only C: `Sources/CSlopDeskSIMD` — one GF(2⁸) NEON kernel + scalar fallback; wrapping arithmetic (`&*`/`&+`) is intentional; `GF256NeonDifferentialTests` pins NEON ≡ scalar (re-run + loopback-validate after kernel/hash changes); frame hash is scalar Swift, not NEON.

## Gates — which one reaches which path

Clean checkout builds headless with no prerequisite: `swift build`/`swift test` never see libghostty / VideoToolbox / ScreenCaptureKit; libghostty only in Xcode app targets (`TerminalSurface` seam), built via `ThirdParty/ghostty/build-libghostty.sh` (Zig; never blocks headless core).

| Gate | When / what it uniquely covers |
|------|-------------------------------|
| `scripts/test-touched.sh` (`make test-touched`) | **Default inner-loop gate after Swift edits** — incremental build + only the test targets whose dependency closure reaches the changed files (~10-50s vs ~100s full `swift test --parallel`). Diffs against the last full-green tree, so scope grows until a full run resets it; Package.swift/golden/unattributable paths escalate to full; a partial green never warms the pre-push cache. Full suite (`make test`) before push / after big cross-cutting changes |
| `.build/release/slopdesk-loopback-validate` (`--smoke`/`--frames N`) | FEC / packetizer / reassembler changes — real VT encode→decode, no GUI |
| `scripts/check-ios.sh` | `#if os(iOS)` / UIKit changes — type-checks the iOS slice (`swift build` skips iOS); runs zero tests |
| `scripts/check-ios-tests.sh` | ONLY executor of iOS tests (host-less bundle, booted simulator, iOS triple). `swift test` compiles the **macOS** side of every `#if os(iOS)` fork — an iOS default asserted there is asserted about the wrong branch |
| `scripts/check-launch-restore.sh` | ONLY gate on the shipping launch path (`workspace.json` restore → offer → `connectIfSavedTarget()`). Every other GUI gate sets `SLOPDESK_AUTOCONNECT_*` → `hasAutomationEnvironment()` true → automation branch (persistence nil, layout replaced by one synthetic pane). Run after `WorkspaceStore` restore/autosave, `connectIfSavedTarget()`, or `runArmedLaunchAdoptIfPossible` changes |
| `scripts/herdr-sync.sh` | `SlopDeskAgentDetect` engine/manifest changes, or herdr upstream sync — builds the real herdr binary, diffs both engines on ~10k screens (`scripts/herdr-differential.py`); pin = `scripts/herdr.pin` |
| `scripts/check-macos.sh`, `check-video.sh` | GUI proof; needs unlocked Aqua + Screen Recording TCC (not over SSH). `check-video.sh --second-client` = ONLY gate with two `SCStream`s + two `VTCompressionSession`s on one capture target (unit tests may not build any of the four). Client B gets the TERMINAL autoconnect only, so it must learn the pane from the document; asserts A's decode counter still climbs after B joins (fan-out, not takeover); screenshots each instance raised by PID — a name-matched raise photographs one client twice |
| `scripts/check-multiclient.sh` | Workspace-document / intent / projection changes — two app instances on one hostd, real menu gesture on one, `slopdesk --socket` reads the other's projection; needs **Accessibility** TCC. Step 7b asserts PTY fan-out unconditionally — every pane in the final layout must take a second subscriber |
| `scripts/soak-fanout-laggard.sh` | Fan-out / subscriber-set / out-FIFO / queue-gate / ReplayBuffer-retention changes — real hostd + clients + PTY, laggard frozen with `SIGSTOP`. Asserts retention loses nothing, eviction takes the LAGGARD not the session, the fast member is never head-of-lined, a pane shrunk back to one member still backpressures the PTY. ~80 s, no GUI/TCC. Default `SLOPDESK_SUB_LAG_BYTES` = 4 MiB for speed; `33554432` soaks the shipped value |

## Invariants

- **Wire is golden-pinned.** Manual binary encode (no JSON/Codable on hot path); multi-byte ints big-endian; UUIDs 16 raw bytes. After wire changes: `bash scripts/golden-check.sh` → update `docs/20-wire-protocol.md`. **Never** `>`-redirect the generator over `golden/golden_vectors.json` — it emits a subset (13 frozen keys are XCTest-only); generate with **no** `SLOPDESK_*` env; intended format change = surgical hand-merge.
- **Bit-exact floats.** Keep `a * b + c` separate — never `addingProduct`/`fma`. `Double.maximum`/`Double.minimum` (NaN-faithful), not `<`/`>` ternaries. `==` only in test pins.
- **Untrusted UDP: validate-then-drop.** Decoders optional/throw; C bools as `byte != 0`.
- **FEC `m == 1` ≡ old XOR** (byte-identical). Keep when touching FEC.
- **Hang-safety:** never create `SCStream`, `VTCompressionSession`, `VTDecompressionSession`, or Metal device in unit tests. Video unit tests = pure `SlopDeskVideoProtocol` + controllers only.
- **No app-layer crypto/auth.** Security = WireGuard mesh; do not reintroduce pairing/tokens. Replay buffer = raw bytes.
- **Client-UI dimensions go through `Slate` tokens** (`SlopDeskClientUI/DesignSystem/SlateDesign.swift`). Raw `.font(.system(size: N))` / `cornerRadius: N` literals in `Sources/SlopDeskClientUI` fail the `check-ds-leaks.sh` ratchet in `make lint`.
- **No `.keyboardShortcut` in `WorkspaceCommands.swift`** — chord dispatch is owned by the `WorkspaceKeyDispatcher` NSEvent monitor (a menu shortcut double-fires and swallows prefix follow-up keys); ratchet: `check-menu-shortcutless.sh`.

## Three paths (do not merge)

Separate transport, message set, version (`1` only — no negotiation).

| Path | Notes that bite |
|------|-----------------|
| Terminal (TCP) | Dual `.data` + `.control`; `TCP_NODELAY` on **both**. ReplayBuffer 256 MiB cap, 64 MiB offline gate **pauses PTY drain**; queue gate 64 KiB attached (latency) ↔ 64 MiB detached (budget — agent keeps running while away). Real smoke: `SubprocessE2ETests` (in-memory loopback misses open-order races). |
| GUI video (UDP) | Media socket (1-byte channel tags; recovery has its own tag) + dedicated cursor socket. FEC via `FECScheme` (RS GF(2⁸)). |
| Inspector (TCP) | Read-only; client→host is only `subscribe(fromSeq:)`. |

## Env (`SLOPDESK_*`)

Not exhaustive — grep `SLOPDESK_`. **Default idiom:** `!= "0"` → default-ON; `== "1"` → default-OFF; check the call site.

| Flag | Notes |
|------|--------|
| `SLOPDESK_FEC_M` / `_FEC_K` | Set **identically** host + client |
| `SLOPDESK_VIDEO_DEBUG` | Video stderr |
| `SLOPDESK_DISPLAY_CAPTURE` | `window` / `display` / `include` |
| `SLOPDESK_PACER` | default present-on-arrival; `=deadline` for smoothness pacer |
| `SLOPDESK_AUDIO` | host app-audio stream gate (default-ON); `_CODEC=pcm` bypasses AAC-ELD |
| `SLOPDESK_SUB_LAG_BYTES` | laggard-eviction threshold, default **32 MiB** — deliberately BELOW the 64 MiB offline gate. TUNING, not a toggle. A lone subscriber is never evicted because eviction needs two or more members |
| `SLOPDESK_WORKSPACE_STATE_DIR` | relocates `workspace-state.json`. EVERY `HostServer` builds a `HostWorkspaceStore` — a test that calls `start()` must set this or inject `workspaceStore:`, or it reads/overwrites the developer's real workspace |

## Traps

- prek fails on partial pathspec commits — commit related files together
- `pkill` can leave host on port — check orphans before loopback tests
- No contiguous secret literals in fixtures (GitHub push protection) — assemble at runtime
- **Multi-client sync has NO toggle** — workspace document and PTY fan-out are both unconditional (tmux/zellij semantics). Do not reintroduce `SLOPDESK_WORKSPACE_DOC` / `SLOPDESK_PANE_FANOUT`; a host that refuses `channelClass 1` gives a client a blank window with no error
- VT HEVC: no `max_ref_frames=1` (all-IDR); no `UsingHardware…` query under low-latency RC (`-12900`); no Lossless key; `DataRateLimits` = bitrate/8
