#!/usr/bin/env python3
"""Raise `internal` declarations to `package` so a moved file keeps its callers.

Splitting one target into several turns every cross-file reference into a cross-MODULE
reference, and Swift's default `internal` stops at the module edge. The mechanical part of
that move — annotating the declarations the other module now has to see — is what this does.

`package`, not `public`: the callers are all inside this SwiftPM package (the UI targets and
the test targets), and the Xcode app targets are OUTSIDE it, so `package` keeps the app-facing
surface exactly as small as it is today. A symbol an app really does need stays `public` by
hand.

WHAT IT ANNOTATES, and nothing else:
  - a type declared at file scope or inside another type;
  - a member (`func`/`var`/`let`/`init`/`subscript`/`typealias`) of such a type;
  - an `extension`, and its members.

WHAT IT LEAVES ALONE, each for a reason the compiler would otherwise teach the hard way:
  - anything already carrying an access modifier — including `private`, which is a decision;
  - `case`, which takes the enum's access;
  - `deinit`, `override`, and operator declarations, which reject the modifier;
  - a protocol BODY — requirements may not carry access modifiers;
  - a function/accessor body — locals are not API;
  - a conformance `extension` (`extension X: Y`), which rejects the modifier on the extension
    itself; its members are still annotated.

It is a line scanner, not a parser, which is sound here because the tree is SwiftFormat-clean:
declarations start their line. The compiler is the oracle either way — run `swift build` after.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

# A declaration line: optional attributes and declaration modifiers, then the keyword.
# `private(set)` is a SETTER access modifier: the getter it leaves behind is still `internal`, so a
# declaration carrying one needs `package` in front of it rather than being skipped as "already
# annotated". It therefore belongs with the declaration modifiers, not with ACCESS.
MODIFIERS = (
    r"(?:final|static|class|lazy|weak|unowned|mutating|nonmutating|required|convenience"
    r"|dynamic|indirect|nonisolated|isolated|borrowing|consuming|sending|override"
    r"|(?:private|fileprivate|internal|package|public)\(set\))"
)
ATTRIBUTE = r"(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)"
ACCESS = r"(?:open|public|package|internal|fileprivate|private)(?!\(set\))"

TYPE_KEYWORDS = ("class", "struct", "enum", "actor", "protocol")
MEMBER_KEYWORDS = ("func", "var", "let", "init", "subscript", "typealias", "associatedtype")
DECLARABLE = (*TYPE_KEYWORDS, "extension", *MEMBER_KEYWORDS)
# Line starters that are STATEMENTS, not declarations. Their brace opens a body, so the scope they
# push must be opaque — otherwise a `let` inside an `if` reads as a member of the enclosing type.
STATEMENT_KEYWORDS = ("deinit", "case", "if", "for", "while", "guard", "switch", "do", "repeat")

# The prefix deliberately ADMITS an access modifier so scope tracking still recognises a declaration
# the tool has already annotated — a second run must see `package final class X {` as a type, or the
# members inside it stop being annotated. Whether a declaration is already annotated is answered by
# looking at the captured prefix, not by failing to parse it.
DECL_RE = re.compile(
    rf"^(?P<indent>\s*)(?P<prefix>(?:{ATTRIBUTE}|{MODIFIERS}\s+|{ACCESS}\s+)*)(?P<keyword>[a-z]+)\b",
)
ACCESS_IN_PREFIX_RE = re.compile(rf"(?:^|\s){ACCESS}\s")


def strip_noise(line: str) -> str:
    """Drop string literals and a trailing line comment so brace counting is honest."""
    out: list[str] = []
    i, n = 0, len(line)
    in_string = False
    while i < n:
        c = line[i]
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            i += 1
            continue
        if c == "/" and i + 1 < n and line[i + 1] == "/":
            break
        if c == "/" and i + 1 < n and line[i + 1] == "*":
            break
        out.append(c)
        i += 1
    return "".join(out)


class Scope:
    """One `{ … }` level, remembering what opened it."""

    __slots__ = ("hoisted", "kind")

    def __init__(self, kind: str, *, hoisted: bool = False) -> None:
        self.kind = kind  # "type" | "protocol" | "opaque" | "file"
        # A `package extension` HANDS its access to every member, and SwiftFormat's
        # `extensionAccessControl` rewrites this tool's per-member output into exactly that shape.
        # So a second run over an already-migrated tree must not re-annotate inside one: the result
        # compiles, with a redundant-modifier warning on every line it touched. This is what makes
        # the tool idempotent against the formatter that runs after it.
        self.hoisted = hoisted


def classify(keyword: str) -> str:
    """What kind of scope does this declaration's brace open?"""
    if keyword == "protocol":
        return "protocol"
    if keyword in TYPE_KEYWORDS or keyword == "extension":
        return "type"
    return "opaque"


def annotates(keyword: str, line: str, scopes: list[Scope]) -> bool:
    enclosing = scopes[-1].kind
    if enclosing not in ("file", "type") or scopes[-1].hoisted:
        return False
    if keyword in TYPE_KEYWORDS or keyword == "extension":
        # `extension X: P` — a conformance extension rejects an access modifier.
        if keyword == "extension":
            head = line.split("{", 1)[0]
            head = head.split(" where ", 1)[0]
            if ":" in head:
                return False
        return enclosing in ("file", "type")
    if keyword in MEMBER_KEYWORDS:
        # `associatedtype` only appears in protocols, which are excluded above.
        return enclosing == "type"
    return False


def transform(text: str) -> tuple[str, int]:
    scopes: list[Scope] = [Scope("file")]
    out: list[str] = []
    raised = 0
    pending_kind: str | None = None
    pending_hoisted = False
    for line in text.splitlines(keepends=True):
        body = strip_noise(line)
        stripped = body.strip()
        emitted = line

        match = DECL_RE.match(body) if stripped else None
        if (
            match
            and not ACCESS_IN_PREFIX_RE.search(match.group("prefix"))
            and match.group("keyword") in DECLARABLE
            and annotates(match.group("keyword"), body, scopes)
        ):
            indent = match.group("indent")
            rest = line[len(indent) :]
            emitted = f"{indent}package {rest}"
            raised += 1
        if match:
            keyword = match.group("keyword")
            if keyword in TYPE_KEYWORDS or keyword == "extension":
                pending_kind = classify(keyword)
                pending_hoisted = keyword == "extension" and bool(
                    re.search(r"(?:^|\s)(?:open|public|package)\s", match.group("prefix")),
                )
            elif keyword in MEMBER_KEYWORDS or keyword in STATEMENT_KEYWORDS:
                pending_kind = "opaque"

        out.append(emitted)

        for ch in body:
            if ch == "{":
                scopes.append(Scope(pending_kind or "opaque", hoisted=pending_hoisted))
                pending_kind, pending_hoisted = None, False
            elif ch == "}":
                if len(scopes) > 1:
                    scopes.pop()
        # A declaration whose brace lands on a later line keeps its kind pending; any other
        # statement clears it so a stray `{` does not inherit a type scope.
        if (
            "{" not in body
            and stripped
            and not (match and match.group("keyword") in (*TYPE_KEYWORDS, "extension"))
        ):
            pending_kind, pending_hoisted = None, False
    return "".join(out), raised


# `struct S: OptionSet { package let rawValue: T }` compiles while S is internal — Swift synthesises
# the memberwise `init(rawValue:)` at the struct's own access level. Raise the struct to `package`
# and that synthesised initializer is suddenly less accessible than the protocol requirement it
# satisfies, which is an error rather than a warning. Writing it out is the whole fix.
RAWVALUE_RE = re.compile(
    r"^(?P<indent>[ \t]*)package let rawValue: (?P<type>[A-Za-z_][A-Za-z0-9_.<>, ]*)\s*$",
    re.MULTILINE,
)
OPTIONSET_HEAD_RE = re.compile(
    r"^[ \t]*package (?:final )?struct [A-Za-z_][A-Za-z0-9_]*[^\n{]*:\s*[^\n{]*"
    r"\b(?:OptionSet|RawRepresentable)\b",
    re.MULTILINE,
)


def add_rawvalue_inits(text: str) -> tuple[str, int]:
    """Write out the `init(rawValue:)` a raised OptionSet/RawRepresentable now needs."""
    added = 0
    out = text
    for match in reversed(list(RAWVALUE_RE.finditer(text))):
        head_start = out.rfind("\n", 0, match.start())
        # Find the declaration this stored property belongs to, and require it to be one of the two
        # protocols whose requirement the synthesised initializer satisfies.
        struct_head = None
        for candidate in OPTIONSET_HEAD_RE.finditer(out[: match.start()]):
            struct_head = candidate
        if struct_head is None:
            continue
        body_end = out.find("\n}", struct_head.end())
        if body_end != -1 and body_end < match.start():
            continue  # the property is not inside that struct
        scope = out[struct_head.end() : match.start() + 4000]
        if "init(rawValue" in scope:
            continue
        indent = match.group("indent")
        rendered = (
            f"\n{indent}package init(rawValue: {match.group('type')}) "
            f"{{ self.rawValue = rawValue }}"
        )
        out = out[: match.end()] + rendered + out[match.end() :]
        added += 1
        del head_start
    return out, added


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=pathlib.Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    files: list[pathlib.Path] = []
    for path in args.paths:
        files.extend(sorted(path.rglob("*.swift")) if path.is_dir() else [path])

    total = 0
    for file in files:
        original = file.read_text()
        updated, raised = transform(original)
        updated, inits = add_rawvalue_inits(updated)
        raised += inits
        if raised and not args.dry_run:
            file.write_text(updated)
        if raised:
            print(f"{raised:5d}  {file}")
        total += raised
    print(f"--- {total} declarations raised to `package` across {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
