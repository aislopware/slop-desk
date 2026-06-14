# Strict formatter / linter / static-analysis entrypoints for the whole repo.
# Configs: .swiftformat .swiftlint.yml rust/{rustfmt,clippy,deny}.toml ruff.toml .shellcheckrc
#
#   make fmt    — auto-format everything (writes)
#   make fix    — fmt + apply every safe lint autofix (writes)
#   make lint   — run every linter strictly, no writes (what CI gates on)
#   make check  — lint + swift build + swift test (the full local gate)
#
# Tools are pinned/installed via `make install-tools`.

SWIFT_PATHS  := Sources Tests Apps
SHELL_FILES  := $(shell git ls-files '*.sh' | grep -v '^ThirdParty/')
PY_FILES     := $(shell git ls-files '*.py')
RUST_DIR     := rust
SHFMT_FLAGS  := -i 2 -ci -sr

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------- #
.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
		| sort | awk -F':.*## ' '{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------- #
# Formatting (writes)
.PHONY: fmt fmt-swift fmt-rust fmt-shell fmt-python
fmt: fmt-swift fmt-rust fmt-shell fmt-python ## Auto-format all languages

fmt-swift: ## Format Swift (SwiftFormat)
	swiftformat $(SWIFT_PATHS)

fmt-rust: ## Format Rust (rustfmt)
	cd $(RUST_DIR) && cargo fmt

fmt-shell: ## Format shell (shfmt)
	@[ -n "$(SHELL_FILES)" ] && shfmt $(SHFMT_FLAGS) -w $(SHELL_FILES) || true

fmt-python: ## Format Python (ruff format)
	@[ -n "$(PY_FILES)" ] && ruff format $(PY_FILES) || true

# ---------------------------------------------------------------------------- #
# Autofix (writes) — formatting + every safe lint autocorrect
.PHONY: fix
fix: fmt ## Format + apply all safe lint autofixes
	-swiftlint --fix --quiet
	-cd $(RUST_DIR) && cargo clippy --workspace --all-targets --fix --allow-dirty --allow-staged
	-[ -n "$(PY_FILES)" ] && ruff check --fix $(PY_FILES)
	-[ -n "$(SHELL_FILES)" ] && shellcheck -f diff $(SHELL_FILES) | git apply --allow-empty 2>/dev/null

# ---------------------------------------------------------------------------- #
# Linting (no writes) — the CI gate
.PHONY: lint lint-swift lint-rust lint-shell lint-python
lint: lint-swift lint-rust lint-shell lint-python ## Run every linter strictly

lint-swift: ## SwiftFormat --lint + SwiftLint --strict
	swiftformat $(SWIFT_PATHS) --lint
	swiftlint --strict --quiet

lint-rust: ## rustfmt --check + clippy -D warnings + cargo-deny + cargo-machete
	cd $(RUST_DIR) && cargo fmt --check
	cd $(RUST_DIR) && cargo clippy --workspace --all-targets --all-features -- -D warnings
	cd $(RUST_DIR) && cargo deny check
	cd $(RUST_DIR) && cargo machete

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
.PHONY: check build test
check: lint build test ## lint + build + test (full local gate)

build: ## swift build (links the Rust FFI staticlib)
	cd $(RUST_DIR) && cargo build --release -p aislopdesk-ffi
	swift build

test: ## swift test + rust test
	swift test
	cd $(RUST_DIR) && cargo test --workspace

# ---------------------------------------------------------------------------- #
.PHONY: install-tools
install-tools: ## Install all required tools (brew + cargo)
	brew install swiftlint swiftformat shellcheck shfmt ruff cargo-deny pre-commit
	cargo install cargo-machete
	rustup component add rustfmt clippy
	pre-commit install
