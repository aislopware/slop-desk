# Strict formatter / linter / static-analysis entrypoints for the whole repo.
# Configs: .swiftformat .swiftlint.yml .shellcheckrc rust/rustfmt.toml rust/Cargo.toml
#
#   just fmt    — auto-format everything (writes)
#   just fix    — fmt + apply every safe lint autofix (writes)
#   just lint   — run every linter strictly, no writes (what CI gates on)
#   just check  — lint + build + test + Miri + golden pin + the iOS triple (the full local gate)
#
# Tools are pinned/installed via `just install-tools`; `just` itself is the one bootstrap
# (`brew install just`), because nothing in this file can install the runner reading it.
# Swift + Rust: two short-lived programs in
# the root workspace (rust/slopdesk-hook, the Claude Code hook relay + its installer — stage 23;
# rust/slopdesk-probe, the host metadata RPC's git/directory/session half + the TERM
# resolution — stages 24 and 25;
# rust/slopdesk-ctl, the
# agent-control CLI; rust/slopdesk-cli, the whole `slopdesk` CLI process — stage 16; rust/slopdesk-codeseed,
# the code panel's workbench profile — stage 22), six daemons and eight library workspaces
# (rust/slopdesk-wire, the terminal wire codec + the replay buffer + the OSC
# vocabulary — stages 1, 14 and 16; rust/slopdesk-video, the PATH-2 FEC math — stage 5;
# rust/slopdesk-ids, the leaf the document is spelled in — pane and tab identity, the JSON writer,
# shell quoting — with no dependency of its own; rust/slopdesk-tree, the workspace DOCUMENT proper —
# geometry, the split tree, sessions, focus and the tree operations — over that leaf;
# rust/slopdesk-settings, the settings catalogue, its layout and its rows, also a leaf;
# rust/slopdesk-workspace, what is left once those three are carved out: the client's remaining
# surfaces — folder frecency, the git line, the phone keyboard, what the host may listen on —
# stages 12, 16 and 17; rust/slopdesk-agent, per-pane agent detection — stages 13
# and 16; rust/slopdesk-terminal, the client's read of the output stream for the input surface, the
# grid's links and the command blocks — stages 15 and 18), each its own workspace. Stages 19 to 21
# added no crate: they moved the generated ZDOTDIR shim into superd, which owns the child whose
# lifetime that directory has, and then BOTH of the host's per-byte readers into superd's PUMP —
# the one place a pane's bytes exist before anyone else sees them. hostd now receives the ANSWER on
# a 0x04 frame (the out-of-band sniff) and a 0x05 frame (the OSC 133 command blocks) instead of
# rescanning every byte in Swift, and superd holds each finished command's output — a ring in hostd
# died on every rebuild (docs/51 §6.13-6.14). Stage 22 moved the code-server PROFILE — the seeded
# settings, both seeded extensions and their registry, the child's argv and environment, the
# resource files themselves — out of hostd and behind `slopdesk-codeseed`, a program hostd FORKS
# rather than dials: every question it asks is asked at most once per boot.
# Every DAEMON is still a separate process over a socket. What changed is the other half of the rule
# in CLAUDE.md — "a port ships over a socket, or as a linked library, pick by lifetime": the
# in-process, lifetime-coupled ports are linked, as `CSlopDeskFFI` from
# `ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework` (docs/55). cargo still never runs inside
# `swift build`; `just ffi` (`slopdesk-gate ffi`) assembles that artifact beforehand.
# `swift build` therefore needs the xcframework to EXIST before it can resolve the package graph, so
# a clean checkout runs `just ffi` — or any of `just build`/`test`/`check`, which depend on it —
# once. `just build` additionally stages the relay and the CLI beside the host binary.

# `sh -c`, not just's default `sh -cu`. Every recipe below was written against make's shell, which
# does not set `-u`, and an unset-variable expansion that used to be the empty string must not
# become a fatal error inside a gate.
set shell := ["sh", "-c"]

SWIFT_PATHS := "Sources Tests Apps"
# Format (SwiftFormat) also covers the package manifest; the SwiftLint scope stays
# Sources/Tests/Apps (Package.swift is config, not linted).
SWIFTFMT_PATHS := "Package.swift " + SWIFT_PATHS
# ZERO files, and the count is the point: every gate, every operator harness, every step of the
# release AND the panel's provisioner is Rust now, so `scripts/` holds pins, fixtures and two Swift
# probes — no program at all. The last one to go was the panel's provisioner, and the "bootstrap"
# argument that had kept it was simply wrong: it installs the PANEL's runtime deps
# (code-server, baguette, adb), not the toolchain a Rust gate needs, and cargo is a prerequisite of
# this tree either way. It is `rust/slopdesk-provision` now.
#
# The globs stay rather than being dropped, so a script that comes back is linted rather than
# silently unlinted — and `scripting-is-rust` in `rust/slopdesk-invariants` fails the moment one
# does. Nothing is exempt any more: the vendored ghostty fork used to be, because its build recipe
# was carried close to upstream's shape, and `docs/68` deleted that whole tree.
# `xargs echo` is the `$(strip …)` this used to carry, at the DEFINITION rather than at each use.
# Both globs match nothing today, and two globs that each expand to nothing still leave the SPACE
# between them — so an unstripped `SHELL_FILES` is the one-character string " ",
# `[ -n "{{SHELL_FILES}}" ]` is TRUE, and `shfmt -w` with no operands reads standard input and dies
# with "-w cannot be used on standard input". `fmt` failed that way from the day the last script
# became Rust. Stripping here makes the emptiness the same emptiness at all four use sites instead
# of at the two that happened to remember.
SHELL_FILES := `ls scripts/*.sh ThirdParty/tools/*.sh 2>/dev/null | xargs echo`
SHFMT_FLAGS := "-i 2 -ci -sr"
# There is no PY_FILES, and no ruff. Every Python script this repo had is now Rust — the four
# lint gates are rules in `rust/slopdesk-invariants`, the operator tools (the release pipeline, the
# herdr harness, the Swift access raiser, the input synclient) are binaries in
# `rust/slopdesk-devtools`. A `scripts/*.py` glob left behind would be a lint scope that
# silently un-empties the day someone drops a script in, which is the shape of gate this file
# already warns about twice below.

# Every Rust WORKSPACE ROOT: `rust/` itself, plus each crate that declares its own `[workspace]` and
# is therefore invisible to `cargo --workspace` run at the root. Derived for the same reason the
# shell list above is: the seventeen of the day were spelled out by hand three times over (once in
# `fmt-rust`, twice in `lint-rust`), so adding a crate meant remembering three places and forgetting
# one left it silently unlinted — the failure `docs/46` warns about in the row about this very target.
#
# A BACKTICK rather than `shell(…)`, and the difference is load-bearing: `just --dry-run` prints an
# unevaluated `shell(…)` as its own source text, and `slopdesk-gate reach` reads a dry run to learn
# which directories a recipe would enter. A backtick prints RAW, so the gate can run the very
# command substitution just would have run. See `gates::reach`.
RUST_WORKSPACES := "rust " + `grep -l '^\[workspace\]' rust/*/Cargo.toml | sed 's|/Cargo.toml$||' | xargs echo`

# The linters `lint` fans out over, in the order their logs are replayed.
LINTERS := "lint-swift lint-shell lint-rust lint-reach lint-invariants"

# ---------------------------------------------------------------------------- #
# The FIRST recipe is what a bare `just` runs, which is this file's `.DEFAULT_GOAL`.

# Show this help
help:
    @{{just_executable()}} --list

# Cargo build products live OUTSIDE the checkout, in a `slopdesk-targets` sibling directory, and
# each crate's `target` is a SYMLINK to its slice of it. The committed half is the per-crate
# `.cargo/config.toml` — one per workspace `RUST_WORKSPACES` names, so 77 crates plus the root's,
# 78 files — which is what makes cargo WRITE there; the symlink is the read half, for the ten
# production files, three justfile sites and one Swift test that name
# `<crate>/target/release/...` as a path.
#
# ⚠️ THE REASON IS MEASURED AND IT IS NOT ABOUT DISK. Both app specs declare the SwiftPM package as
# `path: ../..` — the REPO ROOT — and Xcode enumerates that whole tree on every invocation, single
# threaded, one `lstat` per file. With 3.1M cargo artifacts under it a `slopdesk-gate ios` that
# compiled NOTHING took 987 s, all of it in `IDEContainer _locateFileReferencesRecursivelyInGroup:`.
# Moved out: 22 s. Measured 2026-08-31, both directions, with `sample` naming the frames.
#
# The symlinks do NOT undo it, which is the surprising half and was re-measured five ways before
# being relied on (an earlier round recorded the opposite and was wrong): `-showBuildSettings` runs
# 15–29 s with them live, a full `ios --force` 31 s. Xcode's walk uses `lstat`, which does not
# follow a symlink, so the link is a leaf to the enumerator and a directory to everything else.
#
# Run this after a fresh clone, and after any `cargo clean` that removed a link rather than its
# contents. It is idempotent and costs nothing on a tree that is already linked.

# Re-create the per-crate target symlinks into the sibling slopdesk-targets tree
relink-targets:
    @set -eu; \
    outside="$(cd rust && pwd)/../../slopdesk-targets"; \
    mkdir -p "$outside/_workspace"; \
    ln -sfn "../../slopdesk-targets/_workspace" rust/target; \
    for config in rust/*/.cargo/config.toml; do \
      crate="$(basename "$(dirname "$(dirname "$config")")")"; \
      mkdir -p "$outside/$crate"; \
      ln -sfn "../../../slopdesk-targets/$crate" "rust/$crate/target"; \
    done; \
    echo "==> relinked $(ls -d rust/*/target | wc -l | tr -d ' ') crate target directories"

# ---------------------------------------------------------------------------- #
# Formatting (writes)

# Auto-format all languages
fmt: fmt-swift fmt-shell fmt-rust

# `.swiftformat` states the division of labour: SwiftFormat owns formatting, SwiftLint owns lint.
# The division does not survive contact with `leading_whitespace`. SwiftFormat cannot remove a blank
# line at the START of a file — `consecutiveBlankLines` collapses three to two and stops, and no
# other rule reaches file position 0 (checked against every rule's `--ruleinfo`). SwiftLint enforces
# it, so `just fmt-swift` could not produce a tree `just lint-swift` accepts: the one thing a format
# target exists to guarantee.
#
# So the WRITE half of SwiftLint lives here, in the recipe that writes, and `lint-swift` stays
# strictly read-only (`--lint`, and `swiftlint` with no `--fix`). It is a no-op on a clean tree —
# verified: zero output, byte-identical `git status` and diffstat — so it costs a pass over the tree
# and changes nothing until something is genuinely unformatted.
#
# `--fix` only, never `analyze --fix`. The analyzer half (`unused_import`, `unused_declaration`)
# judges by a compiler log from ONE configuration, so it deletes imports that only an `#if os(iOS)`
# branch uses; it belongs to a deliberate, verified sweep, not to a formatter people run on reflex.

# Format Swift (SwiftFormat, then SwiftLint's correctable rules)
fmt-swift:
    swiftformat {{SWIFTFMT_PATHS}}
    swiftlint --fix --quiet

# Format shell (shfmt)
fmt-shell:
    @if [ -n "{{SHELL_FILES}}" ]; then shfmt {{SHFMT_FLAGS}} -w {{SHELL_FILES}}; fi

# rustfmt.toml turns on nightly-only options (wrap_comments, group_imports, format_strings …).
# Only the FORMATTER needs nightly; the crate itself builds and tests on stable.
#
# `+nightly` is the FLOATING channel and stays that way — never a `nightly-YYYY-MM-DD`, which
# `lint-invariants` (`nightly-is-never-pinned-to-a-date`) enforces. The cost is real and worth
# naming: `wrap_comments` decides where a comment BREAKS, that judgement changes between nightlies,
# and this tree treats comments as an asset — so the day rustup fetches a new one, `just lint` goes
# red on files nobody touched (2026-08-30: 3123 lines across 215 files). That is not a bug to
# prevent, it is a reformat to take: run `just fmt-rust` and commit it on its own.
#
# EVERY workspace, matching `lint-rust` — the daemons each have their own (see the note there), and a
# formatter that skips what the linter checks means `just fmt && just lint` fails on its own output.

# The fan-out is `lint-rust`'s, for `lint-rust`'s reason and one more. Seventy-six `cargo fmt`
# invocations one after another were ~90 s of the inner loop on a ten-core machine — measured, on a
# tree rustfmt then changed nothing in. Each workspace owns its own `target/`, so there is no build
# lock to contend on, and rustfmt WRITES only inside the workspace it was pointed at, so two
# concurrent invocations cannot reach the same file.
#
# Output is buffered per workspace and printed only on failure, so a red format run reads as one
# crate's report rather than seventy-six interleaved ones; xargs exits non-zero when any did.

# Format Rust (latest nightly rustfmt — rust/rustfmt.toml uses unstable options)
fmt-rust:
    @printf '%s\n' {{RUST_WORKSPACES}} | xargs -P 8 -I{} sh -c \
      'cd {} || exit 1; out=$(cargo +nightly fmt --all 2>&1) || { printf "── {} ──\n%s\n" "$out" >&2; exit 1; }'

# ---------------------------------------------------------------------------- #
# Autofix (writes) — formatting + every safe lint autocorrect
#
# The clippy sweep is over every workspace, for the reason `fmt-rust` and `lint-rust` are:
# `cd rust && … --workspace` autofixes the root's four members and leaves the other sixteen crates
# for `just lint` to fail on.

# Format + apply all safe lint autofixes
fix: fmt
    -swiftlint --fix --quiet
    -@for ws in {{RUST_WORKSPACES}}; do (cd $ws && cargo clippy --workspace --all-targets --fix --allow-dirty --allow-staged) || true; done
    -[ -n "{{SHELL_FILES}}" ] && shellcheck -f diff {{SHELL_FILES}} | git apply --allow-empty 2>/dev/null

# ---------------------------------------------------------------------------- #
# Linting (no writes) — the CI gate
#
# The five linters run CONCURRENTLY. They read the tree and write nothing, so nothing orders them,
# and serially they were the inner loop's largest fixed cost: 55 s, of which the cross-language
# ratchets alone were 35 s. Overlapping the other four with them is free wall clock — measured
# 55 s → 36 s. The ratchets are `lint-invariants` now and cost about half a second; what is left in
# `lint-reach` is four dry-run expansions and one content stamp.
#
# Not a plain dependency list and not just's `[parallel]` attribute: five linters interleaving
# diagnostics line by line is a gate whose failures cannot be read. So each runs into its OWN log,
# and the logs are replayed IN THE DECLARED ORDER once every one has finished. The output is
# byte-identical to the serial gate's; only the waiting changed.
#
# `wait` on a KNOWN pid, for the reason `gates::ffi` says: a bare `wait`
# yields zero however the jobs died, and a lint gate that passes on a dead linter is worse than a
# slow one. Every linter is waited on before the exit status is returned, so one failure does not
# leave four tools running against a tree the next command is about to edit.

# Run every linter strictly
lint:
    #!/bin/sh
    dir=$(mktemp -d -t slopdesk-lint); trap 'rm -rf "$dir"' EXIT
    for t in {{LINTERS}}; do
      {{just_executable()}} $t > "$dir/$t.log" 2>&1 & echo $! > "$dir/$t.pid"
    done
    rc=0
    for t in {{LINTERS}}; do
      wait $(cat "$dir/$t.pid") || rc=1
      if [ -s "$dir/$t.log" ]; then printf '── %s ──\n' "$t"; cat "$dir/$t.log"; fi
    done
    exit $rc

# SwiftFormat --lint + SwiftLint --strict
lint-swift:
    swiftformat {{SWIFTFMT_PATHS}} --lint
    swiftlint --strict --quiet

# PORTED — the design-token leak ratchet and the menu-bar shortcut-less ratchet were two shell
# scripts and are two rules in `rust/slopdesk-invariants` (`design_ratchets`: `design-token-leaks`,
# `menu-shortcutless`). Both were a `grep -rnE` for a banned shape plus a `grep -vE` dropping
# comment-only lines, which is `View::Code` and a `NoneUnder`/`Lacks` claim; the fail-closed
# `[[ -d ]]`/`[[ -f ]]` guards are a `Populated` floor and an `Exists`.
#
# PORTED — the dead-FFI-door ratchet, the one-walk ban filter's superset check and the
# transcribed-constant ratchet were three Python scripts and are seven rules in
# `rust/slopdesk-invariants` (`gate_health`, `shared_constants`). `lint-invariants` runs them with
# the rest of the registry over ONE tree walk, so there is nothing left for a separate recipe to do.

# The four questions only a dry run can answer, plus the stale-artifact gate.
#
# `check-supervisor.sh` is GONE — every constant it compared is a rule in `rust/slopdesk-invariants`
# (`lint-invariants`), which reads the tree once and carries a break-test per rule. What could not
# move there is what is here: three of these ask what a `just` recipe would RUN, which means
# expanding it, and the fourth asks whether the linked artifact is older than its Rust sources.
# Neither is decidable by reading text.
#
# `just supervisor-tests` is the other half — the five sidecar suites and the Swift tests that drive
# a real daemon. Behind its own recipe for the reason it was behind a `--tests` flag: the rules above
# are what is worth running on every commit.

# the four questions no rule can answer by reading the tree: every workspace crate is reached by a
# just recipe, the FFI artifact is not older than its sources, every hook stage the config declares
# is installed in THIS clone, and no COMMITTED terminal recording carries the machine it was made
# on. The third has to be reached by a hand-typed recipe — `check` and `quick` both are — because in
# the state it detects the hooks are the thing that is missing. The fourth asks git rather than the
# working tree, because a recording that was made and then rejected is still on disk and no change
# to the repository can take it out of someone's checkout.

# what no rule can decide by reading: every crate is reached by a recipe, the FFI artifact is not older than its sources, the hooks are installed HERE, no committed recording carries its machine
lint-reach:
    @cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- reach
    @cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- ffi --check
    @cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- hooks
    @cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- corpus

# the hostd/superd suites that need a live daemon (slow; not in `check`)
supervisor-tests:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- supervisor-tests

# The same ratchets, as a program. Sections migrate here one at a time and the shell section is
# DELETED in the commit that ports it, so there is never a period where both enforce the same rule.
# It reads the tree once instead of spawning a grep per question — half a second against the shell's
# two and a half minutes — and every rule carries a unit test that seeds the breakage and asserts
# the rule fires, which is the one thing a shell section could not have.

# the ported cross-language ratchets, in Rust
lint-invariants:
    @cd rust/slopdesk-invariants && cargo run --release --quiet -- --root ../..

# The break-tests, which are the reason the port is worth doing: each seeds the drift its rule
# exists to catch and asserts the rule fires. `the_live_tree_satisfies_every_rule` is in there too,
# so this recipe is also the gate — which is what lets `cargo test` here stand in for the whole
# script during development.

# cargo test for the ratchets and their break-tests
invariants-test:
    cd rust/slopdesk-invariants && cargo test

# The `if` form is load-bearing. A `[ -n … ] && cmd` chain exits nonzero on an EMPTY file
# list, and the `|| true` that silences THAT silences every real diagnostic with it: the tool
# prints its findings and the gate still passes. `if` yields 0 for the empty list and the
# tool's own exit status otherwise. Same tools, flags and file set as the CI `shell` job, so local
# green implies CI green rather than the reverse.
#
# The emptiness guard is load-bearing for the same reason, one layer down — a linter handed no files
# reads standard input rather than doing nothing. `SHELL_FILES` is stripped where it is DEFINED so
# that this reads as the plain test it looks like; the note there says what the space cost.

# shellcheck + shfmt --diff
lint-shell:
    @if [ -n "{{SHELL_FILES}}" ]; then shellcheck {{SHELL_FILES}}; fi
    @if [ -n "{{SHELL_FILES}}" ]; then shfmt {{SHFMT_FLAGS}} -d {{SHELL_FILES}}; fi

# Rust: clippy at all/pedantic/nursery/cargo + a curated restriction slice, every group DENY
# (rust/Cargo.toml `[workspace.lints]`), so `-D warnings` is the belt to those braces. `--all-targets`
# reaches the test code too. The format check needs nightly for the same reason `fmt-rust` does.
# `slopdesk-superd` is a SEPARATE workspace (rust/slopdesk-superd/Cargo.toml explains why: the hook
# needs `panic = "abort"`, superd needs `panic = "unwind"`, and profiles are workspace-global). It
# is `exclude`d from rust/Cargo.toml, so `--workspace` does NOT reach it — hence the second pair of
# invocations. Forgetting them is a silently unlinted daemon.
#
# The three per-workspace sweeps below fan OUT rather than looping. Sequentially they were 38 s
# (clippy + fmt) and 16 s (tests) warm on an untouched tree — nineteen cargo freshness checks one
# after another on a machine with ten idle cores. Each workspace owns its target/ (being separate
# workspaces is the whole point), so there is no build lock to contend on. Each invocation's output
# is BUFFERED and printed only if it failed, so a red sweep reads as one crate's report instead of
# nineteen interleaved ones; xargs exits non-zero when any of them did.

# clippy -D warnings (all targets) + rustfmt --check, every workspace RUST_WORKSPACES names
lint-rust: lint-rust-clippy
    @printf '%s\n' {{RUST_WORKSPACES}} | xargs -P 8 -I{} sh -c \
      'cd {} || exit 1; out=$(cargo +nightly fmt --all -- --check 2>&1) || { printf "── {} ──\n%s\n" "$out" >&2; exit 1; }'

# Split out because the pre-commit hook wants clippy WITHOUT the `fmt --check`: prek runs hooks in
# parallel, and the `rustfmt (apply)` hook is rewriting the very files a `--check` would be reading.

# clippy -D warnings across every Rust workspace (no fmt check)
lint-rust-clippy:
    @printf '%s\n' {{RUST_WORKSPACES}} | xargs -P 8 -I{} sh -c \
      'cd {} || exit 1; out=$(cargo clippy --workspace --all-targets --all-features --quiet -- -D warnings 2>&1) || { printf "── {} ──\n%s\n" "$out" >&2; exit 1; }'

# The pre-commit hook's Rust test sweep, and the same `--workspace`-does-not-reach-them story: the
# hook used to run `cd rust && cargo test --workspace` while firing on ANY `rust/**.{rs,toml}` change,
# so a commit to fifteen of the seventeen crates of the day ran the OTHER two crates' tests and
# reported green. ~21 s warm for the lot, which is what makes it a commit-time gate rather than a
# push-time one. The named per-crate recipes below stay: they are how you run ONE crate, and
# `just test` composes them.

# cargo test across every Rust workspace (~21 s warm, 55 s if run one at a time)
test-rust:
    @printf '%s\n' {{RUST_WORKSPACES}} | xargs -P 8 -I{} sh -c \
      'cd {} || exit 1; out=$(cargo test --workspace --quiet 2>&1) || { printf "── {} ──\n%s\n" "$out" >&2; exit 1; }'

# SwiftLint analyzer rules need the compiler INVOCATIONS, which only a verbose build prints. Minutes,
# not seconds — ~750 files, each re-parsed by a real frontend — so this stays out of `lint` and runs
# on demand. `.swiftlint.yml` says `analyzer_rules: all`, so what it covers is every analyzer rule
# SwiftLint ships.
#
# It fed `.build/debug.yaml`, which is llbuild's build MANIFEST and not a compiler log. SwiftLint
# accepted the path, collected nothing out of it, and printed "Found 0 violations, 0 serious in 0
# files" — a clean exit over an empty file set. The `|| echo <note>` that was meant to catch exactly
# that could not fire, because nothing had failed: the recipe had never once run an analyzer rule and
# had reported success for it every time. Same shape as the `|| true` warned about above `lint-shell`,
# reached by a different road.
#
# So: a real `-v` log, no `|| echo`, and the file count asserted. Analysing zero files is the failure
# it always was, and the exit status of the analyzer itself is what the recipe exits with — never
# `tee`'s, which is why the log is written first and printed second.
#
# The clean is load-bearing, not caution. `-v` prints the commands SwiftPM RUNS, so a warm tree
# prints none, the log carries no `swift-frontend` line, and the count assertion below fails on a
# tree with nothing wrong with it. The price is a full rebuild every time this recipe is asked for,
# and the reason it is out of `lint`.

# SwiftLint analyzer rules (full rebuild + analyze; minutes, not seconds)
lint-swift-analyze:
    swift package clean
    swift build --build-tests -v > .build/swiftlint-compiler.log 2>&1 || \
        { tail -40 .build/swiftlint-compiler.log; exit 1; }
    @swiftlint analyze --strict --compiler-log-path .build/swiftlint-compiler.log \
        > .build/swiftlint-analyze.log 2>&1; \
    status=$?; \
    cat .build/swiftlint-analyze.log; \
    grep -qE 'in [1-9][0-9]* files' .build/swiftlint-analyze.log || \
        { echo "lint-swift-analyze: analysed 0 files — the compiler log carries no swiftc invocation"; exit 1; }; \
    exit $status

# ---------------------------------------------------------------------------- #
# Full gate

# lint + build + test + the unsafe memory audit + golden pin + both app triples (full local gate)
check: lint build test miri golden check-ios check-ios-bundle check-macos-apps

# THE INNER LOOP. Run this after every edit; run `check` once before pushing.
#
# It is `check` with two substitutions and one omission, and each of the three is a claim about what
# a single edit can break:
#
#   test → test-touched   The full suite re-runs every Swift target for a change that reaches three.
#                         `slopdesk-gate test-touched` attributes the change set to SwiftPM targets and runs the
#                         test targets whose closure contains them — escalating to the full suite
#                         whenever it cannot attribute a path, so it is fail-toward-slow, not
#                         fail-toward-green. A touched-green never writes the pre-push marker, so
#                         this can never make a push skip what it did not run.
#   check-ios (stamped)   Unchanged as a gate; it just costs nothing when no iOS-compiled input moved
#                         (gates::stamp explains it). It stays IN the inner loop for
#                         that reason — the `#if os(iOS)` surface breaks on a Swift edit like any
#                         other, and now noticing costs nothing on the edits that cannot break it.
#   check-ios-bundle      NOT here, and this is the one substitution that is about COST rather than
#     omitted             about what an edit can break. Building `Apps/ClientApp-iOS/Tests` used to
#                         happen inside `check-ios`, so it ran after every edit. MEASURED
#                         2026-08-30: a `quick` whose iOS stamp missed took 41 MINUTES, of which
#                         that one build was 25+, at 94% of ONE core out of ten — and the stamp
#                         covers the closure of the iOS spec's products, so `SlopDeskWorkspaceCore`,
#                         `SlopDeskClientCore`, `SlopDeskPhoneUI` and the FFI header all pay it.
#                         Warm, this whole recipe is 72 s. The bundle carries
#                         `SWIFT_ENABLE_TESTABILITY: YES` where the app target does not, so the two
#                         builds are different configurations and share NOTHING; five of the seven
#                         test files `@testable import`, so the setting cannot come off either. The
#                         rate was the only lever. It is in `check` with its own stamp — the
#                         protection before a push is identical, it just is not charged per keystroke.
#   miri omitted          ~47 s to re-audit `rust/slopdesk-gfsimd`, which only a change to that crate
#                         can affect. `just miri` by hand when touching it; `check` runs it anyway.
#
# `build` is not omitted so much as implied: `test-touched` builds incrementally before selecting.
#
# Warm, on an untouched tree, this is seconds. The floor used to be the shell ratchet — ~31 s of
# greps over the whole tree, and 44 s before the "this Swift must stay deleted" bans stopped walking
# `Sources/` once per ban. The whole set is `rust/slopdesk-invariants` now: one walk, 300-odd rules
# under rayon, about half a second. The floor is `lint-swift`.
# `ffi` and `lint` come first and in order — the artifact before anything that links it, and the
# linters before the slow half, so a formatting slip fails in seconds rather than after the tests.
# The slow half then runs CONCURRENTLY, ordered logs and known pids exactly as `lint` does: after a
# Swift edit `test-touched` and `check-ios` are the two costs left, they share nothing but the
# SwiftPM lock (which only makes `golden` wait, and `golden` is three seconds), and serially the
# inner loop paid their sum. Measured on one Swift edit: 5:46 serial, and the iOS half of that was
# two schemes where one does the work — the other, the test bundle, is `check-ios-bundle` now and is
# not in this list at all.
QUICK_SLOW := "test-touched golden check-ios check-macos-apps"

# The INNER LOOP: lint + only the tests the change reaches + golden + the (stamped) iOS triple
quick: ffi lint
    #!/bin/sh
    dir=$(mktemp -d -t slopdesk-quick); trap 'rm -rf "$dir"' EXIT
    for t in {{QUICK_SLOW}}; do
      {{just_executable()}} $t > "$dir/$t.log" 2>&1 & echo $! > "$dir/$t.pid"
    done
    rc=0
    for t in {{QUICK_SLOW}}; do
      wait $(cat "$dir/$t.pid") || rc=1
      if [ -s "$dir/$t.log" ]; then printf '── %s ──\n' "$t"; cat "$dir/$t.log"; fi
    done
    if [ $rc -eq 0 ]; then
      printf 'quick: green — run `just check` before pushing (adds the full suite + miri)\n'
    fi
    exit $rc

# `swift build` compiles the macOS slice ONLY — it never type-checks a `#if os(iOS)` source, so the
# UIKit input host and the iOS components in Sources/SlopDeskPhoneUI/iOS/ compiled only in someone's
# head. This gate has existed for exactly that and was reachable from no recipe, no
# hook and no workflow. It was also RED: two xcframeworks each shipped `Headers/module.modulemap`,
# Xcode copies both to `$BUILT_PRODUCTS_DIR/include/`, and neither app had built on either platform
# since (fixed in `gates::ffi`, which now nests its headers and asserts the nesting).
#
# `slopdesk-guigate macos` is the sibling and is deliberately NOT here: it drives a real window and
# needs a logged-in GUI session, so it cannot run from a headless gate.

# iOS-triple typecheck (the `#if os(iOS)` surface `swift build` never compiles)
check-ios: ffi
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- ios

# The iOS TEST BUNDLE, which no other gate compiles: `swift build` never sees `Apps/`, and
# `swift test` compiles the macOS branch of every `#if os(iOS)` fork. It went unbuildable for weeks
# with every gate green, which is why it is gated at all.
#
# In `check` and NOT in `quick`, on a measurement rather than a preference — `QUICK_SLOW`'s comment
# carries the numbers, and `gates::xcode::ios_test_bundle_build` carries why the cost is structural.
# RUNNING these assertions needs a booted simulator and is `check-ios-tests`, which is in neither.

# BUILD the iOS test bundle (stamped; pre-push, not per-edit)
check-ios-bundle: ffi
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- ios-bundle

# The OTHER half of the same hole. `check-ios` compiles `Apps/ClientApp-iOS`; `swift build` compiles
# `Sources/` and `Tests/`. Nothing compiled the two macOS app shells, because they are Xcode targets
# rather than SwiftPM ones — so a rename under `Sources/` could leave `Apps/ClientApp-macOS` unable
# to build while every gate stayed green, which is exactly what happened to `VideoSurfaceHost`.
#
# Distinct from `slopdesk-guigate macos`, which BUILDS AND RUNS the app against a real window and
# therefore needs a logged-in GUI session. This one only type-checks, so it is headless and belongs
# here.

# macOS app-shell typecheck (the `Apps/` code no other gate compiles)
check-macos-apps: ffi
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- macos-apps

# The half `check-ios` does not do: it type-checks and runs ZERO tests. `swift test` compiles the
# MACOS branch of every `#if os(iOS)` fork, so an iOS default asserted there is asserted about the
# wrong branch — a macOS build of `platformDefaultFollowSessionFocus` reads the opposite value.
# `slopdesk-gate ios-tests` is the only thing in the repo that executes an assertion on the iOS
# triple, and it too was reachable from no recipe: `docs/46` calls it the ONLY executor of iOS tests
# and then nothing ran it.
#
# NOT in `check`: it boots a simulator, which a headless gate cannot assume — same reason
# `slopdesk-guigate` stays out. Run it after touching anything inside an `#if os(iOS)`.

# RUN the iOS tests on a booted simulator (the only assertions on that triple)
check-ios-tests: ffi
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- ios-tests

# The four gates that DRIVE THE SHIPPING APP. None is in `check` and none can be: each launches the
# real bundle against a real window server, so all four need an unlocked Aqua login session —
# `video` additionally needs Screen Recording TCC and `multiclient` needs Accessibility TCC.
# They are here so `just help` names them, which is the only way anyone finds them now that the
# shell scripts that used to carry them are gone. Minutes each; run one at a time (each binds its
# own port from `gui::port`, but they all fight over the same window server and the same TCC grant).

# GUI gate: launch, connect, type, quit (needs an unlocked Aqua session)
gui-macos:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-guigate -- macos

# GUI gate: the video pane end to end (also needs Screen Recording TCC)
gui-video:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-guigate -- video

# GUI gate: two clients on one host (also needs Accessibility TCC)
gui-multiclient:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-guigate -- multiclient

# GUI gate: restore `workspace.json` and re-dial the saved host, as a user does
gui-launch-restore:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-guigate -- launch-restore

# The three arm64 static slices the Swift clients link, from `rust/slopdesk-ffi`. FIRST, and not
# optional: `Package.swift` declares a `binaryTarget` at that path, so SwiftPM cannot even resolve
# the graph without it. The gate stamps its inputs and exits in milliseconds when nothing changed,
# which is what makes it safe to put in front of every build.
#
# This recipe's own doc line is what `linked-artifacts-are-built` reads to learn who produces the
# artifact, so the path in the help text is load-bearing rather than decorative.

# Build ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework (macos + ios + ios-sim arm64)
ffi:
    @cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- ffi

# swift build (Swift + the linked Rust FFI slices) + the Rust hook relay, agent CLI, profile seeder and metadata probe
build: ffi hook ctl codeseed probe
    swift build
    @cp rust/target/release/slopdesk-hook "$(swift build --show-bin-path)/slopdesk-hook"
    @cp rust/target/release/slopdesk-agenthooks "$(swift build --show-bin-path)/slopdesk-agenthooks"
    @cp rust/target/release/slopdesk-ctl "$(swift build --show-bin-path)/slopdesk-ctl"
    @cp rust/target/release/slopdesk-probe "$(swift build --show-bin-path)/slopdesk-probe"

# The Claude Code hook relay. Compiled, not a shell script: Claude Code runs hooks SYNCHRONOUSLY
# on PreToolUse/PostToolUse — twice per tool call — and the sh+cat+nc script it replaces spent
# ~10ms of its ~12.4ms forking three processes to move ~60 bytes. It is staged NEXT TO the host
# binary, which is where `AgentHooks.locate` looks for its sibling.
#
# The crate builds TWO binaries. `slopdesk-agenthooks` is the installer that writes the settings
# entries pointing at the relay and stages the relay beside itself; it is separate because it needs
# `serde_json` and the relay's cost IS its startup. The split is measured, not assumed: the relay's
# release binary is byte-for-byte the same size either way, because nothing links what it cannot
# reach.

# Build the Rust hook relay + its installer (rust/slopdesk-hook)
hook:
    cd rust && cargo build --release -p slopdesk-hook

# cargo test for the hook relay
hook-test:
    cd rust && cargo test -p slopdesk-hook

# The agent-control CLI. Was Swift; ported for the same reason as the hook and measured the same
# way — an agent forks it once per `read`/`wait`/`write`/`run`, so its cost IS process startup.
# Above the fork/exec floor the Swift build spent 3.47 ms getting useful work done, this one spends
# 0.73 ms. Same root workspace as the hook because it wants the same startup-tuned profile; staged
# next to hostd by `build`, which is where `rust/slopdesk-hostd` looks for the sibling it exports
# as `SLOPDESK_CTL_BIN`.

# Build the Rust agent-control CLI (rust/slopdesk-ctl)
ctl:
    cd rust && cargo build --release -p slopdesk-ctl

# cargo test for the agent-control CLI
ctl-test:
    cd rust && cargo test -p slopdesk-ctl

# The host metadata RPC's git, directory and session half. hostd forks it per request, which for
# `gitStatus` — the verb the project-scoped watcher polls on a cadence — is FEWER spawns than before:
# that one verb forked `git` four times from hostd's own queue, and now makes those four inside a
# program hostd spawns once. The rest of the shim (the pane's cwd, its processes, its ports) needs
# the PTY master fd and stays in Swift. It also answers the TERM question — whether this host can
# resolve `xterm-ghostty` — which is the same shape of question about the same machine. Same root
# workspace as the hook for the same startup-tuned profile; staged next to hostd by `build`, which
# is where `HostProbe.locate` looks.

# Build the Rust host probe (rust/slopdesk-probe)
probe:
    cd rust && cargo build --release -p slopdesk-probe

# cargo test for the metadata probe
probe-test:
    cd rust && cargo test -p slopdesk-probe

# The process custodian (docs/51). Builds like the hook but is NOT staged next to the host binary:
# it is a launchd agent installed out of the build tree, because launchd re-execs its path and a
# `cargo clean` must not be able to leave the agent pointing at nothing.

# Build slopdesk-superd (rust/slopdesk-superd)
superd:
    cd rust/slopdesk-superd && cargo build --release

# cargo test for the process custodian
superd-test:
    cd rust/slopdesk-superd && cargo test

# The whole of the tree's `unsafe`, and therefore the whole of what a reviewer has to check by hand.
# `--all-features` is not optional here: `winsize-set` gates the one function superd may not call in
# production, and a test run that skipped it would leave that code uncompiled and unlinted.

# cargo test for the isolated unsafe surface (rust/slopdesk-posix)
posix-test:
    cd rust/slopdesk-posix && cargo test --all-features

# The C ABI, tested through the exported symbols rather than through the Rust functions behind
# them — an entry point that marshals its arguments wrongly passes every test of the crate it wraps.

# cargo test for the C ABI Swift calls (rust/slopdesk-ffi)
ffi-test:
    cd rust/slopdesk-ffi && cargo test

# The git engine. Its suite builds REAL repositories under the temp directory and compares every
# answer with the `git` binary's own — the parity that let the four subprocesses be deleted. It is a
# separate workspace because it vendors libgit2, which the fork-per-event root workspace must not
# link (see the crate's manifest).

# cargo test for the in-process git status (rust/slopdesk-git)
git-test:
    cd rust/slopdesk-git && cargo test

# Build + (re)install the com.slopdesk.superd LaunchAgent — RESTARTS superd
superd-install:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-ops -- install superd

# The VT screen engine (docs/52): the terminal parser, the snapshot renderer and the overprint
# collapser, which used to be the hottest Swift in the tree (17.9 MiB/s against 186 in Rust). Its
# own workspace for the same reason superd is: profiles are workspace-global and this one wants
# `opt-level = 3` where the hook wants `"z"`.

# Build slopdesk-screend (rust/slopdesk-screend)
screend:
    cd rust/slopdesk-screend && cargo build --release

# cargo test for the screen engine
screend-test:
    cd rust/slopdesk-sanitize && cargo test
    cd rust/slopdesk-screenwire && cargo test
    cd rust/slopdesk-screend && cargo test

# Build + (re)install the com.slopdesk.screend LaunchAgent
screend-install:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-ops -- install screend

# The operator tools (rust/slopdesk-devtools): the release pipeline, the build gates, the operator
# harnesses (`slopdesk-ops`), the herdr sync + parity harness, the Swift access raiser, the input
# synclient. Not part of `build` — nothing ships them, so they are built when a recipe asks for
# them (`just host-restart`, `just superd-install`, every `just release*` recipe, every gate that
# is a `slopdesk-gate` verb) and not on the inner loop. Their tests DO run in `test-rust`, via the
# workspace glob.

# Build the operator tools (rust/slopdesk-devtools)
devtools:
    cd rust/slopdesk-devtools && cargo build --release

# cargo test for the operator tools
devtools-test:
    cd rust/slopdesk-devtools && cargo test

# PATH 4's daemon (docs/53): the file-drop endpoint clients dial DIRECTLY on `terminalPort + 2`.
# hostd no longer binds that port or sees a body byte — superd spawns dropd and keeps it, so an
# upload in flight survives a host restart. Its own workspace for the same profile reason as above.

# Build slopdesk-dropd (rust/slopdesk-dropd)
dropd:
    cd rust/slopdesk-dropd && cargo build --release

# cargo test for the file-drop service
dropd-test:
    cd rust/slopdesk-dropd && cargo test

# The Android panel's bridge (docs/48): `adb` orchestration and the scrcpy byte pump, which clients
# dial DIRECTLY. It used to be a listener inside hostd, so an H.264 mirror was pumped by the daemon
# that owns every keystroke and `just host-restart` took every mirror down with it. Same
# own-workspace reason as the three above.

# Build slopdesk-androidd (rust/slopdesk-androidd)
androidd:
    cd rust/slopdesk-androidd && cargo build --release

# The SOCKET cases here need a booted device and are gated on SLOPDESK_ANDROID_HW=1
# (`slopdesk-gate android`); without it they print why they proved nothing and pass.

# cargo test for the Android bridge
androidd-test:
    cd rust/slopdesk-androidd && cargo test

# PATH 3's daemon (docs/54): the read-only inspector clients dial DIRECTLY on `terminalPort + 1`.
# hostd never relayed a byte of it — what it did contribute was the process, so a transcript tail
# and a session's whole replay window died with every `just host-restart`. Same own-workspace
# reason as the four above.

# Build slopdesk-inspectord (rust/slopdesk-inspectord)
inspectord:
    cd rust/slopdesk-inspectord && cargo build --release

# cargo test for the inspector service (unit + the transcript corpus)
inspectord-test:
    cd rust/slopdesk-inspectord && cargo test

# Stage 1 of moving hostd off Swift (docs/DECISIONS.md): the PATH-1 terminal wire codec. A LIBRARY,
# not a daemon — nothing links it yet, so `wire-test` is the only thing standing between it and a
# silent drift away from the Swift codec it must stay byte-identical to. `wire-test` re-encodes the
# committed golden corpus, so it is the parity gate, not a smoke test. Own workspace for the same
# profile reason as the daemons: this ends up inside a per-byte loop and wants `opt-level = 3`.
#
# Stage 14 added the RETENTION side of the same wire: `replay` (the per-pane replay buffer and its
# scrollback ring). `replay` lives here rather than in a crate of its own because it is defined over
# `WireMessage` and `MuxFlowControl` — the seq budget and the window/2 payload cap are wire facts,
# not transport ones. The alt-screen cut scanner it repairs evictions with LEFT in stage 27, for
# `rust/slopdesk-altscreen`, so superd could share it without depending on the protocol.

# Build slopdesk-wire (rust/slopdesk-wire)
wire:
    cd rust/slopdesk-wire && cargo build --release

# cargo test for the wire codec + replay buffer (unit + golden-vector parity vs Swift)
wire-test:
    cd rust/slopdesk-wire && cargo test

# The alt-screen cut scanner, lifted OUT of `wire` in stage 27 so superd could share it: three
# scrollback retainers front-truncate a stream and all three need the same answer before they may
# drop bytes — was the cut inside an open `?1049h` segment, and which mode opened it. The ring
# (`wire`'s `replay`) is one; superd's journal is compaction and restore. superd cannot depend on
# `wire`, which is the PROTOCOL and the one thing it must not know, so the scanner is its own
# dependency-free crate rather than a second copy in Rust.

# cargo test for the alt-screen cut scanner (rust/slopdesk-altscreen)
altscreen-test:
    cd rust/slopdesk-altscreen && cargo test

# The four clipboard rules, lifted OUT of `hostserver` for `altscreen`'s reason: both ENDS of
# clipboard sync ask a board the same four questions — image before text, the codec's cap, never a
# file copy, never (on the push side) a concealed clip — and a disagreement is a drift in the
# protocol no compiler sees. The host cannot host them for the client (a daemon's crate the
# `.xcframework` must not link) and `wire` cannot either (that is the PROTOCOL, and a trait
# describing a machine's pasteboard is what feeds it, not part of it).

# cargo test for the pasteboard-to-clip fold both ends share (rust/slopdesk-clipboard)
clipboard-test:
    cd rust/slopdesk-clipboard && cargo test

# The policy half of one hostd pane session: who votes on the pane's grid and what that folds to
# (docs/45 §8.3). Its own crate because `MuxChannelSession` is an IO shell — Tasks, a PTY
# descriptor, four relays — wrapped around arithmetic that needed none of them, and arithmetic
# inside an actor is arithmetic nothing can test without a PTY. The `TIOCSWINSZ` stayed in Swift.

# cargo test for one pane session's decisions (rust/slopdesk-muxsession)
muxsession-test:
    cd rust/slopdesk-muxsession && cargo test

# PATH-1's mux over two sockets, with no end of it in the name (docs/63 stage G.1): the 17-byte
# association preamble both ends write, the four sockopts both ends set, one byte link, one
# sub-channel and the connection that demultiplexes frames into channels. Split out of
# `slopdesk-hostnet` by the question "does this file say HOST anywhere" — five of seven did not, and
# the iOS client links those five. The role asymmetry is `slopdesk-wire::mux::admission`'s and is
# PASSED to it, never branched on here; `tests/role.rs` is that property from outside.

# cargo test for the role-generic mux: preamble, links, sub-channels, connection (rust/slopdesk-muxnet)
muxnet-test:
    cd rust/slopdesk-muxnet && cargo test

# The client's half of PATH-1, and the mirror image of `slopdesk-hostnet` (docs/63 G.2): a host
# ACCEPTS two sockets and parks the first until its partner arrives, a client DIALS two and knows
# they are a pair because it chose the id on both. Neither shape has a counterpart at the other end.
# Also the shared-connection pool — every pane to one host rides one mux — which is 316 lines of
# `@MainActor` reentrancy commentary in Swift and one `Mutex` here, because the actor was never what
# made it correct. Opening a CHANNEL is NOT here: that mutates a connection's own tables, so it is
# `slopdesk-muxnet`'s `open_channel`, and this crate calls it.

# cargo test for the dialler and the shared-connection pool (rust/slopdesk-clientnet)
clientnet-test:
    cd rust/slopdesk-clientnet && cargo test

# hostd's half of PATH-1, and only its half: the accept loop and the map that pairs a CONTROL and a
# DATA connection into one shared mux link (docs/60 stage A, narrowed by docs/63 G.1). Its own crate
# because it is the one part of the port that owns file descriptors before a pair exists, so it
# links `socket2` — a dependency the `.xcframework` has no business carrying. The pairing VERDICTS
# are still `slopdesk-muxsession`'s above; this crate owns the fds and obeys. The loopback suite
# dials real sockets, which is exactly what the Swift original could not test.

# cargo test for hostd's PATH-1 listener and socket pairing (rust/slopdesk-hostnet)
hostnet-test:
    cd rust/slopdesk-hostnet && cargo test

# hostd's end of the superd control socket (docs/60 stage C.0): the framing a descriptor rides on,
# the reply-waiter table, the reader thread and the writer behind it. Its own crate because it
# carries `nix` for `recvmsg`/`SCM_RIGHTS`, which is exactly what `slopdesk-superwire`'s manifest
# keeps OUT of the `.xcframework` — the two crates split at the syscall, not at the layout. The
# suite drives a fake superd over a real AF_UNIX socket, descriptors and all.

# cargo test for hostd's superd client (rust/slopdesk-superclient)
superclient-test:
    cd rust/slopdesk-superclient && cargo test

# hostd's end of the screend socket (docs/60 stage C.2): the connection, the fd pool keyed on the
# address, the autostart with its backoff, and the ten verbs. Its own crate because it carries `nix`
# for `access(2)` and spawns a daemon — neither belongs in `slopdesk-screenwire`, which the
# `.xcframework` links for the framing alone. The suite drives a FAKE screend over a real AF_UNIX
# socket, which is the only way to ask for a hang-up mid-exchange or a reply that does not decode.

# cargo test for hostd's screend client (rust/slopdesk-screenclient)
screenclient-test:
    cd rust/slopdesk-screenclient && cargo test

# hostd's half of ONE pane (docs/60 stage C.1): the master descriptor superd handed over, the verbs
# that steer the child, and the subscription that carries its output back. Its own crate because it
# is the one non-dev enabler of `slopdesk-posix`'s `winsize-set` — `TIOCSWINSZ` has exactly one
# writer and this is it (`docs/51` §6.9). The suite runs a fake superd over a real AF_UNIX socket
# with a real `openpty` behind it, so the ioctls are checked against a terminal rather than a mock.

# cargo test for hostd's half of one pane (rust/slopdesk-hostpane)
hostpane-test:
    cd rust/slopdesk-hostpane && cargo test

# One pane's SESSION (docs/60 stage C.2): the shell that joins the pane below, the mux channel above
# and `muxsession`'s verdicts beside it — the drain thread, the two relays and two senders per
# member, the pause gate, the exit ladder and the teardown. Its own crate for the reason the header
# of its manifest gives: each of the three it sits on refuses it, and each refusal is worth keeping.
# The suite runs the whole path — a fake superd on a real socket, a real PTY, and real sub-channels
# whose framed bytes are decoded back out of the link — so what it asserts is what a client would
# have received.

# cargo test for one pane's session (rust/slopdesk-hostsession)
hostsession-test:
    cd rust/slopdesk-hostsession && cargo test

# hostd's COMPOSITION (docs/60 stage D): the session table over `muxsession`'s registry, and the
# parked-pane store over its retention rules. Its own crate because composition cannot live inside
# any of the crates it composes — `muxsession` is verdicts with no IO, `hostsession` is ONE pane and
# knows nothing of the table it sits in. The suite drives both through a six-method pane trait
# rather than a real session, which is what lets a retention test be a retention test instead of a
# PTY, a superd and six threads per entry.

# cargo test for hostd's composition (rust/slopdesk-hostserver)
hostserver-test:
    cd rust/slopdesk-hostserver && cargo test

# The bridge onto the user's OWN zsh completion (rust/slopdesk-zshcomplete). Its `tests/live.rs`
# SPAWNS a real `zsh -f` over a pty and drives a synthetic completion function through it — the one
# thing no fixture can check, because the `compadd` flag scan is only wrong against a real shell.
# Hermetic (no rc, `compinit -D`), so it asserts about the scan and never about the machine; it
# skips itself where there is no zsh at all.

# cargo test for the zsh completion bridge (rust/slopdesk-zshcomplete)
zshcomplete-test:
    cd rust/slopdesk-zshcomplete && cargo test

# The decision half of one pane's CLIENT session — the same carve as `muxsession` above, from the
# other end of the wire: which output seq is new, what the resume presented, whether an ack is owed,
# whether a campaign may run, and how long the next retry waits. `SlopDeskClient` keeps its actor,
# its transport and its four pumps; what came out is the table of cases underneath them, whose every
# failure was silent rather than visible.

# cargo test for one client session's decisions (rust/slopdesk-clientsession)
clientsession-test:
    cd rust/slopdesk-clientsession && cargo test

# The DRIVER half of the same pane session, standing to `clientsession` exactly as `hostsession`
# stands to `muxsession`: the threads, the locks and the queues that the decision crate must not
# carry, because an iOS slice links that one for its arithmetic alone. One supervisor thread owns
# every state change, which is what dissolves the Swift actor's connect generation counter, its
# teardown depth and both of its post-handshake re-checks — none of the four is expressible when
# commands run to completion in order on a single thread.
#
# Its suite runs against loopback sockets and a hand-rolled host, not a fake transport the driver
# defined itself: the twelve Swift suites this replaces could not tell you whether the bytes they
# deduped had ever been on a wire.

# cargo test for one client pane session's driver (rust/slopdesk-clientdriver)
clientdriver-test:
    cd rust/slopdesk-clientdriver && cargo test

# The interactive remote terminal, and the LAST thing `docs/63` moved out of Swift. Its own crate
# rather than a `slopdesk` subcommand because the shipped name is release-facing (`docs/49` signs
# it); its own workspace root rather than a member because it is a per-byte relay that lives as long
# as a shell session and wants the client profile, not the CLI's startup-tuned one.
#
# The 534-line `main.swift` it replaces held four types that existed only to hold Swift's
# concurrency together — a `DispatchSource`→`AsyncStream` resize bridge, a hand-rolled bounded pipe
# re-creating `write(2)`'s backpressure, a lock around one exit code, and a `Shutdown` that stopped
# two foreign producers before `exit(3)` could leave the terminal raw. None of the four is replaced:
# the resize wait IS a thread in `sigwait`, the backpressure IS `send_input` blocking, and the
# terminal is put back by a `Drop` that runs because `main` RETURNS a code.

# Build slopdesk-client, the interactive remote terminal (rust/slopdesk-client)
client:
    cd rust/slopdesk-client && cargo build --release

# cargo test for the client CLI's arg parse (rust/slopdesk-client)
client-test:
    cd rust/slopdesk-client && cargo test

# THE crown-jewel end-to-end proof, and the one thing in this file that launches two SHIPPED
# binaries against a real PTY. It is what `SubprocessE2ETests` was, re-homed with its subject: six
# scenarios — an echo over TCP, a pane opening in `$HOME` rather than the daemon's cwd, scrollback
# surviving a hostd restart, a cold reattach keeping the cursor shape, two clients on one PTY, and
# the count from the PROCESS TABLE that a second client forks no second shell.
#
# hostd, superd and screend are SEPARATE cargo workspaces, so an integration test in
# `slopdesk-client` cannot ask cargo where any of them is. This recipe builds all three: hostd is
# NAMED in the environment, the other two are FOUND beside their own manifests. Without
# `SLOPDESK_E2E_HOSTD_BIN` the suite SKIPS rather than fails, which is what keeps `client-test` cheap
# and honest.
#
# The variable is deliberately not `SLOPDESK_HOSTD_BIN`: `docs/46` records THAT name as having no
# reader, and the absence is the claim — a search order for hostd beside the installer's is exactly
# what the row rules out. This one is scoped to the harness by its name.
#
# screend is here for a reason worth stating, because it is not obvious from the assertions: hostd's
# state-transfer composer renders a journal THROUGH the screen engine, and an engine that does not
# answer is not an error — the restore quietly demotes to the distilled path. So an unaimed run does
# not skip and does not fail cleanly; it dials whichever screend the developer's live host started,
# which is how these two scenarios passed on one machine and failed on the next. The suite now points
# at a PRIVATE engine from this tree, and this dependency is what puts it there.

# The three SHIPPED binaries against a real PTY (rust/slopdesk-client/tests)
client-e2e: host superd screend
    cd rust/slopdesk-client && \
        SLOPDESK_E2E_HOSTD_BIN="$PWD/../slopdesk-hostd/target/release/slopdesk-hostd" \
        cargo test --test subprocess_e2e -- --test-threads=1 --nocapture

# fzf's `FuzzyMatchV2` — the ranking behind every search field (command palette, Open-Quickly,
# command navigator, Jump-To). Its own crate for the same reason `altscreen` is: it is a pure
# algorithm with no protocol knowledge, and it wants `opt-level = 3` where the daemons want `"z"`.

# cargo test for the fuzzy matcher (rust/slopdesk-fuzzy)
fuzzy-test:
    cd rust/slopdesk-fuzzy && cargo test

# Installing the `slopdesk` command — where the link goes, whether one is already there, whose file
# it is, and the `symlink` itself. Its own crate because the alternatives lend it a subject it does
# not have: `slopdesk-cli`'s lib is the command's argv grammar, and linking that into a GUI would
# pull a parser in for twenty lines of `std::fs`. It depends on nothing.

# cargo test for the CLI symlink (rust/slopdesk-clilink)
clilink-test:
    cd rust/slopdesk-clilink && cargo test

# The two device consoles' line grammars — `logcat -v time` and `log stream --style compact`, which
# were the same parser written twice in Swift over text a device wrote, on the socket read path. Its
# own crate for `slopdesk-fuzzy`'s reason: a pure function with no protocol knowledge, wanting
# `opt-level = 3` where the daemons want `"z"`, and only half of it is Android's.

# cargo test for the device console grammars (rust/slopdesk-devicelog)
devicelog-test:
    cd rust/slopdesk-devicelog && cargo test

# The two device panels' shared decisions — what one ensure round means, how soon to ask again, and
# what to do about a selection with no video yet. The Android and simulator models each held a
# byte-identical copy; its own crate because it reads `slopdesk-wire`'s `ServiceState`. It sat here
# originally because `slopdesk-wire` already depended on `slopdesk-workspace`; that edge is gone —
# the wire now reaches only `slopdesk-ids` and `slopdesk-tree` — so the crate stands on its own.

# cargo test for the device panel decisions (rust/slopdesk-devicepanel)
devicepanel-test:
    cd rust/slopdesk-devicepanel && cargo test

# The same two panels' SOCKETS — the RFC 6455 handshake, the frame codec and its reassembler, the
# reader thread, and the Android bridge's line-then-stream call. Its own crate rather than a module
# of `slopdesk-devicepanel` because that crate is PURE by charter and this one opens `TcpStream`s
# and spawns threads; folding them would put a socket inside the one crate whose whole claim is
# that it has none.

# cargo test for the device panel sockets (rust/slopdesk-devicelink)
devicelink-test:
    cd rust/slopdesk-devicelink && cargo test

# PATH 2's CLIENT sockets — the two UDP flows, their reader threads, the lane table a datagram is
# admitted against, and the teardown that joins. Its own crate rather than a module of
# `slopdesk-video` for the reason that crate's charter states, the same one that split
# `slopdesk-devicelink` off `slopdesk-devicepanel`: a `UdpSocket` inside it would end the property
# that every function in it is a fold a test can drive without a machine.

# cargo test for the client video sockets (rust/slopdesk-videolink)
videolink-test:
    cd rust/slopdesk-videolink && cargo test

# The client control socket's vocabulary — its method names, its three token sets and its NDJSON
# framing. Its own crate because TWO programs speak that socket: `slopdesk` writes the requests and
# the app's `ClientControlDispatcher` reads them, and the app reaches it through `slopdesk-ffi`,
# which cannot link a module of the CLI's own library. It held the golden that pins the request
# bytes, which is why this recipe is not folded into `cli-test`.

# cargo test for the client control vocabulary (rust/slopdesk-clientctl)
clientctl-test:
    cd rust/slopdesk-clientctl && cargo test

# The superd control socket's framing — tags, lengths and the two packed bodies. Its own crate for
# `slopdesk-screenwire`'s reason: superd writes these frames and hostd reads them, and the layout
# was spelled in superd's `frame.rs` AND in `SupervisorFrame.swift`, each calling the other a
# mirror. The app links the framing without linking `nix` and a PTY supervisor with it.

# cargo test for the superd control framing (rust/slopdesk-superwire)
superwire-test:
    cd rust/slopdesk-superwire && cargo test

# What one Claude Code hook body SAYS, in the detection vocabulary — the mapping that used to be a
# typed payload enum plus an adapter a module away, which is how the two drifted. Its own crate
# because it takes `serde_json`, which `slopdesk-agent` (zero-dependency, every input untrusted)
# will not, and because it wants `opt-level = 3` where the relay wants `"z"`.

# cargo test for the hook body reader (rust/slopdesk-hookevent)
hookevent-test:
    cd rust/slopdesk-hookevent && cargo test

# The two row scans a regex engine drives: Hint Mode's targets and find-in-terminal's matches.
# Their own crate because it takes `regex` — the linear-time engine that lets a pattern a human typed
# meet a row a remote program wrote without a backtracking hang — which `slopdesk-terminal`
# (dependency-free, on the PTY hot path) will not.

# cargo test for the regex row scans (rust/slopdesk-rowscan)
rowscan-test:
    cd rust/slopdesk-rowscan && cargo test

# Stage 5 of the same port: the PATH-2 video protocol, opening at the FEC math (GF(2^8),
# Reed-Solomon, the erasure codec). A LIBRARY like `wire` — nothing links it yet, so `video-test` is
# the only thing between it and a silent drift away from `Sources/SlopDeskVideoProtocol`. It replays
# the committed `fecParity` / `fecRecover` corpus, so it is the parity gate, not a smoke test.

# Build slopdesk-video (rust/slopdesk-video)
video:
    cd rust/slopdesk-video && cargo build --release

# cargo test for the FEC codec (unit + golden-vector parity against the Swift codec)
video-test:
    cd rust/slopdesk-video && cargo test

# The headless closed-loop harness over the same protocol: a synthetic frame through the REAL
# hardware encoder, the real packetizer at a chosen FEC tier, index-chosen fragment loss, the real
# reassembler with its parity recovery, the real hardware decoder — and every pure controller on
# synthetic telemetry beside it. No capture, no Metal, no window server, no grant, no clock and no
# randomness, so a verdict that moved is a behaviour that moved. Nothing here is a unit test: the
# reassembler, the recovery policies and the pacer have no golden vector, and this is what stands in
# for one. Run `--smoke` after any wire or FEC change; the bare run before believing a controller.

# Build + smoke the closed-loop video harness (rust/slopdesk-loopback-validate)
loopback-validate:
    cd rust/slopdesk-loopback-validate && cargo build --release
    rust/slopdesk-loopback-validate/target/release/slopdesk-loopback-validate --smoke

# The one crate `slopdesk-video` links, and the third in the tree allowed to write `unsafe`: the
# GF(2^8) byte-region kernels, in NEON. Read its `Cargo.toml` header for why the isolation is drawn
# where it is. Its tests are a differential against the scalar twin, which is the only thing that
# says the shuffle and the field agree.

# cargo test for the SIMD kernels (vector path vs scalar oracle, guarded arenas)
gfsimd-test:
    cd rust/slopdesk-gfsimd && cargo test

# The first crate of the `slopdesk-apple-*` family (`docs/57`): CoreGraphics event synthesis, called
# through `objc2`. macOS-only by construction, and linked into the FFI archive's macOS slice only.
# Its suite does NOT post an event — a test that moved the developer's cursor would be a test nobody
# could run — so what it proves is the modifier table, the thread-local source, and the LEAK check
# `docs/57` §3 asks of every crate in the family, read off the objects' own retain counts.

# cargo test for the CoreGraphics injection wrapper (flags table, source reuse, leak check)
apple-cgevent-test:
    cd rust/slopdesk-apple-cgevent && cargo test

# The `WindowServer`'s read side, split into its two framework areas: the window list and the
# display list. Neither suite needs a window server to be worth running — the window one builds real
# `CFDictionary`s and decodes them, which is where a wrong key constant or a defaulted-instead-of-
# dropped field shows, and it carries §3's leak check as a retain count across ten thousand decodes.
# The display one is honest about being partly vacuous on a headless runner and pins the shape of a
# real answer rather than the existence of one.

# cargo test for the window-list decode (key constants, drop-on-missing, leak check)
apple-cgwindow-test:
    cd rust/slopdesk-apple-cgwindow && cargo test

# cargo test for the display-list reads (space agreement, handle-leak check)
apple-cgdisplay-test:
    cd rust/slopdesk-apple-cgdisplay && cargo test

# The display-list's WRITE side: four private `CoreGraphics` classes reached by NAME through the
# Objective-C runtime, which is why this area stays in the `apple-*` family and spends neither
# CoreFoundation admission. Headless-honest the way `apple-cgdisplay-test` is — a runner with no
# window server answers `private_classes_available` false and every entry point says "no display"
# rather than crashing, and the suite asserts exactly that refusal. Every NUMBER a geometry carries
# is `slopdesk-video`'s and pinned by the golden corpus; nothing here recomputes one.

# cargo test for the virtual-display area (class lookup, refusal path, registration lifetime)
apple-cgvirtualdisplay-test:
    cd rust/slopdesk-apple-cgvirtualdisplay && cargo test

# `IOPMAssertion` — the one resource in this family that does not self-heal. A leaked assertion keeps
# the Mac, or its screen, awake until the process dies, and no test anywhere else turns red for it.
# So the suite is mostly balance: ten thousand asserted/released edges and ten thousand held-then-
# dropped assertions, each ending by asking whether the process can still assert at all, which a
# kernel-side table that grew without bound would eventually refuse.

# cargo test for the sleep assertions (create/release balance, drop balance, leak check)
apple-power-test:
    cd rust/slopdesk-apple-power && cargo test

# `NSRunningApplication` — a pid in, a bundle id / hidden flag / activation out. One of the two
# crates in the family that write NO `unsafe` at all (`apple-nsapp` below is the other):
# `objc2-app-kit` generates every call it makes as safe, which is the bar `docs/57` §3 sets per crate
# rather than as a budget. Its suite asks about pids that name nothing, because that is the whole
# failure mode — every caller reads the answer as "not eligible" and must fail CLOSED rather than on
# a stale or defaulted value.

# cargo test for the running-application reads (nothing-pid answers, no-snapshot property)
apple-app-test:
    cd rust/slopdesk-apple-app && cargo test

# `NSApplication` — the OTHER half of AppKit, and a different framework area: not which app owns a
# pid, but what THIS process is. Three calls, no decisions. `.accessory` initialises the shared
# application, which is what establishes the window-server connection `SCStream.startCapture` aborts
# without (`CGS_REQUIRE_INIT`) even though the `SCShareableContent` enumeration works fine without
# one — the reason that failure reads as a missing Screen-Recording grant and is not. The two loops
# stay two on purpose: `dispatch_main()` is the proven default, `NSApplication.run()` is the arm the
# virtual display needs because a registered `CGVirtualDisplay` wants a live `CFRunLoop` the queue
# drain does not provide, and unifying them is a claim about the default path nobody has measured.
# Every call is generated SAFE behind a `MainThreadMarker`, so the suite can only reach the refusal
# half — a `cargo test` thread is not the main thread, and an off-main caller must be answered rather
# than trapped, because a wiring mistake in a daemon's launch order should not be a crash in the
# field.

# cargo test for the NSApplication connection (off-main refusal, refusals accumulate nothing)
apple-nsapp-test:
    cd rust/slopdesk-apple-nsapp && cargo test

# `NSEvent` — where the pointer IS, in global Cocoa points, and nothing else. A different framework
# area than `slopdesk-apple-cursor`'s `NSCursor`, which is the cursor's IMAGE: one class method, no
# `MainThreadMarker` in its generated signature, and no `unsafe`. The missing marker is the point —
# `mouseLocation` is a window-server query rather than view state, so the 120 Hz sampler calls it
# from its own thread instead of hopping, and the suite's whole job is to hold that: the read
# answers a finite point from an off-main thread and a thousand of them accumulate nothing.

# cargo test for the NSEvent pointer read (off-main is finite, leak check)
apple-nsevent-test:
    cd rust/slopdesk-apple-nsevent && cargo test

# The cursor shape the person is actually looking at. `NSCursor.currentSystemCursor` crosses the
# window-server boundary, so it needs a main thread — which a `cargo test` thread is not, and that
# is the arm the suite covers: an off-main read must answer NOTHING rather than trap, because the
# sampler's hot path is deliberately off-main and a trap there would take the daemon with it. The
# leak check runs that read a thousand times and asks whether anything accumulated.

# cargo test for the NSCursor read + PNG render (off-main answers nothing, leak check)
apple-cursor-test:
    cd rust/slopdesk-apple-cursor && cargo test

# One app's accessibility tree: its windows, their frames, the four effects on one of them (move,
# resize, un-minimize, raise), and one bounded walk for the searches that do not know which element
# they want. Every reading needs a live app AND the Accessibility grant, which is why the two Swift
# files this replaced BOTH carried a standing "compiled + reviewed, not driven from unit tests"
# note — so what this suite can ask is the refusal half: no app, no window, no grant, no allowance.
# The DECISIONS those readers used to make in the same breath live in `slopdesk-video`'s `ax_probe`
# and `nav_history` instead, under `forbid(unsafe_code)`, where they are ordinary tests. The leak
# check creates and releases ten thousand elements and asks whether anything accumulated.

# cargo test for the accessibility tree (refusals without a grant, walk bounds, leak check)
apple-ax-test:
    cd rust/slopdesk-apple-ax && cargo test

# The one Core Text question slopdesk asks: what family name is inside a font FILE. `slopdesk font
# import` copies a face into `~/Library/Fonts` and then has to tell the user what to paste under
# `[terminal]`, and that string is neither the filename nor derivable from it. The suite covers the
# refusal half exhaustively — a non-font, a missing file, an empty path all read as NO NAME, which
# is what lets the CLI say one sentence about every way it can fail — plus the happy path against a
# system face, which doubles as this crate's leak test: a thousand reads, three CF references each.

# cargo test for the Core Text family-name read (refusals, real face, leak check)
apple-text-test:
    cd rust/slopdesk-apple-text && cargo test

# The three crates docs/68's terminal surface is made of, in the order the bytes travel: the engine
# and its confinement (`slopdesk-vterm`), the layout and glyph residency over its frames
# (`slopdesk-termrender`), and the Metal encode that draws them (`slopdesk-apple-metal`). Three
# recipes rather than one because they are three cargo workspaces — each carries a profile its
# neighbours do not want — and `just test` reaches a workspace only by entering its directory.

# cargo test for the terminal engine: the session, the frame scan, selection, find, input
vterm-test:
    cd rust/slopdesk-vterm && cargo test

# cargo test for the terminal renderer: layout, blocks, the glyph atlas, the quad builder
termrender-test:
    cd rust/slopdesk-termrender && cargo test

# cargo test for the corpus recorder: the one input order, and the minimal child environment
ttyrec-test:
    cd rust/slopdesk-ttyrec && cargo test

# The two conformance sweeps over ghostty's OWN minimised fuzz corpus, alone. They are already
# inside `vterm-test` and `termrender-test` — this recipe exists to run them without the 600 unit
# tests around them, which is what you want while chasing one disagreement.
#
# It also REPORTS the skip the tests cannot. Both sweeps read the corpus out of the provisioned
# ghostty tree (`GHOSTTY_SOURCE_DIR`) and pass quietly when it is absent, because a bare checkout
# must not fail a test for a tree it never fetched. Here that is worth saying out loud, because
# "green" and "green over 3271 inputs" are not the same claim.

# The terminal's agreement with ghostty: the frame read, and the paint over it (docs/68 §6.4)
terminal-conformance:
    #!/bin/sh
    set -e
    tree="ThirdParty/tools/.prefix/ghostty"
    if [ ! -d "$tree" ]; then
      printf 'terminal-conformance: ghostty is not provisioned — run `just provision` first.\n'
      printf '  Without it the fuzz-corpus sweeps pass on the COMMITTED corpus only.\n'
      printf '  The recorded sessions in rust/slopdesk-vterm/corpus run either way.\n'
    fi
    cd rust/slopdesk-vterm && cargo test conformance -- --nocapture
    cd ../slopdesk-termrender && cargo test conformance -- --nocapture

# cargo test for the Metal encode (pipeline, texture upload, the device probe)
apple-metal-test:
    cd rust/slopdesk-apple-metal && cargo test

# cargo test for the VideoToolbox session (option dictionaries, timestamps, leak check)
apple-vt-test:
    cd rust/slopdesk-apple-vt && cargo test

# The GUI video daemon itself. Nothing it does to a framework can be reached by a test — capture
# needs a window server and a grant, injection needs Accessibility — which is exactly why every
# DECISION it takes lives in `slopdesk-video` and is asked there. What IS testable here is the half
# that is this crate's own: the argv grammar, the `video-prefs.json` overlay and its precedence, the
# mux lane registry's mint-on-first-hello, the encoder session's lifetime, and the window feed's
# TTL cache and differ. Its own `[workspace]` (a daemon's profile, not the fork-per-event `opt-level
# = "z"`) is why `cargo -p` from `rust/` cannot reach it and this recipe has to `cd`.

# Build slopdesk-videohostd (rust/slopdesk-videohostd)
videohostd:
    cd rust/slopdesk-videohostd && cargo build --release

# cargo test for the GUI video daemon (argv, overlay, mux registry, encoder lifetime, window feed)
videohostd-test:
    cd rust/slopdesk-videohostd && cargo test

# The AudioToolbox row. The ONE crate in the `slopdesk-apple-*` family exempt from §2's raw-pointer
# ban, because Core Audio hands out SAMPLE MEMORY rather than objects — `AudioBufferList` is a C
# flexible-array member and `AudioConverterFillComplexBuffer` fills it through a callback. The
# exemption is a RATCHET at a fixed site count, enforced by `invariants-test`, not a door.
#
# Unlike apple-sck and apple-vt, this suite runs the real framework end to end: the round-trip test
# builds an AAC-ELD encoder AND decoder and asserts the wire cadence, which needs no window server
# and no grant. That test is what `slopdesk-loopback-validate --audio` used to be.

# cargo test for the AudioToolbox codecs (real AAC-ELD round trip, leak checks)
apple-audio-test:
    cd rust/slopdesk-apple-audio && cargo test

# The client's speakers: the jitter stage's hand-off, the producer-side resampler and the cpal
# stream. `forbid(unsafe_code)` — picking cpal over another AudioToolbox wrapper is what keeps the
# one real-time deadline in the client free of hand-written unsafe. Headless-safe: a machine with no
# output device answers a player that works and stays mute, which every test asserts against.

# cargo test for client audio output (hand-off, resampler, cpal device lifecycle)
audio-out-test:
    cd rust/slopdesk-audio-out && cargo test

# The capture stream. Every reading needs a window server AND the Screen-Recording grant, which is
# why the Swift this replaced carried a standing "compiled and code-reviewed, its start() is NEVER
# called from a test" note. So what this suite asks is the half that never needed either: the
# request a spec turns into, the shape of a filter's inputs, what a refusal answers, and the
# handoff's ceiling. Every RULE those calls are made under is `slopdesk-video`'s `capture_config`,
# tested under `video-test`. The leak check builds and drops the configuration many times over.

# cargo test for the ScreenCaptureKit stream (spec to request, refusals, leak check)
apple-sck-test:
    cd rust/slopdesk-apple-sck && cargo test

# `NSPasteboard`, plus the `NSBitmapImageRep` transcode that is the family's one `unsafe` block. Every
# reading here needs no window server — a pasteboard is a pasteboard-server object and
# `NSPasteboard.withUniqueName` gives each test its own, which is why this suite can ask the whole
# question the Swift `SystemPasteboard` could only assert about: what a write declares, what a read
# picks when several flavours are declared, and what bytes that are not an image do. The leak check
# is the transcode loop: 2,000 reps built from hostile bytes and dropped, with the last board still
# writable.

# cargo test for the pasteboard (flavours, the TIFF transcode, leak check)
apple-pasteboard-test:
    cd rust/slopdesk-apple-pasteboard && cargo test

# `FSEvents`. The crate passes a NULL context and keys its callback off the stream ADDRESS, so what
# the suite asks is the balance that design buys: a dropped watch lets go of its listener (the
# `Arc` goes 2 -> 1), leaves no row in the process-wide map, and stays balanced even for a stream
# the framework will never report on. One test is end-to-end — a real write under a temp directory,
# waited for on a condition variable rather than a sleep — because a callback that never fires is
# the failure mode a registry test cannot see.

# cargo test for the FSEvents watch (registry balance, a real change, leak check)
apple-fsevents-test:
    cd rust/slopdesk-apple-fsevents && cargo test

# The workspace LABEL, and the smallest crate in the family: one `NSHost` read, no `unsafe` at all.
# The suite cannot assert the name — it is whatever the machine running it is called — so it asserts
# the two properties the caller depends on instead. An EMPTY name never leaves as a `Some`, because
# hostd's fallback ladder cannot see past one and would caption a workspace with a blank. And a
# thousand asks agree and hold nothing, which is both the leak check and the proof this is not the
# frozen per-process snapshot `NSWorkspace.frontmostApplication` turned out to be.

# cargo test for the host's own name (empty is absent, repeat asks agree, leak check)
apple-machine-test:
    cd rust/slopdesk-apple-machine && cargo test

# The pane census — which processes belong to one PTY, and what they are listening on. Everything
# here used to be Swift that no test could reach: `HostMetadataProbe` carried a standing note that
# it was compiled and code-reviewed ONLY, because every reading needs a live PTY and a real `lsof`.
# What that note protected was the syscalls; what it also covered was a hand-rolled parser for
# hostile subprocess output. Behind this boundary the parse is a function over a string, so the
# suite is the one that could never be written: malformed `lsof` lines, an address with no port, a
# clock that moved backwards, and a descriptor that is not a PTY censusing NOTHING rather than the
# machine's whole process table.

# cargo test for one pane's process and port census (lsof parse, caps, empty-pane answers)
panecensus-test:
    cd rust/slopdesk-panecensus && cargo test

# The memory half of that: what actually reads the loads and stores for a pointer that left its
# allocation or its provenance. `CLAUDE.md` says the third `unsafe` crate was bought with "a
# differential suite that runs under Miri" — and until this line, NOTHING ran it. Not `check`, not
# `test`, not the prek hooks, not the disabled CI. An obligation no recipe reaches is a sentence in
# a document.
#
# It is in `check` because it turns out to be cheap: the `#[cfg(miri)]` seed reduction inside
# `tests/differential.rs` brings the sweep to 47 s wall clock, compile included, against the
# "minutes" this comment used to claim. Still out of `just test`, which the pre-push hook runs on
# every push — that path is measured in the seconds it saves.

# Run rust/slopdesk-gfsimd's differential suite under Miri (~47 s; the unsafe memory audit)
miri:
    rustup component add miri --toolchain nightly
    cd rust/slopdesk-gfsimd && cargo +nightly miri test

# Stage 12: the workspace document's DOMAIN rules — the layout math the wire's intents drive. Also a
# LIBRARY nothing links yet, so `workspace-test` is what stands between it and a silent drift away
# from `Sources/SlopDeskWorkspaceModel`.

# Build slopdesk-workspace (rust/slopdesk-workspace)
workspace:
    cd rust/slopdesk-workspace && cargo build --release

# cargo test for the workspace domain rules
workspace-test:
    cd rust/slopdesk-workspace && cargo test

# The three crates carved OUT of slopdesk-workspace when it reached 25k lines and `slopdesk-wire`
# — which holds the golden-pinned protocol — was found to depend on all of it. Each gets its own
# recipe for the same reason `workspace-test` has one: `test-rust` sweeps every workspace, but a
# named recipe is what someone reaches for when they change one crate, and a crate with no name
# here is a crate nobody runs deliberately.

# Build slopdesk-ids (rust/slopdesk-ids)
ids:
    cd rust/slopdesk-ids && cargo build --release

# cargo test for pane/tab identity, the JSON writer and shell quoting
ids-test:
    cd rust/slopdesk-ids && cargo test

# Build slopdesk-tree (rust/slopdesk-tree)
tree:
    cd rust/slopdesk-tree && cargo build --release

# cargo test for the workspace DOCUMENT — geometry, splits, sessions, focus, tree ops
tree-test:
    cd rust/slopdesk-tree && cargo test

# Build slopdesk-settings (rust/slopdesk-settings)
settings:
    cd rust/slopdesk-settings && cargo build --release

# cargo test for the key table, the file resolver, the schema and its checked-in copy
settings-test:
    cd rust/slopdesk-settings && cargo test

# The JSON Schema `config.toml` is described by, written out of the SAME key table the app resolves
# against. Generated, never edited: a hand-maintained schema is a second declaration of every key
# and would drift the day somebody added one. `settings-test` fails when the checked-in copy is
# stale, so this recipe is what that failure asks for.

# Regenerate docs/config.schema.json from the key table
config-schema:
    cd rust/slopdesk-settings && cargo run --release --quiet --bin write-config-schema

# The code panel's injected dressing: the stylesheet, the four user scripts and the recommendation
# catalogue the workbench's own server never forwards. A LEAF library the FFI artifact links, so
# `codepanel-test` is what stands between it and a page dressed with a string nobody read.

# Build slopdesk-codepanel (rust/slopdesk-codepanel)
codepanel:
    cd rust/slopdesk-codepanel && cargo build --release

# cargo test for the code panel's injected sheet, scripts and tips catalogue
codepanel-test:
    cd rust/slopdesk-codepanel && cargo test

# Stage 13: the half of agent detection that reads the CLOCK — the status state machine, the block
# ledger, the dissent watchdog, the confirmation holds and the input classifier. screend (docs/52)
# keeps the half that reads the BYTES. A LIBRARY nothing links yet, so `agent-test` is what stands
# between it and a silent drift away from `Sources/SlopDeskAgentDetect`.

# Build slopdesk-agent (rust/slopdesk-agent)
agent:
    cd rust/slopdesk-agent && cargo build --release

# cargo test for the agent-detection state machine
agent-test:
    cd rust/slopdesk-agent && cargo test

# Stage 15: the CLIENT side of the byte stream — which screen the host is presenting (DECSET 1049,
# OSC 133) and which output bytes are only the PTY echoing the compose box back. screend reads the
# HOST's bytes for detection, slopdesk-wire reads them as FRAMES; this reads them for the INPUT
# SURFACE. A LIBRARY nothing links yet, so `terminal-test` is what stands between it and a silent
# drift away from `Sources/SlopDeskClaudeCode`.

# Build slopdesk-terminal (rust/slopdesk-terminal)
terminal:
    cd rust/slopdesk-terminal && cargo build --release

# cargo test for the terminal mode tracker + input echo dedup
terminal-test:
    cd rust/slopdesk-terminal && cargo test

# Stage 16: the WHOLE user-facing `slopdesk` CLI — argv in, one dispatch, an exit code out. It is
# the process now, not a core behind a Swift face: the `[[bin]]` here IS the `slopdesk` the tarball
# ships, and `Package.swift` declares no CLI executable at all. A MEMBER of the root workspace, not
# a workspace of its own: it wants the hook's startup-tuned profile for the same reason ctl does,
# and `lint-rust` already reaches it through `cargo clippy --workspace`.
#
# ITS Cargo.toml IS A RELEASE SITE. `slopdesk version` prints `CARGO_PKG_VERSION`, so the number
# there is one of the six the product carries — `slopdesk-release bump-product` owns it, never a
# hand edit. See docs/49 §"The six version sites" and docs/DECISIONS.md, stage 16.

# Build the slopdesk CLI (rust/slopdesk-cli)
cli:
    cd rust && cargo build --release -p slopdesk-cli

# cargo test for the `slopdesk` CLI
cli-test:
    cd rust && cargo test -p slopdesk-cli

# hostd's argv grammar and the launch record it publishes for itself — one crate because `--port 0`
# is accepted by the first and only answerable by the second. A member of the root workspace for the
# reason `slopdesk-sidecars` is: both its callers are here, the `.xcframework` the daemon links and
# `slopdesk-ops restart-hostd`. The suite is mostly the reader's contract — which four fields a
# restart cannot proceed without, which four are report-only, and the key ORDER on disk, which is a
# property a person greps and which `serde`'s declaration order is the only thing holding.

# cargo test for hostd's argv grammar and launch record (round-trip, key order, the stamp)
hostlaunch-test:
    cd rust && cargo test -p slopdesk-hostlaunch

# docs/49: is the sidecar RUNNING the sidecar that is INSTALLED — the verdict, the restart policy,
# and the MANIFEST.json diff. A member of the root workspace for the reason the two above are: both
# its callers are fork-and-exit programs (`slopdesk sidecars`) or link it through the xcframework
# (hostd's startup audit), and it holds no state that wants a daemon's profile.

# cargo test for the per-sidecar version policy + manifest diff
sidecars-test:
    cd rust && cargo test -p slopdesk-sidecars

# Stage 22: the code panel's workbench PROFILE — the settings seed and its whole retired corpus, the
# theme + bridge extensions, the profile registry, the child's argv and environment. hostd keeps the
# SUPERVISION (the handle, the readiness probe, the learned port); this owns every decision about a
# FILE, which is what those 2.7k lines of Swift actually were. Its own workspace for the profile
# reason the daemons record. NOT staged next to hostd: `RustServicePaths` finds it by walking up
# to `rust/slopdesk-codeseed/target/`, the same way it finds every other daemon in this tree, so a
# `cargo clean` can never leave a copy behind that lies about which profile the panel seeds.

# Build slopdesk-codeseed (rust/slopdesk-codeseed)
codeseed:
    cd rust/slopdesk-codeseed && cargo build --release

# cargo test for the code-server profile seeder
codeseed-test:
    cd rust/slopdesk-codeseed && cargo test

# The DAEMON — the composition `hostserver` is composed BY. Its own workspace for the profile
# reason every daemon in this tree has one, so `cargo test` from `rust/` cannot reach it and this
# recipe is the only thing that runs its suite. What it covers is what only the binary can decide:
# which doors `compose` builds, in which order the stop reaches them, and whether a workspace store
# that finds nothing on disk still hands a client a session, a tab and a pane.

# cargo test for the daemon's own composition (rust/slopdesk-hostd)
hostd-test:
    cd rust/slopdesk-hostd && cargo test

# The inner loop for host work. hostd is a cargo binary as of docs/60 stage F, and its crate is its
# OWN cargo workspace, so this is a `cd` and not a `-p` — `rust/Cargo.toml` cannot reach it.
#
# RELEASE, where the Swift `--product` build was debug. Two reasons, and neither is taste: the
# recorded launch this machine replays names `release` (`slopdesk-hostlaunch::record`), so a debug
# build here would leave `host-restart` starting a binary this recipe never touched; and an
# unoptimised Rust daemon is not the daemon — the pane fan-out and the row scan were measured at
# `opt-level = 3`, and reading a debug one's latency would be reading a different program.

# Build ONLY slopdesk-hostd (release, the configuration the launch record replays)
host:
    cd rust/slopdesk-hostd && cargo build --release

# The whole edit loop in one command, and the reason docs/51 exists: superd keeps every pane, both
# child-facing sockets and the panel backends, so this costs a client reconnect rather than the
# afternoon's work. It prints the observed downtime and superd's child count on either side.

# Rebuild hostd and restart the running one, identically (docs/51 §9)
host-restart:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-ops -- restart-hostd

# Report the running hostd (pid, port, flags) and superd's child count; change nothing
host-status:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-ops -- restart-hostd --status

# `hook-test` runs FIRST and unconditionally. `swift build`/`swift test` never compile the Rust
# crate, so a Swift-only gate is blind to it; and the pre-push green-tree cache keys on the
# Swift inputs alone (Package.swift Sources Tests Apps golden), so a rust/ change would hit the
# cache and skip everything. Warm cargo costs ~0.07s and fails before the ~60s Swift run.
#
# The six sidecars at the END of the list are BUILT here, not merely tested, and the reason has
# CHANGED even though the list has not. It used to be the Swift fixtures: `SuperdFixture` and
# `ScreendFixture` booted a real daemon and `XCTSkip`ped by name without one, so a `swift test` that
# never sees cargo reported green over the whole supervised surface. `docs/60` F.9 deleted those
# fixtures and every suite they skipped, and `docs/63` G.5 took the last Swift subprocess suite.
#
# What actually launches a real binary today is two files, and neither is reached from here:
# `rust/slopdesk-screend/tests/idle_exit.rs` (its own crate, so `screend-test` builds it) and
# `rust/slopdesk-client/tests/subprocess_e2e.rs` (`just client-e2e`, which builds `host` and
# `superd` itself). Every other daemon-shaped test uses a FAKE — `slopdesk-screenclient`'s answers
# on a real `AF_UNIX` socket with the wire crate's own encoder, and hostserver's spell paths like
# `/opt/slopdesk-ctl` that are never executed.
#
# The builds STAY because `just test` is also what leaves a tree you can run: `just host-restart`
# and `slopdesk-ops` want the sidecars present. Removing them is a separate change with its own
# argument, not a tidy-up of this comment.
#
# `client-e2e` is in this list and NOT in `quick`, and the asymmetry is deliberate. It is the one
# suite that proves the shipped binaries talk to each other over a real socket against a real PTY,
# so a full run that skipped it would be green about everything except the product. It is also ~11s
# of daemon boots on top of two release builds, which is the whole inner loop's budget — `quick`
# answers "did my edit compile and hold", and this answers "does it still ship", and those are
# different questions asked at different moments. It went missing from the gate for exactly one
# stage: it used to ride `swift test` as `SubprocessE2ETests`, `docs/63` G.5 made it a cargo test,
# and `client-test` runs it with the env var unset — a vacuous green by design. This line is what
# closes that.

# cargo test (relay + agent CLI + metadata probe + the unsafe surface + the C ABI + the git engine + custodian + screen engine + file drop + android bridge + inspector + wire codec + alt-screen cut scanner + one pane session's decisions + hostd's PATH-1 listener + hostd's superd client + hostd's screend client + hostd's half of one pane + one pane's session + hostd's composition + the daemon's own composition + one client session's decisions + one client pane session's driver + fuzzy matcher + device console grammars + device panel decisions + the client control vocabulary + superd framing + hook bodies + row scans + FEC codec + SIMD kernels + CoreGraphics injection + the window and display lists + the virtual display + the two sleep assertions + the running-application reads + the cursor shape + the accessibility tree + the Core Text family name + the VideoToolbox session + the GUI video daemon + the AudioToolbox codecs + client audio output + the capture stream + the pasteboard + the repo watch + the host's own name + one pane's process and port census + workspace rules + identity + the document tree + the settings catalogue + the code panel dressing + agent detection + terminal input + the corpus recorder + CLI core + hostd's launch + sidecar versions + code-server profile + the pinned-dependency provisioner + the operator tools + the instruments' arithmetic) + swift test with the green-tree cache
test: ffi hook-test invariants-test devtools-test ctl-test probe-test posix-test ffi-test git-test superd-test screend-test dropd-test androidd-test inspectord-test wire-test altscreen-test clipboard-test muxsession-test muxnet-test clientnet-test hostnet-test superclient-test screenclient-test hostpane-test hostsession-test hostserver-test zshcomplete-test hostd-test clientsession-test clientdriver-test client-test fuzzy-test clilink-test devicelog-test devicepanel-test devicelink-test videolink-test clientctl-test superwire-test hookevent-test rowscan-test video-test gfsimd-test apple-cgevent-test apple-cgwindow-test apple-cgdisplay-test apple-cgvirtualdisplay-test apple-power-test apple-app-test apple-nsapp-test apple-nsevent-test apple-cursor-test apple-ax-test apple-text-test vterm-test termrender-test ttyrec-test apple-metal-test apple-vt-test videohostd-test apple-audio-test audio-out-test apple-sck-test apple-pasteboard-test apple-fsevents-test apple-machine-test panecensus-test workspace-test ids-test tree-test settings-test codepanel-test agent-test terminal-test cli-test hostlaunch-test sidecars-test codeseed-test provision-test instruments-test client-e2e ctl superd screend dropd androidd inspectord
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- pre-push

# The same six sidecars, for the same reason as `test` above and with more at stake: this is the
# gate CLAUDE.md tells you to run after every edit, and a daemon-backed suite that cannot find its
# binary reports green having run nothing — a fast gate that cannot see the regressions it exists
# for. The build is what makes the skip impossible rather than merely unlikely.

# Fast inner loop: incremental build + only the test targets the change set reaches
test-touched: ctl superd screend dropd androidd inspectord
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- test-touched

# Golden regression pin: mint the wire corpus from the live native-Swift codecs and assert
# byte-identity to golden/golden_vectors.json (replaces the old cross-language Rust golden_parity).
# The minter is `Tests/SlopDeskCoreVectorsTests`, a SUITE and not a binary — the gate runs it with
# every SLOPDESK_* stripped and reads the mint off .work/golden/corevectors.json, which is also the
# file a legitimate wire change merges FROM. NEVER `>` it over the corpus: the corpus also holds the
# frozen keys the suite cannot mint.

# Verify the wire codecs still reproduce golden/golden_vectors.json
golden:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-gate -- golden

# ---------------------------------------------------------------------------- #
# The release metadata, generated from the commit log rather than hand-maintained. The commit TYPE
# decides both the CHANGELOG.md section a change lands in and whether the version moves a minor or
# a patch, which is why the `commit-msg` hook (`slopdesk-release commit-msg`) gates the subject at
# commit time. The whole pipeline is ONE binary — `rust/slopdesk-devtools/src/release/` — where it
# used to be eight shell scripts sharing a tool table by `source`-ing each other.

# Regenerate CHANGELOG.md from the commit log (git-cliff)
changelog:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-release -- changelog render

# Print the version and release notes the next cut would produce; write nothing
release-preview:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-release -- cut --dry-run

# The version a cut is FORCED to, when it is not computed from the commit log. A variable AND the
# recipe's default, so both spellings land in the same place: `just release 0.3.0` passes it
# positionally and `just VERSION=0.3.0 release` overrides the variable. `just release VERSION=0.3.0`
# is the one spelling that does NOT work — just would read that whole string as the positional — so
# the recipe refuses an argument carrying `=` rather than cutting a release called "VERSION=0.3.0".
VERSION := ""

# Commits and tags LOCALLY; pushing the tag is the separate keystroke that starts the signing
# pipeline. `just release 0.3.0` forces a version instead of computing it.

# Cut a release: version + CHANGELOG.md + the six version sites + commit + tag
release version=VERSION:
    @case '{{version}}' in *=*) echo "release: '{{version}}' is not a version — say 'just release 0.3.0'"; exit 1 ;; esac
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-release -- cut {{version}}

# ---------------------------------------------------------------------------- #
# Which SIDECARS the next release would move, and which it would leave alone.
#
# The product version moves on every cut; a sidecar's moves only when its own sources did. That is
# what lets an upgrade replace the daemon that changed and leave the others running — restarting
# superd costs the user every live pane (`docs/51`), and it should cost that only when superd
# actually changed. `slopdesk-release stamps` is what can tell, and `MANIFEST.json` in the tarball
# is where the answer ships.
#
# NOT part of `check` or `quick`, deliberately: a sidecar whose sources changed since the last
# release is the ordinary state of `main`, so a gate here would be red almost always and mean
# nothing when it was. The gate that DOES run is `every-sidecar-is-pinned` in
# `rust/slopdesk-invariants` — every shipped sidecar
# must have a pin entry — and the one that refuses to ship a lie is `slopdesk-release package`,
# which asks each built binary its version and compares it with the pin.

# Show which sidecars changed since the last release, and the bump each would take
tool-versions:
    cd rust/slopdesk-devtools && cargo run --release --quiet --bin slopdesk-release -- bump-tools --dry-run

# ---------------------------------------------------------------------------- #
# The panel's RUNTIME deps (code-server, baguette, adb, scrcpy-server), pinned by URL + SHA-256 in
# ThirdParty/tools/tools.lock. Not part of `build` or `test`: the whole Swift package builds and
# tests headless without any of them, and provisioning downloads ~250 MB.
# `--release` on purpose: the whole cost of this recipe is a 250 MB transfer and a gzip/deflate
# pass over it, and a debug `flate2` turns the extract from seconds into minutes.

# Fetch + verify the pinned host-side runtime deps into ThirdParty/tools/.prefix
provision:
    cd rust/slopdesk-provision && cargo run --release --quiet

# Report which pinned deps are present; download nothing
provision-check:
    cd rust/slopdesk-provision && cargo run --release --quiet -- --check

# The crate's OWN suite: the lock parser, the archive readers and the digest walk. It is in `test`
# even though `provision` is not in `build`, and the two facts do not conflict — running the tests
# opens no socket and downloads nothing, while the recipe above is the one that transfers 250 MB.
# `lint-reach` is what insists on the distinction: a crate that carries tests and has no recipe
# reports green about code nobody ran.

# cargo test for the pinned-dependency provisioner
provision-test:
    cd rust/slopdesk-provision && cargo test

# The four command-line instruments, and the same distinction `provision-test` draws one recipe up:
# RUNNING one needs a GUI session, a Screen-Recording grant or a live daemon on the other end of a
# socket, so none of them is in `build` or in any gate — but their pure halves decide what every
# number they print MEANS, and those run anywhere. `slopdesk-framewatch` is the whole reason this
# recipe exists: the arithmetic under its capture — the flip hysteresis, the flash pairing window,
# the percentile floor, the luma walk and the checksum lattice — is where a cadence result is
# actually computed, and two of its tests pin the report text to the Swift original's byte for byte.
# Its own workspace for the profile reason (`opt-level = "z"` would report a number nothing in
# production sees), so `rust/`'s `cargo test` cannot reach it and this `cd` is the only thing that
# does.

# cargo test for the operator instruments' arithmetic (rust/slopdesk-instruments)
instruments-test:
    cd rust/slopdesk-instruments && cargo test

# ---------------------------------------------------------------------------- #
# DEV tooling only (linters + hooks) — deliberately still brew. These shape the gates, not the
# product: a formula drifting a minor version changes a lint message, it does not put the panel on
# a workbench three releases old. The deps that DO decide product behaviour are in `provision`.
# `just` is on the list even though you already have it: a machine that got it from cargo rather
# than brew still wants brew's copy pinned beside the linters it runs.

# Install all required tools (brew) and the git hooks
install-tools: hooks
    brew install just swiftlint swiftformat shellcheck shfmt prek git-cliff xcodegen
    # The formatter's toolchain, INSTALLED-OR-UPDATED to the latest nightly — the same verb does
    # both, which is the point: `fmt-rust` and `lint-rust` ask for floating `+nightly`, so "install
    # the tools" and "be on the current one" are one step, not a pin somebody has to remember to
    # bump. Without it every fmt path dies on rustup's own "toolchain is not installed", which reads
    # as a broken justfile rather than a missing dependency.
    rustup toolchain install nightly --component rustfmt --profile minimal

# Install the prek git hooks (pre-commit + pre-push)
hooks:
    prek install
