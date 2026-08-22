# CLAUDE.md

SlopDesk — low-latency remote coding: a macOS host (`slopdesk-hostd`), macOS/iOS clients, and six
Rust sidecar daemons. `make help` lists every build, lint and test target; read it rather than
guessing one.

## Read before you touch

| Working on | Read first |
| --- | --- |
| anything | `docs/00-overview.md` |
| a gate, a transport, a `SLOPDESK_*` flag | `docs/46-gates-env-paths.md` |
| agent status detection | `docs/50-agent-detection-architecture.md` |
| a sidecar daemon | `docs/51` superd · `52` screend · `53` dropd · `54` inspectord · `48` androidd |
| the wire | `docs/20-wire-protocol.md` — update it after wire changes |
| Rust that Swift calls in-process | `docs/55-ffi-boundary.md` — the ABI, the artifact, the stale gate |
| an Apple framework from Rust | `docs/57-apple-frameworks-in-rust.md` — the `objc2` family and its bar |
| client UI | `DESIGN.md` |
| release, signing, brew | `docs/49-release-pipeline.md` |
| why something was scoped out | `docs/DECISIONS.md` |

## Rules

- **`make quick` after every edit; `make check` once before pushing.** `quick` is `check` with the
  full suite swapped for `test-touched` (the test targets whose closure contains the change, and the
  full suite whenever a path cannot be attributed) and Miri omitted. Both are cheap on a warm tree
  because the two expensive gates are CONTENT-STAMPED, not re-run: `build-ffi.sh` against the Rust
  sources it links, `check-ios.sh` against every input the iOS triple compiles. `--force` on either
  re-runs it when the stamp itself is in doubt. A *touched-target* green never writes the pre-push
  green-tree marker — only a full suite on a clean tree does — so `quick` cannot make a push skip
  what it did not run.
- **Rust is the default; perf parity is enough to move existing Swift.** Only SwiftUI/AppKit
  justifies staying in Swift. A *measured* regression is the only veto.
- **A port ships over a socket, or as a linked library — pick by lifetime.** A component that must
  outlive its caller, be `execve`d, or be dialled by two processes is a binary on a socket; one that
  is in-process by necessity and lifetime-coupled to its caller is an `.xcframework`, the way
  `libghostty` and `CSlopDeskFFI` already are. **cargo never runs inside `swift build`** — the
  artifact is built by `make ffi` (`scripts/build-ffi.sh`) beforehand, never by a build plugin that
  shells out. A linked port has one failure mode a socket port does not: an artifact older than its
  sources, green tests and all. `build-ffi.sh --check` is in `make lint` for exactly that, and it
  derives its own inputs — a wrapped crate is covered by its `path = "../…"` edge to the shim, not
  by a list anyone maintains. See `docs/55-ffi-boundary.md`.
- **One implementation, never two languages.** Porting means deleting the original in the same
  change: not a fallback, not a test fake, not a cross-language mirror fixture.
- **Three crates may HAND-WRITE `unsafe`, each about one thing** — `rust/slopdesk-posix` (a syscall
  with no safe wrapper), `rust/slopdesk-ffi` (is this `(ptr, len)` from Swift live for the call) and
  `rust/slopdesk-gfsimd` (does this 16-byte load stay inside its chunk). A fourth dissolves the
  isolation; adding one is a design change, not a convenience, and the bar the third cleared is the
  bar: a *measured* conflict where safe Rust cannot reach parity, paid for by a crate small enough to
  read in a sitting and a differential suite that runs under Miri. Inside any of them, carry the
  obligation that makes the code sound and nothing else: if the safety comment cannot be written
  without naming slopdesk, the boundary is in the wrong place, so move the *operation* until the
  obligation is local. Never lower a crate to `deny` to fit code in.
- **`slopdesk-apple-*` is the one other family allowed `unsafe`, and only through `objc2`.** A crate
  in it wraps exactly ONE Apple framework area, calls it through the `objc2` bindings, and may not
  hand-write a raw-pointer dereference or a transmute — if a call needs one, the obligation belongs
  in one of the three crates above and the operation moves there. The one admission is
  `CFRetained::from_raw`, at most ONE site per crate, for a Copy/Create-rule out-parameter that
  `objc2` hands over raw; the count is gated, and any other `from_raw` is still barred. Most of what
  these crates call is `safe` in the bindings already, so `unsafe` here means "the framework's own
  contract", never "Rust's". Each carries `#![deny(unsafe_op_in_unsafe_fn)]`, a `# Safety` note per
  `unsafe` block naming the framework rule it satisfies, and a leak test. This family exists because
  the goal is Swift-as-UI-only: every effect on the system — capture, encode, injection, IOKit, the
  accessibility tree — is Rust's. See `docs/57-apple-frameworks-in-rust.md`. Every crate outside these
  two families is `forbid(unsafe_code)`, which no downstream `allow` can lift.
- **Never `pkill` the host** — `make host-restart` replays hostd's recorded launch exactly. There is
  no live config reload; the restart is the reload.
- **superd owns `read` on every PTY master.** A second reader anywhere steals bytes rather than
  observing them. Tests read through `PaneOutput`.
- **The wire is golden-pinned** — never `>`-redirect the generator over `golden/golden_vectors.json`.
- **No app-layer crypto or auth** — security is the WireGuard mesh. Do not add pairing or tokens.
- **Bit-exact floats** — keep `a * b + c` separate (never `addingProduct`/`fma`); use
  `Double.maximum`/`.minimum`, not `<`/`>` ternaries.
- **Commit subjects are release input** — imperative, ≤72 chars, conventional-commit type. The type
  picks the version bump; the subject lands verbatim in the changelog. Never hand-edit
  `CHANGELOG.md` or bump a version by hand; `make release` owns every version site.

`make lint-supervisor` (`scripts/check-supervisor.sh`) ratchets the cross-language contracts — which
Swift files must stay deleted, socket paths, relinquish-vs-terminate. Its failure messages name the
doc section, so those rules are not restated here.
