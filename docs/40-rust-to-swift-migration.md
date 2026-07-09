# SlopDesk Rust→Native-Swift Reverse-Migration Plan

> **STATUS: SUPERSEDED / DONE.** The Rust tree (`rust/slopdesk-core`, `slopdesk-ffi`) is gone; the wire core is native Swift + `Sources/CSlopDeskSIMD`. Kept only as migration history. Current architecture: [00-overview.md](00-overview.md), [DECISIONS.md](DECISIONS.md) (“Single language: Swift”).

**Goal (historical):** Reabsorb the `slopdesk-core` + `slopdesk-ffi` Rust into optimized native Swift, delete the FFI boundary, and collapse the cross-language `golden_parity` proof into a single-implementation Swift pin — without breaking one bit on the wire.

**Verified against the tree (HEAD `a3508b5`):** 40 golden keys in `rust/slopdesk-core/tests/vectors/golden_vectors.json`; `ycbcr` is golden-pinned with f32 bit-patterns and its Swift site (`YCbCrConversion.swift`) is **clean/committed-delegation** (the real pilot); NEON kernels are exactly `gf_neon.rs` (318) + `frame_hash.rs` (375) = 693 LOC; the FFI link is `Package.swift` L57-58 `.unsafeFlags(["-L…/rust/target/release","-lslopdesk_ffi"])` on the `CSlopDeskFFI` target, consumed by `SlopDeskProtocol`, `SlopDeskVideoProtocol`, `SlopDeskVideoHost`, `SlopDeskVideoClient`.

---

## 1. Summary table

| Metric | Count | Modules |
|---|---|---|
| **Total core/ffi modules** | 62 records / ~48 distinct modules (several appear in 2 clusters: geometry, network_estimate, recovery, recovery_router, interleaver) | |
| **Class A-resurrect** | 47 records (~37 distinct) | dominant class — most "ports" are revertible |
| **Class B-fresh-translate** | 8 | gf256, rs_matrix, frame_hash(core), gf_neon, frame_hash(ffi), adaptive_qp, adaptive_playout, scroll_shift, scroll_reprojection |
| **Class MIXED** | 7 | fec, interleaver, reassembler, recovery, recovery_policy, adaptive_fec, capture_region, terminal_mux |
| **Needs NEON (native SIMD)** | 5 | gf256(scalar ref + NEON region), gf_neon, frame_hash(core scalar ref), frame_hash(ffi NEON), adaptive_qp(per-row hash) — collapses to **2 physical C kernels**: GF split-table multiply + xxHash64 NV12/row hash |
| **float_law risk** | 28 | all controllers, geometry/aspect_fit, coordinate_mapping, ycbcr, vd_geometry, capture_region, window_placement, recovery_policy, size_negotiation, adaptive_fec(threshold ladder), udp_receive_loop, network_estimate, trendline |
| **wire_layout risk** | 21 | every codec: fec, interleaver, fragment, reassembler, mux_header, video_control, input_event, cursor, recovery, window_geometry, terminal wire_message/mux envelope + frame decoders, reader/session/mod |
| **Golden-pinned modules** | 32 of 40 keys map to a module; 8 modules pinned only by FFI-roundtrip + `slopdesk-loopback-validate` (reassembler, packetizer-glue, mux_router, parking_ledger, decode_gate, recovery_idr_policy, recovery_deduper, scroll_*) |

**Key structural fact that shapes the plan:** the overwhelming majority is **A-resurrect**, and a large subset are **uncommitted working-tree changes** (the in-flight "dedup" job) — for those, reversal is discarding the working-tree edit, not writing code. Genuinely-new Rust (Class B, ~8 modules) is the only place real translation happens, and 5 of those 8 are the NEON cluster.

---

## 2. THE NEON STRATEGY (Phase 0, foundational)

**Decision: a tiny native C target compiled by SwiftPM, linked directly into Swift — NOT pure `SIMD16<UInt8>`/`SIMD2<UInt64>`.**

Rationale (from the kernel notes): pure Swift SIMD has **no `vqtbl1q_u8`** (16-entry parallel table lookup), so the GF multiply degrades to per-lane scalar table lookups and loses the win; and NEON has **no 64-bit lane multiply**, so the xxHash64 fold needs the synthesized schoolbook `vmull_u32` sequence to reproduce `u64` wrapping_mul exactly. A C target emits byte-identical `tbl.16b`/`umull`/`eor.16b` codegen with zero FFI marshalling (Swift→C is a direct call, no `AisdBytes` heap dance).

**Two physical kernels** (the 5 "needs_neon" records reduce to these):

1. **GF split-table region multiply** (`gf_neon.rs`): `void aisd_gf_region_mul_add(uint8_t* dst, const uint8_t* src, size_t len, const uint8_t* table_lo, const uint8_t* table_hi)` — split-nibble vtbl: `low = v & 0x0f; high = v >> 4; prod = vqtbl1q_u8(lo,low) ^ vqtbl1q_u8(hi,high); dst ^= prod`. Swift builds `table_lo[i]=mul(c,i)`, `table_hi[i]=mul(c,i<<4)` per coeff, slices 16-byte chunks, handles the tail + non-arm64 fallback via the scalar `ScalarGf` Swift reference.
2. **xxHash64 32-byte block fold** (`frame_hash.rs`): `uint64x2x2 aisd_xxh64_fold_blocks(...)` on the four lanes held as two `uint64x2_t`, `round_pair(acc,k)=vmulq_u64_synth(rotl31(acc + vmulq_u64_synth(k,P2)), P1)`. Plane-walk, cross-row buffering (`StreamHasher` seam), `<32B` tail, and finalize stay in scalar Swift.

**SwiftPM wiring** (replaces the deleted `CSlopDeskFFI`):

```
Sources/CSlopDeskSIMD/
  include/slopdesk_simd.h     // the 2 C prototypes
  gf_region.c                   // #if defined(__aarch64__) NEON else scalar memcpy-xor
  xxh64_fold.c

// Package.swift
.target(
  name: "CSlopDeskSIMD",
  path: "Sources/CSlopDeskSIMD",
  cSettings: [ .unsafeFlags(["-O3"]) ]   // NO -L/-l, NO prebuilt archive, NO build ordering
)
// consumers (SlopDeskVideoHost, SlopDeskVideoProtocol) add "CSlopDeskSIMD" dep
```

This C target is **compiled by SwiftPM from source every build** — it kills the "rust staticlib must exist before swift build" ordering constraint. The `#if defined(__aarch64__)` guard gives x86_64 CI/sim a scalar fallback so headless builds stay green.

**Differential oracle (non-negotiable):** keep the Rust scalar bodies' logic as the portable Swift reference (`ScalarGf.mulAdd`, scalar `xxHash64`), and pin `scalar == C-NEON` with a property test over random inputs — the differential test the Rust side ships. **The bit-exact trap is integer WRAPPING, not FMA** (no float here): every Rust `wrapping_mul`/`wrapping_add`/`wrapping_sub` + `rotate_left` becomes Swift `&*`/`&+`/`&-`/manual `(x<<n)|(x>>(64-n))`. Plain `*`/`+`/`-` **trap in release**.

---

## 3. Dependency-ordered phases

Ordering rule: (a) NEON C-kernel + 1 pilot prove the loop end-to-end; (b) leaf modules with no core-internal deps before dependents; (c) FFI/cbindgen/build-ordering teardown last.

### Phase 0 — NEON foundation + PILOT vertical slice
**Modules:** `CSlopDeskSIMD` C target (2 kernels) + the pilot `ycbcr` (§4).
**Class:** B-fresh (C kernels) + A-resurrect (pilot).
**Golden:** `ycbcr`; plus a new `scalar==NEON` differential test for both kernels.
**Traps:** kernel = integer wrapping (`&*`/`&+`/manual rotl), `vqtbl1q_u8` table fill via `gf256::mul`, schoolbook `vmull_u32` for `vmulq_u64`. Pilot = compute coefficients **in f32 throughout** (`luma_scale=255.0/219.0`, etc.) — an f64 intermediate narrows wrong and diverges the pinned bit-patterns; `full_range` differs only in luma scale/bias.
**Effort:** kernels **M**, pilot **S**.
**Exit gate:** `make check` green + `cargo test golden_parity` green (ycbcr now Swift-native, Rust still present for cross-check) + kernel differential test passes. Proves "delete an FFI delegation, golden stays green" and "the C kernel matches scalar."

### Phase 1 — Pure value-codec leaves (no NEON, no state, golden-pinned)
**Modules:** `geometry` value types + `aspect_fit` (float_law), `coordinate_mapping`, `window_geometry`, `input_event`, `cursor`, `recovery` (types 1-5; NACK type-6 already native — keep), `video_control` (re-add ScrollOffset type 13 + ContentMask type 14 on top of `7b6b62a`), `mux_header` (bare prefix), `recovery_idr`-independent geometry callers. Delete the matching FFI shims (`video/{video_control,input_event,cursor,recovery,ycbcr,aspect_fit,coordinate_mapping,window_geometry}.rs`) as each Swift site goes native.
**Class:** A-resurrect (video_control MIXED: resurrect `7b6b62a`, re-add types 13/14).
**Golden:** `coordWindowPoint`, `windowGeometry`, `inputEvent`, `cursorUpdate`, `cursorShape`, `recovery`, `videoControl`, `muxBare`, `muxFragment`.
**Traps:**
- aspect_fit/coordinate_mapping/vd/placement/capture: **keep `mul` then `add` SEPARATE — never `mul_add`** (`du=(su-0.5-px)*z+0.5`, `origin.x+du*width`).
- cursor: **round-half-away-then-truncate** `UInt16(truncatingIfNeeded: Int(w.rounded()))` (32.4→32, 32.6→33).
- recovery: **reject trailing bytes** (`bytes_remaining()==0 else Malformed`) — load-bearing for byte-keyed dedup; NACK count > 64 → Malformed *before* alloc.
- input_event/video_control: `read_finite_f64` rejects NaN/Inf (NaN crashes client `CALayerInvalidGeometry`); strict UTF-8 on Text/strings; `MouseButton::from_u8` only 0/1/2.
- geometry intersection: **strict `<` per axis** → edge-touch returns non-null zero-area rect (CGRect-faithful); use native CGRect for the rect methods, do NOT port them onto VideoRect.
**Effort:** mostly **S**, video_control **L**.

### Phase 2 — Pure-function controllers + geometry/host-math leaves (float_law, stateless or value)
**Modules:** `ycbcr` done; `geometry::aspect_fit` done; `virtual_display_geometry`, `capture_region` (MIXED: resurrect `1f68d89^` + re-apply `is_associatable_layer` layer-101 + `content_rects()`), `window_placement`, `udp_receive_loop_policy` (discard WT delegation), `live_bitrate_policy`, `adaptive_playout` (B-fresh into existing enum), `qp_controller`, `static_frame_suppression`, `stillness_crisp`, `decode_frontier`, `cursor_shape_refresh`, `loss_observation_window`, `recovery_request_redundancy`, `size_negotiation`, `system_dialog_detector`.
**Class:** A-resurrect (most) + B-fresh (adaptive_playout) + MIXED (capture_region).
**Golden:** `vdChipPixelLimit`, `vdOriginToRight`, `vdRefreshRates`, `virtualDisplayGeometry`, `captureUnion`, `captureRetarget`, `windowPlacement`, `windowFits`, `udpBackoff`, `udpRearm`, `sizeNegotiationClamp`, `sizeNegotiationEpoch`, `systemDialogClassify`, `systemDialogDetect`.
**Traps:**
- **NaN-faithful ordered min/max as ternaries** everywhere (`y<x?y:x`), NEVER `f64::min`/`Swift.min` where notes call it out: capture_region `!(area>0.0)` skip-guard, window_placement `dw<window?dw:window`, size_negotiation `swift_min/max`, vd `ppi>=1.0?ppi:1.0`.
- vd `chip_pixel_limit` **branch order**: test pro/max/ultra BEFORE "apple m" (`M1 Max`→7680 not 6144); `refresh_rates` strict `fps>60`, sorted DESC + dedup.
- placement `needs_resize = (w+0.5 < window_w)` exact half-pt tolerance, clamped-vs-RAW.
- udp_backoff: `0.005 * Double(1<<min(n-1,16))` exact power-of-two scale, `min(scaled,0.25)`.
- adaptive_playout: `(k*jitter+base).clamp(floor,ceil)` separate mul+add; non-finite→floor.
**Effort:** S–M.

### Phase 3 — FEC + GF + NEON-region wiring (the bit-exact heart)
**Modules:** `gf256` (B: tables + ScalarGf, wire NeonGf region to the Phase-0 GF kernel), `rs_matrix` (B: Cauchy + Gauss-Jordan invert), `fec` (MIXED: resurrect XorParityFec m==1 from `a90268b` as golden anchor, fresh-translate ReedSolomonFec/Cauchy/recover/adaptive-m), `interleaver` (MIXED: data column-major from `c5bd7fd` + m-aware parity spread), `adaptive_fec` (MIXED: resurrect group-size ladder, re-translate parity-m ladder + TierState).
**Class:** B + MIXED.
**Golden:** `fecParity`, `fecRecover`, `fragmentEncode` (carrier), `adaptiveTier`, `adaptiveGroupSize`.
**Traps:**
- **m==1 must be byte-identical to the standalone XOR** for ANY `group_size` (incl. `group_size > k`): `effective_group_size` no-clamp at m==1, clamp-to-k at m≥2. `u32 BE` length-prefix framing; XOR zero-padded to widest member; parity laid `parity[group*m+rank]`.
- gf256: doubled `EXP[512]` table (sum up to 508, never `%255`); table build `value<<=1; if value&0x100 { value^=0x11D }` in **u16** (no overflow).
- adaptive_fec: exact f64 **threshold ladder literals + comparison directions** (`up=[>=0.005,>=0.02,…]`); with `default_m==1` EVERY tier resolves m==1.
- **untrusted-input validate-then-drop**: `strip_length_prefix→nil`, `recover_group` early-return on `holes>m`/singular `invert_subset→nil`; never force-unwrap.
**Effort:** fec **L**, gf256/rs_matrix/adaptive_fec **M**, interleaver **S**. **Highest bit-exact risk phase.**

### Phase 4 — Reassembly + packetization (stateful, untrusted UDP)
**Modules:** `fragment` (A: header codec already native — keep; resurrect VideoPacketizer state + adaptive-m), `frame_hash` core + ffi (B: scalar ref + wire NV12/row hash to Phase-0 xxh kernel), `scroll_shift` (B: cross-correlation, row-hash companion → kernel), `adaptive_qp` (B: per-row hash + ramp law), `reassembler` (MIXED: resurrect `1e479fd` struct + re-apply m-aware FEC + NACK/ARQ + try_complete precheck), `static_idr_decider` (A: resurrect `4df21c0^` VALUE struct). Delete FFI shims `video/{packetizer,reassembler,scroll_shift,frame_hash}.rs`.
**Class:** A + B + MIXED.
**Golden:** `fragmentEncode`, `staticIdrDrive`. Reassembler has **no golden** → **re-run `.build/release/slopdesk-loopback-validate`** after rewrite (mandatory).
**Traps:**
- frame_hash: integer **wrapping** (`&*`/`&+`/manual rotl), `le_u64` panic-free zero-fill over-read, cross-row 32B buffering bit-identical to NEON.
- reassembler: **untrusted ingest guard** (`frag_count>0 && ≤8192 && frag_index<frag_count` → stale BEFORE any alloc); `m==1 + retransmit OFF == pre-port behavior`; parity keyed by GROUP ORDER not raw frag_index; wrap-aware `distance_wrapped`.
- static_idr_decider: golden-pinned via f64.bitPattern — **strict `<` quiet vs inclusive `>=` heartbeat**, `0.0`=none sentinel, branch order exact.
- adaptive_qp: ramp `t=(b-b_lo)/(b_hi-b_lo); ramp=t*range; q=qp_sharp+ramp` SEPARATE mul+add, then `.round()` + clamp.
**Effort:** reassembler **L** (highest-risk module), packetizer/frame_hash/adaptive_qp/scroll_shift **M**, static_idr **M**.

### Phase 5 — Recovery/decode-gating + routing + session SM (mostly stateful A-resurrect)
**Modules:** `recovery_policy` (MIXED: resurrect redundancy+loss-window from HEAD, re-translate loss-adaptive escalation float law), `recovery_router` (discard WT delegation; re-add RetransmitFragments arm), `recovery_idr_policy` (A: resurrect `dc73936^` token-bucket — HIGH risk, fixed the 600ms freeze), `recovery_request_deduper` (A: resurrect `53b2908^` byte-key ring), `decode_gate` (A: resurrect `81bf99e^` — HIGH risk, prevents -12909 tear), `video_session/state_machine` + `size_negotiation` (trivial — already live native, delete dead Rust shadow), `video_mux_router` (A: `d9ae769^`, Set instead of BTreeSet), `input_router`/`input_button_balance` (A: resurrect Set<MouseButton>), `scroll_reprojection` (B: client UV-offset).
**Class:** A (most) + MIXED (recovery_policy) + B (scroll_reprojection).
**Golden:** `recovery` (router transitively), `staticIdrDrive` (done). Most have **no golden** → unit tests + loopback-validate.
**Traps:**
- recovery_policy/redundancy: **NaN-collapse-not-clamp** — `all_copies_lost` uses `p.max(0).min(1)` + repeated `out *= p` (clamp would propagate NaN; global min/max collapse NaN→0).
- recovery_idr_policy: **decide() ORDER is load-bearing** (refill→grant-pending→SuppressStale→SuppressInFlight→SuppressRateLimited→Grant); refill `(now-last)*rate` separate then add.
- decode_gate: `note_loss` never downgrades NeedKeyframe; keyframe-success downgrade only if session still ALIVE; wrap-aware.
- deduper: `!(window>0.0)` admit / `!(now-t>window)` retain (NaN kill-switch fidelity).
- recovery_router: `RequestIdr→ForceKeyframe` must NEVER degrade to LTR; sentinel `0xFFFFFFFF→nil`; recovery on its OWN channel (type bytes 1/2/3 alias InputEvent).
**Effort:** recovery_idr/decode_gate **L**, recovery_policy/router/deduper/mux_router **M**, session SM/input routers **S**.

### Phase 6 — Terminal / PTY path-1 + SSH mux
**Modules:** `terminal/wire_message/{mod,codec}` (A: codec is the ONE genuinely-deleted body — resurrect from `7e18469`, adopt scalar-boundary title clamp `1b4ad19`), `terminal/frame_decoder` + `mux/frame_decoder` (A: **revert** — native still at HEAD, discard WT M), `mux/envelope` (A: revert), `mux/{flow_control,flow_credit_policy,receive_window_accountant,bounded_queue_policy}` (A: revert WT M, keep value structs), `reader`/`error`/`session`/`mod` (already native — keep). Drop FFI-only zero-copy artifacts (`data_frame_view`, `encode_channel_data_into`, `next_inner`). Delete `terminal_mux.rs` (1145 LOC) + `aisd_wire_*`/`aisd_frame_decoder_*` from `lib.rs`.
**Class:** A (all) — wire_message/codec is the only real translate; rest are reverts.
**Golden:** `terminalWireMessages`, `muxEnvelopes`, `muxFragment`.
**Traps:** `[u32 BE payloadLength][u8 type][body]`, length excludes the 4-byte prefix; UUID/SessionId = 16 raw bytes; STRICT UTF-8 on Title(21)/Notification(25)/CommandStatus(23) → throw, never force-unwrap; `frameTooLarge` when `payloadLength>16MiB` BEFORE buffering; partial frame returns nil not error; flow policies keep `overflowing_add` saturation + non-negative clamp; `SLOPDESK_MUX_*` must match host+client.
**Real-binary smoke:** re-run `SubprocessE2ETests` (catches real-socket open-ordering races loopback misses).
**Effort:** codec **M**, everything else **S** (reverts).

### Phase 7 — FFI / cbindgen / build-ordering TEARDOWN (last)
Only after EVERY module is reabsorbed and all goldens + loopback-validate + SubprocessE2E are green. See §6 checklist.

---

## 4. THE PILOT

**Module:** `rust/slopdesk-core/src/ycbcr.rs` (130 LOC) + its FFI shim `rust/slopdesk-ffi/src/video/ycbcr.rs` (71 LOC).
**Why the best first slice:** smallest pure module; **no NEON, no opaque-handle, no state, no untrusted decode** (a coefficient table, not a codec); golden-pinned; and its Swift site `Sources/SlopDeskVideoProtocol/YCbCrConversion.swift` is **clean at HEAD** (the delegation is *committed*, not a working-tree edit), so reabsorbing it is a **real native-Swift rewrite that exercises "delete an FFI delegation → golden stays green"** — unlike the working-tree-M candidates (decode_frontier, static_frame_suppression, stillness_crisp) where reversal just discards an uncommitted edit and proves nothing.
**Golden key:** `ycbcr` (pins 7 f32 bit-patterns × {video, full} — e.g. `lumaScale=1066732165`, `crToR=1070174988`).
**FFI site to delete:** `Sources/SlopDeskVideoProtocol/RustBridge.swift:987` `aisd_ycbcr_coefficients(fullRange ? 1 : 0)` → replace `YCbCrConversion.coefficients` with the native f32 table.
**Original Swift rev to resurrect:** `53b2908` (`YCbCrConversion.swift` body before the `655d69a` swap). Struct/enum scaffolding (`ColorRange`, doc comments) survives at HEAD; only `coefficients` needs to return native f32 instead of calling FFI.
**The one trap:** compute every value **in `Float` end-to-end** (`255.0/219.0`, `16.0/255.0`, `128.0/255.0`, matrix coeffs `1.5748/0.1873/0.4681/1.8556`). An f64 intermediate narrowed to f32 diverges the low bits and fails the pinned bit-patterns. No mul+add chains, so the FMA rule doesn't bite here.
**Proof:** `make check` + `swift test --filter YCbCr` + `cd rust && cargo test golden_parity` all green with the FFI call gone.

---

## 5. Risk register (top 5)

| # | Risk | Guard |
|---|---|---|
| 1 | **FMA rewrite** — clippy/refactor turns separate `mul`+`add` into `mul_add`, diverging low bits and breaking golden parity (aspect_fit, coordinate_mapping, every EWMA controller, adaptive_qp ramp, vd/capture/placement). | Port `mul` and `add` as **two statements**; comment `// keep separate — FMA breaks bit-exact parity` at each site; re-run the module's golden key after each port; keep SwiftFormat from collapsing them (it has deleted statements before). |
| 2 | **Integer-overflow wrapping** in the NEON/hash cluster (gf256 table build, xxHash64 fold, SplitMix PRNGs) — plain Swift `*`/`+`/`-` **traps in release**. | Translate every Rust `wrapping_*`/`rotate_left` to `&*`/`&+`/`&-`/manual `(x<<n)|(x>>(64-n))`; pin `scalar==NEON` differential test in Phase 0; never let the type widen silently. |
| 3 | **NaN min/max semantics** — Rust `f64::max`/`min` vs Swift `Swift.max`/global-min vs the NaN-faithful ternary differ on a NaN operand; flipping the form silently mis-routes (capture qualify, placement clamp, size_negotiation, deduper/redundancy NaN kill-switch, recovery `all_copies_lost`). | Reproduce the **exact predicate form** the notes specify (`!(area>0.0)`, `y<x?y:x`, `p.max(0).min(1)`+`out*=p`); do NOT "simplify" to `Swift.min`; add the NaN-input case to each module's unit test. |
| 4 | **Untrusted-UDP memory safety** — reassembler/recovery/video_control/input_event parse raw datagrams; a force-unwrap or pre-alloc-against-attacker-count panics (release is `panic=abort`). | Every decode throws/returns optional, never force-unwrap; validate counts BEFORE alloc (frag_count≤8192, NACK count≤64, list counts per-record); guard `frag_index<frag_count` → stale before any per-frame alloc. |
| 5 | **No-golden stateful modules** (reassembler, recovery_idr_policy, decode_gate, mux_router, parking_ledger) — bit-exactness proven ONLY by FFI-roundtrip + loopback-validate, which vanish with the boundary. | Before deleting each FFI shim, snapshot its `tests/ffi_boundary.rs`/Rust unit assertions as **native Swift tests**; **re-run `.build/release/slopdesk-loopback-validate`** (real VT HEVC + FEC + deterministic loss) after Phases 4 and 5; preserve decide()/verdict() branch ORDER verbatim (test-first: a test that FAILS on a reordered branch). |

---

## 6. Teardown checklist (Phase 7 — only after all modules reabsorbed + green)

1. **Delete the FFI marshalling shims** as each Swift site goes native (incremental, per phase): `rust/slopdesk-ffi/src/video/*.rs`, `terminal_mux.rs` (1145 LOC), `aisd_wire_*`/`aisd_frame_decoder_*` in `lib.rs`, `raw.rs`, `gf_neon.rs`/`frame_hash.rs` (logic now in `CSlopDeskSIMD`).
2. **Delete the whole `slopdesk-ffi` crate** + `rust/slopdesk-core` once nothing links the staticlib; remove the cargo workspace (`rust/Cargo.toml`, `rust/target/`).
3. **Delete `Sources/CSlopDeskFFI`** target + its `Package.swift` entry (L54-58, the `.unsafeFlags(["-L…","-lslopdesk_ffi"])`) and remove `"CSlopDeskFFI"` from every consumer's `dependencies` (SlopDeskProtocol, SlopDeskVideoProtocol, SlopDeskVideoHost, SlopDeskVideoClient). Add `"CSlopDeskSIMD"` to the host/protocol targets instead.
4. **Kill the rust-before-swift build ordering**: `rust/build-apple.sh` (+ cbindgen header-regen + `--ios` slice), the `CSlopDeskFFI` header `slopdesk_ffi.h`, the cbindgen drift-gate (`make check`'s `check-ffi-header`, the `rust` CI job, `cbindgen.toml`). `swift build` now compiles from a clean checkout with no prerequisite.
5. **Collapse `golden_parity` from cross-language to single-impl pin**: the corpus stays (`golden_vectors.json` still generated by `swift run slopdesk-corevectors`), but the consumer becomes a **Swift XCTest** that decodes the JSON and asserts the native codecs reproduce it — no second implementation to diff against, so it's a regression pin, not a parity proof. Delete Rust `tests/golden_parity.rs`, `tests/ffi_boundary.rs`, `tests/smoke.c`.
6. **Remove the opaque-handle wrappers** (`final class … { OpaquePointer; deinit { aisd_*_free } }`) — fold each back into a Swift value struct/class owning its state directly (reassembler, decode_gate, recovery_idr_policy, deduper, mux_router, parking_ledger, pacer_depth_policy, owd_late_detector, scroll_reprojector, fec codec).
7. **Remove all `repr(C)` marshalling + memory contracts**: `AisdBytes`/`AisdBytesArray`/`AisdWireMessage`/`AisdVideoControl`/… structs, every `aisd_*_free`, the `defer { aisd_bytes_free(out) }` copy-then-free dance, the `from_parts`/value-round-trip constructors, the `u8 != 0` bool reads (now native Swift `Bool`).
8. **CI/docs**: drop the `rust` CI job + `cargo deny`/`machete`/`clippy`; update `CLAUDE.md` (remove "build ordering is mandatory," the FFI conventions §3-5, "Rust core is source of truth"), `docs/00-overview.md`, `docs/DECISIONS.md` (re-scope the Rust-core decision FIRST per convention #9), `docs/20-wire-protocol.md` (wire law now lives in Swift). The `suboptimal_flops` clippy allow-list note migrates to a Swift lint comment convention.
9. **Final gate:** `make check` (Swift-only lint+build+test) + `swift test` (~2200) + `bash scripts/check-ios.sh` + `.build/release/slopdesk-loopback-validate --frames 120` + `SubprocessE2ETests`, all green with zero Rust in the tree.

**Sequencing across sessions:** Phases 0→6 each leave the Rust *present* (FFI shim still compiled) so `golden_parity` keeps cross-checking native-Swift-vs-Rust the whole way — you only lose the cross-language oracle at Phase 7. Commit each green phase atomically (branch first; the tree has 95+ uncommitted working-tree files from the in-flight dedup job, several of which Phases 2/5/6 discard).

**Absolute paths:** pilot `/Users/dev/slop-desk/Sources/SlopDeskVideoProtocol/YCbCrConversion.swift` + `/Users/dev/slop-desk/Sources/SlopDeskVideoProtocol/RustBridge.swift:987`; golden corpus `/Users/dev/slop-desk/rust/slopdesk-core/tests/vectors/golden_vectors.json`; NEON kernels `/Users/dev/slop-desk/rust/slopdesk-ffi/src/gf_neon.rs` + `/Users/dev/slop-desk/rust/slopdesk-ffi/src/frame_hash.rs`; FFI link `/Users/dev/slop-desk/Package.swift:57-58`; new C target home `/Users/dev/slop-desk/Sources/CSlopDeskSIMD/`.
