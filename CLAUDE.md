# CLAUDE.md

Agent guidance for this repo. Product/architecture: `README.md`, `docs/00-overview.md`, `docs/DECISIONS.md`. This file is **conventions + traps only**.

SlopDesk = low-latency remote coding (macOS host, macOS/iOS clients). **Native Swift** owns the wire (codecs, FEC, controllers, terminal mux). Only C: `Sources/CSlopDeskSIMD` (one GF(2⁸) NEON kernel + scalar fallback).

## Layout

- `Sources/`, `Tests/`, `Apps/` — SwiftPM package (`Package.swift`)
- `Sources/CSlopDeskSIMD` — only non-Swift; differential tests pin NEON ≡ scalar (`GF256NeonDifferentialTests`). Frame hash is scalar Swift (not NEON).
- `docs/` — design; `DECISIONS.md` first when re-scoping; wire contract = `docs/20-wire-protocol.md`

## Build / test

```sh
swift build
swift test
bash scripts/golden-check.sh
make check                 # lint + build + test + golden
make lint / make fmt / make fix
swift test --filter ClassNameOrMethod
```

Clean checkout builds with no prerequisite (no Rust/FFI). Headless `swift build`/`swift test` never see libghostty / VideoToolbox / ScreenCaptureKit.

| Extra | When |
|-------|------|
| `.build/release/slopdesk-loopback-validate` (`--smoke` / `--frames N`) | After FEC / packetizer / reassembler changes — real VT encode→decode, no GUI |
| `bash scripts/check-ios.sh` | After `#if os(iOS)` / UIKit changes — TYPE-CHECKS the iOS slice (`swift build` skips iOS). Runs **zero** tests |
| `bash scripts/check-ios-tests.sh` | The ONLY thing that EXECUTES an iOS test — `Apps/ClientApp-iOS/Tests` as a host-less bundle in a booted simulator, on the iOS triple. `swift test` compiles the **macOS** side of every `#if os(iOS)` fork, so an iOS default asserted there is asserted about the wrong branch. Run it after touching anything forked on platform |
| `bash scripts/check-launch-restore.sh` | The ONLY gate that reaches the SHIPPING launch path — restore `workspace.json` → offer it → `connectIfSavedTarget()`. Every other GUI gate sets `SLOPDESK_AUTOCONNECT_*`, so `hasAutomationEnvironment()` is true and the app takes the automation branch instead (persistence nil, the layout replaced by one synthetic pane). Run it after `WorkspaceStore` restore / autosave, `connectIfSavedTarget()`, or `runArmedLaunchAdoptIfPossible` changes |
| `bash scripts/herdr-sync.sh` | After `SlopDeskAgentDetect` engine/manifest changes, or to sync herdr upstream — builds the REAL herdr binary and diffs both engines on ~10k screens (`scripts/herdr-differential.py`); pin = `scripts/herdr.pin` |
| `scripts/check-macos.sh`, `check-video.sh` | GUI proof; needs unlocked Aqua + Screen Recording TCC (not over SSH) |
| `scripts/check-multiclient.sh` | After workspace-document / intent / projection changes — TWO app instances on one hostd, a real menu gesture on one, `slopdesk --socket` reads the OTHER's projection. Also needs **Accessibility** TCC (it drives a menu). Step 7b asserts the PTY fan-out unconditionally — every pane in the final layout must take a second subscriber |
| `bash scripts/soak-fanout-laggard.sh` | After fan-out / subscriber-set / out-FIFO / queue-gate / ReplayBuffer-retention changes — real hostd + clients + PTY, laggard frozen with `SIGSTOP`. Asserts retention loses nothing, eviction takes the LAGGARD not the session, the fast member is never head-of-lined, and a pane that shrank back to one member still backpressures the PTY. ~80 s, no GUI/TCC. `SLOPDESK_SUB_LAG_BYTES` picks the threshold (default 4 MiB for speed; set `33554432` to soak the shipped one) |

**CI:** lint jobs gate merges. Hosted runners lack Xcode 26.5 → `swift build`/`swift test`/golden are **not** enforced on CI — run `make check` locally.

## Conventions

1. **Wire is golden-pinned.** Manual binary encode (no JSON/Codable on hot path); multi-byte ints big-endian; UUIDs 16 raw bytes. After wire changes: edit Swift → `bash scripts/golden-check.sh` → update `docs/20-wire-protocol.md`. **Never** `>`-redirect the generator over `golden/golden_vectors.json` (emits a subset; 13 frozen keys are XCTest-only). Generate with **no** `SLOPDESK_*` env. Intended format change = surgical hand-merge.

2. **Bit-exact floats.** Keep `a * b + c` separate — never `addingProduct` / `fma`. Use `Double.maximum` / `Double.minimum` (NaN-faithful), not `<`/`>` ternaries. `==` only in test pins.

3. **Untrusted UDP: validate-then-drop.** Decoders optional/throw; never force-unwrap attacker input; check lengths before allocate; C bools as `byte != 0`.

4. **Only C = `CSlopDeskSIMD`.** Wrapping arithmetic (`&*` / `&+`) is intentional. Re-run differential tests + loopback-validate after kernel/hash changes.

5. **FEC `m == 1` ≡ old XOR** (byte-identical). Keep when touching FEC.

6. **Hang-safety:** never create `SCStream`, `VTCompressionSession`, `VTDecompressionSession`, or Metal device in unit tests. Video unit tests = pure `SlopDeskVideoProtocol` + controllers only.

7. **Headless-first.** PATH 1 + video *logic* build without GUI/libghostty/VT. libghostty only in Xcode app targets (`TerminalSurface` seam).

8. **No app-layer crypto/auth.** Security = WireGuard mesh. Do not reintroduce pairing/tokens. Replay buffer = raw bytes.

9. **Re-scope → `docs/DECISIONS.md` first.** Commit only when asked; branch first if on default branch (`origin git@github.com:aislopware/slop-desk.git`).

## Three paths (do not merge)

Separate transport, message set, version (`1` only — no negotiation).

| Path | Notes that bite |
|------|-----------------|
| Terminal (TCP) | Dual `.data` + `.control`; `TCP_NODELAY` on **both**. ReplayBuffer 256 MiB cap, 64 MiB offline gate **pauses PTY drain**; queue gate 64 KiB attached (latency) ↔ 64 MiB detached (budget — agent keeps running while away). Real smoke: `SubprocessE2ETests` (in-memory loopback misses open-order races). |
| GUI video (UDP) | Media socket (1-byte channel tags; recovery has its own tag) + dedicated cursor socket. FEC via `FECScheme` (RS GF(2⁸)). |
| Inspector (TCP) | Read-only; client→host is only `subscribe(fromSeq:)`. |

## Env (`SLOPDESK_*`)

Grep `SLOPDESK_` for the full set. **Default idiom:** `!= "0"` → default-ON; `== "1"` → default-OFF. Check the call site.

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
- Prefer targeted edits over `git checkout`/`stash`/`perl -0pi` (easy to clobber)
- `pkill` can leave host on port — check orphans before loopback tests
- No contiguous secret literals in fixtures (GitHub push protection) — assemble at runtime
- libghostty xcframework: `ThirdParty/ghostty/build-libghostty.sh` (Zig; never blocks headless core)
- Test-first: prove fail before fix; no tautological asserts
- **Multi-client sync has NO toggle** — workspace document and PTY fan-out are both unconditional (tmux/zellij semantics). Do not reintroduce `SLOPDESK_WORKSPACE_DOC` / `SLOPDESK_PANE_FANOUT`; a host that refuses `channelClass 1` gives a client a blank window with no error
- VT HEVC: no `max_ref_frames=1` (all-IDR); no `UsingHardware…` query under low-latency RC (`-12900`); no Lossless key; `DataRateLimits` = bitrate/8
