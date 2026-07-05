# Strict formatter / linter / static-analysis entrypoints for the whole repo.
# Configs: .swiftformat .swiftlint.yml ruff.toml .shellcheckrc
#
#   make fmt    — auto-format everything (writes)
#   make fix    — fmt + apply every safe lint autofix (writes)
#   make lint   — run every linter strictly, no writes (what CI gates on)
#   make check  — lint + swift build + swift test + golden pin (the full local gate)
#
# Tools are pinned/installed via `make install-tools`.
# Single language: Swift + a tiny native SIMD C kernel (Sources/CSlopDeskSIMD). No Rust, no FFI,
# no build ordering — `swift build` compiles from a clean checkout with no prerequisite.

SWIFT_PATHS  := Sources Tests Apps
# Format (SwiftFormat) also covers the package manifest; the SwiftLint scope stays
# Sources/Tests/Apps (Package.swift is config, not linted).
SWIFTFMT_PATHS := Package.swift $(SWIFT_PATHS)
SHELL_FILES  := $(shell git ls-files '*.sh' | grep -v '^ThirdParty/')
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
.PHONY: fmt fmt-swift fmt-shell fmt-python
fmt: fmt-swift fmt-shell fmt-python ## Auto-format all languages

fmt-swift: ## Format Swift (SwiftFormat)
	swiftformat $(SWIFTFMT_PATHS)

fmt-shell: ## Format shell (shfmt)
	@[ -n "$(SHELL_FILES)" ] && shfmt $(SHFMT_FLAGS) -w $(SHELL_FILES) || true

fmt-python: ## Format Python (ruff format)
	@[ -n "$(PY_FILES)" ] && ruff format $(PY_FILES) || true

# ---------------------------------------------------------------------------- #
# Autofix (writes) — formatting + every safe lint autocorrect
.PHONY: fix
fix: fmt ## Format + apply all safe lint autofixes
	-swiftlint --fix --quiet
	-[ -n "$(PY_FILES)" ] && ruff check --fix $(PY_FILES)
	-[ -n "$(SHELL_FILES)" ] && shellcheck -f diff $(SHELL_FILES) | git apply --allow-empty 2>/dev/null

# ---------------------------------------------------------------------------- #
# Linting (no writes) — the CI gate
.PHONY: lint lint-swift lint-shell lint-python lint-ds-leaks lint-menu-shortcutless
lint: lint-swift lint-shell lint-python lint-ds-leaks lint-menu-shortcutless ## Run every linter strictly

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

lint-shell: ## shellcheck + shfmt --diff
	@[ -n "$(SHELL_FILES)" ] && shellcheck $(SHELL_FILES) || true
	@[ -n "$(SHELL_FILES)" ] && shfmt $(SHFMT_FLAGS) -d $(SHELL_FILES) || true

lint-python: ## ruff check + ruff format --check
	@[ -n "$(PY_FILES)" ] && ruff check $(PY_FILES) || true
	@[ -n "$(PY_FILES)" ] && ruff format --check $(PY_FILES) || true

# SwiftLint analyzer rules need a compiler invocation log — heavier, run on demand.
.PHONY: lint-swift-analyze
lint-swift-analyze: ## SwiftLint analyzer rules (compiles the package first)
	swift build --build-tests 2>/dev/null; \
	swiftlint analyze --strict --compiler-log-path .build/debug.yaml 2>/dev/null || \
		echo "note: run 'swift build -v | tee build.log' then 'swiftlint analyze --compiler-log-path build.log'"

# ---------------------------------------------------------------------------- #
# Full gate
.PHONY: check build test golden
check: lint build test golden ## lint + build + test + golden pin (full local gate)

build: ## swift build (Swift + CSlopDeskSIMD, no prerequisites)
	swift build

test: ## swift test (~2300 native Swift tests)
	swift test

# Golden regression pin: regenerate the wire corpus from the live native-Swift codecs and assert
# byte-identity to golden/golden_vectors.json (replaces the old cross-language Rust golden_parity).
golden: ## Verify the wire codecs still reproduce golden/golden_vectors.json
	bash scripts/golden-check.sh

# ---------------------------------------------------------------------------- #
.PHONY: install-tools hooks
install-tools: hooks ## Install all required tools (brew) and the git hooks
	brew install swiftlint swiftformat shellcheck shfmt ruff prek

hooks: ## Install the prek git hooks (pre-commit + pre-push)
	prek install
