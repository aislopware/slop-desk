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
| `bash scripts/check-ios.sh` | After `#if os(iOS)` / UIKit changes (`swift build` skips iOS) |
| `scripts/check-macos.sh`, `check-video.sh` | GUI proof; needs unlocked Aqua + Screen Recording TCC (not over SSH) |

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
| `SLOPDESK_SYSTEM_DIALOG_PANES` | unset/on · `0` off · `force` for E2E |
| `SLOPDESK_PACER` | default present-on-arrival; `=deadline` for smoothness pacer |
| `SLOPDESK_AUDIO` | host app-audio stream gate (default-ON); `_CODEC=pcm` bypasses AAC-ELD |

## Traps

- prek fails on partial pathspec commits — commit related files together
- Prefer targeted edits over `git checkout`/`stash`/`perl -0pi` (easy to clobber)
- `pkill` can leave host on port — check orphans before loopback tests
- No contiguous secret literals in fixtures (GitHub push protection) — assemble at runtime
- libghostty xcframework: `ThirdParty/ghostty/build-libghostty.sh` (Zig; never blocks headless core)
- Test-first: prove fail before fix; no tautological asserts
- VT HEVC: no `max_ref_frames=1` (all-IDR); no `UsingHardware…` query under low-latency RC (`-12900`); no Lossless key; `DataRateLimits` = bitrate/8
