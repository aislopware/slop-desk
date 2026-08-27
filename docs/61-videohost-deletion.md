# 61 — Deleting `Sources/SlopDeskVideoHost`

`CLAUDE.md` says a port deletes its original in the same change. This tree is the ONE place that
rule is deferred, and this file is why it is safe to defer it and what the deferral owes.

The reason is arithmetic, not preference. `SlopDeskVideoHostSession.swift` is 2051 code lines and is
the only thing that OWNS the other 46 files — the capturer, the encoder, the packetizer, the
injector and the window feed are all reached through it and through nothing else. Deleting the tree
before that file is ported would delete a working daemon and leave nothing that serves; deleting it
one file at a time would mean a fallback, a shim or a cross-language mirror at every step, each of
which `CLAUDE.md` names by name. So the tree goes in ONE commit, with the session, and every row
below has to be green in that same commit.

**The Rust side is landing meanwhile.** `rust/slopdesk-videohostd` already holds the argv grammar,
the settings overlay, `--list`, the UDP mux and the encoder's lifetime. None of it is reachable from
Swift, by design: no FFI door was added for any of it, so there is no bridge to unpick later.

## §1 The cascade — everything that must move in the deletion commit

| # | What | Where | What it needs |
| --- | --- | --- | --- |
| 1 | `SlopDeskVideoHostSession.swift` | `Sources/SlopDeskVideoHost/` | the port itself: 2051 lines, the keystone |
| 2 | the `SlopDeskVideoHost` library product | `Package.swift:121` | deleted |
| 3 | the `SlopDeskVideoHost` target | `Package.swift:699` | deleted |
| 4 | the `slopdesk-videohostd` executable target | `Package.swift:811-817` | deleted — the Rust binary is the daemon |
| 5 | `slopdesk-perfbench` | `Package.swift:832-836` | dissolve or retarget onto the Rust encoder. It drives `VideoEncoder` + `VideoDecoder` + the packetizer at real host configs, and every one of those is Rust already |
| 6 | `slopdesk-framewatch` | `Package.swift:840` | it has NO `SlopDeskVideoHost` edge — an SCK capture that logs arrival timestamps. `rust/slopdesk-apple-sck` covers it; retarget or dissolve on its own merits |
| 7 | `SlopDeskVideoHostTests` | `Package.swift:1071` | deleted with its target |
| 8 | the `apple_floors` rules that name the tree | `rust/slopdesk-invariants/src/rules/apple_floors.rs:35,188,358,405,575,583` | each names a path under `Sources/SlopDeskVideoHost/` or `Sources/slopdesk-videohostd/`. A rule whose subject is deleted must be RE-AIMED at the Rust that replaced it, never merely dropped — and its break-test with it |
| 9 | the devtools GUI's video page | `rust/slopdesk-devtools/src/gui/mod.rs`, `gui/video.rs` | check whether they name the Swift target or only the daemon's socket |
| 10 | `EnvBridge.loadDefaultSidecarIntoEnvConfig` | Swift client side | the daemon's `setenv` fold. `crate::env::Overlay` replaced it; the Swift call site dies with the launch path |
| 11 | `docs/00` and `docs/01` | prose | the "genuinely left to Swift: Network.framework" line is no longer true of this path |
| 12 | the four `slopdesk-videohostd` names in `STRANDED_RUST_MODULES` | `rust/slopdesk-invariants/src/rules/repo_invariants.rs` | `encode`, `feed`, `mux_registry` and `windowgeometry` are registered DEBT, not exemptions. The session port is what reaches them, so all four leave the list in this commit — removing a name is the last step of finishing the port, never a step of its own |
| 13 | the `drag-cadence-ratchet` rule | `rust/slopdesk-invariants/src/rules/window_placement.rs` | it pins `WindowGeometryWatcher.swift`'s poll cadence to `windowgeometry.rs`'s. Its Swift subject dies here, so it is re-aimed or dropped WITH its break-test, the same way row 8 treats `apple_floors` |

## §2 The one architectural debt the port deliberately took on

`rust/slopdesk-videohostd` depends on `slopdesk-ffi`, which is the Swift shim crate, and that edge
would be wrong in any other daemon. It is there because `slopdesk-ffi::encoder` holds the ENCODER
DRIVER, and the driver holds one `unsafe` obligation that is legal in exactly three crates: HEVC
parameter sets have no copy-out variant in the SDK, so `slopdesk-apple-vt` answers them as
`(ptr, len)` values and the single `slice::from_raw_parts` that lays them in front of a slice is made
in `slopdesk-ffi`, whose whole remit `docs/57` §2 states is that question.

Three ways out were checked and two fail on the repo's own terms:

- **A crate of its own for the driver.** A fourth hand-written-`unsafe` crate. `CLAUDE.md` admits one
  only for a MEASURED perf conflict; this is code organisation, so it does not clear the bar.
- **Put the driver in `slopdesk-videohostd`.** That crate is `forbid(unsafe_code)` like every crate
  outside the two families. The slice cannot be written there at all.
- **Amend `docs/57`'s buffer paragraph to give `slopdesk-apple-vt` the exemption
  `slopdesk-apple-audio` has.** This is the one that works — but not yet. The audio exemption was
  granted only because that crate's "move the obligation to `slopdesk-ffi`" escape hatch was a
  dependency CYCLE. For `slopdesk-apple-vt` the hatch exists and is already taken, so the doc's own
  three-route test rejects the amendment while `slopdesk-ffi` is still the natural home.

It stops being the natural home the moment the C doors die — which is this deletion. So the
amendment belongs in THIS commit, and it is three edits:

1. `slopdesk-apple-vt` gains ONE `copy_parameter_sets_into(&mut Vec<u8>)` site, written the way
   `copy_payload_into` already is, and `docs/57`'s buffer paragraph names it and says why.
2. The driver moves out of `slopdesk-ffi` into a `forbid(unsafe_code)` crate the daemon owns.
3. `CSink`, `CallerContext`, `SlopDeskEncodedFrameFn` and the whole `extern "C"` half of
   `encoder.rs` are deleted, along with their declarations in `slopdesk_ffi.h` — including the
   third-convention paragraph in the header, whose subject is those doors and nothing else.

`rust/slopdesk-videohostd/Cargo.toml` carries this note on the edge itself, so the person who
deletes the Swift finds it without reading this file first.

## §3 What the Rust daemon still owes before the commit can be written

Ported: the argv grammar, the settings overlay, `--list`, the UDP mux and its lane registry, the
encoder's lifetime and its four encode paths, and the whole WINDOW FEED — the census
(`windowsource`), the budgeted accessibility probe (`windowprobe`), the four placement sequences
(`windowplace`), the drag/union poll cadence (`windowgeometry`) and the feed loop over them
(`feed`).

Not yet: the session itself, `VideoSessionLogic`, `LiveCongestionController`, `FPSGovernor`,
`VideoSendLane`, `VirtualDisplay` and its recovery policy, `CursorSampler`, `HostPrivacyBlank`,
`OffScreenWindowMintRescue`, `AudioStreamEncoder`, `LTRController`, and the `--vd-sck-probe`
one-shot. The capture half — an `SCStream` the daemon owns — is the reason `encode`, `feed`,
`mux_registry` and `windowgeometry` are registered in `STRANDED_RUST_MODULES` rather than composed
in `main.rs`: wiring them today builds a daemon that binds its sockets and serves no frames, which
no gate can tell from an idle one.
