//! Raise `internal` declarations to `package` so a moved file keeps its callers.
//!
//! Splitting one target into several turns every cross-file reference into a cross-MODULE
//! reference, and Swift's default `internal` stops at the module edge. The mechanical part of that
//! move — annotating the declarations the other module now has to see — is what this does.
//!
//! `package`, not `public`: the callers are all inside this `SwiftPM` package (the UI targets and
//! the test targets), and the Xcode app targets are OUTSIDE it, so `package` keeps the app-facing
//! surface exactly as small as it is today. A symbol an app really does need stays `public` by
//! hand.
//!
//! WHAT IT ANNOTATES, and nothing else:
//!   - a type declared at file scope or inside another type;
//!   - a member (`func`/`var`/`let`/`init`/`subscript`/`typealias`) of such a type;
//!   - an `extension`, and its members.
//!
//! WHAT IT LEAVES ALONE, each for a reason the compiler would otherwise teach the hard way:
//!   - anything already carrying an access modifier — including `private`, which is a decision;
//!   - `case`, which takes the enum's access;
//!   - `deinit`, `override`, and operator declarations, which reject the modifier;
//!   - a protocol BODY — requirements may not carry access modifiers;
//!   - a function/accessor body — locals are not API;
//!   - a conformance `extension` (`extension X: Y`), which rejects the modifier on the extension
//!     itself; its members are still annotated.
//!
//! It is a line scanner, not a parser, which is sound here because the tree is SwiftFormat-clean:
//! declarations start their line. The compiler is the oracle either way — run `swift build` after.

use std::sync::LazyLock;

use regex::Regex;

/// Declaration modifiers that may sit between the attributes and the keyword.
///
/// `private(set)` is a SETTER access modifier: the getter it leaves behind is still `internal`, so
/// a declaration carrying one needs `package` in front of it rather than being skipped as "already
/// annotated". It therefore belongs here, not with `ACCESS`.
const MODIFIERS: &str = concat!(
    r"(?:final|static|class|lazy|weak|unowned|mutating|nonmutating|required|convenience",
    r"|dynamic|indirect|nonisolated|isolated|borrowing|consuming|sending|override",
    r"|(?:private|fileprivate|internal|package|public)\(set\))"
);
/// An attribute and the whitespace after it.
const ATTRIBUTE: &str = r"(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)";
/// An access modifier.
///
/// The Python this came from spelled a `(?!\(set\))` after this group, which the `regex` crate has
/// no syntax for and which neither use site needs: both are `ACCESS` followed by `\s`, and
/// `private(set)` fails that on the `(` without any lookahead. The exclusion is structural.
const ACCESS: &str = r"(?:open|public|package|internal|fileprivate|private)";

/// Keywords whose brace opens a type body.
const TYPE_KEYWORDS: [&str; 5] = ["class", "struct", "enum", "actor", "protocol"];
/// Keywords that declare a member of a type.
const MEMBER_KEYWORDS: [&str; 7] = [
    "func",
    "var",
    "let",
    "init",
    "subscript",
    "typealias",
    "associatedtype",
];
/// Line starters that are STATEMENTS, not declarations.
///
/// Their brace opens a body, so the scope they push must be opaque — otherwise a `let` inside an
/// `if` reads as a member of the enclosing type.
const STATEMENT_KEYWORDS: [&str; 9] = [
    "deinit", "case", "if", "for", "while", "guard", "switch", "do", "repeat",
];

/// The declaration line reader.
///
/// The prefix deliberately ADMITS an access modifier so scope tracking still recognises a
/// declaration the tool has already annotated — a second run must see `package final class X {` as
/// a type, or the members inside it stop being annotated. Whether a declaration is already
/// annotated is answered by looking at the captured prefix, not by failing to parse it.
fn declaration() -> &'static Regex {
    static HELD: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(&format!(
            r"^(?P<indent>\s*)(?P<prefix>(?:{ATTRIBUTE}|{MODIFIERS}\s+|{ACCESS}\s+)*)(?P<keyword>[a-z]+)\b"
        ))
        .expect("the declaration pattern is a literal in this file")
    });
    &HELD
}

/// Whether a captured prefix already carries an access modifier.
fn access_in_prefix() -> &'static Regex {
    static HELD: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(&format!(r"(?:^|\s){ACCESS}\s")).expect("the access pattern is a literal in this file")
    });
    &HELD
}

/// An `extension` prefix that already hands its access down to every member.
fn hoisting_prefix() -> &'static Regex {
    static HELD: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?:^|\s)(?:open|public|package)\s").expect("the hoist pattern is a literal in this file")
    });
    &HELD
}

/// Drop string literals and a trailing line comment so brace counting is honest.
#[must_use]
pub fn strip_noise(line: &str) -> String {
    let chars: Vec<char> = line.chars().collect();
    let mut out = String::with_capacity(line.len());
    let mut at = 0;
    let mut in_string = false;
    while let Some(here) = chars.get(at).copied() {
        if in_string {
            if here == '\\' {
                at += 2;
                continue;
            }
            if here == '"' {
                in_string = false;
            }
            at += 1;
            continue;
        }
        if here == '"' {
            in_string = true;
            at += 1;
            continue;
        }
        if here == '/' && matches!(chars.get(at + 1), Some('/' | '*')) {
            break;
        }
        out.push(here);
        at += 1;
    }
    out
}

/// What kind of scope a declaration's brace opens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// A file's top level.
    File,
    /// A type or an extension body: its members are API.
    Type,
    /// A protocol body: requirements may not carry access modifiers.
    Protocol,
    /// Anything whose contents are not API — a function body, an `if`, a `switch`.
    Opaque,
}

/// One `{ … }` level, remembering what opened it.
#[derive(Debug, Clone, Copy)]
struct Scope {
    kind: Kind,
    /// A `package extension` HANDS its access to every member, and `SwiftFormat`'s
    /// `extensionAccessControl` rewrites this tool's per-member output into exactly that shape. So
    /// a second run over an already-migrated tree must not re-annotate inside one: the result
    /// compiles, with a redundant-modifier warning on every line it touched. This is what makes
    /// the tool idempotent against the formatter that runs after it.
    hoisted: bool,
}

/// What kind of scope does this declaration's brace open?
fn classify(keyword: &str) -> Kind {
    if keyword == "protocol" {
        return Kind::Protocol;
    }
    if TYPE_KEYWORDS.contains(&keyword) || keyword == "extension" {
        return Kind::Type;
    }
    Kind::Opaque
}

/// Whether this declaration takes a `package`.
fn annotates(keyword: &str, line: &str, scopes: &[Scope]) -> bool {
    let Some(enclosing) = scopes.last() else {
        return false;
    };
    if !matches!(enclosing.kind, Kind::File | Kind::Type) || enclosing.hoisted {
        return false;
    }
    if TYPE_KEYWORDS.contains(&keyword) || keyword == "extension" {
        // `extension X: P` — a conformance extension rejects an access modifier.
        if keyword == "extension" {
            let head = line.split_once('{').map_or(line, |(head, _)| head);
            let head = head.split_once(" where ").map_or(head, |(head, _)| head);
            if head.contains(':') {
                return false;
            }
        }
        return true;
    }
    // `associatedtype` only appears in protocols, which are excluded above.
    MEMBER_KEYWORDS.contains(&keyword) && enclosing.kind == Kind::Type
}

/// Every line, split on `\n` with the separator kept.
///
/// Python's `splitlines` also breaks on `\r`, `\x0b`, `\x0c`, ` ` and ` `; this does
/// not, and the difference is the right one. A lone `\r` inside a Swift file is either in a
/// string literal — where a break would desynchronise the brace counter — or a line ending no
/// SwiftFormat-clean file has.
fn lines_with_endings(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut rest = text;
    while !rest.is_empty() {
        let cut = rest.find('\n').map_or(rest.len(), |at| at + 1);
        let (line, tail) = rest.split_at(cut);
        out.push(line);
        rest = tail;
    }
    out
}

/// Annotate a file, and say how many declarations were raised.
#[must_use]
pub fn transform(text: &str) -> (String, usize) {
    let mut scopes: Vec<Scope> = vec![Scope {
        kind: Kind::File,
        hoisted: false,
    }];
    let mut out = String::with_capacity(text.len());
    let mut raised = 0;
    let mut pending: Option<Kind> = None;
    let mut pending_hoisted = false;

    for line in lines_with_endings(text) {
        let body = strip_noise(line);
        let stripped = body.trim();
        let found = if stripped.is_empty() {
            None
        } else {
            declaration().captures(&body)
        };
        let keyword_here: Option<String> = if let Some(found) = found.as_ref() {
            let keyword = found.name("keyword").map_or("", |at| at.as_str()).to_owned();
            let prefix = found.name("prefix").map_or("", |at| at.as_str());
            let declarable = TYPE_KEYWORDS.contains(&keyword.as_str())
                || keyword == "extension"
                || MEMBER_KEYWORDS.contains(&keyword.as_str());
            if declarable && !access_in_prefix().is_match(prefix) && annotates(&keyword, &body, &scopes) {
                let indent = found.name("indent").map_or("", |at| at.as_str());
                let rest = line.get(indent.len()..).unwrap_or(line);
                out.push_str(indent);
                out.push_str("package ");
                out.push_str(rest);
                raised += 1;
            } else {
                out.push_str(line);
            }
            if TYPE_KEYWORDS.contains(&keyword.as_str()) || keyword == "extension" {
                pending = Some(classify(&keyword));
                pending_hoisted = keyword == "extension" && hoisting_prefix().is_match(prefix);
            } else if MEMBER_KEYWORDS.contains(&keyword.as_str())
                || STATEMENT_KEYWORDS.contains(&keyword.as_str())
            {
                pending = Some(Kind::Opaque);
            }
            Some(keyword)
        } else {
            out.push_str(line);
            None
        };

        for here in body.chars() {
            if here == '{' {
                scopes.push(Scope {
                    kind: pending.unwrap_or(Kind::Opaque),
                    hoisted: pending_hoisted,
                });
                pending = None;
                pending_hoisted = false;
            } else if here == '}' && scopes.len() > 1 {
                scopes.pop();
            }
        }
        // A declaration whose brace lands on a later line keeps its kind pending; any other
        // statement clears it so a stray `{` does not inherit a type scope.
        let opens_a_type = keyword_here
            .as_deref()
            .is_some_and(|keyword| TYPE_KEYWORDS.contains(&keyword) || keyword == "extension");
        if !body.contains('{') && !stripped.is_empty() && !opens_a_type {
            pending = None;
            pending_hoisted = false;
        }
    }
    (out, raised)
}

/// A raised `rawValue` and the type it holds.
fn rawvalue() -> &'static Regex {
    static HELD: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?m)^(?P<indent>[ \t]*)package let rawValue: (?P<type>[A-Za-z_][A-Za-z0-9_.<>, ]*)[ \t]*$",
        )
        .expect("the rawValue pattern is a literal in this file")
    });
    &HELD
}

/// A raised struct head that conforms to one of the two protocols with a synthesised initializer.
fn optionset_head() -> &'static Regex {
    static HELD: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"(?m)^[ \t]*package (?:final )?struct [A-Za-z_][A-Za-z0-9_]*[^\n{]*:\s*[^\n{]*\b(?:OptionSet|RawRepresentable)\b",
        )
        .expect("the OptionSet head pattern is a literal in this file")
    });
    &HELD
}

/// How far past a stored property to look for an initializer that is already written out.
const SCOPE_WINDOW: usize = 4000;

/// Write out the `init(rawValue:)` a raised `OptionSet`/`RawRepresentable` now needs.
///
/// `struct S: OptionSet { package let rawValue: T }` compiles while `S` is internal — Swift
/// synthesises the memberwise `init(rawValue:)` at the struct's own access level. Raise the struct
/// to `package` and that synthesised initializer is suddenly less accessible than the protocol
/// requirement it satisfies, which is an error rather than a warning. Writing it out is the whole
/// fix.
#[must_use]
pub fn add_rawvalue_inits(text: &str) -> (String, usize) {
    let mut added = 0;
    let mut out = text.to_owned();
    // Back to front, so every insertion lands after the region the next match is measured in.
    let matches: Vec<(usize, usize, String, String)> = rawvalue()
        .captures_iter(text)
        .filter_map(|found| {
            let whole = found.get(0)?;
            Some((
                whole.start(),
                whole.end(),
                found.name("indent")?.as_str().to_owned(),
                found.name("type")?.as_str().to_owned(),
            ))
        })
        .collect();
    for (start, end, indent, held) in matches.into_iter().rev() {
        // Find the declaration this stored property belongs to, and require it to be one of the
        // two protocols whose requirement the synthesised initializer satisfies.
        let before = out.get(..start).unwrap_or("");
        let Some(head) = optionset_head().find_iter(before).last() else {
            continue;
        };
        let body_end = out.get(head.end()..).and_then(|rest| rest.find("\n}"));
        if body_end.is_some_and(|at| head.end() + at < start) {
            continue; // the property is not inside that struct
        }
        let window = clamp_to_boundary(&out, start + SCOPE_WINDOW);
        if out
            .get(head.end()..window)
            .is_some_and(|scope| scope.contains("init(rawValue"))
        {
            continue;
        }
        let rendered = format!("\n{indent}package init(rawValue: {held}) {{ self.rawValue = rawValue }}");
        out.insert_str(end, &rendered);
        added += 1;
    }
    (out, added)
}

/// The nearest char boundary at or below `at`, so a window never splits a scalar.
fn clamp_to_boundary(text: &str, at: usize) -> usize {
    let mut at = at.min(text.len());
    while at > 0 && !text.is_char_boundary(at) {
        at -= 1;
    }
    at
}

#[cfg(test)]
mod tests {
    use super::{add_rawvalue_inits, strip_noise, transform};

    fn raised(source: &str) -> String {
        transform(source).0
    }

    #[test]
    fn a_file_scope_type_and_its_members_are_raised() {
        let source = "struct Pane {\n    let id: Int\n    func draw() {}\n}\n";
        assert_eq!(
            raised(source),
            "package struct Pane {\n    package let id: Int\n    package func draw() {}\n}\n"
        );
    }

    /// The idempotence the formatter that runs after this tool demands.
    #[test]
    fn a_second_run_changes_nothing() {
        let source = "struct Pane {\n    let id: Int\n}\n";
        let (once, first) = transform(source);
        let (twice, second) = transform(&once);
        assert_eq!(once, twice);
        assert_eq!((first, second), (2, 0));
    }

    /// `SwiftFormat` hoists the members' access onto the extension; re-annotating inside one is a
    /// redundant-modifier warning per line.
    #[test]
    fn a_hoisted_extension_body_is_left_alone() {
        let source = "package extension Pane {\n    func draw() {}\n}\n";
        assert_eq!(raised(source), source);
    }

    #[test]
    fn a_conformance_extension_keeps_its_head_and_raises_its_members() {
        let source = "extension Pane: Equatable {\n    func draw() {}\n}\n";
        assert_eq!(
            raised(source),
            "extension Pane: Equatable {\n    package func draw() {}\n}\n"
        );
    }

    /// A `where` clause is not a conformance, so the extension itself IS raised.
    #[test]
    fn a_constrained_extension_is_raised() {
        let source = "extension Pane where Element: Hashable {\n    func draw() {}\n}\n";
        assert!(raised(source).starts_with("package extension Pane where"));
    }

    #[test]
    fn a_protocol_body_is_never_annotated() {
        let source = "protocol Drawing {\n    func draw()\n    var id: Int { get }\n}\n";
        assert_eq!(
            raised(source),
            "package protocol Drawing {\n    func draw()\n    var id: Int { get }\n}\n"
        );
    }

    #[test]
    fn locals_inside_a_body_are_not_api() {
        let source =
            "struct Pane {\n    func draw() {\n        let scratch = 1\n        if x {\n            let \
             inner = 2\n        }\n    }\n}\n";
        let out = raised(source);
        assert!(!out.contains("package let scratch"), "{out}");
        assert!(!out.contains("package let inner"), "{out}");
        assert_eq!(transform(source).1, 2, "only the struct and the func");
    }

    #[test]
    fn an_existing_modifier_is_a_decision_and_stays() {
        let source = "struct Pane {\n    private let secret: Int\n    public func draw() {}\n}\n";
        let out = raised(source);
        assert!(out.contains("    private let secret"), "{out}");
        assert!(out.contains("    public func draw"), "{out}");
    }

    /// `private(set)` leaves an INTERNAL getter behind, so the declaration still needs raising.
    #[test]
    fn a_private_set_declaration_is_still_raised() {
        let source = "struct Pane {\n    private(set) var id: Int\n}\n";
        assert!(raised(source).contains("    package private(set) var id"));
    }

    #[test]
    fn an_enum_case_takes_the_enums_access() {
        let source = "enum Side {\n    case left\n    case right\n}\n";
        assert_eq!(
            raised(source),
            "package enum Side {\n    case left\n    case right\n}\n"
        );
    }

    #[test]
    fn an_attribute_does_not_hide_the_keyword() {
        let source = "struct Pane {\n    @MainActor func draw() {}\n}\n";
        assert!(raised(source).contains("    package @MainActor func draw"));
    }

    /// A brace inside a string literal must not push a scope.
    #[test]
    fn a_brace_in_a_literal_is_not_a_scope() {
        let source = "struct Pane {\n    let glyph = \"{\"\n    let id: Int\n}\n";
        let out = raised(source);
        assert!(out.contains("    package let id: Int"), "{out}");
    }

    #[test]
    fn a_raised_optionset_gets_its_initializer_written_out() {
        let source = "package struct Marks: OptionSet {\n    package let rawValue: UInt8\n}\n";
        let (out, added) = add_rawvalue_inits(source);
        assert_eq!(added, 1);
        assert!(
            out.contains("package init(rawValue: UInt8) { self.rawValue = rawValue }"),
            "{out}"
        );

        // Idempotent: an initializer already in the body is not written twice.
        assert_eq!(add_rawvalue_inits(&out).1, 0);
    }

    /// A plain struct's `rawValue` has no protocol requirement to satisfy, so nothing is added.
    #[test]
    fn a_rawvalue_outside_the_two_protocols_is_left_alone() {
        let source = "package struct Tag {\n    package let rawValue: UInt8\n}\n";
        assert_eq!(add_rawvalue_inits(source).1, 0);
    }

    #[test]
    fn noise_stripping_keeps_the_code_and_drops_the_rest() {
        assert_eq!(strip_noise("let a = 1 // trailing {\n"), "let a = 1 ");
        assert_eq!(strip_noise("let a = \"}\" /* {\n"), "let a =  ");
        assert_eq!(strip_noise("let a = \"\\\"{\"\n"), "let a = \n");
    }
}
