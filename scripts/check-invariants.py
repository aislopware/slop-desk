#!/usr/bin/env python3
"""Repo-wide invariant ratchets — the ones CLAUDE.md states and nothing else enforced.

Why this file is Python and its neighbours are bash
---------------------------------------------------
Every gate here is "this token must not appear in code", and in shell that reads as a `grep`.
Three different bugs came out of that in one afternoon, all of them silent:

* `repo_files … | xargs grep -ln` PRINTS the offending file and still exits non-zero, because
  `xargs` splits 742 paths into batches and reports the LAST batch's status. `if hit=$(…)` is
  then false and the gate says nothing — a violation found and discarded.
* A `grep` for `pkill` matched the gate's own failure MESSAGE, so the check reported itself and
  could never be made to pass.
* Stripping comments with `sed -E 's,//.*,,'` also mangles `https://…` inside a string literal.

None of the three is a shell-scripting mistake so much as the shape of the tool: a pipeline hides
status, and a regex has no idea what a comment is. Both failures look exactly like success. The
gates below carry a tokenizer instead, and each is a function whose name says what it protects.

Run directly, or through `make lint-supervisor`, which folds the exit status into its own count.
`--list` prints the gates without running them.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

#: A failing gate returns the sites it found and the sentence that says why they are wrong.
Report = tuple[list[str], str] | None


def repo_files(*patterns: str) -> list[Path]:
    """Tracked files plus untracked-but-not-ignored ones, the way the other gates see the tree.

    `--others --exclude-standard` is not decoration: most of `rust/` is untracked while the port
    lands, and a gate reading only the index would be blind to it.
    """
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", *patterns],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=True,
    )
    return [REPO / line for line in out.stdout.split("\n") if line]


_C_TOKENS = re.compile(
    r"""
      (?P<raw>r\#*"(?:[^"]|"(?!\#))*"\#*)   # Rust raw string, r"…" / r#"…"#
    | (?P<str>"(?:\\.|[^"\\\n])*")          # ordinary string literal
    | (?P<char>'(?:\\.|[^'\\\n])')          # character literal
    | (?P<block>/\*.*?\*/)                  # /* … */
    | (?P<line>//[^\n]*)                    # // …
    """,
    re.VERBOSE | re.DOTALL,
)


def strip_comments(source: str, kind: str) -> str:
    """Blank out comments, keeping line numbering intact so a report can still cite a line.

    String literals survive: a gate banning a token would otherwise miss it whenever a neighbouring
    string happened to contain a slash pair, and one reading `//` would fire on every URL.
    """
    if kind == "shell":
        kept = ("" if line.lstrip().startswith("#") else line for line in source.split("\n"))
        return "\n".join(kept)

    def blank(match: re.Match[str]) -> str:
        text = match.group(0)
        if match.lastgroup in {"raw", "str", "char"}:
            return text
        return "\n" * text.count("\n")  # keep the newlines so line numbers survive

    return _C_TOKENS.sub(blank, source)


def hits(paths: list[Path], kind: str, pattern: str) -> list[str]:
    """Every `path:line: text` where the pattern matches real code rather than a comment."""
    rx = re.compile(pattern)
    found: list[str] = []
    for path in paths:
        try:
            source = path.read_text(errors="ignore")
        except OSError:
            continue
        for number, line in enumerate(strip_comments(source, kind).split("\n"), 1):
            if line.strip() and rx.search(line):
                found.append(f"{path.relative_to(REPO)}:{number}: {line.strip()}")
    return found


# --------------------------------------------------------------------------------------------- #
# The gates. Each returns None when it holds.
# --------------------------------------------------------------------------------------------- #

#: Files allowed to import a crypto framework, each with the reason it is not what the rule bans.
#: An allowlist rather than excluding `Tests/` wholesale: a hash over a PINNED ARTIFACT is
#: supply-chain integrity and always will be, while a hash over a credential is the thing the rule
#: exists to stop — and both would live under `Tests/`.
CRYPTO_ALLOWED = {
    "Tests/SlopDeskHostTests/VendoredToolsTests.swift": (
        "SHA-256 of a COMMITTED jar against its tools.lock pin — integrity, not an auth path"
    ),
}


def no_app_layer_crypto() -> Report:
    """CLAUDE.md: "No app-layer crypto or auth — security is the WireGuard mesh."

    The way that rule dies is one import, for one hash, in one file, six months before anyone
    reads the sentence that forbids it.
    """
    stale = [name for name in CRYPTO_ALLOWED if not (REPO / name).exists()]
    if stale:
        return stale, "a crypto allowlist entry names a file that does not exist"

    swift = repo_files("Sources/*.swift", "Apps/*.swift", "Tests/*.swift")
    found = [
        line
        for line in hits(swift, "swift", r"^\s*import\s+(CryptoKit|CommonCrypto)\b")
        if line.split(":", 1)[0] not in CRYPTO_ALLOWED
    ]
    if not found:
        return None
    return found, "app-layer crypto reached the tree — security here is the WireGuard mesh"


def no_swiftpm_build_plugin() -> Report:
    """CLAUDE.md: "cargo never runs inside `swift build`."

    A SwiftPM `.plugin`/`buildTool` in the manifest is exactly the shape that rule forbids, and it
    would arrive looking like a convenience.
    """
    found = hits([REPO / "Package.swift"], "swift", r"\.plugin\(|buildTool\(|\.buildTool\b")
    if not found:
        return None
    return found, "Package.swift declares a build plugin — the FFI artifact is built by 'make ffi'"


def no_fused_multiply_add() -> Report:
    """CLAUDE.md: keep `a * b + c` as two roundings — the golden corpus pins the bit patterns.

    The METHOD form only. `gf256::mul_add` and `slopdesk_gfsimd::mul_add` are Galois-field region
    ops over `u8` with nothing to do with float rounding; a path call is never a float fusion.
    """
    swift = repo_files("Sources/*.swift", "Tests/*.swift", "Apps/*.swift")
    rust = [p for p in repo_files("rust/*.rs") if "/target/" not in str(p)]
    found = hits(swift, "swift", r"\.addingProduct\(|(?<![\w.])fma\(")
    found += hits(rust, "rust", r"\.mul_add\(")
    if not found:
        return None
    return found, "a fused multiply-add reached the tree — FMA rounds once, the wire rounds twice"


def every_script_sets_pipefail() -> Report:
    """Without `pipefail` a pipeline reports the LAST command's status.

    Every gate in this repo is a pipeline somewhere, so a script missing it is a gate that cannot
    fail. The check reads the WORD, not a flag spelling: two scripts say `set -uo pipefail`
    deliberately, and a first draft matching `set -euo pipefail` called both of them broken.
    """
    scripts = [
        p for p in repo_files("*.sh") if not str(p.relative_to(REPO)).startswith("ThirdParty/")
    ]
    missing = [
        str(p.relative_to(REPO))
        for p in scripts
        if not re.search(r"(?m)^\s*set\s+[^\n]*pipefail", p.read_text(errors="ignore"))
    ]
    if not missing:
        return None
    return missing, "a shell script does not set pipefail — a death inside a pipe would read green"


_LOCATE_CALL = re.compile(
    r"RustServicePaths\.locate(?:Beside)?\(\s*(?:\"(?P<literal>slopdesk-[a-z]+)\"|(?P<symbol>\w+))",
)
_BINARY_NAME_CONSTANT = re.compile(r"""\bbinaryName\s*=\s*"(slopdesk-[a-z]+)\"""")


def the_release_ships_every_sidecar_the_host_needs() -> Report:
    """A daemon hostd resolves at runtime and the tarball omits is a feature that cannot run.

    This gate exists because the tarball was three binaries — `slopdesk`, `slopdesk-hostd`,
    `slopdesk-ctl` — while hostd resolved eight more, superd among them. superd forks every PTY
    master, so a `brew install` produced a host that could not open a single pane, and no gate
    could see it: the release path is exercised by TAGGING, and a change that moves an
    implementation out of the Swift graph is invisible to everything that is not a release.

    Derived from the call sites, not from a list: every `RustServicePaths.locate`/`locateBeside`
    names the binary it wants, so a seventh daemon is covered the day someone writes the lookup.
    Two names cannot be found that way and are added explicitly rather than left to an
    approximation that would quietly drop them — `slopdesk-superd`, which hostd reaches by SOCKET
    and never by path, and `slopdesk-hook`, which `slopdesk-agenthooks` copies from its own
    directory (`rust/slopdesk-hook/src/bin/agenthooks.rs`, `executable.parent()/RELAY_NAME`).

    The shipped set is read from the tool ARRAYS, not from the file: a first draft grepped
    `package-release.sh` whole, which the comment above those arrays — it names every daemon —
    satisfied on its own. A gate a comment can pass is not a gate.

    The arrays moved to `scripts/shipped-tools.sh` when a fourth reader appeared (per-tool version
    stamping), so this reads them there. Same rule, one file over: a list four scripts share is a
    list that must live in one of them and be sourced by the rest, or it is four lists.
    """
    wanted: set[str] = {"slopdesk-superd", "slopdesk-hook"}
    for path in repo_files("Sources/*.swift"):
        source = path.read_text(errors="ignore")
        constants = _BINARY_NAME_CONSTANT.findall(source)
        for match in _LOCATE_CALL.finditer(source):
            if literal := match.group("literal"):
                wanted.add(literal)
            elif match.group("symbol") == "binaryName":
                wanted.update(constants)

    packaging = (REPO / "scripts/shipped-tools.sh").read_text(errors="ignore")
    arrays = re.findall(
        r"^(?:SPM_TOOLS|RUST_ROOT_TOOLS|RUST_CRATE_TOOLS)=\((.*?)\)",
        packaging,
        re.MULTILINE | re.DOTALL,
    )
    if not arrays:
        blind = "the release tool arrays are gone — this gate is blind"
        return ["scripts/shipped-tools.sh"], blind
    shipped = {name for body in arrays for name in re.findall(r"\bslopdesk-[a-z]+\b", body)}
    missing = sorted(wanted - shipped)
    if not missing:
        return None
    return missing, "the host resolves a sidecar the release tarball does not ship"


def a_script_with_a_shebang_is_executable() -> Report:
    """A shebang is a promise that `scripts/foo.sh --flag` works; the mode bit is what keeps it.

    Four scripts had lost the bit and nothing noticed, because the Makefile invokes every one of
    them as `bash scripts/foo.sh` — the one spelling that works either way. What breaks is the
    spelling the scripts and `docs/46` tell a human to type (`scripts/restart-hostd.sh --status`),
    which is exactly the path no gate walks. So the shebang is the declaration and this is its
    check: `#!` on line one, no `x` bit, is a documented entry point that answers "permission
    denied". Derived from the file itself, so a new script is covered the day it is written.
    """
    scripts = [
        p
        for p in [*repo_files("*.sh"), *repo_files("*.py"), *repo_files("*.awk")]
        if not str(p.relative_to(REPO)).startswith("ThirdParty/")
    ]
    found = [
        str(p.relative_to(REPO))
        for p in scripts
        if p.read_bytes()[:2] == b"#!" and not os.access(p, os.X_OK)
    ]
    if not found:
        return None
    return found, "a script declares a shebang but is not executable — running it by name fails"


def pkill_never_reaches_the_developers_host() -> Report:
    """CLAUDE.md: "Never `pkill` the host — `make host-restart` replays hostd's recorded launch."

    The harnesses under `scripts/` DO kill hosts, and must: each spawns its own on a private port
    and reaps it. What is banned is the UNQUALIFIED form, which reaches the developer's running
    hostd as readily as the harness's own. So the question is not "does this script say pkill" but
    "does a pkill naming hostd carry the qualifier that scopes it to a host this script started".
    """
    shells = [*repo_files("scripts/*.sh"), REPO / "Makefile"]
    found = [
        line
        for line in hits(shells, "shell", r"pkill\s+-f")
        if "slopdesk-hostd" in line and "--port" not in line and "DerivedData" not in line
    ]
    if not found:
        return None
    return found, "an unqualified pkill names slopdesk-hostd — it would reap the running host"


def shell_quoting_has_one_owner() -> Report:
    """POSIX `'…'` quoting was written eight times; it lives once, behind `slopdesk_ws_shell_quote`.

    This gate existed in `check-supervisor.sh` and could not fail: it piped 742 paths into
    `xargs grep -ln`, which prints the offender and still exits non-zero when the final batch is
    clean — so the surrounding `if hit=$(…)` was false exactly when there was something to report.
    """
    found = hits(repo_files("Sources/*.swift"), "swift", r"replacingOccurrences\(of: \"'\"")
    if not found:
        return None
    return found, "a site quotes a shell word itself — every one asks slopdesk_ws_shell_quote"


#: The modules this gate knows are stranded, each with the Swift that still runs instead. They are
#: DEBT, registered so the gate can be green while it shrinks — not exemptions. Removing a name here
#: is the last step of finishing that port; adding one is a change `docs/DECISIONS.md` must record.
STRANDED_RUST_MODULES = {
    # `WorkspacePersistence.swift` + `Canvas+Codable.swift` + `SplitNode+Codable.swift` still
    # encode and decode the client's workspace file. The Rust half has 22 tests and no caller.
    "slopdesk-workspace::persist",
    # `ConnectionTarget.swift` is a four-field `Codable` value 20 files hold and SwiftUI diffs —
    # a vocabulary by `docs/55` §6, so the Rust twin is the copy that should go, not the Swift.
    "slopdesk-workspace::connection",
}

_PUB_MOD = re.compile(r"^pub mod (\w+);", re.MULTILINE)
_PUB_USE_GROUP = re.compile(r"^pub use (\w+)::\{(.*?)\};", re.MULTILINE | re.DOTALL)
_PUB_USE_ONE = re.compile(r"^pub use (\w+)::(\w+);", re.MULTILINE)
_LIB_DECLARATIONS = re.compile(r"^pub (?:mod|use) [^;]*;", re.MULTILINE | re.DOTALL)


def no_rust_module_is_written_and_then_never_called() -> Report:
    """A crate module nothing reaches is a port that stopped one step short of finishing.

    The failure this catches is quiet and expensive: `e6b1ce9b` moved four `slopdesk-workspace`
    modules to Rust, gave them 47 tests between them, re-exported all four from `lib.rs` — and
    wired none. `cargo` says nothing, because a `pub` item in a library crate has no unused
    warning to give; the tests are green; and the Swift the port was meant to delete is what
    actually runs. Two implementations, which is the one thing `CLAUDE.md` forbids outright.

    A module counts as REACHED when another Rust file names `module::`, or names something
    `lib.rs` re-exports from it, or when the module exports a `no_mangle` door — that last one is
    the FFI crate's whole shape, and its caller is Swift, which is not in this tree's `.rs` files.
    `lib.rs` itself counts as a caller, but its own `pub mod` / `pub use` lines do not: a
    re-export is what a stranded module has instead of a caller, so reading it as one would make
    this gate unable to fail.
    """
    sources = [path for path in repo_files("rust/*.rs") if "target" not in path.parts]
    bodies = {path: path.read_text(errors="ignore") for path in sources}
    found: list[str] = []
    for lib in sorted(path for path in sources if path.name == "lib.rs"):
        crate, source = lib.parent.parent.name, bodies[lib]
        exported: dict[str, set[str]] = {}
        for module, group in _PUB_USE_GROUP.findall(source):
            spelled = group.replace("\n", " ").split(",")
            names = (name.strip().split(" as ")[0] for name in spelled)
            wanted = {name for name in names if name and name != "self"}
            exported.setdefault(module, set()).update(wanted)
        for module, name in _PUB_USE_ONE.findall(source):
            exported.setdefault(module, set()).add(name)

        for module in _PUB_MOD.findall(source):
            file, directory = lib.parent / f"{module}.rs", lib.parent / module
            inside = [path for path in sources if path == file or directory in path.parents]
            body = "".join(bodies[path] for path in inside)
            if "no_mangle" in body:
                continue  # a door; its caller is Swift
            names = exported.get(module, set())
            reached = False
            for path in sources:
                if path in inside:
                    continue
                text = _LIB_DECLARATIONS.sub("", bodies[path]) if path == lib else bodies[path]
                named = any(re.search(rf"\b{name}\b", text) for name in names)
                if named or re.search(rf"\b{module}::", text):
                    reached = True
                    break
            if not reached and f"{crate}::{module}" not in STRANDED_RUST_MODULES:
                found.append(f"{lib.relative_to(REPO)}: pub mod {module};")
    if not found:
        return None
    stranded = "a Rust module is written and tested and reached by nothing — finish or drop it"
    return found, stranded


#: The docs `CLAUDE.md` sends a reader to before touching anything, plus the two front doors. These
#: must not lie. Every OTHER document — `docs/19`, the `27` to `31` handoffs, `docs/40`, and all of
#: `docs/ui-shell/` — is a record of a plan as it stood, and a path that was real then is not a
#: defect now. 476 stale citations live in those; 5 lived here, which is the whole argument for
#: drawing the line where CLAUDE.md already draws it.
LIVE_DOCS = (
    "CLAUDE.md",
    "README.md",
    "Makefile",
    "docs/00-overview.md",
    "docs/20-wire-protocol.md",
    "docs/45-multi-client-state-sync.md",
    "docs/46-gates-env-paths.md",
    "docs/47-simulator-panel.md",
    "docs/48-android-panel.md",
    "docs/49-release-pipeline.md",
    "docs/50-agent-detection-architecture.md",
    "docs/51-process-supervision.md",
    "docs/52-screen-engine.md",
    "docs/53-file-drop-service.md",
    "docs/54-inspector.md",
    "docs/55-ffi-boundary.md",
)

_PATH_SPAN = re.compile(r"`([^`\s]+)`")
_PATH_ROOTS = (
    "Sources/",
    "Tests/",
    "Apps/",
    "rust/",
    "scripts/",
    "docs/",
    "golden/",
    "ThirdParty/",
)
_LINE_SUFFIX = re.compile(r":[\d,+-]+$")
_DOC_NUMBER = re.compile(r"^docs/(\d+)$")
#: A citation whose whole point is that the file is gone. `docs/51` has a "What this deleted"
#: section; flagging it would be the gate arguing with the document's subject.
_DELETION_HEADINGS = ("What this deleted", "Deleted", "Removed")


def live_docs_cite_files_that_exist() -> Report:
    """A doc a reader is SENT to must not name a path that is not there.

    The failure is not tidiness. `docs/45` claimed a mitigation —
    "`…/HostOutputSnifferGoldenGuardTests.swift` asserts the frozen vector still round-trips" —
    for a test that had moved to Rust with the sniffer. A reader checking whether the blind spot
    was covered would grep, find nothing, and conclude it was not.
    """
    found: list[str] = []
    for name in LIVE_DOCS:
        path = REPO / name
        if not path.exists():
            found.append(f"{name}: the live-doc list names a file that does not exist")
            continue
        deleting = False
        for number, line in enumerate(path.read_text(errors="ignore").split("\n"), 1):
            if line.startswith("#"):
                deleting = any(h in line for h in _DELETION_HEADINGS)
            if deleting:
                continue
            for span in _PATH_SPAN.findall(line):
                cited = span.strip("(").rstrip(".,:;)")
                if not cited.startswith(_PATH_ROOTS) or any(c in cited for c in "*{}…"):
                    continue
                cited = _LINE_SUFFIX.sub("", cited).split("#")[0].split("§")[0]
                numbered = _DOC_NUMBER.match(cited)
                if numbered:  # `docs/51` is how this repo cites doc 51, not a path
                    if not list((REPO / "docs").glob(f"{numbered.group(1)}-*.md")):
                        found.append(f"{name}:{number}: {cited}")
                elif not (REPO / cited).exists():
                    found.append(f"{name}:{number}: {cited}")
    if not found:
        return None
    return found, "a doc CLAUDE.md sends readers to cites a path that is not in the tree"


#: A backticked path is a SOURCE citation only when it ends in one of these — a comment saying
#: "see `Foo/Bar.swift`" is making a checkable claim, whereas `Sources/SlopDeskMacUI/Pane` is a
#: place and `SlopDeskError/badFrame` is a DocC symbol link that happens to carry a slash.
_CITED_SUFFIXES = (".swift", ".rs", ".py", ".sh", ".h", ".toml", ".json", ".yml")
_CITED_PATH = re.compile(r"`{1,2}([A-Za-z0-9_./+-]+/[A-Za-z0-9_+.-]+)`{1,2}")
#: The roots a source citation may be written against. A comment cites either the full repo path
#: or the tail of one (`SlopDeskPhoneUI/Settings/SettingsPages.swift`), and both must resolve.
_CITED_ROOTS = ("Sources", "Tests", "Apps", "ThirdParty", "rust", "scripts", "docs", "golden")


def _addressable_first_segments() -> set[str]:
    """The directory names a citation may START with and still be a claim about THIS tree.

    Without this the gate reads every `foo/bar.rs` in a comment as a repo path, and the ones that
    are not are exactly the ones worth quoting: libghostty upstream (`Helpers/Cursor.swift`), a
    system header (`Carbon/HIToolbox/Events.h`), a runtime file (`slopdesk/config.toml`). None of
    them is in the tree and none of them should be — a gate that demanded they were would be
    demanding the comment lie. So the addressable set is the repo roots plus whatever sits one
    level inside the three source roots, which is derived, never listed.
    """
    segments = set(_CITED_ROOTS)
    for root in ("Sources", "Tests", "Apps"):
        directory = REPO / root
        if directory.is_dir():
            segments.update(child.name for child in directory.iterdir() if child.is_dir())
    return segments


def source_comments_cite_files_that_exist() -> Report:
    """A comment that points at a file must point at a file that is there.

    This is `live_docs_cite_files_that_exist` aimed at the OTHER half of the prose. The docs a
    reader is sent to are gated; the ~40 000 lines of header comment that actually explain this
    codebase were not, and a rename walks straight through them. Increment 63 folded the shared
    SwiftUI target into `SlopDeskPhoneUI` and left nine live citations of
    `SlopDeskClientUI/…/Foo.swift` behind — each one a sentence telling a reader where the other
    half of a decision lives, and each one resolving to nothing. A DocC link into a deleted
    module is worse than no link: it renders as prose and reads as a fact.

    The rule is SHAPE, not a name list, which is why it cannot decay: a backticked token with a
    slash in it and a source suffix on the end IS a path claim, so it must resolve — as a repo
    path or as the tail of one. Names are not checked at all (a module name is not a path, and
    history that says "it lived in the old shared target" is honest and stays legal).
    """
    known: dict[str, list[str]] = {}
    for path in repo_files():
        if path.suffix in _CITED_SUFFIXES:
            known.setdefault(path.name, []).append(str(path.relative_to(REPO)))
    addressable = _addressable_first_segments()
    found: list[str] = []
    for path in repo_files(*(f"{root}/**" for root in _CITED_ROOTS)):
        if path.suffix not in (".swift", ".rs"):
            continue
        for number, line in enumerate(path.read_text(errors="ignore").split("\n"), 1):
            for cited in _CITED_PATH.findall(line):
                if not cited.endswith(_CITED_SUFFIXES):
                    continue
                tail = cited.lstrip("./")
                if tail.split("/")[0] not in addressable:
                    continue
                if not any(real.endswith(tail) for real in known.get(Path(tail).name, [])):
                    found.append(f"{path.relative_to(REPO)}:{number}: {cited}")
    if not found:
        return None
    return found, "a comment cites a source path that is not in the tree — a rename walked past it"


#: `public var onSomething: (…) -> …` — the injected-sink shape this codebase wires its views with.
_SINK_DECL = re.compile(r"public var (on[A-Z][A-Za-z0-9]*)\s*:\s*\(")


def every_injected_sink_has_someone_who_binds_it() -> Report:
    """A seam a view is supposed to install must be installed by a view, not only by a test.

    The pattern all over this tree is an `@ObservationIgnored public var onX: (() -> Void)?` that
    the model FIRES and a view BINDS. When that state later grows an observable twin the view can
    read directly, the sink stops being bound — and nothing says so, because firing an unbound
    optional is a silent no-op and the tests kept assigning it. Three of them survived that way
    (`onRequestCopyMode`, `onCopyConfirmation`, `onRequestViKeyHints`): declared, documented, fired
    from four call sites, asserted by six tests, and connected to no pixel on either platform.

    That shape is worse than dead code, because a test that binds the sink PASSES — it proves the
    model fires, which is true, and says nothing about whether anything listens. It is also the
    shape the two-headed client makes easy: a sink one half binds and the other does not looks
    alive from anywhere except the half that is silent.

    Tests are deliberately not counted as binders, which is the whole point of the gate. Assignment
    anywhere in product code counts, including inside the declaring file — an `init` that takes the
    closure and stores it to `self` is a binding, made by whoever calls the initialiser.
    """
    sinks: dict[str, str] = {}
    for path in repo_files("Sources/**"):
        if path.suffix != ".swift":
            continue
        for name in _SINK_DECL.findall(path.read_text(errors="ignore")):
            sinks.setdefault(name, str(path.relative_to(REPO)))
    product = [
        path
        for path in repo_files("Sources/**", "Apps/**", "ThirdParty/**")
        if path.suffix == ".swift"
    ]
    sources = [path.read_text(errors="ignore") for path in product]
    found: list[str] = []
    for name, home in sorted(sinks.items()):
        assigned = re.compile(rf"(?<![A-Za-z0-9_]){name}\s*=(?!=)")
        if not any(assigned.search(source) for source in sources):
            found.append(f"{home}: {name}")
    if not found:
        return None
    return found, "an injected sink is bound by nobody outside the tests — it reaches no view"


def every_shipped_sidecar_carries_its_own_version() -> Report:
    """A sidecar the pin has never heard of ships at whatever its Cargo.toml happened to say.

    `MANIFEST.json` publishes a version per binary, and the install side restarts a daemon when
    that version moves — so a tool missing from `scripts/tool-stamps.pin` is not a cosmetic gap.
    `package-release.sh` would find no pinned version, and `bump-tool-versions.sh` would treat the
    tool as new on every single run, bumping it whether or not it changed. Either way the number
    stops meaning "this daemon is different from the one you have", which is the only thing the
    number is for.

    The wanted set is the ARRAYS in `scripts/shipped-tools.sh`, the same source
    `the_release_ships_every_sidecar_the_host_needs` reads, so a seventh daemon is covered here the
    day it is added there rather than the day someone remembers this file.

    Only the CARGO tools: `slopdesk` and `slopdesk-hostd` are SwiftPM, they ARE the product, and
    their version is the product's (`docs/49` §"The six version sites"). A pin entry for them would
    be a seventh version site — exactly the thing `bump-version.sh` exists to prevent.
    """
    tools = (REPO / "scripts/shipped-tools.sh").read_text(errors="ignore")
    arrays = re.findall(
        r"^(?:RUST_ROOT_TOOLS|RUST_CRATE_TOOLS)=\((.*?)\)",
        tools,
        re.MULTILINE | re.DOTALL,
    )
    if not arrays:
        return ["scripts/shipped-tools.sh"], "the cargo tool arrays are gone — this gate is blind"
    shipped = {name for body in arrays for name in re.findall(r"\bslopdesk-[a-z]+\b", body)}

    pin = REPO / "scripts/tool-stamps.pin"
    if not pin.exists():
        return ["scripts/tool-stamps.pin"], "the tool pin is missing — every sidecar is unversioned"
    pinned = {
        line.split()[0]
        for line in pin.read_text(errors="ignore").splitlines()
        if line.strip() and not line.startswith("#")
    }

    missing = sorted(shipped - pinned)
    # A pin entry for a tool nobody ships is the same bug wearing the other hat: it keeps a stale
    # version alive in `MANIFEST.json` for a binary that is not in the tarball.
    orphaned = sorted(pinned - shipped)
    if not missing and not orphaned:
        return None
    return (
        missing + orphaned,
        (
            "scripts/tool-stamps.pin and the shipped cargo tools disagree"
            " — run scripts/bump-tool-versions.sh"
        ),
    )


def the_formula_installs_every_binary_the_release_ships() -> Report:
    """A binary the tarball carries and the formula does not name is a feature `brew` cannot run.

    This is the same failure `the_release_ships_every_sidecar_the_host_needs` catches one step
    earlier, at the step nothing was watching. The tarball was fixed to carry all twelve tools; the
    FORMULA went on installing three of them — `slopdesk`, `slopdesk-hostd`, `slopdesk-ctl` — for
    four releases, so a `brew install` still produced a host with no superd and therefore no pane.
    Nothing could see it, for the same reason as before and one repository over: the formula lived
    in `aislopware/homebrew-tap`, and a file in another repository is checked by nobody.

    So the formula lives in `packaging/homebrew/` and the release workflow COPIES it into the tap,
    rewriting only `version` and `sha256`. That makes it a file in this tree, which makes it
    gateable, which is this function.

    `MANIFEST.json` is checked too, and it is not decoration: `slopdesk sidecars` diffs it against
    the copy recorded by the previous install to say WHICH binaries an upgrade changed. Without it
    installed the only honest answer is "all of them", which is the all-or-nothing upgrade the
    per-tool version exists to end (`docs/49`).
    """
    site = "packaging/homebrew/Formula/slopdesk.rb"
    formula = REPO / site
    if not formula.exists():
        return [site], "the formula is gone — the tap has no source of truth"
    text = formula.read_text(errors="ignore")

    installed_block = re.search(r"bin\.install\b(.*?)\n\n", text, re.DOTALL)
    if not installed_block:
        return [site], "the formula has no bin.install — this gate is blind"
    installed = set(re.findall(r'"(slopdesk(?:-[a-z]+)?)"', installed_block.group(1)))

    tools = (REPO / "scripts/shipped-tools.sh").read_text(errors="ignore")
    arrays = re.findall(
        r"^(?:SPM_TOOLS|RUST_ROOT_TOOLS|RUST_CRATE_TOOLS)=\((.*?)\)",
        tools,
        re.MULTILINE | re.DOTALL,
    )
    if not arrays:
        return ["scripts/shipped-tools.sh"], "the release tool arrays are gone — this gate is blind"
    shipped = {name for body in arrays for name in re.findall(r"\bslopdesk(?:-[a-z]+)?\b", body)}

    missing = sorted(shipped - installed)
    # The other direction is a bug too: a formula naming a binary the tarball does not carry makes
    # `brew install` fail outright on the missing file, which at least is loud — but it is still a
    # claim about the release that the release does not honour.
    invented = sorted(installed - shipped)
    if not text.count('prefix.install "MANIFEST.json"'):
        return (
            [site],
            "the formula installs no MANIFEST.json — `slopdesk sidecars` cannot say what changed",
        )
    if not missing and not invented:
        return None
    return missing + invented, f"{site} and the shipped tool set disagree"


GATES = [
    live_docs_cite_files_that_exist,
    source_comments_cite_files_that_exist,
    every_injected_sink_has_someone_who_binds_it,
    no_app_layer_crypto,
    no_swiftpm_build_plugin,
    no_fused_multiply_add,
    every_script_sets_pipefail,
    a_script_with_a_shebang_is_executable,
    the_release_ships_every_sidecar_the_host_needs,
    every_shipped_sidecar_carries_its_own_version,
    the_formula_installs_every_binary_the_release_ships,
    no_rust_module_is_written_and_then_never_called,
    pkill_never_reaches_the_developers_host,
    shell_quoting_has_one_owner,
]


def main() -> int:
    """Run every gate, report each failure with its sites, and answer with the exit status."""
    if "--list" in sys.argv:
        for gate in GATES:
            summary = (gate.__doc__ or "").strip().split("\n")[0]
            print(f"{gate.__name__}: {summary}")
        return 0

    broken = 0
    for gate in GATES:
        report = gate()
        if report is None:
            continue
        broken += 1
        sites, message = report
        for site in sites:
            print(site, file=sys.stderr)
        print(f"check-invariants: FAIL — {message}", file=sys.stderr)

    if broken:
        print(f"check-invariants: {broken} of {len(GATES)} invariants broken.", file=sys.stderr)
        return 1
    print(f"check-invariants: {len(GATES)} invariants hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
