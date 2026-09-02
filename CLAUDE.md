# CLAUDE.md

SlopDesk — low-latency remote coding: a macOS host (`slopdesk-hostd`), macOS/iOS clients, and six
Rust sidecar daemons. `just help` lists every recipe; read it rather than guessing one. The one
bootstrap this tree needs is `brew install just`.

## Read before you touch

| Working on | Read first |
| --- | --- |
| anything | `docs/00-overview.md` |
| a gate, a transport, a `SLOPDESK_*` flag | `docs/46-gates-env-paths.md` |
| a setting, `config.toml`, the schema | `docs/58-configuration.md` — there is NO settings GUI |
| agent status detection | `docs/50-agent-detection-architecture.md` |
| a sidecar daemon | `docs/51` superd · `52` screend · `53` dropd · `54` inspectord · `48` androidd |
| the wire | `docs/20-wire-protocol.md` — update it after wire changes |
| Rust that Swift calls in-process | `docs/55-ffi-boundary.md` |
| an Apple framework from Rust | `docs/57-apple-frameworks-in-rust.md` |
| why hostd's socket has the shape it has | `docs/59-hostd-projection.md` — historical: the Swift projection it replaced. `MuxChannelSession` and `HostServer` are deleted (`docs/60` F.9) |
| hostd's socket, or Swift you think must stay | `docs/60-hostd-in-rust.md` |
| the terminal surface | `docs/68-terminal-surface-in-rust.md` — §6.4–6.5 are the ghostty conformance sweeps |
| a recorded TUI session | `rust/slopdesk-vterm/corpus/README.md` — frames are inputs not goldens, but the recorded INPUT bytes are pinned; `slopdesk-ttyrec` records all four kinds |
| bumping ANY dependency or pin | `docs/69-dependency-currency.md` — audited 2026-09-02, all at latest |
| re-auditing the tree, or a finding that looks new | `docs/70-codebase-audit-2026-09.md` — what the 2026-09-02 pass fixed, rejected with evidence, and ratcheted |
| video smoothness, `--fps`, the encode-load pacer, vsync | `docs/71-video-smoothness-2026-09.md` — the `just gui-smooth` harness and every 2026-09-02 number; the 30 fps default is NOMINAL |
| client UI | `DESIGN.md` |
| the iOS/iPadOS client | `docs/62-phone-uikit.md` |
| release, signing, brew | `docs/49-release-pipeline.md` |
| why something was scoped out | `docs/DECISIONS.md` |

## Rules

- **`just quick` after every edit; `just check` once before pushing.**
- **Rust is the default.** Only AppKit/UIKit justifies staying in Swift. A *measured* regression is
  the only veto.
- **One implementation, never two languages.** Porting deletes the original in the same change — not
  a fallback, not a test fake, not a cross-language mirror fixture.
- **`unsafe` lives in five crates and nowhere else.** Hand-written in `slopdesk-posix`,
  `slopdesk-ffi` and `slopdesk-gfsimd`; through `objc2` only in the `slopdesk-apple-*` family. A
  sixth is a design change, not a convenience — see `docs/57`. Everything else is
  `forbid(unsafe_code)`.
- **Never `pkill` the host** — `just host-restart` replays hostd's recorded launch. The restart is
  the config reload; there is no live one.
- **superd owns `read` on every PTY master.** A second reader steals bytes rather than observing
  them. Tests read through `PaneOutput`.
- **The wire is golden-pinned** — never `>`-redirect the generator over `golden/golden_vectors.json`.
- **No app-layer crypto or auth** — security is the WireGuard mesh. Do not add pairing or tokens.
- **Bit-exact floats** — keep `a * b + c` separate (never `addingProduct`/`fma`); use
  `Double.maximum`/`.minimum`, not `<`/`>` ternaries.
- **Commit subjects are release input** — imperative, ≤72 chars, conventional-commit type. Never
  hand-edit `CHANGELOG.md` or bump a version by hand; `just release` owns every version site.

`just lint-invariants` ratchets the cross-language contracts and each failure names its doc section,
so those rules are not restated here. `just lint-reach` covers what no rule can decide by reading:
what a recipe would RUN, and whether a linked artifact is older than its sources.
