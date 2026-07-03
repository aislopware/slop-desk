# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Aislopdesk is a terminal-first, low-latency remote-coding tool for Apple platforms (macOS host + macOS/iOS clients). It is a **single-language native Swift** package — the performance-critical algorithms (wire codecs, FEC, realtime controllers, terminal mux) are written in Swift and are the single source of truth. Read `README.md` for the product/architecture overview and `docs/00-overview.md` + `docs/DECISIONS.md` for the binding design decisions. This file covers what isn't obvious from those: the conventions you must respect when changing code, and the traps.

## Layout in one breath

- **`Sources/`, `Tests/`, `Apps/`** — the SwiftPM package (`Package.swift`). All the wire codecs, FEC + frame reassembly, the realtime controllers, coordinate mapping, and the terminal/PTY protocol (incl. the SSH-style channel mux) are native Swift here; there is no other language and no FFI boundary.
- **`Sources/CAislopdeskSIMD`** — the **only** C/`unsafe` in the tree: ONE aarch64 NEON kernel compiled from source as a SwiftPM C target — GF(2⁸) region multiply (FEC), `#if defined(__aarch64__)` NEON with a scalar fallback otherwise, pinned bit-for-bit by `GF256NeonDifferentialTests`. Frame hashing is **pure scalar Swift**: xxHash64 is 64-bit-multiply-heavy and NEON has no native 64-bit lane multiply, so on Apple Silicon the native scalar multiply beats a synthesized-NEON fold ~3.4× (measured); pinned by `FrameHashNeonDifferentialTests`. GF stays NEON because byte-table `vqtbl1q_u8` lookup IS NEON-friendly.
- **`docs/`** — design docs; `DECISIONS.md` is the decision log, `20-wire-protocol.md` is the wire contract.

## Build, test, lint

**A clean checkout builds with no prerequisite** — `swift build` compiles the whole package straight away (the only C is the in-tree `CAislopdeskSIMD` target, built from source by SwiftPM; there is no staticlib to pre-build, no FFI, no build ordering).

```sh
swift build                # headless build (libs + execs); never sees libghostty/VideoToolbox/ScreenCaptureKit
swift test                 # headless Swift suite (~2300 tests)
bash scripts/golden-check.sh   # regenerate the emitted golden subset from aislopdesk-corevectors + diff vs the corpus

make check                 # the full local gate = lint + build + test + golden
make golden                # just the golden-corpus check (scripts/golden-check.sh)
make lint                  # exactly what CI gates on (see below)
make fmt / make fix        # format all langs / format + safe lint autofixes
make install-tools         # brew-install the pinned toolchain + prek git hooks
```

Run a **single test**:

```sh
swift test --filter StreamCadenceClientTests          # regex over <Target>.<Class>/<method>; class OR method name both work
```

**Headless HW video validation** — the only way to prove the video FEC/wire path with **real VideoToolbox**, no GUI/TCC. Build `-c release`, then `.build/release/aislopdesk-loopback-validate` drives synthetic frames → real VT HEVC encode → packetizer/FEC → deterministic loss → reassembler (FEC recovery) → real VT decode, plus the controllers. `--smoke` = quick 10-frame liveness; `--frames N` overrides count (default 120). Runs from a normal shell (VT hangs only inside xctest). **Re-run after any change to the FEC/packetizer/reassembler.**

**CI** (`.github/workflows/ci.yml`) runs three jobs: `shell-python` (shellcheck/shfmt/ruff), `swift-lint` (SwiftFormat + SwiftLint `--strict`, no compile), and `swift-build-test` (`swift build`/`swift test` + the golden-corpus check). The `swift-build-test` job needs Xcode 26.5+ which hosted runners lack, so **`swift build`/`swift test`/golden is effectively NOT enforced by hosted CI** — you must run `make check` locally. The lint jobs DO gate merges.

### Things `swift build`/`swift test` do not cover

- **iOS code rots silently.** `swift build` on macOS compiles only the macOS slice and never type-checks `#if os(iOS)` sources. Run `bash scripts/check-ios.sh` (xcodebuild against the iOS Simulator) after touching iOS UIKit code.
- **GUI/runtime proof** is via `scripts/check-macos.sh` (PATH 1), `check-video.sh` (PATH 2 video), `check-system-dialog.sh`. These build the app with xcodegen+xcodebuild, run real daemons, and screenshot. They require a **real, unlocked GUI (Aqua) login session with Screen-Recording TCC** — they hang/get 0 frames over SSH or while locked. Driven by `AISLOPDESK_AUTOCONNECT_*` / `AISLOPDESK_VIDEO_AUTOCONNECT_*` env seams (keep those names stable).

## Core conventions (respect these when changing code)

1. **Swift is the single source of truth for the wire; the corpus proves bit-exactness.** The codecs are native Swift — there is no second implementation to keep in sync, but the wire is still **frozen by a golden corpus** so a refactor can't silently shift a byte. When you change anything on the wire:
   - Edit the algorithm in the relevant Swift module.
   - Re-run the golden check, **NEVER** redirecting the generator over the corpus file — `swift run aislopdesk-corevectors` emits only a **subset** and would drop the 13 frozen keys (geometry/VD/etc.) that are XCTest-pinned, not regenerated:
     ```sh
     swift run aislopdesk-corevectors      # inspect the emitted subset (stdout)
     bash scripts/golden-check.sh          # regenerate that subset + diff vs golden/golden_vectors.json (43 keys)
     ```
     Generate with **NO `AISLOPDESK_*` env set** (the controllers must resolve their compile-time-const defaults). If a wire-format change is intended, hand-edit `golden/golden_vectors.json` surgically (or merge the regenerated subset) so the 13 frozen keys survive.
   - Update `docs/20-wire-protocol.md`. Hot path stays **manual binary encoding** (never JSON/Codable); all multi-byte ints **big-endian**; UUIDs are 16 raw bytes.

2. **Bit-exact float math: keep separate `*`+`+`, never fuse.** Never let a refactor rewrite `a * b + c` to `a.addingProduct(b, c)` / `fma` (FMA keeps extra precision → low bits diverge → breaks the golden corpus). Use NaN-faithful ordered min/max — `Double.maximum` / `Double.minimum` (or an explicit ordered comparison), **not** a bare `<`/`>` ternary, which has the wrong NaN behaviour. Library code uses only ordered float comparisons; `==` only in test pins. SwiftLint carries the convention (the rule that flags `addingProduct`/`fma` in codec/controller code replaces the old Rust `forbid(unsafe_code)` / `suboptimal_flops` gates).

3. **Validate-then-drop on untrusted UDP — never crash on a hostile datagram.** Every decoder returns an optional / throws and **drops** a corrupt or short datagram; validate declared counts/lengths **before** allocating, and never force-unwrap (`!`) or trap on attacker-controlled input. Read C-struct / interop booleans as `byte != 0`, never assume `{0,1}`. (The video path is built to tolerate loss — a dropped datagram is the normal case, not a fault.)

4. **The only C/`unsafe` is `Sources/CAislopdeskSIMD`.** ONE NEON kernel (GF(2⁸) region multiply), `#if defined(__aarch64__)` NEON else scalar; frame hashing is scalar Swift (faster than synthesized-NEON xxHash64 on Apple Silicon — see Layout above). The hash/SIMD cluster uses **integer-wrapping arithmetic** (`&*` / `&+` / `&<<`) deliberately — that's the algorithm, not an oversight; don't "fix" it to checked ops. Any change to the kernel or the scalar hash must stay bit-identical to the Swift scalar path, proven by `GF256NeonDifferentialTests` + `FrameHashNeonDifferentialTests` (re-run them, and the HW loopback-validate, after touching either).

5. **FEC `m == 1` is byte-identical to the old XOR scheme.** The Reed–Solomon codec (`FECScheme`, RS over GF(2⁸)) degenerates to plain XOR parity at `m == 1`; that equivalence is load-bearing and pinned — keep it when touching FEC.

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
| `AISLOPDESK_PACER` | present-on-arrival | Presentation pacer. Absent (or any value ≠ `deadline`) → present-on-arrival (the 2026 latency-first default, no playout hold); `=deadline` restores the smoothness-tuned deadline pacer. Setting `AISLOPDESK_PLAYOUT_MS` (even to its default) flips client out of adaptive playout. |

## Traps

- **prek/pre-commit falsely fails on partial-pathspec commits** (e.g. a duplicated mod file mid-split) — commit all related changes at once.
- **`git checkout -- file` / `git stash` nuke uncommitted work.** Revert a single bad line with a targeted `Edit`, never a loose `perl -0pi` regex (it has clobbered the wrong line before).
- **`pkill` leaves a stale host on the port.** Confirm no orphaned `aislopdesk-hostd`/`-client`/`xctest` before re-running loopback tests.
- **GitHub push-protection rejects contiguous secret-token literals** in test fixtures — assemble such fixtures at runtime.
- **libghostty xcframework** (`ThirdParty/ghostty/build-libghostty.sh`) is the one fragile, Zig-dependent step — on a macOS-26.5/Xcode-26.5 host it needs an `xcrun` SDK-shim + `ar`/libtool assembly to dodge the Zig↔SDK incompatibility (see the script's caveats), but the recipe is **proven and produces the xcframework** (macOS + iOS). It never blocks the headless core.
- **Test-first discipline:** every fix needs a test proven to FAIL on the un-fixed code (revert-to-confirm-fail); avoid tautological tests that assert against the output's own derivation.
- **VideoToolbox HEVC gotchas:** don't set `max_ref_frames=1` (H.264 trap → all-IDR); don't query `UsingHardwareAcceleratedVideoEncoder` under low-latency RC (`-12900`); there is no Lossless VT key; `DataRateLimits` cap is bitrate/8.
