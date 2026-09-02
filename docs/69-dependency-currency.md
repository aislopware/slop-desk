# 69 — Dependency currency, and the wheels that are not wheels

An audit taken 2026-09-02 across every pinned thing this repo builds on: the Rust crates, the two
ghostty pins, the Swift packages, the host-side tool lock, and the toolchains. Written down because
the RESULT is "nothing to bump", and a null result nobody recorded is a null result somebody pays to
re-derive.

Read `docs/46-gates-env-paths.md` for the pins' gates, `docs/68` §4 for what the two ghostty pins
are, and `ThirdParty/tools/tools.lock`'s own header for what the tool lock is for.

## 1. What was checked, and how

Registry latest came from deps.dev, not from memory — a model's idea of "the latest version" is a
snapshot of its training window and is wrong by construction on a tree that tracks upstream. Locked
versions came from the `Cargo.lock` of all 17 workspaces, not from the manifests: a caret range says
what is *allowed*, and only the lock says what is *built*.

## 2. Result — every pin is at upstream latest

**The 44 crates.io dependencies.** Locked version equals registry latest for every one. Not "within
a caret" — equal.

| | |
| --- | --- |
| `serde` 1.0.229 · `serde_json` 1.0.151 · `nix` 0.31.3 · `libc` 0.2.189 · `regex` 1.13.1 | `base64` 0.23.1 · `socket2` 0.6.5 · `sha2` 0.11.0 · `rayon` 1.12.0 · `toml` 1.1.4 |
| `unicode-segmentation` 1.13.3 · `percent-encoding` 2.3.2 · `zip` 8.6.0 · `tar` 0.4.46 | `flate2` 1.1.10 · `libz-sys` 1.1.29 · `xattr` 1.6.1 · `ureq` 3.4.0 · `png` 0.18.1 |
| `rtrb` 0.4.0 · `cpal` 0.18.2 · `git2` 0.21.0 · `sha1_smol` 1.0.1 | `objc2` 0.6.4 · `dispatch2` 0.3.1 · `block2` 0.6.2 · the 19 `objc2-*` framework crates at 0.3.2 |

The `objc2` family's `=` pins are the only ones that could have gone stale silently — an exact pin
does not float — and all 22 are at latest. They stay exact: the family shares a generated ABI
surface and moves together or not at all.

**The two ghostty pins, and why they are ONE pin.** `libghostty-vt` is pinned at
`aislopware/libghostty-rs@5988a0b7`, which is byte-identical to `uzaaft/libghostty-rs`' master head
— the mirror carries nothing of ours, as `docs/68` §4 records. The `ghostty` record in
`tools.lock` is `22d13172`, and that is not an independent choice: `libghostty-vt-sys`'s `build.rs`
declares `const GHOSTTY_COMMIT: &str = "22d13172cde…"`, so the bindings are generated against that
tree and `GHOSTTY_SOURCE_DIR` must point at that tree. Upstream ghostty has moved on since
2026-08-06, and **bumping it alone would be a bug, not an upgrade** — it is what
`slopdesk-invariants`' `engine-pin-agree` exists to refuse. The engine moves when the bindings move.

**The Swift packages.** `Defaults` 9.0.9, `SFSafeSymbols` 7.0.0, `swift-syntax` 603.0.2 — each at
its own latest, and 603 is the release train that matches `swift-tools-version:6.3`. Both of the
first two are really used (9 and 60 files); `swift-syntax` is fetched by `Defaults`' macro target
and linked into nothing, which `Package.swift` already documents at the dependency.

**The tool lock.** `baguette` 0.1.97 and `scrcpy-server` 4.1 are each upstream's newest release, and
`adb` 37.0.1 is the newest `platform-tools` Google publishes. `code-server` 4.135.0 was deliberately
**not** audited: it is removed after this release (`docs/DECISIONS.md`, the native editor), so a
version answer about it is work with no consumer.

**The toolchains.** Rust edition 2024 with resolver 3 and no `rust-toolchain.toml`, which is the
ruling rather than an omission — nightly always tracks latest, and `nightly-is-never-pinned-to-a-date`
ratchets it. Swift tools 6.3. Zig 0.16, which is what the ghostty pin needs and what the machine has.

## 3. The reinvented wheels, and why each one is not

Five places in the tree implement something a crate could have supplied. Each was checked against
the crate it would replace, and each has a reason written where it lives. None is a candidate for
deletion, and this section exists so the next audit does not have to re-derive that.

| Where | The "wheel" | Why the crate loses |
| --- | --- | --- |
| `slopdesk-sanitize::vtscan` | a VT escape scanner beside `libghostty-vt` | it scans a byte stream with **no terminal attached** — the replay transform runs over retained bytes before any engine exists. An engine cannot answer "what is in these bytes"; it answers "what did they do to a grid". |
| `slopdesk-altscreen` | alt-screen tracking | same shape one layer down: it is handed the bytes an evictor is DROPPING and must name the DECSET that re-opens the beheaded segment. There is no grid at eviction time and no engine to ask. |
| `slopdesk-ids::json` | a JSON writer beside `serde_json` | escaping is byte-exact against two persistence files, and `serde_json` was **measured** to disagree on three escapes. The crate also promises zero dependencies to callers on the wire decode path. |
| `slopdesk-rowscan` | nothing — it EXISTS to take `regex` | the inverse case, and the one that proves the rule is applied: patterns a human typed run against text a remote program wrote, so the linear-time engine is the requirement and the crate boundary is what lets `slopdesk-terminal` and `slopdesk-sanitize` keep their no-dependency promise. |
| every CLI's `std::env::args` | `clap` | the `rust/Cargo.toml` header is the argument: these binaries are forked **per event** — the hook twice per tool call, `slopdesk` once per keystroke — and the release profile is `opt-level = "z"` + `lto` for exactly that. Startup is the whole cost. |

The tree's *absent* dependencies are the same kind of decision: no async runtime, no `anyhow`, no
`tracing`. Proposing one is proposing a different product, not a cleanup.

## 4. How to re-run this

Registry latest for the Rust set, in one call, is a deps.dev query over the union of the manifests:

```sh
grep -rhE '^[a-z0-9_-]+ *= *(\{|")' rust/*/Cargo.toml | sed 's/ *=.*//' | sort -u
```

Locked versions, which are what actually build:

```sh
grep -rhA1 '^name = "<crate>"$' rust/*/Cargo.lock | grep '^version'
```

The ghostty pair must be checked as a pair, and the check is mechanical: `tools.lock`'s `ghostty`
digest, `rust/.cargo/config.toml`'s `GHOSTTY_SOURCE_DIR` and `libghostty-vt-sys`'s `GHOSTTY_COMMIT`
are one value in three places. `just lint-invariants` holds the first two against each other; the
third is upstream's and moves only with the `rev`.
