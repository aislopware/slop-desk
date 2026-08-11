# Strict formatter / linter / static-analysis entrypoints for the whole repo.
# Configs: .swiftformat .swiftlint.yml ruff.toml .shellcheckrc rust/rustfmt.toml rust/Cargo.toml
#
#   make fmt    — auto-format everything (writes)
#   make fix    — fmt + apply every safe lint autofix (writes)
#   make lint   — run every linter strictly, no writes (what CI gates on)
#   make check  — lint + swift build + swift test + golden pin (the full local gate)
#
# Tools are pinned/installed via `make install-tools`.
# Swift + a tiny native SIMD C kernel (Sources/CSlopDeskSIMD) + ONE standalone Rust binary
# (rust/slopdesk-hook, the Claude Code hook relay). There is still NO FFI: the relay is a separate
# process that speaks the same socket framing as the sh script it replaces, so the wire, the
# codecs and every test path stay pure Swift. `swift build` alone still compiles the package from
# a clean checkout; `make build` additionally stages the relay beside the host binary.

SWIFT_PATHS  := Sources Tests Apps
# Format (SwiftFormat) also covers the package manifest; the SwiftLint scope stays
# Sources/Tests/Apps (Package.swift is config, not linted).
SWIFTFMT_PATHS := Package.swift $(SWIFT_PATHS)
# ThirdParty/ghostty/ only: that tree is the vendored libghostty build recipe, carried close to
# upstream's own shape. ThirdParty/tools/provision.sh is OURS and meets the same bar as scripts/.
SHELL_FILES  := $(shell git ls-files '*.sh' | grep -v '^ThirdParty/ghostty/')
PY_FILES     := $(shell git ls-files '*.py')
SHFMT_FLAGS  := -i 2 -ci -sr

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

fmt-swift: ## Format Swift (SwiftFormat)
	swiftformat $(SWIFTFMT_PATHS)

fmt-shell: ## Format shell (shfmt)
	@if [ -n "$(SHELL_FILES)" ]; then shfmt $(SHFMT_FLAGS) -w $(SHELL_FILES); fi

fmt-python: ## Format Python (ruff format)
	@if [ -n "$(PY_FILES)" ]; then ruff format $(PY_FILES); fi

# rustfmt.toml turns on nightly-only options (wrap_comments, group_imports, format_strings …).
# Only the FORMATTER needs nightly; the crate itself builds and tests on stable.
fmt-rust: ## Format Rust (nightly rustfmt — rust/rustfmt.toml uses unstable options)
	cd rust && cargo +nightly fmt --all

# ---------------------------------------------------------------------------- #
# Autofix (writes) — formatting + every safe lint autocorrect
.PHONY: fix
fix: fmt ## Format + apply all safe lint autofixes
	-swiftlint --fix --quiet
	-cd rust && cargo clippy --workspace --all-targets --fix --allow-dirty --allow-staged
	-[ -n "$(PY_FILES)" ] && ruff check --fix $(PY_FILES)
	-[ -n "$(SHELL_FILES)" ] && shellcheck -f diff $(SHELL_FILES) | git apply --allow-empty 2>/dev/null

# ---------------------------------------------------------------------------- #
# Linting (no writes) — the CI gate
.PHONY: lint lint-swift lint-shell lint-python lint-rust lint-ds-leaks lint-menu-shortcutless
lint: lint-swift lint-shell lint-python lint-rust lint-ds-leaks lint-menu-shortcutless ## Run every linter strictly

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
lint-rust: ## clippy -D warnings (all targets) + rustfmt --check
	cd rust && cargo clippy --workspace --all-targets --all-features -- -D warnings
	cd rust && cargo +nightly fmt --all -- --check

# SwiftLint analyzer rules need a compiler invocation log — heavier, run on demand.
.PHONY: lint-swift-analyze
lint-swift-analyze: ## SwiftLint analyzer rules (compiles the package first)
	swift build --build-tests 2>/dev/null; \
	swiftlint analyze --strict --compiler-log-path .build/debug.yaml 2>/dev/null || \
		echo "note: run 'swift build -v | tee build.log' then 'swiftlint analyze --compiler-log-path build.log'"

# ---------------------------------------------------------------------------- #
# Full gate
.PHONY: check build test test-touched golden hook hook-test
check: lint build test golden ## lint + build + test + golden pin (full local gate)

build: hook ## swift build (Swift + CSlopDeskSIMD) + stage the Rust hook relay
	swift build
	@cp rust/target/release/slopdesk-hook "$$(swift build --show-bin-path)/slopdesk-hook"

# The Claude Code hook relay. Compiled, not a shell script: Claude Code runs hooks SYNCHRONOUSLY
# on PreToolUse/PostToolUse — twice per tool call — and the sh+cat+nc script it replaces spent
# ~10ms of its ~12.4ms forking three processes to move ~60 bytes. It is staged NEXT TO the host
# binary, which is where AgentInstaller.bundledBinaryPath looks for it.
hook: ## Build the Rust hook relay (rust/slopdesk-hook)
	cd rust && cargo build --release

hook-test: ## cargo test for the hook relay
	cd rust && cargo test

# `hook-test` runs FIRST and unconditionally. `swift build`/`swift test` never compile the Rust
# crate, so a Swift-only gate is blind to it; and pre-push-test.sh's green-tree cache keys on the
# Swift inputs alone (Package.swift Sources Tests Apps golden), so a rust/ change would hit the
# cache and skip everything. Warm cargo costs ~0.07s and fails before the ~60s Swift run.
test: hook-test ## cargo test (relay) + swift test --parallel with the green-tree cache
	bash scripts/pre-push-test.sh

test-touched: ## Fast inner loop: incremental build + only the test targets the change set reaches
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
	git-cliff --output CHANGELOG.md

release-preview: ## Print the version and release notes the next cut would produce; write nothing
	bash scripts/cut-release.sh --dry-run

# Commits and tags LOCALLY; pushing the tag is the separate keystroke that starts the signing
# pipeline. `make release VERSION=0.3.0` forces a version instead of computing it.
release: ## Cut a release: version + CHANGELOG.md + the six version sites + commit + tag
	bash scripts/cut-release.sh $(VERSION)

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
