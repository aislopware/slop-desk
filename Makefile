# Strict formatter / linter / static-analysis entrypoints for the whole repo.
# Configs: .swiftformat .swiftlint.yml ruff.toml .shellcheckrc rust/rustfmt.toml rust/Cargo.toml
#
#   make fmt    — auto-format everything (writes)
#   make fix    — fmt + apply every safe lint autofix (writes)
#   make lint   — run every linter strictly, no writes (what CI gates on)
#   make check  — lint + build + test + Miri + golden pin + the iOS triple (the full local gate)
#
# Tools are pinned/installed via `make install-tools`.
# Swift + Rust: two short-lived programs in
# the root workspace (rust/slopdesk-hook, the Claude Code hook relay + its installer — stage 23;
# rust/slopdesk-probe, the host metadata RPC's git/directory/session half + the TERM
# resolution — stages 24 and 25;
# rust/slopdesk-ctl, the
# agent-control CLI; rust/slopdesk-cli, the `slopdesk` CLI core — stage 16; rust/slopdesk-codeseed,
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
# `swift build`; `make ffi` (scripts/build-ffi.sh) assembles that artifact beforehand.
# `swift build` therefore needs the xcframework to EXIST before it can resolve the package graph, so
# a clean checkout runs `make ffi` — or any of `make build`/`test`/`check`, which depend on it —
# once. `make build` additionally stages the relay and the CLI beside the host binary.

SWIFT_PATHS  := Sources Tests Apps
# Format (SwiftFormat) also covers the package manifest; the SwiftLint scope stays
# Sources/Tests/Apps (Package.swift is config, not linted).
SWIFTFMT_PATHS := Package.swift $(SWIFT_PATHS)
# ThirdParty/ghostty/ only: that tree is the vendored libghostty build recipe, carried close to
# upstream's own shape. ThirdParty/tools/provision.sh is OURS and meets the same bar as scripts/.
#
# Read off the FILESYSTEM, not `git ls-files`. Tracking is not the same question as ownership, and
# using it as a proxy silently dropped five scripts — `check-supervisor.sh` and `build-ffi.sh` among
# them, the two this repo leans on hardest. They are untracked, so `git ls-files` never named them,
# so shellcheck had never run on either and `make fmt-shell` had never touched them: a lint scope
# that shrinks when a file is new is exactly backwards. Every `.sh` we own lives in `scripts/` (the
# 25 tracked ones all do) plus the one under `ThirdParty/tools`, and a glob says so without a list.
SHELL_FILES  := $(wildcard scripts/*.sh) ThirdParty/tools/provision.sh
PY_FILES     := $(wildcard scripts/*.py)
SHFMT_FLAGS  := -i 2 -ci -sr

# Every Rust WORKSPACE ROOT: `rust/` itself, plus each crate that declares its own `[workspace]` and
# is therefore invisible to `cargo --workspace` run at the root. Derived for the same reason the
# shell list above is: the seventeen were spelled out by hand three times over (once in `fmt-rust`,
# twice in `lint-rust`), so adding a crate meant remembering three places and forgetting one left it
# silently unlinted — the failure `docs/46` warns about in the row about this very target.
RUST_WORKSPACES := rust $(patsubst %/Cargo.toml,%,$(shell grep -l '^\[workspace\]' rust/*/Cargo.toml))

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------- #
.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
		| sort | awk -F':.*## ' '{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------- #
# Formatting (writes)
.PHONY: fmt fmt-swift fmt-shell fmt-python fmt-rust
fmt: fmt-swift fmt-shell fmt-python fmt-rust ## Auto-format all languages

# `.swiftformat` states the division of labour: SwiftFormat owns formatting, SwiftLint owns lint.
# The division does not survive contact with `leading_whitespace`. SwiftFormat cannot remove a blank
# line at the START of a file — `consecutiveBlankLines` collapses three to two and stops, and no
# other rule reaches file position 0 (checked against every rule's `--ruleinfo`). SwiftLint enforces
# it, so `make fmt-swift` could not produce a tree `make lint-swift` accepts: the one thing a format
# target exists to guarantee.
#
# So the WRITE half of SwiftLint lives here, in the target that writes, and `lint-swift` stays
# strictly read-only (`--lint`, and `swiftlint` with no `--fix`). It is a no-op on a clean tree —
# verified: zero output, byte-identical `git status` and diffstat — so it costs a pass over the tree
# and changes nothing until something is genuinely unformatted.
#
# `--fix` only, never `analyze --fix`. The analyzer half (`unused_import`, `unused_declaration`)
# judges by a compiler log from ONE configuration, so it deletes imports that only an `#if os(iOS)`
# branch uses; it belongs to a deliberate, verified sweep, not to a formatter people run on reflex.
fmt-swift: ## Format Swift (SwiftFormat, then SwiftLint's correctable rules)
	swiftformat $(SWIFTFMT_PATHS)
	swiftlint --fix --quiet

fmt-shell: ## Format shell (shfmt)
	@if [ -n "$(SHELL_FILES)" ]; then shfmt $(SHFMT_FLAGS) -w $(SHELL_FILES); fi

fmt-python: ## Format Python (ruff format)
	@if [ -n "$(PY_FILES)" ]; then ruff format $(PY_FILES); fi

# rustfmt.toml turns on nightly-only options (wrap_comments, group_imports, format_strings …).
# Only the FORMATTER needs nightly; the crate itself builds and tests on stable.
# EVERY workspace, matching `lint-rust` — the daemons each have their own (see the note there), and a
# formatter that skips what the linter checks means `make fmt && make lint` fails on its own output.
fmt-rust: ## Format Rust (nightly rustfmt — rust/rustfmt.toml uses unstable options)
	@for ws in $(RUST_WORKSPACES); do (cd $$ws && cargo +nightly fmt --all) || exit 1; done

# ---------------------------------------------------------------------------- #
# Autofix (writes) — formatting + every safe lint autocorrect
.PHONY: fix
fix: fmt ## Format + apply all safe lint autofixes
	-swiftlint --fix --quiet
	@# Every workspace, for the reason `fmt-rust` and `lint-rust` are: `cd rust && … --workspace`
	@# autofixes the root's four members and leaves the other sixteen crates for `make lint` to fail on.
	-@for ws in $(RUST_WORKSPACES); do (cd $$ws && cargo clippy --workspace --all-targets --fix --allow-dirty --allow-staged) || true; done
	-[ -n "$(PY_FILES)" ] && ruff check --fix $(PY_FILES)
	-[ -n "$(SHELL_FILES)" ] && shellcheck -f diff $(SHELL_FILES) | git apply --allow-empty 2>/dev/null

# ---------------------------------------------------------------------------- #
# Linting (no writes) — the CI gate
.PHONY: lint lint-swift lint-shell lint-python lint-rust lint-rust-clippy test-rust lint-ds-leaks lint-menu-shortcutless lint-ffi-doors lint-ban-union lint-shared-constants lint-supervisor lint-invariants
LINTERS := lint-swift lint-shell lint-python lint-rust lint-ds-leaks lint-menu-shortcutless lint-ffi-doors lint-ban-union lint-shared-constants lint-supervisor lint-invariants

# The seven linters run CONCURRENTLY. They read the tree and write nothing, so nothing orders them,
# and serially they were the inner loop's largest fixed cost: 55 s, of which `lint-supervisor` alone
# is 35 s. Overlapping the other six with it is free wall clock — measured 55 s → 36 s.
#
# Not a plain prerequisite list under `make -j`: the top-level `make` is not invoked with one, and a
# prerequisite list only runs in parallel if the make expanding it was told to. And not `-j` here
# either, because this repo's make is 3.81 (Apple's), which has no `--output-sync` — seven linters
# interleaving diagnostics line by line is a gate whose failures cannot be read. So each runs into
# its OWN log, and the logs are replayed IN THE DECLARED ORDER once every one has finished. The
# output is byte-identical to the serial gate's; only the waiting changed.
#
# `wait` on a KNOWN pid, for the reason `build-ffi.sh` and `check-supervisor.sh` say: a bare `wait`
# yields zero however the jobs died, and a lint gate that passes on a dead linter is worse than a
# slow one. Every linter is waited on before the exit status is returned, so one failure does not
# leave six tools running against a tree the next command is about to edit.
lint: ## Run every linter strictly
	@dir=$$(mktemp -d -t slopdesk-lint); trap 'rm -rf "$$dir"' EXIT; \
	for t in $(LINTERS); do \
	  $(MAKE) --no-print-directory $$t > "$$dir/$$t.log" 2>&1 & echo $$! > "$$dir/$$t.pid"; \
	done; \
	rc=0; \
	for t in $(LINTERS); do \
	  wait $$(cat "$$dir/$$t.pid") || rc=1; \
	  if [ -s "$$dir/$$t.log" ]; then printf '── %s ──\n' "$$t"; cat "$$dir/$$t.log"; fi; \
	done; \
	exit $$rc

lint-swift: ## SwiftFormat --lint + SwiftLint --strict
	swiftformat $(SWIFTFMT_PATHS) --lint
	swiftlint --strict --quiet

# Design-system leak RATCHET: fail on a new raw .font(.system(size:)) / integer cornerRadius: in a view
# file (text-only, no compile — runs in the lint gate, not the build gate). See scripts/check-ds-leaks.sh.
lint-ds-leaks: ## Design-system token-leak ratchet (raw font/radius literals)
	bash scripts/check-ds-leaks.sh

# Menu-bar shortcut-LESS RATCHET (E1 N6): fail on a `.keyboardShortcut(` in the discoverability-only
# WorkspaceCommands.swift — the NSEvent dispatcher owns chords (text-only, no compile). See the script.
lint-menu-shortcutless: ## Menu-bar shortcut-less ratchet (no .keyboardShortcut in WorkspaceCommands)
	bash scripts/check-menu-shortcutless.sh

# DEAD FFI DOOR ratchet. `build-ffi.sh --check` catches the loud failure of a linked port — an
# artifact older than its sources. This catches the quiet one: a door nothing calls, which costs
# nothing at runtime and everything at read time, because the next reader cannot tell a second way
# to ask from the only way to ask. Text-only, no compile. See scripts/check-ffi-doors.py.
lint-ffi-doors: ## Dead-FFI-door ratchet (every exported door is called, or named deliberate)
	python3 scripts/check-ffi-doors.py

# check-supervisor.sh walks Sources/ ONCE for its twenty-one "this Swift must stay deleted" bans,
# each of which then re-greps only the candidates. Sound only while the union is a superset of every
# ban — drop one out and that ban reports SUCCESS on the file it exists to catch, which is the
# silent pass the gate has a whole section warning about. So the union is verified, not trusted.
lint-ban-union: ## The one-walk ban filter really contains every ban that filters through it
	python3 scripts/check-ban-union.py

# TRANSCRIBED-CONSTANT ratchet, the counterpart of the dead-door one above. That gate catches a door
# nothing calls; this catches the number that should have been a door — a constant with the same name
# and the same value on both sides of the boundary. Nothing else would: both languages compile, both
# suites pass, and the two copies agree right up until one of them is tuned. Text-only, no compile.
lint-shared-constants: ## No number is spelled in both languages unless it is asked for or ratcheted
	python3 scripts/check-shared-constants.py

# hostd ↔ superd CONTRACT ratchet: the constants that are necessarily typed in both languages
# (rendezvous socket name, protocol version, verbs, frame tags, body cap, PTY read chunk) compared
# textually, plus the "nothing in Sources/ reads a PTY master" invariant. Text-only, no compile, no
# daemon — the skew it catches is invisible to both languages' own suites, because each side is
# internally consistent. `scripts/check-supervisor.sh --tests` adds the runs that need a toolchain.
lint-supervisor: ## hostd/superd cross-language contract ratchet
	bash scripts/check-supervisor.sh

# The same ratchets, as a program. Sections migrate here one at a time and the shell section is
# DELETED in the commit that ports it, so there is never a period where both enforce the same rule.
# It reads the tree once instead of spawning a grep per question — half a second against the shell's
# two and a half minutes — and every rule carries a unit test that seeds the breakage and asserts
# the rule fires, which is the one thing a shell section could not have.
lint-invariants: ## the ported cross-language ratchets, in Rust
	@cd rust/slopdesk-invariants && cargo run --release --quiet -- --root ../..

# The break-tests, which are the reason the port is worth doing: each seeds the drift its rule
# exists to catch and asserts the rule fires. `the_live_tree_satisfies_every_rule` is in there too,
# so this target is also the gate — which is what lets `cargo test` here stand in for the whole
# script during development.
invariants-test: ## cargo test for the ratchets and their break-tests
	cd rust/slopdesk-invariants && cargo test

# The `if` form is load-bearing. A `[ -n … ] && cmd` chain exits nonzero on an EMPTY file
# list, and the `|| true` that silences THAT silences every real diagnostic with it: the tool
# prints its findings and the gate still passes. `if` yields 0 for the empty list and the
# tool's own exit status otherwise. Same tools, flags and file sets as the CI `shell-python`
# job, so local green implies CI green rather than the reverse.
lint-shell: ## shellcheck + shfmt --diff
	@if [ -n "$(SHELL_FILES)" ]; then shellcheck $(SHELL_FILES); fi
	@if [ -n "$(SHELL_FILES)" ]; then shfmt $(SHFMT_FLAGS) -d $(SHELL_FILES); fi

lint-python: ## ruff check + ruff format --check
	@if [ -n "$(PY_FILES)" ]; then ruff check $(PY_FILES); fi
	@if [ -n "$(PY_FILES)" ]; then ruff format --check $(PY_FILES); fi

# Rust: clippy at all/pedantic/nursery/cargo + a curated restriction slice, every group DENY
# (rust/Cargo.toml `[workspace.lints]`), so `-D warnings` is the belt to those braces. `--all-targets`
# reaches the test code too. The format check needs nightly for the same reason `fmt-rust` does.
# `slopdesk-superd` is a SEPARATE workspace (rust/slopdesk-superd/Cargo.toml explains why: the hook
# needs `panic = "abort"`, superd needs `panic = "unwind"`, and profiles are workspace-global). It
# is `exclude`d from rust/Cargo.toml, so `--workspace` does NOT reach it — hence the second pair of
# invocations. Forgetting them is a silently unlinted daemon.
lint-rust: lint-rust-clippy ## clippy -D warnings (all targets) + rustfmt --check, all 17 Rust workspaces
	@for ws in $(RUST_WORKSPACES); do (cd $$ws && cargo +nightly fmt --all -- --check) || exit 1; done

# Split out because the pre-commit hook wants clippy WITHOUT the `fmt --check`: prek runs hooks in
# parallel, and the `rustfmt (apply)` hook is rewriting the very files a `--check` would be reading.
lint-rust-clippy: ## clippy -D warnings across every Rust workspace (no fmt check)
	@for ws in $(RUST_WORKSPACES); do (cd $$ws && cargo clippy --workspace --all-targets --all-features -- -D warnings) || exit 1; done

# The pre-commit hook's Rust test sweep, and the same `--workspace`-does-not-reach-them story: the
# hook used to run `cd rust && cargo test --workspace` while firing on ANY `rust/**.{rs,toml}` change,
# so a commit to fifteen of the seventeen crates ran the OTHER two crates' tests and reported green.
# ~16 s warm for the lot, which is what makes it a commit-time gate rather than a push-time one. The
# named per-crate targets below stay: they are how you run ONE crate, and `make test` composes them.
test-rust: ## cargo test across every Rust workspace (~16 s warm)
	@for ws in $(RUST_WORKSPACES); do (cd $$ws && cargo test --workspace --quiet) || exit 1; done

# SwiftLint analyzer rules need the compiler INVOCATIONS, which only a verbose build prints. Minutes,
# not seconds — ~750 files, each re-parsed by a real frontend — so this stays out of `lint` and runs
# on demand. `.swiftlint.yml` says `analyzer_rules: all`, so what it covers is every analyzer rule
# SwiftLint ships.
#
# It fed `.build/debug.yaml`, which is llbuild's build MANIFEST and not a compiler log. SwiftLint
# accepted the path, collected nothing out of it, and printed "Found 0 violations, 0 serious in 0
# files" — a clean exit over an empty file set. The `|| echo <note>` that was meant to catch exactly
# that could not fire, because nothing had failed: the target had never once run an analyzer rule and
# had reported success for it every time. Same shape as the `|| true` warned about above `lint-shell`,
# reached by a different road.
#
# So: a real `-v` log, no `|| echo`, and the file count asserted. Analysing zero files is the failure
# it always was, and the exit status of the analyzer itself is what the target exits with — never
# `tee`'s, which is why the log is written first and printed second.
#
# The clean is load-bearing, not caution. `-v` prints the commands SwiftPM RUNS, so a warm tree
# prints none, the log carries no `swift-frontend` line, and the count assertion below fails on a
# tree with nothing wrong with it. The price is a full rebuild every time this target is asked for,
# and the reason it is out of `lint`.
.PHONY: lint-swift-analyze
lint-swift-analyze: ## SwiftLint analyzer rules (full rebuild + analyze; minutes, not seconds)
	swift package clean
	swift build --build-tests -v > .build/swiftlint-compiler.log 2>&1 || \
		{ tail -40 .build/swiftlint-compiler.log; exit 1; }
	@swiftlint analyze --strict --compiler-log-path .build/swiftlint-compiler.log \
		> .build/swiftlint-analyze.log 2>&1; \
	status=$$?; \
	cat .build/swiftlint-analyze.log; \
	grep -qE 'in [1-9][0-9]* files' .build/swiftlint-analyze.log || \
		{ echo "lint-swift-analyze: analysed 0 files — the compiler log carries no swiftc invocation"; exit 1; }; \
	exit $$status

# ---------------------------------------------------------------------------- #
# Full gate
.PHONY: check quick check-ios check-macos-apps check-ios-tests build test test-touched golden ffi ffi-test hook hook-test ctl ctl-test posix-test superd superd-test superd-install screend screend-test screend-install dropd dropd-test androidd androidd-test inspectord inspectord-test wire wire-test altscreen-test fuzzy-test devicelog-test devicepanel-test superwire-test hookevent-test rowscan-test video video-test gfsimd-test apple-cgevent-test apple-cgwindow-test apple-cgdisplay-test apple-app-test apple-cursor-test apple-ax-test apple-vt-test apple-sck-test panecensus-test miri workspace workspace-test invariants-test ids ids-test tree tree-test settings settings-test agent agent-test terminal terminal-test cli cli-test sidecars-test codeseed codeseed-test probe probe-test git-test host host-restart host-status
check: lint build test miri golden check-ios check-macos-apps ## lint + build + test + the unsafe memory audit + golden pin + both app triples (full local gate)

# THE INNER LOOP. Run this after every edit; run `check` once before pushing.
#
# It is `check` with two substitutions and one omission, and each of the three is a claim about what
# a single edit can break:
#
#   test → test-touched   The full suite re-runs every Swift target for a change that reaches three.
#                         `test-touched.sh` attributes the change set to SwiftPM targets and runs the
#                         test targets whose closure contains them — escalating to the full suite
#                         whenever it cannot attribute a path, so it is fail-toward-slow, not
#                         fail-toward-green. A touched-green never writes the pre-push marker, so
#                         this can never make a push skip what it did not run.
#   check-ios (stamped)   Unchanged as a gate; it just costs nothing when no iOS-compiled input moved
#                         (scripts/check-ios.sh explains the stamp). It stays IN the inner loop for
#                         that reason — the `#if os(iOS)` surface breaks on a Swift edit like any
#                         other, and now noticing costs nothing on the edits that cannot break it.
#   miri omitted          ~47 s to re-audit `rust/slopdesk-gfsimd`, which only a change to that crate
#                         can affect. `make miri` by hand when touching it; `check` runs it anyway.
#
# `build` is not omitted so much as implied: `test-touched` builds incrementally before selecting.
#
# Warm, on an untouched tree, this is seconds. The floor is `lint-supervisor` — ~31 s of ratchets
# that read the whole tree. It was 44 s until the twenty-one "this Swift must stay deleted" bans
# stopped walking `Sources/` twenty-one times for an answer that is empty whenever they pass (see
# `DELETED_SWIFT_UNION`); what is left is the honest price of the cross-language contracts.
# `ffi` and `lint` come first and in order — the artifact before anything that links it, and the
# linters before the slow half, so a formatting slip fails in seconds rather than after the tests.
# The slow half then runs CONCURRENTLY, ordered logs and known pids exactly as `lint` does: after a
# Swift edit `test-touched` and `check-ios` are the two costs left, they share nothing but the
# SwiftPM lock (which only makes `golden` wait, and `golden` is three seconds), and serially the
# inner loop paid their sum. Measured on one Swift edit: 5:46 serial, and the iOS half of that was
# two schemes where one does the work.
QUICK_SLOW := test-touched golden check-ios check-macos-apps

quick: ffi lint ## The INNER LOOP: lint + only the tests the change reaches + golden + the (stamped) iOS triple
	@dir=$$(mktemp -d -t slopdesk-quick); trap 'rm -rf "$$dir"' EXIT; \
	for t in $(QUICK_SLOW); do \
	  $(MAKE) --no-print-directory $$t > "$$dir/$$t.log" 2>&1 & echo $$! > "$$dir/$$t.pid"; \
	done; \
	rc=0; \
	for t in $(QUICK_SLOW); do \
	  wait $$(cat "$$dir/$$t.pid") || rc=1; \
	  if [ -s "$$dir/$$t.log" ]; then printf '── %s ──\n' "$$t"; cat "$$dir/$$t.log"; fi; \
	done; \
	if [ $$rc -eq 0 ]; then \
	  printf 'quick: green — run `make check` before pushing (adds the full suite + miri)\n'; \
	fi; \
	exit $$rc

# `swift build` compiles the macOS slice ONLY — it never type-checks a `#if os(iOS)` source, so the
# UIKit input host and the iOS components in Sources/SlopDeskPhoneUI/iOS/ compiled only in someone's
# head. `scripts/check-ios.sh` has existed for exactly that and was reachable from no target, no
# hook and no workflow. It was also RED: two xcframeworks each shipped `Headers/module.modulemap`,
# Xcode copies both to `$BUILT_PRODUCTS_DIR/include/`, and neither app had built on either platform
# since (fixed in scripts/build-ffi.sh, which now nests its headers and asserts the nesting).
#
# `check-macos.sh` is the sibling and is deliberately NOT here: it drives a real window and needs a
# logged-in GUI session, so it cannot run from a headless gate.
check-ios: ffi ## iOS-triple typecheck (the `#if os(iOS)` surface `swift build` never compiles)
	bash scripts/check-ios.sh

# The OTHER half of the same hole. `check-ios` compiles `Apps/ClientApp-iOS`; `swift build` compiles
# `Sources/` and `Tests/`. Nothing compiled the two macOS app shells, because they are Xcode targets
# rather than SwiftPM ones — so a rename under `Sources/` could leave `Apps/ClientApp-macOS` unable
# to build while every gate stayed green, which is exactly what happened to `VideoSurfaceHost`.
#
# Distinct from `check-macos.sh`, which BUILDS AND RUNS the app against a real window and therefore
# needs a logged-in GUI session. This one only type-checks, so it is headless and belongs here.
check-macos-apps: ffi ## macOS app-shell typecheck (the `Apps/` code no other gate compiles)
	bash scripts/check-macos-apps.sh

# The half `check-ios` does not do: it type-checks and runs ZERO tests. `swift test` compiles the
# MACOS branch of every `#if os(iOS)` fork, so an iOS default asserted there is asserted about the
# wrong branch — a macOS build of `platformDefaultFollowSessionFocus` reads the opposite value.
# `scripts/check-ios-tests.sh` is the only thing in the repo that executes an assertion on the iOS
# triple, and it too was reachable from no target: `docs/46` calls it the ONLY executor of iOS tests
# and then nothing ran it.
#
# NOT in `check`: it boots a simulator, which a headless gate cannot assume — same reason
# `check-macos.sh` stays out. Run it after touching anything inside an `#if os(iOS)`.
check-ios-tests: ffi ## RUN the iOS tests on a booted simulator (the only assertions on that triple)
	bash scripts/check-ios-tests.sh

# The three arm64 static slices the Swift clients link, from `rust/slopdesk-ffi`. FIRST, and not
# optional: `Package.swift` declares a `binaryTarget` at that path, so SwiftPM cannot even resolve
# the graph without it. The script stamps its inputs and exits in milliseconds when nothing changed,
# which is what makes it safe to put in front of every build.
ffi: ## Build ThirdParty/slopdesk-ffi/SlopDeskFFI.xcframework (macos + ios + ios-sim arm64)
	bash scripts/build-ffi.sh

build: ffi hook ctl codeseed probe ## swift build (Swift + the linked Rust FFI slices) + the Rust hook relay, agent CLI, profile seeder and metadata probe
	swift build
	@cp rust/target/release/slopdesk-hook "$$(swift build --show-bin-path)/slopdesk-hook"
	@cp rust/target/release/slopdesk-agenthooks "$$(swift build --show-bin-path)/slopdesk-agenthooks"
	@cp rust/target/release/slopdesk-ctl "$$(swift build --show-bin-path)/slopdesk-ctl"
	@cp rust/target/release/slopdesk-probe "$$(swift build --show-bin-path)/slopdesk-probe"

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
hook: ## Build the Rust hook relay + its installer (rust/slopdesk-hook)
	cd rust && cargo build --release -p slopdesk-hook

hook-test: ## cargo test for the hook relay
	cd rust && cargo test -p slopdesk-hook

# The agent-control CLI. Was Swift; ported for the same reason as the hook and measured the same
# way — an agent forks it once per `read`/`wait`/`write`/`run`, so its cost IS process startup.
# Above the fork/exec floor the Swift build spent 3.47 ms getting useful work done, this one spends
# 0.73 ms. Same root workspace as the hook because it wants the same startup-tuned profile; staged
# next to hostd by `build:`, which is where `slopdesk-hostd/main.swift` looks for the sibling it
# exports as `SLOPDESK_CTL_BIN`.
ctl: ## Build the Rust agent-control CLI (rust/slopdesk-ctl)
	cd rust && cargo build --release -p slopdesk-ctl

ctl-test: ## cargo test for the agent-control CLI
	cd rust && cargo test -p slopdesk-ctl

# The host metadata RPC's git, directory and session half. hostd forks it per request, which for
# `gitStatus` — the verb the project-scoped watcher polls on a cadence — is FEWER spawns than before:
# that one verb forked `git` four times from hostd's own queue, and now makes those four inside a
# program hostd spawns once. The rest of the shim (the pane's cwd, its processes, its ports) needs
# the PTY master fd and stays in Swift. It also answers the TERM question — whether this host can
# resolve `xterm-ghostty` — which is the same shape of question about the same machine. Same root
# workspace as the hook for the same startup-tuned profile; staged next to hostd by `build:`, which
# is where `HostProbe.locate` looks.
probe: ## Build the Rust host probe (rust/slopdesk-probe)
	cd rust && cargo build --release -p slopdesk-probe

probe-test: ## cargo test for the metadata probe
	cd rust && cargo test -p slopdesk-probe

# The process custodian (docs/51). Builds like the hook but is NOT staged next to the host binary:
# it is a launchd agent installed out of the build tree, because launchd re-execs its path and a
# `cargo clean` must not be able to leave the agent pointing at nothing.
superd: ## Build slopdesk-superd (rust/slopdesk-superd)
	cd rust/slopdesk-superd && cargo build --release

superd-test: ## cargo test for the process custodian
	cd rust/slopdesk-superd && cargo test

# The whole of the tree's `unsafe`, and therefore the whole of what a reviewer has to check by hand.
# `--all-features` is not optional here: `winsize-set` gates the one function superd may not call in
# production, and a test run that skipped it would leave that code uncompiled and unlinted.
posix-test: ## cargo test for the isolated unsafe surface (rust/slopdesk-posix)
	cd rust/slopdesk-posix && cargo test --all-features

# The C ABI, tested through the exported symbols rather than through the Rust functions behind
# them — an entry point that marshals its arguments wrongly passes every test of the crate it wraps.
ffi-test: ## cargo test for the C ABI Swift calls (rust/slopdesk-ffi)
	cd rust/slopdesk-ffi && cargo test

# The git engine. Its suite builds REAL repositories under the temp directory and compares every
# answer with the `git` binary's own — the parity that let the four subprocesses be deleted. It is a
# separate workspace because it vendors libgit2, which the fork-per-event root workspace must not
# link (see the crate's manifest).
git-test: ## cargo test for the in-process git status (rust/slopdesk-git)
	cd rust/slopdesk-git && cargo test

superd-install: ## Build + (re)install the com.slopdesk.superd LaunchAgent — RESTARTS superd
	bash scripts/install-superd.sh

# The VT screen engine (docs/52): the terminal parser, the snapshot renderer and the overprint
# collapser, which used to be the hottest Swift in the tree (17.9 MiB/s against 186 in Rust). Its
# own workspace for the same reason superd is: profiles are workspace-global and this one wants
# `opt-level = 3` where the hook wants `"z"`.
screend: ## Build slopdesk-screend (rust/slopdesk-screend)
	cd rust/slopdesk-screend && cargo build --release

screend-test: ## cargo test for the screen engine
	cd rust/slopdesk-sanitize && cargo test
	cd rust/slopdesk-screenwire && cargo test
	cd rust/slopdesk-screend && cargo test

screend-install: ## Build + (re)install the com.slopdesk.screend LaunchAgent
	bash scripts/install-screend.sh

# PATH 4's daemon (docs/53): the file-drop endpoint clients dial DIRECTLY on `terminalPort + 2`.
# hostd no longer binds that port or sees a body byte — superd spawns dropd and keeps it, so an
# upload in flight survives a host restart. Its own workspace for the same profile reason as above.
dropd: ## Build slopdesk-dropd (rust/slopdesk-dropd)
	cd rust/slopdesk-dropd && cargo build --release

dropd-test: ## cargo test for the file-drop service
	cd rust/slopdesk-dropd && cargo test

# The Android panel's bridge (docs/48): `adb` orchestration and the scrcpy byte pump, which clients
# dial DIRECTLY. It used to be a listener inside hostd, so an H.264 mirror was pumped by the daemon
# that owns every keystroke and `make host-restart` took every mirror down with it. Same
# own-workspace reason as the three above.
androidd: ## Build slopdesk-androidd (rust/slopdesk-androidd)
	cd rust/slopdesk-androidd && cargo build --release

# The SOCKET cases here need a booted device and are gated on SLOPDESK_ANDROID_HW=1
# (`scripts/check-android.sh`); without it they print why they proved nothing and pass.
androidd-test: ## cargo test for the Android bridge
	cd rust/slopdesk-androidd && cargo test

# PATH 3's daemon (docs/54): the read-only inspector clients dial DIRECTLY on `terminalPort + 1`.
# hostd never relayed a byte of it — what it did contribute was the process, so a transcript tail
# and a session's whole replay window died with every `make host-restart`. Same own-workspace
# reason as the four above.
inspectord: ## Build slopdesk-inspectord (rust/slopdesk-inspectord)
	cd rust/slopdesk-inspectord && cargo build --release

inspectord-test: ## cargo test for the inspector service (unit + the transcript corpus)
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
wire: ## Build slopdesk-wire (rust/slopdesk-wire)
	cd rust/slopdesk-wire && cargo build --release

wire-test: ## cargo test for the wire codec + replay buffer (unit + golden-vector parity vs Swift)
	cd rust/slopdesk-wire && cargo test

# The alt-screen cut scanner, lifted OUT of `wire` in stage 27 so superd could share it: three
# scrollback retainers front-truncate a stream and all three need the same answer before they may
# drop bytes — was the cut inside an open `?1049h` segment, and which mode opened it. The ring
# (`wire`'s `replay`) is one; superd's journal is compaction and restore. superd cannot depend on
# `wire`, which is the PROTOCOL and the one thing it must not know, so the scanner is its own
# dependency-free crate rather than a second copy in Rust.
altscreen-test: ## cargo test for the alt-screen cut scanner (rust/slopdesk-altscreen)
	cd rust/slopdesk-altscreen && cargo test

# fzf's `FuzzyMatchV2` — the ranking behind every search field (command palette, Open-Quickly,
# command navigator, Jump-To). Its own crate for the same reason `altscreen` is: it is a pure
# algorithm with no protocol knowledge, and it wants `opt-level = 3` where the daemons want `"z"`.
fuzzy-test: ## cargo test for the fuzzy matcher (rust/slopdesk-fuzzy)
	cd rust/slopdesk-fuzzy && cargo test

# The two device consoles' line grammars — `logcat -v time` and `log stream --style compact`, which
# were the same parser written twice in Swift over text a device wrote, on the socket read path. Its
# own crate for `slopdesk-fuzzy`'s reason: a pure function with no protocol knowledge, wanting
# `opt-level = 3` where the daemons want `"z"`, and only half of it is Android's.
devicelog-test: ## cargo test for the device console grammars (rust/slopdesk-devicelog)
	cd rust/slopdesk-devicelog && cargo test

# The two device panels' shared decisions — what one ensure round means, how soon to ask again, and
# what to do about a selection with no video yet. The Android and simulator models each held a
# byte-identical copy; its own crate because it reads `slopdesk-wire`'s `ServiceState`. It sat here
# originally because `slopdesk-wire` already depended on `slopdesk-workspace`; that edge is gone —
# the wire now reaches only `slopdesk-ids` and `slopdesk-tree` — so the crate stands on its own.
devicepanel-test: ## cargo test for the device panel decisions (rust/slopdesk-devicepanel)
	cd rust/slopdesk-devicepanel && cargo test

# The superd control socket's framing — tags, lengths and the two packed bodies. Its own crate for
# `slopdesk-screenwire`'s reason: superd writes these frames and hostd reads them, and the layout
# was spelled in superd's `frame.rs` AND in `SupervisorFrame.swift`, each calling the other a
# mirror. The app links the framing without linking `nix` and a PTY supervisor with it.
superwire-test: ## cargo test for the superd control framing (rust/slopdesk-superwire)
	cd rust/slopdesk-superwire && cargo test

# What one Claude Code hook body SAYS, in the detection vocabulary — the mapping that used to be a
# typed payload enum plus an adapter a module away, which is how the two drifted. Its own crate
# because it takes `serde_json`, which `slopdesk-agent` (zero-dependency, every input untrusted)
# will not, and because it wants `opt-level = 3` where the relay wants `"z"`.
hookevent-test: ## cargo test for the hook body reader (rust/slopdesk-hookevent)
	cd rust/slopdesk-hookevent && cargo test

# The two row scans a regex engine drives: Hint Mode's targets and find-in-terminal's matches.
# Their own crate because it takes `regex` — the linear-time engine that lets a pattern a human typed
# meet a row a remote program wrote without a backtracking hang — which `slopdesk-terminal`
# (dependency-free, on the PTY hot path) will not.
rowscan-test: ## cargo test for the regex row scans (rust/slopdesk-rowscan)
	cd rust/slopdesk-rowscan && cargo test

# Stage 5 of the same port: the PATH-2 video protocol, opening at the FEC math (GF(2^8),
# Reed-Solomon, the erasure codec). A LIBRARY like `wire` — nothing links it yet, so `video-test` is
# the only thing between it and a silent drift away from `Sources/SlopDeskVideoProtocol`. It replays
# the committed `fecParity` / `fecRecover` corpus, so it is the parity gate, not a smoke test.
video: ## Build slopdesk-video (rust/slopdesk-video)
	cd rust/slopdesk-video && cargo build --release

video-test: ## cargo test for the FEC codec (unit + golden-vector parity against the Swift codec)
	cd rust/slopdesk-video && cargo test

# The one crate `slopdesk-video` links, and the third in the tree allowed to write `unsafe`: the
# GF(2^8) byte-region kernels, in NEON. Read its `Cargo.toml` header for why the isolation is drawn
# where it is. Its tests are a differential against the scalar twin, which is the only thing that
# says the shuffle and the field agree.
gfsimd-test: ## cargo test for the SIMD kernels (vector path vs scalar oracle, guarded arenas)
	cd rust/slopdesk-gfsimd && cargo test

# The first crate of the `slopdesk-apple-*` family (`docs/57`): CoreGraphics event synthesis, called
# through `objc2`. macOS-only by construction, and linked into the FFI archive's macOS slice only.
# Its suite does NOT post an event — a test that moved the developer's cursor would be a test nobody
# could run — so what it proves is the modifier table, the thread-local source, and the LEAK check
# `docs/57` §3 asks of every crate in the family, read off the objects' own retain counts.
apple-cgevent-test: ## cargo test for the CoreGraphics injection wrapper (flags table, source reuse, leak check)
	cd rust/slopdesk-apple-cgevent && cargo test

# The `WindowServer`'s read side, split into its two framework areas: the window list and the
# display list. Neither suite needs a window server to be worth running — the window one builds real
# `CFDictionary`s and decodes them, which is where a wrong key constant or a defaulted-instead-of-
# dropped field shows, and it carries §3's leak check as a retain count across ten thousand decodes.
# The display one is honest about being partly vacuous on a headless runner and pins the shape of a
# real answer rather than the existence of one.
apple-cgwindow-test: ## cargo test for the window-list decode (key constants, drop-on-missing, leak check)
	cd rust/slopdesk-apple-cgwindow && cargo test

apple-cgdisplay-test: ## cargo test for the display-list reads (space agreement, handle-leak check)
	cd rust/slopdesk-apple-cgdisplay && cargo test

# `NSRunningApplication` — a pid in, a bundle id / hidden flag / activation out. The one crate in the
# family that writes NO `unsafe` at all: `objc2-app-kit` generates every call it makes as safe, which
# is the bar `docs/57` §3 sets per crate rather than as a budget. Its suite asks about pids that name
# nothing, because that is the whole failure mode — every caller reads the answer as "not eligible"
# and must fail CLOSED rather than on a stale or defaulted value.
apple-app-test: ## cargo test for the running-application reads (nothing-pid answers, no-snapshot property)
	cd rust/slopdesk-apple-app && cargo test

# The cursor shape the person is actually looking at. `NSCursor.currentSystemCursor` crosses the
# window-server boundary, so it needs a main thread — which a `cargo test` thread is not, and that
# is the arm the suite covers: an off-main read must answer NOTHING rather than trap, because the
# sampler's hot path is deliberately off-main and a trap there would take the daemon with it. The
# leak check runs that read a thousand times and asks whether anything accumulated.
apple-cursor-test: ## cargo test for the NSCursor read + PNG render (off-main answers nothing, leak check)
	cd rust/slopdesk-apple-cursor && cargo test

# One app's accessibility tree: its windows, their frames, the four effects on one of them (move,
# resize, un-minimize, raise), and one bounded walk for the searches that do not know which element
# they want. Every reading needs a live app AND the Accessibility grant, which is why the two Swift
# files this replaced BOTH carried a standing "compiled + reviewed, not driven from unit tests"
# note — so what this suite can ask is the refusal half: no app, no window, no grant, no allowance.
# The DECISIONS those readers used to make in the same breath live in `slopdesk-video`'s `ax_probe`
# and `nav_history` instead, under `forbid(unsafe_code)`, where they are ordinary tests. The leak
# check creates and releases ten thousand elements and asks whether anything accumulated.
apple-ax-test: ## cargo test for the accessibility tree (refusals without a grant, walk bounds, leak check)
	cd rust/slopdesk-apple-ax && cargo test

apple-vt-test: ## cargo test for the VideoToolbox session (option dictionaries, timestamps, leak check)
	cd rust/slopdesk-apple-vt && cargo test

# The capture stream. Every reading needs a window server AND the Screen-Recording grant, which is
# why the Swift this replaced carried a standing "compiled and code-reviewed, its start() is NEVER
# called from a test" note. So what this suite asks is the half that never needed either: the
# request a spec turns into, the shape of a filter's inputs, what a refusal answers, and the
# handoff's ceiling. Every RULE those calls are made under is `slopdesk-video`'s `capture_config`,
# tested under `video-test`. The leak check builds and drops the configuration many times over.
apple-sck-test: ## cargo test for the ScreenCaptureKit stream (spec to request, refusals, leak check)
	cd rust/slopdesk-apple-sck && cargo test

# The pane census — which processes belong to one PTY, and what they are listening on. Everything
# here used to be Swift that no test could reach: `HostMetadataProbe` carried a standing note that
# it was compiled and code-reviewed ONLY, because every reading needs a live PTY and a real `lsof`.
# What that note protected was the syscalls; what it also covered was a hand-rolled parser for
# hostile subprocess output. Behind this boundary the parse is a function over a string, so the
# suite is the one that could never be written: malformed `lsof` lines, an address with no port, a
# clock that moved backwards, and a descriptor that is not a PTY censusing NOTHING rather than the
# machine's whole process table.
panecensus-test: ## cargo test for one pane's process and port census (lsof parse, caps, empty-pane answers)
	cd rust/slopdesk-panecensus && cargo test

# The memory half of that: what actually reads the loads and stores for a pointer that left its
# allocation or its provenance. `CLAUDE.md` says the third `unsafe` crate was bought with "a
# differential suite that runs under Miri" — and until this line, NOTHING ran it. Not `check`, not
# `test`, not the prek hooks, not the disabled CI. An obligation no target reaches is a sentence in
# a document.
#
# It is in `check` because it turns out to be cheap: the `#[cfg(miri)]` seed reduction inside
# `tests/differential.rs` brings the sweep to 47 s wall clock, compile included, against the
# "minutes" this comment used to claim. Still out of `make test`, which the pre-push hook runs on
# every push — that path is measured in the seconds it saves.
miri: ## Run rust/slopdesk-gfsimd's differential suite under Miri (~47 s; the unsafe memory audit)
	rustup component add miri --toolchain nightly
	cd rust/slopdesk-gfsimd && cargo +nightly miri test

# Stage 12: the workspace document's DOMAIN rules — the layout math the wire's intents drive. Also a
# LIBRARY nothing links yet, so `workspace-test` is what stands between it and a silent drift away
# from `Sources/SlopDeskWorkspaceModel`.
workspace: ## Build slopdesk-workspace (rust/slopdesk-workspace)
	cd rust/slopdesk-workspace && cargo build --release

workspace-test: ## cargo test for the workspace domain rules
	cd rust/slopdesk-workspace && cargo test

# The three crates carved OUT of slopdesk-workspace when it reached 25k lines and `slopdesk-wire`
# — which holds the golden-pinned protocol — was found to depend on all of it. Each gets its own
# target for the same reason `workspace-test` has one: `test-rust` sweeps every workspace, but a
# named target is what someone reaches for when they change one crate, and a crate with no name
# here is a crate nobody runs deliberately.
ids: ## Build slopdesk-ids (rust/slopdesk-ids)
	cd rust/slopdesk-ids && cargo build --release

ids-test: ## cargo test for pane/tab identity, the JSON writer and shell quoting
	cd rust/slopdesk-ids && cargo test

tree: ## Build slopdesk-tree (rust/slopdesk-tree)
	cd rust/slopdesk-tree && cargo build --release

tree-test: ## cargo test for the workspace DOCUMENT — geometry, splits, sessions, focus, tree ops
	cd rust/slopdesk-tree && cargo test

settings: ## Build slopdesk-settings (rust/slopdesk-settings)
	cd rust/slopdesk-settings && cargo build --release

settings-test: ## cargo test for the settings catalogue, its layout and its rows
	cd rust/slopdesk-settings && cargo test

# Stage 13: the half of agent detection that reads the CLOCK — the status state machine, the block
# ledger, the dissent watchdog, the confirmation holds and the input classifier. screend (docs/52)
# keeps the half that reads the BYTES. A LIBRARY nothing links yet, so `agent-test` is what stands
# between it and a silent drift away from `Sources/SlopDeskAgentDetect`.
agent: ## Build slopdesk-agent (rust/slopdesk-agent)
	cd rust/slopdesk-agent && cargo build --release

agent-test: ## cargo test for the agent-detection state machine
	cd rust/slopdesk-agent && cargo test

# Stage 15: the CLIENT side of the byte stream — which screen the host is presenting (DECSET 1049,
# OSC 133) and which output bytes are only the PTY echoing the compose box back. screend reads the
# HOST's bytes for detection, slopdesk-wire reads them as FRAMES; this reads them for the INPUT
# SURFACE. A LIBRARY nothing links yet, so `terminal-test` is what stands between it and a silent
# drift away from `Sources/SlopDeskClaudeCode`.
terminal: ## Build slopdesk-terminal (rust/slopdesk-terminal)
	cd rust/slopdesk-terminal && cargo build --release

terminal-test: ## cargo test for the terminal mode tracker + input echo dedup
	cd rust/slopdesk-terminal && cargo test

# Stage 16: the pure core of the USER-facing `slopdesk` CLI — global flags, completions, the local
# config-file ops and the list/inspect tables. A MEMBER of the root workspace, not a workspace of
# its own: it wants the hook's startup-tuned profile for the same reason ctl does, and `lint-rust`
# already reaches it through `cargo clippy --workspace`. The rest of what `SlopDeskCLICore` held
# moved to the crate that owns the SUBJECT — see docs/DECISIONS.md, stage 16.
cli: ## Build slopdesk-cli (rust/slopdesk-cli)
	cd rust && cargo build --release -p slopdesk-cli

cli-test: ## cargo test for the `slopdesk` CLI core
	cd rust && cargo test -p slopdesk-cli

# docs/49: is the sidecar RUNNING the sidecar that is INSTALLED — the verdict, the restart policy,
# and the MANIFEST.json diff. A member of the root workspace for the reason the two above are: both
# its callers are fork-and-exit programs (`slopdesk sidecars`) or link it through the xcframework
# (hostd's startup audit), and it holds no state that wants a daemon's profile.
sidecars-test: ## cargo test for the per-sidecar version policy + manifest diff
	cd rust && cargo test -p slopdesk-sidecars

# Stage 22: the code panel's workbench PROFILE — the settings seed and its whole retired corpus, the
# theme + bridge extensions, the profile registry, the child's argv and environment. hostd keeps the
# SUPERVISION (the handle, the readiness probe, the learned port); this owns every decision about a
# FILE, which is what those 2.7k lines of Swift actually were. Its own workspace for the profile
# reason the daemons record. NOT staged next to hostd: `RustServicePaths` finds it by walking up
# to `rust/slopdesk-codeseed/target/`, the same way it finds every other daemon in this tree, so a
# `cargo clean` can never leave a copy behind that lies about which profile the panel seeds.
codeseed: ## Build slopdesk-codeseed (rust/slopdesk-codeseed)
	cd rust/slopdesk-codeseed && cargo build --release

codeseed-test: ## cargo test for the code-server profile seeder
	cd rust/slopdesk-codeseed && cargo test

# The inner loop for host work. `--product` compiles hostd and the libraries under it and NOT the
# client app, the video host or the iOS surfaces — which is most of the package.
host: ## Build ONLY slopdesk-hostd and its libraries
	swift build --product slopdesk-hostd

# The whole edit loop in one command, and the reason docs/51 exists: superd keeps every pane, both
# child-facing sockets and the panel backends, so this costs a client reconnect rather than the
# afternoon's work. It prints the observed downtime and superd's child count on either side.
host-restart: ## Rebuild hostd and restart the running one, identically (docs/51 §9)
	bash scripts/restart-hostd.sh

host-status: ## Report the running hostd (pid, port, flags) and superd's child count; change nothing
	bash scripts/restart-hostd.sh --status

# `hook-test` runs FIRST and unconditionally. `swift build`/`swift test` never compile the Rust
# crate, so a Swift-only gate is blind to it; and pre-push-test.sh's green-tree cache keys on the
# Swift inputs alone (Package.swift Sources Tests Apps golden), so a rust/ change would hit the
# cache and skip everything. Warm cargo costs ~0.07s and fails before the ~60s Swift run.
#
# `superd` is BUILT here, not merely tested, and that is load-bearing: hostd cannot fork a shell
# any more (docs/51), so every test that needs a real pty boots a private daemon and SKIPS without
# the binary (`SuperdFixture`). A bare `swift test` on a clean checkout still works and still never
# sees cargo — it just reports those tests skipped, by name.
test: ffi hook-test invariants-test ctl-test probe-test posix-test ffi-test git-test superd-test screend-test dropd-test androidd-test inspectord-test wire-test altscreen-test fuzzy-test devicelog-test devicepanel-test superwire-test hookevent-test rowscan-test video-test gfsimd-test apple-cgevent-test apple-cgwindow-test apple-cgdisplay-test apple-app-test apple-cursor-test apple-ax-test apple-vt-test apple-sck-test panecensus-test workspace-test ids-test tree-test settings-test agent-test terminal-test cli-test sidecars-test codeseed-test ctl superd screend dropd androidd inspectord ## cargo test (relay + agent CLI + metadata probe + the unsafe surface + the C ABI + the git engine + custodian + screen engine + file drop + android bridge + inspector + wire codec + alt-screen cut scanner + fuzzy matcher + device console grammars + device panel decisions + superd framing + hook bodies + row scans + FEC codec + SIMD kernels + CoreGraphics injection + the window and display lists + the running-application reads + the cursor shape + the accessibility tree + the VideoToolbox session + the capture stream + one pane's process and port census + workspace rules + identity + the document tree + the settings catalogue + agent detection + terminal input + CLI core + sidecar versions + code-server profile) + swift test with the green-tree cache
	bash scripts/pre-push-test.sh

# `superd` for the same load-bearing reason as `test:` above, and it matters MORE here: this is the
# gate CLAUDE.md tells you to run after a Swift edit, and the code most of those edits touch is the
# supervised pty path. Without the binary `SuperdFixture` throws `XCTSkip` from its initialiser, so
# SupervisedPaneSurvivalTests, HostRestartSurvivalTests, PaneOutputStreamTests and PTYProcessTests
# all report green having run nothing — a fast gate that cannot see the regressions it exists for.
test-touched: ctl superd screend dropd androidd inspectord ## Fast inner loop: incremental build + only the test targets the change set reaches
	bash scripts/test-touched.sh

# Golden regression pin: regenerate the wire corpus from the live native-Swift codecs and assert
# byte-identity to golden/golden_vectors.json (replaces the old cross-language Rust golden_parity).
golden: ## Verify the wire codecs still reproduce golden/golden_vectors.json
	bash scripts/golden-check.sh

# ---------------------------------------------------------------------------- #
.PHONY: changelog release release-preview
# The release metadata, generated from the commit log rather than hand-maintained. The commit TYPE
# decides both the CHANGELOG.md section a change lands in and whether the version moves a minor or
# a patch, which is why `scripts/check-commit-msg.sh` gates the subject at commit-msg time.
changelog: ## Regenerate CHANGELOG.md from the commit log (git-cliff)
	bash scripts/render-changelog.sh

release-preview: ## Print the version and release notes the next cut would produce; write nothing
	bash scripts/cut-release.sh --dry-run

# Commits and tags LOCALLY; pushing the tag is the separate keystroke that starts the signing
# pipeline. `make release VERSION=0.3.0` forces a version instead of computing it.
release: ## Cut a release: version + CHANGELOG.md + the six version sites + commit + tag
	bash scripts/cut-release.sh $(VERSION)

# ---------------------------------------------------------------------------- #
.PHONY: tool-versions
# Which SIDECARS the next release would move, and which it would leave alone.
#
# The product version moves on every cut; a sidecar's moves only when its own sources did. That is
# what lets an upgrade replace the daemon that changed and leave the others running — restarting
# superd costs the user every live pane (`docs/51`), and it should cost that only when superd
# actually changed. `scripts/tool-stamps.sh` is what can tell, and `MANIFEST.json` in the tarball
# is where the answer ships.
#
# NOT part of `check` or `quick`, deliberately: a sidecar whose sources changed since the last
# release is the ordinary state of `main`, so a gate here would be red almost always and mean
# nothing when it was. The gate that DOES run is in `check-invariants.py` — every shipped sidecar
# must have a pin entry — and the one that refuses to ship a lie is in `package-release.sh`, which
# asks each built binary its version and compares it with the pin.
tool-versions: ## Show which sidecars changed since the last release, and the bump each would take
	bash scripts/bump-tool-versions.sh --dry-run

# ---------------------------------------------------------------------------- #
.PHONY: provision provision-check
# The panel's RUNTIME deps (code-server, baguette, adb, scrcpy-server), pinned by URL + SHA-256 in
# ThirdParty/tools/tools.lock. Not part of `build` or `test`: the whole Swift package builds and
# tests headless without any of them, and provisioning downloads ~250 MB.
provision: ## Fetch + verify the pinned host-side runtime deps into ThirdParty/tools/.prefix
	bash ThirdParty/tools/provision.sh

provision-check: ## Report which pinned deps are present; download nothing
	bash ThirdParty/tools/provision.sh --check

# ---------------------------------------------------------------------------- #
.PHONY: install-tools hooks
# DEV tooling only (linters + hooks) — deliberately still brew. These shape the gates, not the
# product: a formula drifting a minor version changes a lint message, it does not put the panel on
# a workbench three releases old. The deps that DO decide product behaviour are in `provision`.
install-tools: hooks ## Install all required tools (brew) and the git hooks
	brew install swiftlint swiftformat shellcheck shfmt ruff prek git-cliff xcodegen

hooks: ## Install the prek git hooks (pre-commit + pre-push)
	prek install
