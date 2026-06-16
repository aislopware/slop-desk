# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Aislopdesk is a terminal-first, low-latency remote-coding tool for Apple platforms (macOS host + macOS/iOS clients). The performance-critical algorithms live in a **Rust core** behind a C-ABI; the **Swift/SwiftUI apps are the platform shell**. Read `README.md` for the product/architecture overview and `docs/00-overview.md` + `docs/DECISIONS.md` for the binding design decisions. This file covers what isn't obvious from those: build ordering, conventions you must respect when changing code, and the traps.

## Layout in one breath

- **`rust/`** — a separate Cargo workspace (NOT part of `Package.swift`), two crates:
  - `aislopdesk-core` — pure, zero-dependency, `#![forbid(unsafe_code)]`. The **single source of truth** for every wire codec (terminal + video), FEC + frame reassembly, the realtime controllers, coordinate mapping, and the terminal/PTY protocol (incl. the SSH-style channel mux).
  - `aislopdesk-ffi` — the **only** crate allowed `unsafe`. A thin C-ABI shim over the core; emits `libaislopdesk_ffi.a`. ALL raw-pointer/heap primitives are isolated to `src/raw.rs`; aarch64 NEON kernels (`gf_neon.rs`, `frame_hash.rs`) live here too.
- **`Sources/`, `Tests/`, `Apps/`** — the SwiftPM package (`Package.swift`). Swift codec bodies are one-line delegations into the Rust core via `CAislopdeskFFI` (the C shim target that links the staticlib).
- **`docs/`** — design docs; `DECISIONS.md` is the decision log, `20-wire-protocol.md` is the wire contract.

## Build, test, lint

**Build ordering is mandatory: the Rust FFI staticlib must exist before `swift build`** (the `CAislopdeskFFI` target links `rust/target/release/libaislopdesk_ffi.a` via `-L/-l` unsafeFlags). A clean checkout fails to link until you build it.

```sh
bash rust/build-apple.sh   # build libaislopdesk_ffi.a (macOS arm64), REGENERATE the C header via cbindgen (Rust = SoT) + sync into Sources/CAislopdeskFFI; pass --ios for device+sim slices
swift build                # headless build (12 libs + 7 execs); never sees libghostty/VideoToolbox/ScreenCaptureKit
swift test                 # headless Swift suite (~2200 tests)
cd rust && cargo test --workspace   # Rust unit + golden-parity tests

make check                 # the full local gate = lint + build (rust ffi then swift) + test
make lint                  # exactly what CI gates on (see below)
make fmt / make fix        # format all 4 langs / format + safe lint autofixes
make install-tools         # brew + cargo install the pinned toolchain + prek git hooks
```

Run a **single test**:

```sh
swift test --filter StreamCadenceClientTests          # Swift: regex over <Target>.<Class>/<method>; class OR method name both work
cd rust && cargo test -p aislopdesk-core spike_past_threshold_is_late   # Rust: -p <crate> <fn-substring>; crates are aislopdesk-core, aislopdesk-ffi only
```

**Headless HW video validation** — the only way to prove the video FEC/wire path with **real VideoToolbox**, no GUI/TCC. Build `-c release`, then `.build/release/aislopdesk-loopback-validate` drives synthetic frames → real VT HEVC encode → packetizer/FEC → deterministic loss → reassembler (FEC recovery) → real VT decode, plus the controllers. `--smoke` = quick 10-frame liveness; `--frames N` overrides count (default 120). Runs from a normal shell (VT hangs only inside xctest). **Re-run after any change to the FEC/packetizer/reassembler in `aislopdesk-core`.**

**CI** (`.github/workflows/ci.yml`) runs four jobs: `rust` (fmt/clippy `-D warnings`/test/`cargo deny`/`cargo machete`), `shell-python` (shellcheck/shfmt/ruff), `swift-lint` (SwiftFormat + SwiftLint `--strict`, no compile). The `swift-build-test` job needs Xcode 26.5+ which hosted runners lack, so **`swift build`/`swift test` is effectively NOT enforced by hosted CI** — you must run `make check` locally. The lint jobs DO gate merges.

### Things `swift build`/`swift test` do not cover

- **iOS code rots silently.** `swift build` on macOS compiles only the macOS slice and never type-checks `#if os(iOS)` sources. Run `bash scripts/check-ios.sh` (xcodebuild against the iOS Simulator) after touching iOS UIKit code.
- **GUI/runtime proof** is via `scripts/check-macos.sh` (PATH 1), `check-video.sh` (PATH 2 video), `check-system-dialog.sh`. These build the app with xcodegen+xcodebuild, run real daemons, and screenshot. They require a **real, unlocked GUI (Aqua) login session with Screen-Recording TCC** — they hang/get 0 frames over SSH or while locked. Driven by `AISLOPDESK_AUTOCONNECT_*` / `AISLOPDESK_VIDEO_AUTOCONNECT_*` env seams (keep those names stable).

## Core conventions (respect these when changing code)

1. **Rust core is the source of truth; Swift tracks it, never the reverse.** There are no native Swift wire codecs and no fallback path — Swift codec bodies delegate to Rust. Agreement is *proven*, not assumed, by the `golden_parity` test. When you change anything on the wire:
   - Edit the algorithm in `aislopdesk-core` (+ the FFI shim if the signature changes).
   - Regenerate the golden corpus from the **real Swift codecs**, with **NO `AISLOPDESK_*` env set** (the controllers must resolve their compile-time-const defaults):
     ```sh
     swift run aislopdesk-corevectors > rust/aislopdesk-core/tests/vectors/golden_vectors.json
     ```
   - Update `docs/20-wire-protocol.md`. Hot path stays **manual binary encoding** (never JSON/Codable); all multi-byte ints **big-endian**; UUIDs are 16 raw bytes.

2. **Float math in controllers/codecs must stay written as separate `mul`+`add`** — never let clippy or a refactor rewrite it to `a.mul_add(b, c)` (FMA keeps extra precision → low bits diverge → breaks bit-exact golden parity). The nursery `suboptimal_flops` lint is allow-listed for exactly this reason. Library code uses only ordered float comparisons; `==` only in test pins.

3. **All `unsafe` stays in `aislopdesk-ffi`, and all raw-pointer primitives in `src/raw.rs`.** To add an FFI function: write a **safe-bodied** `extern "C"` shim (null/length-check pointers in safe Rust first, return `AISD_ERR_NULL` rather than deref a null), reach genuinely-unsafe work only through the `raw.rs` primitives with a `// SAFETY:` comment, then **regenerate the header** (`bash rust/build-apple.sh`) and update `tests/smoke.c` + `tests/ffi_boundary.rs`. The C header `aislopdesk-ffi/include/aislopdesk_ffi.h` is **GENERATED by cbindgen** from the `#[repr(C)]`/`extern "C"` surface (Rust = SoT) and **must NOT be hand-edited** — a CI drift-gate (`make check`'s `check-ffi-header` + the `rust` CI job) regenerates and `cmp`s, failing on any diff. Keep per-field rationale as Rust `///` docs so it round-trips into the header (cbindgen config in `aislopdesk-ffi/cbindgen.toml`; pinned build/dev tool, ships nothing in the staticlib). `tests/smoke.c` + `tests/ffi_boundary.rs` remain the **runtime** ABI proof (header-correctness ≠ ABI-correctness). `build-apple.sh` keeps the SwiftPM copy byte-identical. → [DECISIONS.md: Rust core / FFI boundary]

4. **Memory ownership across the C-ABI: Rust allocates, Rust frees.** Any `AisdBytes`/`AisdBytesArray`/`AisdWireMessage` *returned* to the caller must be released with `aisd_*_free` (never C `free()`); buffers passed *in* are borrowed for the call only (`cap == 0`). Swift wrappers `defer { aisd_bytes_free(out) }` after copying into `Data`. Decoders overwrite `*out` without freeing prior contents — free reused storage first.

5. **C-struct booleans are `u8` read as `!= 0`, never Rust `bool`** — a Rust `bool` is validity-UB for any byte ≠ {0,1}, but a JNI `jboolean`/C `int` may carry 2. (Release is `panic = "abort"`, so the core must never panic on untrusted UDP input — every decoder returns `Result` and drops a corrupt datagram.)

6. **Hang-safety rule: never instantiate an `SCStream`, `VTCompressionSession`, `VTDecompressionSession`, or Metal device in a test.** `AislopdeskVideoHost`/`AislopdeskVideoClient` are compiled + code-reviewed only; they hang without a window-server + TCC session. Only the pure `AislopdeskVideoProtocol` (and the controllers) are unit-tested for the video path.

7. **Headless-first.** The whole PATH 1 byte pipeline and PATH 2 video *logic* must build/test with no GUI, no libghostty, no VideoToolbox/ScreenCaptureKit/Metal. The renderer (libghostty / `CGhostty`) sits behind the `TerminalSurface` seam (`AislopdeskTerminal`) and `TerminalRenderingView`/`TerminalRendererFactory` (`AislopdeskClientUI`); it's compiled only inside the Xcode app target. Headless builds render `BuildStatusPlaceholderView` instead.

8. **No app-layer crypto/auth, by design** (see README for the rationale). Do not reintroduce crypto/pairing/tokens — the security boundary is the trusted WireGuard mesh, not the app. The replay buffer stores raw bytes.

9. **When re-scoping a decision, update `docs/DECISIONS.md` first**, then the detailed docs. Commit each green layer atomically; only commit/push when asked, and branch first if on the default branch (remote: `origin git@github.com:aislopware/aislopdesk.git`).

## The three data paths — README has the overview; these are the non-obvious deltas

The terminal (TCP), GUI-video (UDP), and read-only inspector (2nd TCP) paths **share nothing** — separate transport, message set, and version constants; no shared `WireMessage`/`FrameDecoder`. What bites:

- **Terminal:** two TCP conns per session (`.data` vs `.control`) so an output burst can't head-of-line-block a resize-ack. `TCP_NODELAY` must be set on **both** sockets in `AislopdeskTransport` or Nagle adds ~200ms/keystroke. The `ReplayBuffer` (lossless reconnect) has a 64 MiB ceiling and a 4 MiB offline gate that **pauses the PTY drain** rather than dropping un-acked data.
- **GUI video:** two UDP sockets — a `media` socket muxes 6 logical channels by a 1-byte tag (recovery has its OWN tag, never input — the type bytes alias otherwise); a dedicated `cursor` socket carries bare bytes so pointer latency = RTT. FEC sits behind a `FECScheme` (RS over GF(2^8); `m=1` wire-identical to the old XOR).
- **No version negotiation** on either path: the host accepts only version `1`, else rejects. The inspector is read-only by construction (only client→host msg is `subscribe(fromSeq:)`).
- **Terminal real-binary smoke:** `SubprocessE2ETests` launches the shipped `aislopdesk-hostd`+`aislopdesk-client` over an ephemeral socket and pipes `echo` through. In-memory loopback tests install handlers before driving the connection and so MISS real-socket open-ordering races (see `docs/25`) — keep/extend it when touching transport/mux.

## Runtime env flags

Behavior is tuned by dozens of `AISLOPDESK_*` env vars read at well-known sites (grep `AISLOPDESK_` for the full set). **Watch the default idiom**: `env[x] != "0"` means *default-ON* (only `"0"` disables) while `env[x] == "1"` means *default-OFF* (only `"1"` enables) — check the exact comparison at the defining site. Most relevant:

| Flag | Default | Effect |
|------|---------|--------|
| `AISLOPDESK_FEC_M` / `_FEC_K` | `1` / `defaultK` | RS parity count / group size. `m≥2` activates multi-loss RS. Resolved at ONE shared site → **set identically on host and client** or they disagree. |
| `AISLOPDESK_VIDEO_DEBUG` | off | stderr diagnostics across the whole video pipeline. |
| `AISLOPDESK_DISPLAY_CAPTURE` | auto | Force SCStream filter: `window` / `display` (excluding) / `include` (displayIncluding, the VD-park default). |
| `AISLOPDESK_SYSTEM_DIALOG_PANES` | on (Settings) | Auto-spawn a pane for system password dialogs. THREE states: unset/on, `0` off, `force` bypasses the toggle (use for E2E). |
| `AISLOPDESK_PACER` | `deadline` | Presentation pacer; any other value → present-on-arrival. Setting `AISLOPDESK_PLAYOUT_MS` (even to its default) flips client out of adaptive playout. |

**`AISLOPDESK_RUST_VIDEO_PATH` does NOT exist** — the planned Stage2-5 video-path gate never landed; the codecs/FEC/packetizer that moved to Rust are routed through FFI unconditionally. Don't document or rely on it.

## Traps

- **prek/pre-commit falsely fails on partial-pathspec commits** (e.g. a duplicated mod file mid-split) — commit all related changes at once.
- **`git checkout -- file` / `git stash` nuke uncommitted work.** Revert a single bad line with a targeted `Edit`, never a loose `perl -0pi` regex (it has clobbered the wrong line before).
- **`pkill` leaves a stale host on the port.** Confirm no orphaned `aislopdesk-hostd`/`-client`/`xctest` before re-running loopback tests.
- **GitHub push-protection rejects contiguous secret-token literals** in test fixtures — assemble such fixtures at runtime.
- **libghostty xcframework** (`ThirdParty/ghostty/build-libghostty.sh`) is the one fragile, Zig-dependent step — on a macOS-26.5/Xcode-26.5 host it needs an `xcrun` SDK-shim + `ar`/libtool assembly to dodge the Zig↔SDK incompatibility (see the script's caveats), but the recipe is **proven and produces the xcframework** (macOS + iOS). It never blocks the headless core.
- **Test-first discipline:** every fix needs a test proven to FAIL on the un-fixed code (revert-to-confirm-fail); avoid tautological tests that assert against the output's own derivation.
- **VideoToolbox HEVC gotchas:** don't set `max_ref_frames=1` (H.264 trap → all-IDR); don't query `UsingHardwareAcceleratedVideoEncoder` under low-latency RC (`-12900`); there is no Lossless VT key; `DataRateLimits` cap is bitrate/8.
