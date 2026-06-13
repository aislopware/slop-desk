I have everything I need. The FFI patterns referenced throughout the specs (AisdBytes, AisdStatus, opaque-handle Box pattern à la AisdFrameDecoder, AISD_ERR_* codes, hand-written header) are confirmed present in the repo. Synthesizing the ordered plan now.

---

# Swift→Rust Strangler Swap Plan

The Rust core (`aislopdesk-core`) and its `extern "C"` shim (`aislopdesk-ffi`, only crate allowed `unsafe`) already exist and are byte/bit-exact-proven against Swift via golden vectors. This plan widens the FFI and redirects Swift implementation bodies behind their *unchanged* public APIs (strangler pattern), one wave at a time, gated by the three hard constraints.

The existing ABI contract is the backbone for everything below: `AisdStatus` (`AISD_OK=0`, `AISD_EMPTY=1`, `AISD_ERR_NULL=-1`, `_FRAME_TOO_LARGE=-2`, `_TRUNCATED=-3`, `_UNKNOWN_TYPE=-4`, `_MALFORMED=-5`, `_INVALID_ARGUMENT=-6`), `AisdBytes` (Rust-alloc / Rust-free via `aisd_bytes_free`), the opaque `Box<inner>` handle pattern (proven by `aisd_frame_decoder_*`), and the jboolean-validity rule (cross all `bool`s as `u8`, read `!= 0` Rust-side). Every new function reuses these. The hand-written header `rust/aislopdesk-ffi/include/aislopdesk_ffi.h` grows in lockstep, and the C smoke test (`-Werror` against the `.a`) re-proves the ABI each pass.

---

## Guiding rules applied to every item

- **Strangler boundary.** The Swift public type keeps its exact signature. Its body becomes a thin wrapper that owns the opaque Rust handle (for stateful types) or calls the pure extern (for stateless). No Swift call site changes its call shape — only the type's internals.
- **No-behavior-change gate.** The existing Swift test target for each type re-runs unchanged and must stay green. Golden parity already proves byte/bit equality, so any test failure post-swap is a wrapper bug, not a semantics drift.
- **No-perf-regression gate.** Anything that marshals a buffer per frame/datagram is benchmarked against the live 60fps full-screen-scroll (and lossy-stream) workload *before* flipping the live path. If it regresses, it stays Swift.
- **Sequencing.** Shared dependency types (`NetworkEstimate`, the `AisdMuxFrame` struct) land before their consumers so the FFI is widened once, not piecemeal.

---

# WAVE A — safe-scalar controllers + pure functions (swap now, perf-trivial)

All scalar in / scalar out, no buffer marshaling, called at event/netstats/lifecycle rate (never per-pixel). FFI call overhead is dwarfed by nothing because there is no payload copy. Highest clarity, lowest risk. **Land `NetworkEstimate` first** — it is the shared input to two Wave-A controllers.

### A0. NetworkEstimate (shared dependency — land first)
- **Module:** `aislopdesk-core::network_estimate`
- **FFI additions:** opaque `AisdNetworkEstimate`: `aisd_network_estimate_new()`, `_fold(handle, rtt_ms:i32, rtt_present:u8, frames_received:u32, unrecovered:u32, owd_jitter_micros:u32, owd_trend_state:u8, owd_trend_modified_milli:i32)`, `_snapshot(handle, out:*mut AisdNetworkEstimateSnapshot)` (flat repr(C) of all 8 public scalars: `smoothed_rtt_ms`, `min_rtt_ms`, `loss_rate`, `last_loss_sample`, `owd_gradient_rising`, `owd_trend_overusing`, `owd_trend_modified`, `last_rtt_sample_ms`+`valid`), `_free`. Plus pure static `aisd_compute_rtt_millis(host_now_ms:u32, latest_host_send_ts:u32, client_hold_ms:u32, out:*mut i32)->u8`.
- **Swift call sites:** `AislopdeskVideoHostSession.swift:275` (instance), `.fold(...)` per NetworkStatsReport. The snapshot is what feeds A1/A2 — co-design those signatures around this struct.
- **Test target:** `Tests/AislopdeskVideoHostTests/NetworkEstimateTests.swift` + golden_parity (corevectors line 272).
- **Perf risk:** none (scalar, ~2/s).

### A1. LiveCongestionController
- **Module:** `aislopdesk-core::live_congestion_controller`
- **FFI additions:** opaque `AisdLiveCongestionController`: `aisd_live_cc_new(ceiling:i32, gradient_cut_enabled:u8)` (+ floor-explicit variant), `_decide(handle, /*flattened NetworkEstimate snapshot: smoothed_rtt_ms:f64, min_rtt_ms:f64, loss_rate:f64, last_loss_sample:f64, owd_trend_overusing:u8, last_rtt_sample_ms:f64, last_rtt_sample_valid:u8*/, out_target:*mut i32, out_reason:*mut u8)->AisdStatus`, `_current`/`_ticks` getters, `_free`. Pure static `aisd_live_cc_is_material_change(prev:i32, target:i32, ceiling:i32)->u8`. Consumes the A0 snapshot fields directly.
- **Swift call sites:** `AislopdeskVideoHostSession.swift:917` (init with ceiling), `:824` (`ctrl.decide(networkEstimate)` in netstats fold).
- **Test target:** `Tests/AislopdeskVideoHostTests/LiveCongestionControllerTests.swift`.
- **Perf risk:** none (~7 scalars in, 2 out, ~2/s).

### A2. FPSGovernor (+ its pure statics) and SelfHealCadence
- **Module:** `aislopdesk-core::fps_governor`
- **FFI additions:** opaque `AisdFpsGovernor`: `aisd_fps_gov_new(base_fps:i32)`, `_note_encoded_frame(handle, bytes:i64, is_anchor:u8)`, `_on_tick(handle, target_bps:i64, congested:u8)->i32`, `_current_fps(handle)->i32`, `_free`. Pure statics (no handle): `aisd_fps_gov_congestion_evidence(last_loss:f64, smoothed_rtt:f64, min_rtt:f64, abr_current:i32, abr_current_valid:u8, abr_ceiling:i32, abr_ceiling_valid:u8)->u8` and `aisd_self_heal_effective_every(base_every:i32, base_fps:i32, governed_fps:i32)->i32`.
- **Swift call sites:** `AislopdeskVideoHostSession.swift:1315` (init), `:843` (`gov.onTick`), `noteEncodedFrame(...)` per encoded frame; SelfHealCadence consumed where governed fps scales the self-heal K (pure helper, no instance).
- **Test target:** `Tests/AislopdeskVideoHostTests/FPSGovernorTests.swift` (covers SelfHealCadence cases too).
- **Perf risk:** none. `note_encoded_frame` is per encoded frame but is a single scalar push, no buffer. (`EncodeCadenceGate` is in this file but is driven from `WindowCapturer` at frame cadence — deferred to Wave B-bench, see A-deferred below.)

### A3. LTRController
- **Module:** `aislopdesk-core::ltr_controller`
- **FFI additions:** opaque `AisdLtrController`: `aisd_ltr_new()`, `_record_frame(handle, frame_id:u32, token:i64)`, `_ack_frame(handle, frame_id:u32, out_token:*mut i64, out_found:*mut u8)`, `_recovery_decision(handle, request:u8, has_enable_ltr:u8)->u8`, `_has_acked_token(handle)->u8`, `_reset(handle)`, `_acked_tokens(handle, out_buf:*mut i64, cap:usize, out_count:*mut usize)` (caller-provided stack buffer, cap 8 i64, no Rust alloc), `_free`.
- **Swift call sites:** `AislopdeskVideoHostSession.swift:322` (instance); `recordLTRFrame`/`ackFrame`/`recoveryDecision`/`reset`/`currentAcknowledgedTokens` on the encoded-frame + `.ack` folds.
- **Test target:** `Tests/AislopdeskVideoHostTests` LTRController tests.
- **Perf risk:** none. The acked-token list is ≤64 bytes into a caller stack buffer.

### A4. RecoveryIDRPolicy
- **Module:** `aislopdesk-core::recovery_idr_policy`
- **FFI additions:** opaque `AisdRecoveryIdrPolicy`: `aisd_recovery_idr_new(/*Config flattened: grace_fraction:f64, grace_floor_s:f64, grace_ceil_s:f64, bucket_capacity:f64, refill_per_s:f64, grant_pending_timeout:f64, keyframe_ring_cap:i32*/)` + `_new_default()`, `_note_keyframe_sent(handle, frame_id:u32, now:f64)`, `_note_keyframe_delivered(handle, frame_id:u32)`, `_decide(handle, now:f64, client_last_decoded:u32, client_last_decoded_present:u8, smoothed_rtt_s:f64)->u8`, `_available_tokens(handle)->f64`, `_free`. (keyframe ring stays Rust-side; nil-client mapped via `_present`.)
- **Swift call sites:** `AislopdeskVideoHostSession.swift:280` (instance), `:895` (`.decide`), `noteKeyframeSent` per keyframe, `noteKeyframeDelivered` on `.ack`.
- **Test target:** `Tests/AislopdeskVideoHostTests` RecoveryIDRPolicy tests.
- **Perf risk:** none.

### A5. RecoveryRequestDeduper
- **Module:** `aislopdesk-core::recovery_request_deduper`
- **FFI additions:** opaque `AisdRecoveryRequestDeduper`: `aisd_recovery_deduper_new(window_seconds:f64, capacity:usize)`, `_admit(handle, datagram:*const u8, len:usize, now:f64)->u8` (1=first sighting, 0=dup), `_free`. Datagram is BORROWED, read-only, ≤17 bytes, recovery-request cadence → treat as safe-scalar despite small-buffer ioShape. Entry ring stays Rust-side.
- **Swift call sites:** `AislopdeskVideoHostSession.swift:286` (instance), `.admit(datagram, now:)` per inbound recovery-request datagram.
- **Test target:** `Tests/AislopdeskVideoHostTests` RecoveryRequestDeduper tests.
- **Perf risk:** negligible (tiny borrowed buffer, rare cadence).

### A6. LiveBitratePolicy
- **Module:** `aislopdesk-core::live_bitrate_policy`
- **FFI additions:** pure (no handle): `aisd_live_bitrate_target(pixel_width:i32, pixel_height:i32, fps:i32, floor:i32)->i32`, `aisd_live_bitrate_minimum()->i32`. **Env subtlety:** `bitsPerPixelPerFrame` is env-resolved (`AISLOPDESK_BPP`) — keep the core env-free by adding an explicit `bpp:f64` parameter the host resolves and passes, so the resolution-derived value stays byte-identical.
- **Swift call sites:** `AislopdeskVideoHostSession.swift` — `targetBitrate(...)` feeds `LiveCongestionController(ceiling:)` at :917; `minimumBitrate` is the controller floor clamp.
- **Test target:** `Tests/AislopdeskVideoHostTests` LiveBitratePolicy tests.
- **Perf risk:** none. (Land before/with A1 since it produces A1's ceiling.)

### A7. IdleReapDecider (monomorphized to u32)
- **Module:** `aislopdesk-core::idle_reap_decider`
- **FFI additions:** opaque `AisdIdleReapDecider` (instantiated `<u32>` — live FlowID is concretely `UInt32`): `aisd_idle_reap_new(idle_timeout:f64)`, `_note_inbound(handle, id:u32, now:f64, is_keepalive:u8)`, `_reap(handle, now:f64, out_buf:*mut u32, cap:usize, out_count:*mut usize)` (caller-provided fixed buffer, no Rust alloc), `_forget(handle, id:u32)`, `_record(handle, id:u32, out_last_inbound:*mut f64, out_saw_keepalive:*mut u8, out_present:*mut u8)`, `_free`.
- **Swift call sites:** `NWVideoMuxDatagramTransport.swift:60` (instance), `noteInbound` :299, `reap` :194, `forget` :104/:199.
- **Test target:** `Tests/AislopdeskVideoHostTests/IdleReapDeciderTests.swift`.
- **Perf risk:** none (flow count small, reaper-timer cadence).

### A8. TrendSampler
- **Module:** `aislopdesk-core::trendline_estimator`
- **FFI additions:** opaque `AisdTrendSampler` (one `Option<u32>` state): `aisd_trend_sampler_new()`, `_should_sample(handle, frame_id:u32, send_ts:u32)->u8`, `_free`. **Recommend folding into the TrendlineEstimator handle** (Wave-A-deferred C-controllers) since they're always paired at the call site.
- **Swift call sites:** `AislopdeskVideoClientSession.swift:317` (instance), `:672` (`shouldSample` gate before `owdTrend.note` / `owdLateDetector.note`).
- **Test target:** `Tests/AislopdeskVideoClientTests/TrendlineEstimatorTests.swift` (TrendSampler cases).
- **Perf risk:** none.

### A9. RecoveryPolicy (client-side, despite host group label)
- **Module:** `aislopdesk-core::recovery_policy`
- **FFI additions:** pure (config-by-value): `aisd_recovery_policy_should_escalate_to_idr(idr_rtt_mult:f64, lossy_idr_rtt_mult:f64, lossy_floor_s:f64, lossy_floor_rtt_mult:f64, elapsed_since_request:f64, rtt:f64, observing_loss:u8)->u8`. `initialRequest(...)` builds a `RecoveryMessage` → that is the *already-ported* recovery wire layer (`aislopdesk-core::recovery`), so reuse it; the only new FFI here is the escalate decision. **Env subtlety:** `defaultLossyEscalationFloor` reads `AISLOPDESK_ESCALATION_FLOOR_MS` once — pass the resolved floor in as a param.
- **Swift call sites:** `AislopdeskVideoClientSession.swift:345` (injected); `initialRequest`/`shouldEscalateToIDR` drive the client recovery timer.
- **Test target:** AislopdeskVideoProtocolTests / client RecoveryPolicy tests.
- **Perf risk:** none.

### A10. DecodeFrontier (client)
- **Module:** `aislopdesk-core::decode_frontier`
- **FFI additions:** opaque `AisdDecodeFrontier`: `aisd_decode_frontier_new()`, `_free(ptr)`, `_note_decoded(ptr, frame_id:u32)`, `_wire_value(const ptr)->u32`. (State is one `Option<u32>`; opaque handle matches the existing `AisdFrameDecoder` Box pattern.)
- **Swift call sites:** `AislopdeskVideoClientSession.swift:271` (instance), `:800` (`noteDecoded`), `:1128`/`:1139` (`wireValue` on requestLTRRefresh/requestIDR).
- **Test target:** `Tests/AislopdeskVideoClientTests` DecodeFrontier tests; loopback-validate recovery sim.
- **Perf risk:** none.

### A11. DecodeGate (client)
- **Module:** `aislopdesk-core::decode_gate`
- **FFI additions:** opaque `AisdDecodeGate`: `aisd_decode_gate_new()`/`_free`, `_note_loss(ptr, u32)`, `_note_hard_decode_failure(ptr)`, `_note_awaiting_keyframe(ptr)`, `aisd_decode_gate_verdict(const ptr, frame_id:u32, keyframe:u8, acked_anchored:u8)->i32` (0=submit, 1=drop), `_note_decode_succeeded(ptr, u32, keyframe:u8)`, `aisd_decode_gate_mode(const ptr)->u8`. Bools cross as `u8` read `!=0`.
- **Swift call sites:** `AislopdeskVideoClientSession.swift:277` (instance), `:738` (noteLoss), `:785` (verdict), `:803` (noteDecodeSucceeded), `:853` (noteAwaitingKeyframe), `:883` (noteHardDecodeFailure).
- **Test target:** `Tests/AislopdeskVideoClientTests` DecodeGate (13 rust unit tests mirror); loopback-validate. **NOTE:** this type has burned the verify-the-verifier loop before (stay-needKeyframe not reset) — re-run the full DecodeGate suite, do not trust a single case.
- **Perf risk:** none (several scalar mutations per frame on the loss path, no buffer).

### A12. OwdLateDetector (client)
- **Module:** `aislopdesk-core::owd_late_detector`
- **FFI additions:** opaque `AisdOwdLateDetector`: `aisd_owd_late_detector_new(bucket_ms:f64, floor_ms:f64, interval_fraction:f64, warmup:usize)` + `_new_default()`, `_free`, `aisd_owd_late_detector_note(ptr, arrival_ms:f64, send_ts:u32, interval_ms:f64, out_over_ms:*mut f64)->i32` (1=late w/ out written, 0 else). Env resolution stays Swift (build Config there). f64 bit-exactness relies on existing golden parity.
- **Swift call sites:** `AislopdeskVideoClientSession.swift:321` (instance), `:680` (`note(...)`→ non-nil → `gui.noteNetworkLate()`).
- **Test target:** `Tests/AislopdeskVideoClientTests` OwdLateDetector tests + golden_parity:631 + loopback-validate component-H (main.swift:2072).
- **Perf risk:** none for copy (scalar), but called per admitted frame — see TrendlineEstimator note; rolling-min f64 is cheap, passes trivially.

---

## Wave-A deferred-to-bench items (scalar IO, but per-frame call cadence)

These are **scalar in/out with zero buffer copy**, so they are architecturally Wave A, but they fire at per-frame/per-tick cadence so the *only* open question is whether the C-ABI call overhead at 60–120 Hz is negligible vs the in-Swift call. Bench once; they almost certainly promote to swap-now (one call/frame, no allocation). Group them in the same FFI pass but flip the live wiring only after the micro-bench passes.

- **TrendlineEstimator (client)** — `aislopdesk-core::trendline_estimator`. Opaque `AisdTrendlineEstimator`: `_new`/`_free`, `aisd_trendline_note(ptr, arrival_ms:f64, send_ts:u32)`, `_is_stale(ptr, now_ms:f64)->u8`, `_state(ptr)->u8`, `_wire_trend_milli(ptr)->u32`, `_wire_trend_flags(ptr)->u32`. Pure statics `aisd_trendline_pack_trend_milli(f64)->u32`, `aisd_trendline_pack_trend_flags(state:u8, num_deltas:i32)->u32`. Call sites: `AislopdeskVideoClientSession.swift:313` instance, `:674` `note` per sampled frame, `:474`/`:482-483` wire packing into NetworkStatsReport. Test: TrendlineEstimatorTests + golden_parity:588 + loopback-validate (main.swift:1203,1323). **Perf risk:** the float-heaviest per-frame path (OLS over a 20-sample window) — no buffer crosses, so only the per-frame call cost is in question; bench at 60 Hz.
- **PacerDepthPolicy (client)** — `aislopdesk-core::pacer_depth_policy`. Opaque `AisdPacerDepthPolicy`: `aisd_pacer_depth_policy_new(const AisdPacerDepthConfig*, adapt_enabled:u8)`/`_free`, `_note_arrival(ptr, f64)`, `_note_present(ptr, f64)->i32` (GapClass), `_note_network_late(ptr, f64)`, `_note_reshow(ptr, f64)`, `_set_interval_hint(ptr, has_value:u8, seconds:f64)`, `_drain_counters(ptr, out_late:*mut u32, out_gaps:*mut u32)`, `_depth(const ptr)->i32`, `_expected_interval_seconds`/`_late_threshold_seconds(const ptr)->f64`. Config crosses as flat repr(C) `AisdPacerDepthConfig` (~16 scalars), built in Swift (host resolves `AISLOPDESK_DEPTH_*`, keeps core env-free). Ring buffers stay Rust-side. Call sites: `FramePacer.swift:135/219/252/285/313/335/348/412/460/488/548`, `VideoWindowPipeline.swift:181/309`. Test: PacerDepthPolicy/FramePacer tests + golden_parity:682,709 + loopback-validate (847,2071,2156,2635). **Perf risk:** `noteArrival`/`notePresent` run under FramePacer's lock at present cadence — no buffer copy; bench the per-tick C-ABI cost at 120 Hz. (FramePacer itself stays Swift — only the policy struct swaps.)
- **EncodeCadenceGate (host)** — `aislopdesk-core::fps_governor`. Opaque `AisdEncodeCadenceGate`: `_new`, `aisd_cadence_gate_admit(ptr, now:f64, target_interval_s:f64, tolerance_s:f64, forced:u8)->u8`, `_next_due(ptr)->f64`, `_free`. One `f64` of state — a value-copy struct ABI (no handle) is also viable. Call site: `WindowCapturer.swift:161` instance, `admit(...)` per delivered frame (up to 2×fps ≈120/s). Test: FPSGovernor/cadence tests. **Perf risk:** ~6 float ops body called at frame cadence — FFI call overhead likely dwarfs the work; **bench, or fold into the FPSGovernor handle to amortize**, before flipping.

### A-Adaptive: AdaptiveFECPolicy (host) — clean scalar swap, no handle
- **Module:** `aislopdesk-core::adaptive_fec`
- **FFI additions:** pure scalars: `aisd_adaptive_fec_group_size(tier:u8, default_group_size:usize, out_group_size:*mut usize)->bool` (false = OFF/nil tier), `aisd_adaptive_fec_tier(loss:f64, previous_tier:u8, allow_off:u8)->u8`, `aisd_adaptive_fec_next_tier_state(loss:f64, AisdTierState{tier:u8, relax_streak:i32, sticky_relax_remaining:i32}, dwell:i32, allow_off:u8, saw_unrecovered:u8)->AisdTierState`. No handle, no buffers.
- **Swift call sites:** `AislopdeskVideoHostSession.swift:317` (TierState value), `:807` (nextTierState per netstats), `:1498` (tier read), `:1540` (groupSize for interleave); `FrameReassembler.swift:316` parityGroupSize. **Note:** if the reassembler/packetizer are later ported (Wave C), the Rust core calls `adaptive_fec::group_size` internally — so only the host-side LOSS→TIER decision and interleave-group lookup need this standalone scalar FFI.
- **Test target:** `Tests/AislopdeskVideoProtocolTests/AdaptiveFECPolicyTests.swift` + golden parity.
- **Perf risk:** none (~2/s for the decision, once/frame for groupSize, all scalar). The lowest-risk, highest-clarity swap in the whole video group — can land in Wave A alongside the host controllers.

---

# WAVE B — small-buffer codecs (cursor / geometry / coordinate / input-event / control)

Event-rate (window move/resize, pointer/key, session bringup, picker poll), not per-pixel. Payloads are small fixed scalars plus at most one small UTF-8 string or a tiny variable-count record list. One copy is cheap. All reuse the existing `AisdBytes`/`AisdStatus` contract, NaN-reject → `AISD_ERR_MALFORMED`, strict-UTF-8 → `AISD_ERR_MALFORMED`.

### B1. CursorUpdate (fixed 36-byte message)
- **Module:** `aislopdesk-core::cursor`
- **FFI additions:** `aisd_cursor_update_encode(shape_id:u16, visible:u8, x:f64, y:f64, hotspot_x:f64, hotspot_y:f64, out:*mut AisdBytes)->AisdStatus` (Rust-owned 36-byte buffer); `aisd_cursor_update_decode(data:*const u8, len:usize, out:*mut AisdCursorUpdate{shape_id, visible:u8, x, y, hotspot_x, hotspot_y})->AisdStatus`. Flat repr(C) decode-out, no owned buffer on the decode path.
- **Swift call sites:** host encode `AislopdeskVideoHostSession.swift:1767` (onCursorUpdate) via `VideoSessionLogic.swift:743` (CursorChannelMessage.encode); client decode `AislopdeskVideoClientSession.swift:962`→`:1006` (applyCursor).
- **Test target:** `Tests/AislopdeskVideoProtocolTests/CodecTests.swift` (cursor round-trip + NaN-reject) + golden_parity (cursorUpdate hex).
- **Perf risk:** none (36 bytes, cursor cadence).

### B2. CursorChannelMessage (first-byte router — thin)
- **Module:** `aislopdesk-core::cursor`
- **FFI additions:** no opaque handle. Either thin `aisd_cursor_channel_kind(data, len)->i32` (1=update, 2=shape, negative=err) so Swift dispatches per-variant, or fold routing into the CursorUpdate decoder (it already rejects a wrong type byte). **Do not** build a unified tagged C struct carrying the bitmap `AisdBytes` — that taxes the hot update path with the shape's payload field.
- **Swift call sites:** host encode router `VideoSessionLogic.swift:743`; client receive router `AislopdeskVideoClientSession.swift:963` (peeks first byte).
- **Test target:** cursor.rs `channel_routes_by_first_byte`; Swift CursorShapeCodec round-trip.
- **Perf risk:** none (one-byte peek). The shape variant stays Swift (KEEP-SWIFT, below) — route to it.

### B3. WindowGeometryMessage
- **Module:** `aislopdesk-core::window_geometry`
- **FFI additions:** `aisd_window_geometry_encode(kind:u8{1..4}, x, y, w, h:f64, title:AisdBytes(borrowed, used iff kind==4), out:*mut AisdBytes)`; `aisd_window_geometry_decode(data, len, out:*mut AisdWindowGeometry{kind:u8, x, y, w, h:f64, title:AisdBytes Rust-owned for kind4})`. Strict-UTF-8 → `AISD_ERR_MALFORMED`; nonfinite → `AISD_ERR_MALFORMED`. Title freed via `aisd_bytes_free`.
- **Swift call sites:** host `VideoSessionLogic.swift:738` (scheduleGeometry encode), `AislopdeskVideoHostSession.swift:1637`/`:1800`, `WindowGeometryWatcher.swift:25`; client decode `VideoClientSessionLogic.swift:377`→ `AislopdeskVideoClientSession.swift:934` (applyGeometry).
- **Test target:** `window_geometry.rs` round_trips/rejects + golden_parity + Swift geometry codec tests.
- **Perf risk:** none (window-event rate, one small string copy on title path only).

### B4. CoordinateMapping (+ ScreenInfo)
- **Module:** `aislopdesk-core::coordinate_mapping`
- **FFI additions:** four pure scalar fns: `aisd_coord_window_point(nx, ny, ox, oy, w, h:f64, out_x:*mut f64, out_y:*mut f64)`; `aisd_coord_cg_rect_to_cocoa(x, y, w, h, primary_height:f64, out:*mut [f64;4])`; `aisd_coord_backing_scale_factor(win_x, win_y, win_w, win_h:f64, screens:*const AisdScreenInfo{repr(C): f64 x, y, w, h, scale}, count:usize, primary_height:f64, out_scale:*mut f64)->AisdStatus` (AISD_OK / `AISD_EMPTY` for no-overlap None); `aisd_coord_window_point_from_pixel(...)`. No handle, no owned buffers (screens array is borrowed in).
- **Swift call sites:** `InputInjector.swift:215` (`windowPoint` per injected pointer event).
- **Test target:** `coordinate_mapping.rs` (4 tests) + `Tests/AislopdeskVideoProtocolTests/CoordinateMappingTests.swift`.
- **Perf risk:** none (event rate; `windowPoint` is 2 mul + 2 add, FFI overhead dominates but is still trivially cheap and not per video frame).

### B5. AspectFit (+ VideoPoint/Size/Rect/ContentMode) — *split: event-rate uses only*
- **Module:** `aislopdesk-core::geometry`
- **FFI additions:** `aisd_aspect_displayed_video_rect(view_w, view_h, video_w, video_h:f64, mode:u8{0=fit,1=fill}, out:*mut [f64;4])`; `aisd_aspect_view_point(host_x, host_y, view_w, view_h, video_w, video_h, zoom, pan_x, pan_y:f64, mode:u8, out_x/out_y:*mut f64)`; and to move the input encoder, `aisd_aspect_normalize(view_x, view_y, ..., mode)->(nx, ny)` (the 0..1 inverse currently Swift-only on top of displayedVideoRect). VideoPoint/Size/Rect are repr(C) mirrors in the param lists, no FFI of their own. `intersection_area` stays internal.
- **Swift call sites to redirect (event-rate only):** `VideoClientSessionLogic.swift:424` (InputEventEncoder.normalize), `AislopdeskVideoClientSession.swift:71`/`:72`, `ClientCursorCompositor.swift:105`/`:108` (cursor overlay placement).
- **Swift call sites to LEAVE NATIVE:** `MetalVideoRenderer.swift:175` (displayedVideoRect per drawn frame, 60 Hz) — see KEEP-SWIFT.
- **Test target:** `geometry.rs` + `Tests/AislopdeskVideoProtocolTests/AspectFitTests.swift`.
- **Perf risk:** event-rate uses = none; **the per-frame renderer call must NOT cross FFI** (6-flop function per frame = pure overhead; the renderer also recomputes the same ratios inline in MSL).

### B6. InputEvent (+ InputModifiers, MouseButton)
- **Module:** `aislopdesk-core::input_event`
- **FFI additions:** `aisd_input_event_encode(kind:u8{1..7}, tag:u32, button:u8, click_count:u8, modifiers:u8, nx, ny, dx, dy:f64, key_code:u16, down:u8, text:AisdBytes(borrowed iff kind==6), out:*mut AisdBytes)`; `aisd_input_event_decode(data, len, out:*mut AisdInputEvent{kind, tag, button, click_count, modifiers, nx, ny, dx, dy, key_code, down, text:AisdBytes Rust-owned})`. Reject unknown button/type / non-finite / bad-UTF-8 via existing status codes; text freed by `aisd_bytes_free`. InputModifiers/MouseButton are just the u8 fields — no separate FFI.
- **Swift call sites:** client encode `AislopdeskVideoClientSession.swift:1042` (sendInput); host decode `AislopdeskVideoHostSession.swift:549` + `VideoSessionLogic.swift:272`, consumed at `InputInjector.swift:200-211`.
- **Test target:** `input_event.rs` round_trips/rejects + golden_parity + `CodecTests.swift`.
- **Perf risk:** none (scalar variants < 40 bytes; `.text` is one small copy). **Keep `InputEventEncoder` in Swift** (KEEP-SWIFT) — only the underlying `InputEvent.encode/decode` + `normalize` math swap.

### B7. VideoControlMessage — *scalar arms swap now; list arms bench-gated*
- **Module:** `aislopdesk-core::video_control`
- **FFI additions (scalar arms, swap now):** `aisd_video_control_encode(AisdVideoControl{type:u8, protocol_version:u16, requested_window_id:u32, viewport_w/h:f64, accepted:u8, stream_id:u32, capture_w/h:u16, bounds_x/y/w/h:f64, full_range:u8, desired_w/h:f64, epoch:u32, fps:u16}, out:*mut AisdBytes)` + matching `aisd_video_control_decode(data, len, out)`. Covers hello/helloAck/bye/resizeRequest/resizeAck/keepalive/listWindows/focusWindow/streamCadence/listSystemDialogs.
- **FFI additions (list arms, bench-gate — windowList/systemDialogList):** encode takes borrowed `*const AisdWindowSummary{id:u32, w:u16, h:u16, app:AisdBytes, title:AisdBytes}` array (caller caps to one datagram); decode returns Rust-owned out-array + count, freed by a new `aisd_window_summary_list_free` (per-record app/title AisdBytes are Rust-owned). Untrusted-count discipline already in the Rust codec (no reserveCapacity, per-record truncation throw).
- **Swift call sites:** host encode `VideoSessionLogic.swift:748`; host decode `AislopdeskVideoHostSession.swift:582`; client decode `VideoClientSessionLogic.swift:369`; client encode `AislopdeskVideoClientSession.swift:437/557/1097`; discovery `VideoWindowDiscovery.swift:44/93`.
- **Test target:** `video_control.rs` round_trip + golden_parity + `ResizeControlCodecTests`/`KeepaliveCodecTests`/`WindowListCodecTests`/`SystemDialogCodecTests`/`StreamCadenceCodecTests`.
- **Perf risk:** scalar arms = none (session-bringup rate). List arms = a small flat-array marshal, but lists are tiny (a handful of windows) and produced rarely (picker poll) → acceptable; still bench-gate the list marshal before flipping.

### B8. YCbCrConversion (+ ColorRange) — swap now, but cache the result
- **Module:** `aislopdesk-core::ycbcr`
- **FFI additions:** `aisd_ycbcr_coefficients(full_range:u8, out:*mut AisdYCbCrCoefficients{repr(C): f32 luma_scale, luma_bias, chroma_bias, cr_to_r, cb_to_g, cr_to_g, cb_to_b})`. Pure by-value, no handle, no owned buffer. ColorRange collapses to `full_range:u8`.
- **Swift call sites:** `MetalVideoRenderer.swift:199` (coefficients → 7-float shader uniform).
- **Test target:** `ycbcr.rs` + `Tests/AislopdeskVideoProtocolTests/YCbCrConversionTests.swift` (pins shader literals).
- **Perf risk:** function is per-rendered-frame today but returns by-value scalars (no buffer). **Mitigation: cache the coefficients on range-change and call the Rust selector once per negotiated range, not per frame** — the swap should also fix the redundant per-frame recompute.

---

# WAVE C — large-buffer codecs (wire / FEC / packetizer / reassembler / mux) — bench-gated

Every item here crosses a frame-sized or datagram-sized payload. The hard "no-perf-regression" constraint is the dominant gate: each must be benchmarked against the live 60fps full-screen-scroll (and, for the reassembler, a lossy 60fps stream) before the live path flips. The Rust counterparts are all byte/bit-exact-proven by golden vectors. Land the shared `AisdMuxFrame` struct + `aisd_mux_frame_free` first since two terminal items depend on it.

### C1. FrameReassembler (+ ReassembledFrame, ReassemblyResult) — strongest C candidate
- **Module:** `aislopdesk-core::reassembler` (+ `seq::distance_wrapped`, already exposed as `aisd_seq_distance`)
- **FFI additions:** opaque `AisdFrameReassembler`: `aisd_frame_reassembler_new(fec_off:u8, group_size:usize, fec_reorder_grace:i32)`, `_free`, `aisd_frame_reassembler_ingest(handle, datagram:*const u8, len:usize, out:*mut AisdReassemblyResult)->AisdStatus` where `AisdReassemblyResult` is repr(C) tagged `{kind:u8 (incomplete/completed/dropped/stale), frame_id:u32, keyframe/crisp/recovered_via_fec/is_ltr/acked_anchored:u8, avcc:AisdBytes}`; `aisd_frame_reassembler_next_dropped(handle, out_frame_id:*mut u32)->u8`. **Fold `FrameFragment.decode` inside** (accept RAW datagram bytes) so the per-datagram fragment decode never crosses as its own call. `XorParityFec` built internally from `fec_off`+`group_size` (no standalone FEC FFI). avcc freed via `aisd_bytes_free`.
- **Swift call sites:** `AislopdeskVideoClientSession.swift:170` (instance), `:351` (init), `:686` (`ingest(fragment)` → change to raw-datagram ingest), `:716` (`nextDroppedFrame()` drain).
- **Test target:** `Tests/AislopdeskVideoProtocolTests/FrameReassemblerValidationTests.swift` + reassembler.rs (FEC recovery, sweep, hostile-input) + fragment golden parity.
- **Perf risk:** per-datagram client RX hot path. Cost = one fragment IN per datagram + one AVCC frame OUT per completed frame (already an allocation in Swift today, so OUT is near-parity). Raw-datagram ingest avoids a second per-datagram copy. **Bench ingest throughput on a lossy 60fps stream before flipping.** Owns the most algorithmic complexity (loss-frontier sweep, FEC reorder grace, fragCount inversion, hostile-input bounds, retired-set pruning) — exactly what the Android core should own.

### C2. VideoPacketizer (+ FrameFragment encode, FEC, interleave folded in)
- **Module:** `aislopdesk-core::fragment::VideoPacketizer` (+ `interleaver::interleave` folded in, `fec` internal)
- **FFI additions:** opaque `AisdVideoPacketizer`: `aisd_video_packetizer_new(group_size:usize, fec_off:u8)`, `_free`, `_peek_next_frame_id(const)->u32` and `_peek_next_stream_seq(const)->u32` (non-mutating, for the LTR/recovery-IDR record-before-packetize race), `aisd_video_packetizer_packetize(handle, frame:*const u8, len:usize, AisdPacketizeOptions{keyframe, crisp, host_send_ts_millis:u32, fec_tier:u8, is_ltr, acked_anchored, interleave_group_size:usize /*0=no-op*/}, out_fragments:*mut AisdBytes)->AisdStatus` — out is a self-describing count-prefixed `[hdr|payload]*` buffer the host iterates, plus matching free. **Interleave folds in** via the opts field (no standalone `aisd_fragment_interleave`). FEC built internally.
- **Swift call sites:** `AislopdeskVideoHostSession.swift:350` (instance), `:441` (init), `:1522`/`:1529` (peekNextFrameID — map to non-mutating peeks), `:1532` (`packetize(...)`), `:1541` (FragmentInterleaver.interleave — fold into packetize opts).
- **Test target:** `Tests/AislopdeskVideoProtocolTests/FramePacketizerTests.swift` (incl XORParityFEC groupSize:4 case) + fragment.rs.
- **Perf risk:** per-encoded-frame host TX hot path. Each call copies a full AVCC frame IN (multi-MB keyframes) and every fragment header+payload OUT — a fresh per-frame copy of the whole frame's bytes. **The win is dubious vs the copy cost; bench against live 60fps scroll before committing.** Entangled with `peekNextFrameID` read on-actor before packetize → the non-mutating peeks are mandatory. Return one contiguous count-prefixed buffer to amortize marshaling.

### C3. Terminal mux: AisdMuxFrame struct + MuxEnvelopeCodec + MuxFrameDecoder (land struct first)
- **Module:** `aislopdesk-core::terminal::mux::envelope` and `::frame_decoder`
- **Shared FFI struct (land first):** flat `#[repr(C)] AisdMuxFrame{tag:u8 (MuxFrameType raw), channel_id:u32, session_id:[u8;16], last_received_seq:i64, channel_class:u8, accepted:u8, bytes_to_add:u32, payload:AisdBytes (channelData only)}` + `aisd_mux_frame_free` (frees the channelData payload). Reuses `AisdStatus` FrameTooLarge/Truncated/UnknownType/MalformedBody mapping already in `lib.rs`.
- **MuxEnvelopeCodec FFI:** `aisd_mux_envelope_encode(*const AisdMuxFrame, out:*mut AisdBytes)->AisdStatus`, `aisd_mux_envelope_decode(inner:*const u8, len:usize, out:*mut AisdMuxFrame)->AisdStatus`.
- **MuxFrameDecoder FFI:** opaque (structural twin of the proven `aisd_frame_decoder_*`): `aisd_mux_frame_decoder_new()`, `_free`, `aisd_mux_frame_decoder_append(handle, *const u8, usize)->AisdStatus`, `aisd_mux_frame_decoder_next(handle, out:*mut AisdMuxFrame)->AisdStatus` (`AISD_EMPTY` when no whole frame).
- **Swift call sites:** envelope encode/decode across `MuxNWConnection.swift` (openChannel/registerChannels/recordConsumed/route/closeChannel/acceptChannel) + `MuxRoutingCore.swift:route`; decoder instances `MuxNWConnection.swift:51`/`:52`, `ingest`(append), `nextFrame`.
- **Test target:** `Tests/AislopdeskProtocolTests/MuxEnvelopeCodecTests.swift` + `MuxFrameDecoderTests.swift`, end-to-end re-validated by `Tests/AislopdeskTransportTests/MuxLoopbackTests.swift` + `MuxConnectionLifecycleTests.swift`.
- **Perf risk:** channelOpen/Ack/Close/windowAdjust arms are tiny-scalar (safe); **channelData encode AND decode + the decoder's per-chunk drain are the flood hot path** that round-trips the up-to-32KiB output / 16KiB input payload. Swap only if the channelData payload can cross by move/borrow without an extra copy beyond the one Swift already does into the envelope; **bench per-chunk append+drain vs Swift first.** The lazy-compaction readOffset cursor is already ported and parity-proven.

### C4. ChannelTable / ChannelState — bench-gated, swap with MuxRoutingCore
- **Module:** `aislopdesk-core::terminal::mux::channel_table`
- **FFI additions:** opaque `aisd_channel_table_new`/`_free`; scalar `aisd_channel_table_allocate(handle)->u32`, `_open(handle, u32)`, `_reject(handle, u32)->u8`, `_local_close`/`_remote_close(handle, u32)->u8`, `_state_of(handle, u32, out:*mut u8)->AisdStatus` (`AISD_EMPTY` when nil), `_is_open(handle, u32)->u8`, `_state_count(handle)->usize`. ChannelState stable u8 constants `AISD_CHANNEL_IDLE/OPEN/HALFCLOSED/CLOSED`. `liveChannelIDs` (Set) is diagnostics-only — expose a count, skip the set.
- **Swift call sites:** `MuxNWConnection.swift:53-57`, `MuxNWConnection.swift:route/registerChannels`, `MuxRoutingCore.swift:route(_:in:&ChannelTable)`, `MuxRouter.swift:32`/`HostChannelRouter.swift:16`, `HostServer.swift:49` (relies on allocate starting at 1).
- **Test target:** `Tests/AislopdeskProtocolTests/ChannelTableTests.swift` + `MuxConnectionLifecycleTests.swift` + `MuxBugFixRegressionTests.swift`.
- **Perf risk:** lifecycle-frequency (channelOpen/Close, not per data frame) so FFI overhead is negligible — but it is stateful and `MuxRoutingCore.route(_:in: inout ChannelTable)` reads decision + mutates table in one Swift call. **Swap ChannelTable + MuxRoutingCore together**, or expose enough table primitives to reconstruct the routing decision Swift-side; do not swap the table alone and re-cross per route decision. terminal_ring eviction (R12 #1 DoS bound, cap 1024) is ported and parity-relevant.

---

# KEEP-SWIFT — must NOT be swapped (and why)

These are either zero-copy by nature (and lose that crossing the C ABI), hot per-pixel/per-frame paths where the FFI call is pure overhead, VideoToolbox/SCK/CADisplayLink-bound, inseparable from a held lock, dead code, or trivial constants whose only value is being the source of truth for the *non-Swift* shell.

- **FECScheme / XORParityFEC** — never an independent live call; only invoked inside VideoPacketizer (`parity`) and FrameReassembler (`recover`). Swap as an **internal detail** of the C2/C1 handles (Rust constructs `XorParityFec` from `fec_off`+`group_size`). Exposing `parity()`/`recover()` standalone would marshal whole fragment-arrays per frame for zero benefit. **Do not add `aisd_fec_parity`/`aisd_fec_recover`.**
- **FragmentInterleaver** — a pure permutation of the same `[FrameFragment]` array the packetizer just produced, on the host TX hot path. Standalone FFI = marshal the frame's fragments out, into interleave, back out — pure copy churn for an index shuffle. **Fold into VideoPacketizer's opts (`interleave_group_size`)**; no `aisd_fragment_interleave`.
- **NALUnit** — `split()` returns zero-copy `&[u8]` borrows into the input, which **cannot cross the C ABI without per-NALU copies**, defeating the point. Live use is the client's HEVC parameter-set extraction (config/keyframe boundaries, not per frame) + one integer constant `lengthPrefixSize=4` fed to VideoToolbox; `join()` has **no live call site**. The Rust `nal_unit` module exists for the Android client's own decoder feed, not a Swift swap.
- **FrameFragment (standalone)** — its only standalone live call (`FrameFragment.decode` at RX classify) runs once per received datagram on the hot receive loop; marshaling the datagram in + flattened header/payload out adds 1–2 copies/datagram. **Fold encode into VideoPacketizer (C2) and decode into FrameReassembler (C1)** behind one handle each; never expose it alone.
- **VideoMuxHeaderCodec / MuxFrameFragmentHeader** — VideoMuxHeaderCodec is a trivial 4-byte channelID prefix splice/strip on both hot paths; decode returns a zero-copy Swift `Data` slice today, so crossing FFI forces a full-payload copy for a 4-byte op = near-zero win. MuxFrameFragmentHeader is **not wired into the live transport** (the 15→19-byte folded-header migration hasn't flipped) — nothing to swap. Revisit only if the whole mux datagram path moves Rust-side later.
- **CursorShapeMessage** — carries a full PNG bitmap and fires rarely; the Swift path is a `Data` slice (no copy). FFI would copy the bitmap in AND back out for a non-hot message. Keep Swift; route to it from B2's first-byte dispatcher.
- **AspectFit — the renderer's per-frame call** (`MetalVideoRenderer.swift:175`) — `displayedVideoRect` once per drawn frame at 60 Hz for a 6-flop function; the renderer also recomputes the ratios inline in MSL. Crossing FFI per frame is pure overhead with no payload benefit. **Swap only the event-rate uses (B5); keep the renderer call native/inlined.**
- **InputEventEncoder** — the only mutable state is a single `&+= u32` tag counter, and the heavy math (`normalize`/AspectFit) is already a pure-math port (B5). An opaque Rust handle just to increment a counter that the SwiftUI view layer drives per gesture is all cost, no benefit. It is the view→event adapter, not a wire codec. Keep the tag-minting + view glue in Swift.
- **KeepaliveTiming** — three compile-time constants (5/30/5 s) with no logic. FFI ceremony buys nothing for the Swift app; the Rust consts exist as the source of truth for the Android/JNI shell. Keep Swift's copy on macOS/iOS.
- **FlowCreditPolicy / ConsumeResult** — one Int + a few branches mutated **inside the MuxSubChannel actor** on every credit-park decision, no allocation. An FFI hop per `consume()`/`remaining` on the send hot path adds boundary cost for trivially-correct, parity-proven arithmetic. Safe-scalar only if ported for Android; **keep-swift on the live app.**
- **ReceiveWindowAccountant** — receiver twin of FlowCreditPolicy: a single Int threshold accumulator in a per-channel Swift dictionary on the MuxNWConnection actor, consumed once per delivered batch. An opaque-handle-per-channel adds create/free lifecycle churn for half-window arithmetic. Keep-swift on the live app.
- **BoundedQueuePolicy** — mutated **while holding the PausableQueueGate NSLock** (FIX #3 lost-wakeup atomicity), its bool result drives pause/resume under that same lock. An FFI hop inside the held lock on the host PTY-read drain path is both a perf cost and an **atomicity hazard** (the gate's atomicity contract does not cross the boundary). Keep-swift.
- **MuxFlowControl constants** — env-resolved (`AISLOPDESK_MUX_*`) compile/launch-time constants read once at channel setup. Swapping forces the env-seam behind FFI for zero runtime benefit and risks the documented MUST-match-both-processes invariant. The Rust consts/resolvers exist for Android parity; **the env READ stays caller-side**. Keep Swift as the source of the env-tuned values on the live app.
- **DecodeSequencer — must NOT swap naively** — its API passes/returns `ReassembledFrame` carrying a frame-sized `avcc` buffer. A naive swap round-trips every frame's full payload through Rust just for an ordering decision it never reads (every in-order completion would copy in + copy out for nothing). **It is only swappable after a token-indirection redesign** (feed the scalar descriptor `frame_id, keyframe, opaque uint64 token`; return the ordered list of tokens to release; Swift submits the buffers it still holds — `aisd_decode_sequencer_note_completed(handle, frame_id, keyframe:u8, token:u64, out_tokens:*mut u64, out_cap:usize)->count`, same for `_note_lost`, plus `_next_expected`). That requires a token-keyed (generic-over-payload) sequencer variant in the core so avcc never crosses, plus a fresh Swift test asserting release-ORDER equivalence vs the buffer-carrying version. **Defer until that core variant exists; do not swap the buffer-carrying form.**

---

# Consolidated FFI growth — ALL new `extern "C"` functions, grouped by Rust module

Widen `rust/aislopdesk-ffi/src/lib.rs` and `rust/aislopdesk-ffi/include/aislopdesk_ffi.h` in one pass per wave. All reuse `AisdStatus`/`AisdBytes`/`aisd_bytes_free` and the jboolean→`u8` rule. New repr(C) structs are listed with their owning function group.

### Existing (already present — for reference)
`aisd_seq_distance`, `aisd_bytes_free`, `aisd_wire_message_encode/free`, `aisd_frame_decoder_new/free/append/next`.

### `network_estimate` (Wave A) — struct `AisdNetworkEstimateSnapshot`
- `aisd_network_estimate_new`, `aisd_network_estimate_fold`, `aisd_network_estimate_snapshot`, `aisd_network_estimate_free`, `aisd_compute_rtt_millis`

### `live_congestion_controller` (Wave A)
- `aisd_live_cc_new` (+ floor-explicit variant), `aisd_live_cc_decide`, `aisd_live_cc_current`, `aisd_live_cc_ticks`, `aisd_live_cc_is_material_change`, `aisd_live_cc_free`

### `fps_governor` (Wave A + A-deferred) — struct `AisdEncodeCadenceGate` (or value)
- `aisd_fps_gov_new`, `aisd_fps_gov_note_encoded_frame`, `aisd_fps_gov_on_tick`, `aisd_fps_gov_current_fps`, `aisd_fps_gov_free`, `aisd_fps_gov_congestion_evidence`, `aisd_self_heal_effective_every`
- `aisd_cadence_gate_new`, `aisd_cadence_gate_admit`, `aisd_cadence_gate_next_due`, `aisd_cadence_gate_free`

### `ltr_controller` (Wave A)
- `aisd_ltr_new`, `aisd_ltr_record_frame`, `aisd_ltr_ack_frame`, `aisd_ltr_recovery_decision`, `aisd_ltr_has_acked_token`, `aisd_ltr_reset`, `aisd_ltr_acked_tokens`, `aisd_ltr_free`

### `recovery_idr_policy` (Wave A)
- `aisd_recovery_idr_new`, `aisd_recovery_idr_new_default`, `aisd_recovery_idr_note_keyframe_sent`, `aisd_recovery_idr_note_keyframe_delivered`, `aisd_recovery_idr_decide`, `aisd_recovery_idr_available_tokens`, `aisd_recovery_idr_free`

### `recovery_request_deduper` (Wave A)
- `aisd_recovery_deduper_new`, `aisd_recovery_deduper_admit`, `aisd_recovery_deduper_free`

### `live_bitrate_policy` (Wave A)
- `aisd_live_bitrate_target`, `aisd_live_bitrate_minimum`

### `idle_reap_decider` (Wave A, monomorphized u32)
- `aisd_idle_reap_new`, `aisd_idle_reap_note_inbound`, `aisd_idle_reap_reap`, `aisd_idle_reap_forget`, `aisd_idle_reap_record`, `aisd_idle_reap_free`

### `recovery_policy` (Wave A)
- `aisd_recovery_policy_should_escalate_to_idr` (reuse already-ported `aislopdesk-core::recovery` for `initialRequest`)

### `adaptive_fec` (Wave A) — struct `AisdTierState`
- `aisd_adaptive_fec_group_size`, `aisd_adaptive_fec_tier`, `aisd_adaptive_fec_next_tier_state`

### `decode_frontier` (Wave A)
- `aisd_decode_frontier_new`, `aisd_decode_frontier_free`, `aisd_decode_frontier_note_decoded`, `aisd_decode_frontier_wire_value`

### `decode_gate` (Wave A)
- `aisd_decode_gate_new`, `aisd_decode_gate_free`, `aisd_decode_gate_note_loss`, `aisd_decode_gate_note_hard_decode_failure`, `aisd_decode_gate_note_awaiting_keyframe`, `aisd_decode_gate_verdict`, `aisd_decode_gate_note_decode_succeeded`, `aisd_decode_gate_mode`

### `owd_late_detector` (Wave A)
- `aisd_owd_late_detector_new`, `aisd_owd_late_detector_new_default`, `aisd_owd_late_detector_free`, `aisd_owd_late_detector_note`

### `trendline_estimator` (Wave A-deferred-bench + A8 sampler)
- `aisd_trend_sampler_new`, `aisd_trend_sampler_should_sample`, `aisd_trend_sampler_free`
- `aisd_trendline_new`, `aisd_trendline_note`, `aisd_trendline_is_stale`, `aisd_trendline_state`, `aisd_trendline_wire_trend_milli`, `aisd_trendline_wire_trend_flags`, `aisd_trendline_pack_trend_milli`, `aisd_trendline_pack_trend_flags`, `aisd_trendline_free`

### `pacer_depth_policy` (Wave A-deferred-bench) — struct `AisdPacerDepthConfig`, enum GapClass→i32
- `aisd_pacer_depth_policy_new`, `aisd_pacer_depth_policy_free`, `aisd_pacer_depth_note_arrival`, `aisd_pacer_depth_note_present`, `aisd_pacer_depth_note_network_late`, `aisd_pacer_depth_note_reshow`, `aisd_pacer_depth_set_interval_hint`, `aisd_pacer_depth_drain_counters`, `aisd_pacer_depth_depth`, `aisd_pacer_depth_expected_interval_seconds`, `aisd_pacer_depth_late_threshold_seconds`

### `cursor` (Wave B) — struct `AisdCursorUpdate`
- `aisd_cursor_update_encode`, `aisd_cursor_update_decode`, `aisd_cursor_channel_kind` (router; no shape FFI)

### `window_geometry` (Wave B) — struct `AisdWindowGeometry`
- `aisd_window_geometry_encode`, `aisd_window_geometry_decode`

### `coordinate_mapping` (Wave B) — struct `AisdScreenInfo`
- `aisd_coord_window_point`, `aisd_coord_cg_rect_to_cocoa`, `aisd_coord_backing_scale_factor`, `aisd_coord_window_point_from_pixel`

### `geometry` (Wave B — event-rate only; renderer stays native)
- `aisd_aspect_displayed_video_rect`, `aisd_aspect_view_point`, `aisd_aspect_normalize`

### `input_event` (Wave B) — struct `AisdInputEvent`
- `aisd_input_event_encode`, `aisd_input_event_decode`

### `video_control` (Wave B — scalar arms now; list arms bench-gated) — structs `AisdVideoControl`, `AisdWindowSummary`
- `aisd_video_control_encode`, `aisd_video_control_decode`, `aisd_window_summary_list_free`

### `ycbcr` (Wave B) — struct `AisdYCbCrCoefficients`
- `aisd_ycbcr_coefficients`

### `reassembler` (Wave C) — struct `AisdReassemblyResult`
- `aisd_frame_reassembler_new`, `aisd_frame_reassembler_free`, `aisd_frame_reassembler_ingest`, `aisd_frame_reassembler_next_dropped` (FrameFragment.decode + XorParityFec folded internal; reuses `aisd_seq_distance`)

### `fragment` (Wave C) — struct `AisdPacketizeOptions`
- `aisd_video_packetizer_new`, `aisd_video_packetizer_free`, `aisd_video_packetizer_peek_next_frame_id`, `aisd_video_packetizer_peek_next_stream_seq`, `aisd_video_packetizer_packetize` (FrameFragment.encode + FEC + interleave folded internal)

### `terminal::mux::envelope` + `::frame_decoder` (Wave C) — struct `AisdMuxFrame`
- `aisd_mux_frame_free`, `aisd_mux_envelope_encode`, `aisd_mux_envelope_decode`, `aisd_mux_frame_decoder_new`, `aisd_mux_frame_decoder_free`, `aisd_mux_frame_decoder_append`, `aisd_mux_frame_decoder_next`

### `terminal::mux::channel_table` (Wave C — swap with MuxRoutingCore) — consts `AISD_CHANNEL_IDLE/OPEN/HALFCLOSED/CLOSED`
- `aisd_channel_table_new`, `aisd_channel_table_free`, `aisd_channel_table_allocate`, `aisd_channel_table_open`, `aisd_channel_table_reject`, `aisd_channel_table_local_close`, `aisd_channel_table_remote_close`, `aisd_channel_table_state_of`, `aisd_channel_table_is_open`, `aisd_channel_table_state_count`

### Deferred until a core redesign exists (not in this FFI pass)
- `decode_sequencer`: `aisd_decode_sequencer_new/free`, `_note_completed`, `_note_lost`, `_next_expected` — **only after** a token-keyed (payload-free) sequencer variant lands so avcc never crosses.
- **Not to be added:** `aisd_fec_parity`/`aisd_fec_recover`, `aisd_fragment_interleave`, standalone `aisd_frame_fragment_encode/decode`, `aisd_nal_split`/`aisd_nal_join`, standalone `aisd_video_mux_encode/decode` + MuxFrameFragmentHeader, standalone CursorShape FFI, FlowCreditPolicy / ReceiveWindowAccountant / BoundedQueuePolicy / MuxFlowControl / KeepaliveTiming externs — all KEEP-SWIFT per the reasons above (they exist in the core only for the non-Swift Android shell).

---

# Execution order summary

1. **FFI pass 1 (Wave A):** add all scalar externs above (incl. `AisdNetworkEstimateSnapshot`, `AisdTierState`, `AisdPacerDepthConfig` structs). Land `network_estimate` + `live_bitrate_policy` before their consumers. Widen header, re-run C smoke (`-Werror`).
2. **Swap Wave A bodies** behind unchanged Swift APIs; re-run each Swift host/client test target (NetworkEstimate, LiveCongestionController, FPSGovernor, LTR, RecoveryIDR, RecoveryDeduper, LiveBitrate, IdleReap, RecoveryPolicy, AdaptiveFEC, DecodeFrontier, DecodeGate, OwdLateDetector, TrendSampler) — must stay green. **Re-run the full DecodeGate suite** (prior verify-the-verifier trap).
3. **Micro-bench the A-deferred per-frame items** (TrendlineEstimator, PacerDepthPolicy, EncodeCadenceGate) at 60/120 Hz; flip live wiring only if the per-call C-ABI cost is negligible. Otherwise keep Swift.
4. **FFI pass 2 (Wave B):** add the small-buffer codec externs + structs; widen header, re-run C smoke. Swap bodies; re-run CodecTests / geometry / coordinate / input-event / control / ycbcr targets. Cache YCbCr coefficients on range-change. Route CursorChannel to the kept-Swift CursorShape.
5. **FFI pass 3 (Wave C):** land `AisdMuxFrame` + `aisd_mux_frame_free` first, then reassembler / packetizer / mux externs. **Bench each on the live 60fps scroll (and lossy stream for the reassembler) BEFORE flipping the live path.** If any regresses, keep Swift. Re-run FrameReassembler/FramePacketizer/Mux*/Channel* test targets + loopback-validate.
6. **KEEP-SWIFT** items are never flipped; their Rust modules remain the source of truth for the Android shell only. DecodeSequencer waits on a token-keyed core variant before any swap.

Every wave preserves: (1) unchanged Swift public APIs → green test suite, (2) no buffer marshal flips without a passing bench → no perf regression, (3) implementation-only body swaps → minimal blast radius.