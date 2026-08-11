# CLAUDE.md

Non-derivable facts only. **`docs/46-gates-env-paths.md` = gate matrix, `SLOPDESK_*` env, three-path notes, golden procedure — read before picking a gate, touching a transport, or adding a flag.** Architecture: `docs/00-overview.md`; re-scoping → `docs/DECISIONS.md`; wire contract → `docs/20-wire-protocol.md` (update after wire changes); design language → `DESIGN.md`; shipping (sign/notarize/brew) → `docs/49-release-pipeline.md`.

SlopDesk = low-latency remote coding (macOS host, macOS/iOS clients). Swift owns the wire. Only C: `Sources/CSlopDeskSIMD` — GF(2⁸) NEON kernel + scalar fallback, wrapping `&*`/`&+` intentional, `GF256NeonDifferentialTests` pins NEON ≡ scalar (re-run + loopback-validate after kernel/hash edits). Only Rust: `rust/slopdesk-hook` — the Claude Code hook relay, a SEPARATE PROCESS with no FFI (`make hook`; gates `make lint-rust` / `make hook-test`; nightly only for `cargo fmt`). Clean checkout builds headless: `swift build`/`swift test` never see libghostty / VideoToolbox / ScreenCaptureKit — nor cargo.

## Gates

`make test-touched` after Swift edits (a partial green never warms the pre-push cache); `make test` before push. Every other path — FEC, iOS, launch restore, agent detect, GUI/video, multi-client, fan-out soak — has one dedicated script; match it in `docs/46` instead of guessing.

## Invariants

- **Wire is golden-pinned** — manual binary encode, big-endian, UUIDs 16 raw bytes. `scripts/golden-check.sh` after changes; never `>`-redirect the generator over `golden/golden_vectors.json` (`docs/46`).
- **Bit-exact floats** — keep `a * b + c` separate, never `addingProduct`/`fma`; `Double.maximum`/`.minimum`, not `<`/`>` ternaries; `==` only in test pins.
- **Untrusted UDP: validate-then-drop** — decoders optional/throw; C bools as `byte != 0`.
- **FEC `m == 1` ≡ old XOR**, byte-identical.
- **Hang-safety** — never create `SCStream`, `VTCompressionSession`, `VTDecompressionSession` or a Metal device in unit tests.
- **No app-layer crypto/auth** — security is the WireGuard mesh; do not reintroduce pairing/tokens.
- **Hook relay = compiled binary, sync, both Pre AND PostToolUse** — the cost was fork (3 processes), never the AF_UNIX round-trip (11µs). Do NOT detach it (ordering is meaning) and do NOT drop `PostToolUse` (it resolves the `AskUserQuestion` block and keeps `lastAuthoritativeAt` fresh). AF_UNIX `SO_SNDBUF` defaults to 8KB on macOS vs TCP's 128KB — raise it before moving any BULK path to a unix socket, or it gets ~3× slower (`docs/DECISIONS.md` 2026-08-10).
- **Three paths never merge** — terminal TCP / video UDP / inspector TCP: separate transport, message set, version `1`, no negotiation.
- **ONE appearance** — ground cream `#FFFBEB`, terminal island glass `#22212C`, chrome = macOS native semantic colors. The theme system is terminal-profile-only; the theme picker was deleted. Do not reintroduce an appearance setting or hand-rolled chrome palettes (`DESIGN.md`).
- **Client-UI dimensions go through `Slate` tokens** — raw `.font(.system(size:))` / `cornerRadius:` literals under `Sources/SlopDeskClientUI` fail `make lint`.
- **No `.keyboardShortcut` in `WorkspaceCommands.swift`** — `WorkspaceKeyDispatcher`'s NSEvent monitor owns chords (a menu shortcut double-fires and eats prefix follow-ups).
- **Multi-client sync has NO toggle** — workspace document and PTY fan-out are unconditional; do not reintroduce `SLOPDESK_WORKSPACE_DOC` / `SLOPDESK_PANE_FANOUT`.
- **Commit subjects are release input, not prose** — the conventional-commit TYPE decides the version bump (`git cliff --bumped-version`) AND the `CHANGELOG.md` section, so an off-grammar subject contributes to neither, silently. Gated at `commit-msg` by `scripts/check-commit-msg.sh`. Never hand-edit `CHANGELOG.md` or bump a version by hand: `make release` (→ `scripts/cut-release.sh`) owns the version, the notes, all six version sites, the commit and the tag; `scripts/bump-version.sh` alone if only the version is wrong. `cliff.toml` deliberately skips almost nothing — git-cliff drops a release whose commits were ALL skipped, header included, and `changelog-section.sh` then fails on a version that really shipped (`docs/49`).
- **Panel runtime deps are PINNED, not brewed** — `code-server`/`baguette`/`adb`/`scrcpy-server` in `ThirdParty/tools/tools.lock` (URL + SHA-256), `make provision` → `.prefix/bin`, which outranks `PATH`. hostd only ever STATS — it never downloads. The `scrcpy-server` jar is COMMITTED (`ThirdParty/tools/vendor/`, reversing the old "never in this repo" rule). iOS simulators and the Android emulator are NOT vendorable (Xcode / `sdkmanager` licence, GB-scale) — do not try. `docs/46`.

## Traps

- prek fails on partial pathspec commits — commit related files together
- `pkill` can leave a host on the port — check orphans before loopback tests
- No contiguous secret literals in fixtures (GitHub push protection) — assemble at runtime
- A test calling `HostServer.start()` must set `SLOPDESK_WORKSPACE_STATE_DIR` or inject `workspaceStore:`, else it overwrites the real workspace
- The client app is SANDBOXED — its real state lives in `~/Library/Containers/com.slopdesk.client.macos/Data/`, not `~/Library/Application Support/SlopDesk` (that one belongs to hostd/CLI/tests)
- Client-app verification builds must pass `CODE_SIGNING_ALLOWED=NO` — a signed build is sandboxed, so `defaults` writes are invisible
- VT HEVC: no `max_ref_frames=1` (all-IDR); no `UsingHardware…` query under low-latency RC (`-12900`); no Lossless key; `DataRateLimits` = bitrate/8
