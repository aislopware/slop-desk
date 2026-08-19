#!/usr/bin/env python3
"""A number meaning the same in both languages is ASKED FOR or RATCHETED, never spelled twice.

Two constants with the same name and the same value on either side of the FFI boundary are one
constant written twice. Nothing catches that: both sides compile, every test passes, and the two
copies agree right up until someone tunes one of them. Then the client draws by a threshold the host
does not enforce, and the first symptom is a wrong-length ring or a fragmented datagram, never an
error.

This repo settles it two ways, and which one is right follows from the LIFETIME of the boundary
(CLAUDE.md, "a port ships over a socket, or as a linked library"):

  * IN-PROCESS, across `CSlopDeskFFI` — Swift ASKS. The number crosses through a door and exists
    once — `Canvas.minItemSize`, `WorkspaceTopology.closedTabRingCap`,
    `VideoPacketizer.maxDatagramSize`.
  * ACROSS A SOCKET, to a sidecar — the two spellings are RATCHETED against each other by a gate in
    `check-supervisor.sh`, because a separately-shipped binary cannot link the other's constant.

A VOCABULARY is the exception both answers miss, and it gets the third: an alphabet of field bytes
that both ends must NAME, frozen on the wire, where an index-shaped door would only move the
transcription. Those pairs are ratcheted here instead, letter for letter and in both directions.

So a pair is a finding here only when it is none of the three. The allowlist below is for HOMONYMS:
names that collide by accident and describe unrelated laws, where folding them would be the bug.

Usage: scripts/check-shared-constants.py   (exit 1 on any finding)
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Names that collide but do NOT describe the same law. Folding either pair into one door would make
# a change to one silently move the other.
# Enums that share a name across the two languages without sharing a meaning. None yet: every pair
# found so far is one wire alphabet. An entry here needs the reason the two are unrelated.
HOMONYM_ENUMS: set[str] = set()

# Swift OptionSets whose members share a name with a WIRE flag set without sharing its law. A bit
# position is only a shared law when the byte crosses; a set that never leaves the client may lay
# its bits out however it likes.
HOMONYM_BIT_FILES = {
    # `KeyChord.Modifiers` is an `Int` the client keys chords by. It converts to nothing, so its
    # agreement with the wire's `InputModifiers` about ⇧⌃⌥⌘ is convention, not a contract.
    "Sources/SlopDeskWorkspaceCore/Workspace/Store/CommandInterpreter.swift",
}

HOMONYMS = {
    # A kernel TCP keepalive probe interval on PATH 1, against the video path's application-level
    # UDP keepalive that holds a NAT mapping open. Both happen to be 5 s.
    "keepaliveIntervalSeconds",
    # A workspace state FILE's schema version, against slopdesk-dropd's socket protocol version.
    "version",
    "currentSchemaVersion",
    # The split tree's nesting depth limit, against the JSON reader's recursion limit.
    "maxDepth",
    # The playout law's jitter coefficient, against the adaptive FEC's data-shard count. Both `k`.
    "defaultK",
}

# A VOCABULARY is the one shared number a door cannot dissolve. A field byte is not a law anyone
# may tune — it is a letter of the document's alphabet, frozen the moment a golden vector carries
# one, and both ends must be able to NAME it (`WorkspacePaneField.liveTitle`) rather than reach for
# it through an index that would itself be the transcription. So the pair is ratcheted instead:
# every name in the scope must exist on both sides and carry the same byte, in both directions. A
# field added to one language and not the other fails here rather than at a peer of another build.
#
# Each entry is (Swift file, Rust file, {Swift type: Rust module}).
VOCABULARIES = [
    (
        "Sources/SlopDeskWorkspaceModel/State/WorkspaceFields.swift",
        "rust/slopdesk-wire/src/document/fields.rs",
        {
            "WorkspaceRootField": "root",
            "WorkspaceSessionField": "session",
            "WorkspaceTabField": "tab",
            "WorkspacePaneField": "pane",
            "WorkspaceSplitNodeField": "split_node",
            "WorkspaceProjectField": "project",
        },
    ),
]

# A DERIVED gate names no constant, which is what makes it a ratchet rather than a list — and what
# makes it invisible to the "does check-supervisor.sh mention this name" test below. These pairs
# declare the gate that already compares them, so the two are not counted twice.
# Keyed by the gate's own label, which must still be there: an escape hatch pointing at a gate
# someone deleted is a suppression, not a ratchet.
DERIVED_RATCHETS = {
    ("Sources/SlopDeskScreen/ScreenProtocol.swift", "rust/slopdesk-screenwire/src/lib.rs"): (
        'same "screend reset flags"'
    ),
}

RUST_SCOPE = re.compile(r"^pub mod ([a-z_]+) \{$", re.MULTILINE)
SWIFT_SCOPE = re.compile(r"^public enum ([A-Za-z]+) \{$", re.MULTILINE)

# Decimal, hex or binary — a flag byte is written `0x10` on both sides and a decimal-only pattern
# reads neither of them, which is how four `slopdesk-screenwire` flags stayed unwatched.
NUMBER = r"(0[xX][0-9a-fA-F_]+|0b[01_]+|[0-9][0-9_]*(?:\.[0-9]+)?)"

RUST_CONST = re.compile(
    # Indented, because a vocabulary declares its constants inside a `mod` — anchoring at column 0
    # hid every field byte in `slopdesk_wire::document::fields` from this gate until 2026-08-17.
    r"^[ \t]*pub const ([A-Z][A-Z_0-9]*): *"
    r"(?:usize|u8|u16|u32|u64|i8|i16|i32|i64|f32|f64) *= *" + NUMBER + r"\s*;",
    re.MULTILINE,
)
SWIFT_CONST = re.compile(
    r"^\s*(?:public |private |internal |fileprivate )?static let ([A-Za-z][A-Za-z0-9]*)"
    r"(?: *: *[A-Za-z][A-Za-z0-9]*)? *= *" + NUMBER + r"\s*$",
    re.MULTILINE,
)

# An enum's discriminants are the same kind of alphabet as a field byte, and drift the same way: a
# verb byte that moved in one language is a request the other end answers as a DIFFERENT verb. These
# pair by NAME rather than by a declared list, because a wire enum is spelled the same in both
# languages — so any enum both sides declare, sharing any case, must agree about every case.
RUST_ENUM = re.compile(r"^pub enum ([A-Za-z][A-Za-z0-9]*)[^\n]*\{$", re.MULTILINE)
SWIFT_ENUM = re.compile(
    r"^(?:public |internal |private )?enum ([A-Za-z][A-Za-z0-9]*)[^\n]*\{$", re.MULTILINE
)
RUST_CASE = re.compile(r"^\s*([A-Z][A-Za-z0-9]*) = " + NUMBER + r",\s*$", re.MULTILINE)

# An OptionSet's bit POSITIONS are the third alphabet: `1 << 6` on both sides, spelled as an
# expression rather than a literal, so neither of the patterns above reads one.
RUST_BIT = re.compile(
    r"^\s*pub const ([A-Z][A-Z_0-9]*): *Self *= *Self\(1 *<< *([0-9]+)\);", re.MULTILINE
)
SWIFT_BIT = re.compile(
    r"^\s*(?:public |private |internal )?static let ([A-Za-z][A-Za-z0-9]*)"
    r" *(?::[^=\n]+)?= *(?:Self|[A-Za-z][A-Za-z0-9]*)\(rawValue: *1 *<< *([0-9]+)\)",
    re.MULTILINE,
)
SWIFT_CASE = re.compile(r"^\s*case ([a-z][A-Za-z0-9]*) = " + NUMBER + r"\s*$", re.MULTILINE)


def tracked(pattern: str) -> list[Path]:
    """Every git-tracked file matching a pathspec, so an untracked scratch file is not audited."""
    out = subprocess.run(
        ["git", "ls-files", pattern], cwd=ROOT, capture_output=True, text=True, check=True
    )
    return [ROOT / line for line in out.stdout.split()]


def numeric(text: str) -> float:
    """A literal's value, in whichever of the three notations it was written."""
    plain = text.replace("_", "")
    return float(int(plain, 0)) if plain[:2].lower() in {"0x", "0b"} else float(plain)


def scopes(
    text: str, opener: re.Pattern[str], const: re.Pattern[str]
) -> dict[str, dict[str, float]]:
    """Each `mod`/`enum` in `text`, mapped to the constants declared before the next one opens."""
    starts = [(m.group(1), m.end()) for m in opener.finditer(text)]
    if not starts:
        return {}
    ends = [start for _, start in starts[1:]] + [len(text)]
    bounds = [(name, at, end) for (name, at), end in zip(starts, ends, strict=True)]
    return {
        name: {n.replace("_", "").lower(): numeric(v) for n, v in const.findall(text[at:end])}
        for name, at, end in bounds
    }


def vocabulary_findings() -> list[str]:
    """Every way a declared alphabet stopped meaning the same thing letter for letter."""
    out: list[str] = []
    for swift_file, rust_file, pairs in VOCABULARIES:
        swift = scopes((ROOT / swift_file).read_text(), SWIFT_SCOPE, SWIFT_CONST)
        rust = scopes((ROOT / rust_file).read_text(), RUST_SCOPE, RUST_CONST)
        for swift_scope, rust_scope in pairs.items():
            here, there = swift.get(swift_scope, {}), rust.get(rust_scope, {})
            if not here or not there:
                out.append(f"  {swift_file}: `{swift_scope}` and `{rust_scope}` no longer pair up")
                continue
            for name in sorted(set(here) | set(there)):
                if name not in here:
                    out.append(
                        f"  {swift_file}: `{swift_scope}` is missing `{name}`, "
                        f"which {rust_scope} declares"
                    )
                elif name not in there:
                    out.append(
                        f"  {rust_file}: `{rust_scope}` is missing `{name}`, "
                        f"which {swift_scope} declares"
                    )
                elif here[name] != there[name]:
                    out.append(
                        f"  {swift_file}: `{swift_scope}.{name} = {here[name]:g}` against "
                        f"`{rust_scope}::{name} = {there[name]:g}`"
                    )
    return out


def enum_findings() -> list[str]:
    """Every wire enum whose two spellings stopped agreeing, case for case."""
    rust: dict[str, list[tuple[str, dict[str, float]]]] = {}
    for path in tracked("rust/*.rs"):
        text = path.read_text()
        for name, cases in scopes(text, RUST_ENUM, RUST_CASE).items():
            if cases:
                rust.setdefault(name, []).append((str(path.relative_to(ROOT)), cases))

    out: list[str] = []
    for path in tracked("Sources/*.swift"):
        here_file = str(path.relative_to(ROOT))
        for name, here in scopes(path.read_text(), SWIFT_ENUM, SWIFT_CASE).items():
            if not here or name in HOMONYM_ENUMS:
                continue
            for there_file, there in rust.get(name, []):
                if not set(here) & set(there):
                    continue  # same name, no case in common: not the same alphabet
                for case in sorted(set(here) | set(there)):
                    if case not in here:
                        out.append(f"  {here_file}: `{name}` is missing `{case}`, in {there_file}")
                    elif case not in there:
                        out.append(f"  {there_file}: `{name}` is missing `{case}`, in {here_file}")
                    elif here[case] != there[case]:
                        out.append(
                            f"  {here_file}: `{name}.{case} = {here[case]:g}` against "
                            f"`{there[case]:g}` in {there_file}"
                        )
    return out


def bit_findings() -> list[str]:
    """Every wire flag whose bit moved in one language and not the other."""
    rust: dict[str, list[tuple[str, str, int]]] = {}
    for path in tracked("rust/*.rs"):
        for name, bit in RUST_BIT.findall(path.read_text()):
            key = name.replace("_", "").lower()
            rust.setdefault(key, []).append((str(path.relative_to(ROOT)), name, int(bit)))

    out: list[str] = []
    for path in tracked("Sources/*.swift"):
        here_file = str(path.relative_to(ROOT))
        if here_file in HOMONYM_BIT_FILES:
            continue
        for name, bit in SWIFT_BIT.findall(path.read_text()):
            for there_file, there_name, there_bit in rust.get(name.lower(), []):
                if int(bit) != there_bit:
                    out.append(
                        f"  {here_file}: `{name} = 1 << {bit}` against "
                        f"`{there_name} = 1 << {there_bit}` in {there_file}"
                    )
    return out


def main() -> int:
    rust: dict[str, list[tuple[Path, str, float]]] = {}
    for path in tracked("rust/*.rs"):
        for name, value in RUST_CONST.findall(path.read_text()):
            rust.setdefault(name.replace("_", "").lower(), []).append((path, name, numeric(value)))

    # A name a supervisor gate already compares is ratcheted, which is the sidecar answer.
    ratcheted = (ROOT / "scripts" / "check-supervisor.sh").read_text()

    vocabulary = {ROOT / swift for swift, _, _ in VOCABULARIES}

    findings: list[str] = []
    for path in tracked("Sources/*.swift"):
        if path in vocabulary:
            continue  # ratcheted letter for letter below, which is stricter than this pass
        for name, value in SWIFT_CONST.findall(path.read_text()):
            for rust_path, rust_name, rust_value in rust.get(name.lower(), []):
                if numeric(value) != rust_value:
                    continue  # a different number is a different constant, or a gate's business
                if name in HOMONYMS or name in ratcheted or rust_name in ratcheted:
                    continue
                pair = (str(path.relative_to(ROOT)), str(rust_path.relative_to(ROOT)))
                if DERIVED_RATCHETS.get(pair, "\0") in ratcheted:
                    continue
                findings.append(
                    f"  {path.relative_to(ROOT)}: `{name} = {value}` restates "
                    f"`{rust_name}` in {rust_path.relative_to(ROOT)}"
                )

    if findings:
        print("check-shared-constants: FAIL — a constant is spelled in both languages\n")
        print("\n".join(sorted(findings)))
        print(
            "\nAsk for it through a `CSlopDeskFFI` door (see `slopdesk_ws_min_weight` for the\n"
            "shape), or — if the two ends are separate BINARIES — ratchet the pair in\n"
            "scripts/check-supervisor.sh. A genuine name collision goes in this script's HOMONYMS\n"
            "with the reason the two laws are unrelated."
        )
        return 1

    drifted = vocabulary_findings() + enum_findings() + bit_findings()
    if drifted:
        print("check-shared-constants: FAIL — a shared alphabet drifted\n")
        print("\n".join(drifted))
        print(
            "\nA field byte is frozen on the wire and NAMED on both sides, so the two spellings\n"
            "are ratcheted rather than folded into a door. Add the letter to both, or give it the\n"
            "same byte on both — a mis-numbered field decodes cleanly into the wrong meaning."
        )
        return 1

    print(
        "check-shared-constants: every shared number is asked for or ratcheted, and the field\n"
        "vocabulary, the wire enums and the flag bits agree letter for letter."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
