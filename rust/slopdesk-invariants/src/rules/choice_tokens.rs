//! A choice's stops are the TABLE's, and the Swift enum that reads one may not spell a stop of its
//! own.
//!
//! `AppConfig.choice(_:_:)` is `texts[path].flatMap(T.init(rawValue:)) ?? fallback`. The table
//! already carries every path's default, so the fallback fires only for a token no case spells —
//! which makes the fallback dead, and makes the table the single spelling. That argument holds only
//! while every token the table ACCEPTS has a case to land on. A token that does not is worse than a
//! missing setting: the schema validates the user's `config.toml`, the value reaches an enum with
//! no case for it, and the repair-to-default initialiser most of these carry answers the default
//! with no diagnostic anywhere. The setting is simply unreachable, and nothing says so.
//!
//! ## What this caught on its first run
//!
//! `shell.close-confirm-window`. The table said `multiple-tabs` and the enum said `multiple_tabs` —
//! the underscore is the spelling already in users' `UserDefaults`, which docs/56 records as
//! deliberate for exactly two tokens. So `multiple-tabs` passed the schema and repaired to
//! `process`, and `multiple_tabs` failed the schema. The one stop the setting exists for could not
//! be reached by either spelling.
//!
//! ## The three shapes an `options:` comes in
//!
//! A literal array is read as itself. A named `const` in the same file is resolved and read as
//! itself. And a list whose elements are CALLS — `ClipboardAccess::Ask.token()` — or paths into the
//! crate is CRATE-OWNED and skipped, with no violation and no exemption list: those Swift enums
//! have no `String` raw type at all, their `rawValue` reads the same crate table through a door,
//! and there is no second spelling for this rule to compare. Skipping them is the rule's own
//! conclusion rather than a hole in it.
//!
//! docs/58 — "The one duplication still standing, and the rule that would end it".

use std::collections::{BTreeMap, BTreeSet};

use crate::report::Report;
use crate::text::{cached, capture_all};
use crate::tree::Tree;

const TABLE: &str = "rust/slopdesk-settings/src/config/table.rs";

/// A `Kind::Choice` whose stops this rule can read, or the fact that it cannot.
enum Options {
    /// The tokens, spelled in the table as string literals.
    Tokens(BTreeSet<String>),
    /// The list is built out of the crate's own `token()` calls or constants, so the Swift side
    /// reads it through a door and has no spelling to disagree with.
    CrateOwned,
}

/// Every `Kind::Choice` path in the table, with the stops it accepts.
///
/// Read off the file's CODE view: the header above `CLOSE_CONFIRMATION` quotes the very tokens it
/// declares, and a rule that read prose would pin the paragraph rather than the table.
fn table_options(source: &str) -> BTreeMap<String, Options> {
    let consts: BTreeMap<String, Options> = cached(r"(?s)const (\w+): &\[&str\] = &\[(.*?)\];")
        .captures_iter(source)
        .filter_map(|caps| Some((caps.get(1)?.as_str().to_owned(), read_list(caps.get(2)?.as_str()))))
        .collect();

    cached(r#"(?s)path: "([^"]+)",\s*kind: Kind::Choice \{(.*?)\n *\},"#)
        .captures_iter(source)
        .filter_map(|caps| {
            let path = caps.get(1)?.as_str().to_owned();
            let body = caps.get(2)?.as_str();
            let options = cached(r"(?s)options: (?:&\[(.*?)\]|(\w+))").captures(body)?;
            let stops = match (options.get(1), options.get(2)) {
                (Some(literal), _) => read_list(literal.as_str()),
                // A bare name: the same file's `const`, or something this rule cannot see — which
                // is the crate's business either way, not a second spelling.
                (_, Some(name)) => {
                    match consts.get(name.as_str()) {
                        Some(Options::Tokens(tokens)) => Options::Tokens(tokens.clone()),
                        _ => Options::CrateOwned,
                    }
                },
                _ => return None,
            };
            Some((path, stops))
        })
        .collect()
}

/// One `&[…]` body as stops, or as crate-owned when any element is not a string literal.
fn read_list(body: &str) -> Options {
    let tokens: BTreeSet<String> = capture_all(body, r#""([^"]*)""#).into_iter().collect();
    // Count the ELEMENTS, not the literals: `&[A::B.token(), "x"]` has one of each, and a rule that
    // compared only the literal would pin half a list and call it whole.
    let elements = body.split(',').filter(|part| !part.trim().is_empty()).count();
    if tokens.is_empty() || tokens.len() != elements {
        return Options::CrateOwned;
    }
    Options::Tokens(tokens)
}

/// The raw values of `enum <name>: String`'s cases, or `None` when this tree holds no such
/// declaration — which is every enum whose `rawValue` is computed off a crate table.
///
/// A case's raw value is its explicit `= "…"` when it has one and its NAME otherwise, which is
/// Swift's own rule. The backticks around a keyword case are part of the spelling and not of the
/// value: `` case `default` `` is the token `default`.
fn swift_cases(tree: &Tree, name: &str) -> Option<BTreeSet<String>> {
    let opener = format!(r"(?s)\benum {name}\s*:\s*String\b.*?\{{(.*?)\n(?:    )?\}}");
    for (_, source) in tree.under("Sources") {
        let Some(body) = cached(&opener)
            .captures(source.statements())
            .and_then(|caps| caps.get(1))
        else {
            continue;
        };
        return Some(
            cached(r"(?m)^\s*case `?(\w+)`?(?:\s*=\s*\x22([^\x22]*)\x22)?\s*$")
                .captures_iter(body.as_str())
                .map(|caps| {
                    // The explicit raw value when there is one, the case's own name otherwise —
                    // Swift's own rule for a `String`-raw enum.
                    let explicit = caps.get(2).map(|m| m.as_str().to_owned());
                    explicit
                        .unwrap_or_else(|| caps.get(1).map_or_else(String::new, |m| m.as_str().to_owned()))
                })
                .filter(|token| !token.is_empty())
                .collect(),
        );
    }
    None
}

/// A `config.choice("path", Enum.case)` call site, as the three names it joins.
struct CallSite {
    path: String,
    enum_name: String,
    fallback: String,
}

/// Every choice call site in the tree, in path order.
fn call_sites(tree: &Tree) -> Vec<CallSite> {
    let mut sites: Vec<CallSite> = tree
        .under("Sources")
        .flat_map(|(_, source)| {
            cached(r#"\.choice\("([a-z0-9.-]+)",\s*([A-Za-z_]\w*)\.(\w+)"#)
                .captures_iter(source.statements())
                .filter_map(|caps| {
                    Some(CallSite {
                        path: caps.get(1)?.as_str().to_owned(),
                        enum_name: caps.get(2)?.as_str().to_owned(),
                        fallback: caps.get(3)?.as_str().to_owned(),
                    })
                })
                .collect::<Vec<_>>()
        })
        .collect();
    sites.sort_by(|a, b| (&a.path, &a.enum_name).cmp(&(&b.path, &b.enum_name)));
    sites.dedup_by(|a, b| a.path == b.path && a.enum_name == b.enum_name);
    sites
}

/// Every table stop is spelled by a case of the enum that reads it.
///
/// Also checks that a call site names a path the table actually has, and that its fallback is one
/// of that path's stops. Neither is the load-bearing claim — the first is a typo and the second is
/// a fallback that would be a second default if it were ever reachable — but both are free once the
/// join is built, and a rule that has the answer and does not say it is a rule read twice.
#[must_use]
pub fn a_choice_enum_spells_exactly_the_tables_stops(tree: &Tree) -> Report {
    let mut report = Report::new();
    let Some(table) = tree.get(TABLE) else {
        report.fail(format!(
            "{TABLE} is gone — the choice table is where every setting's stops are spelled (docs/58)",
        ));
        return report;
    };
    let options = table_options(table.statements());
    report.fail_if(
        options.is_empty(),
        format!(
            "{TABLE} yielded no Kind::Choice entries — this rule's extraction has gone stale and is \
             comparing nothing (docs/58, 'The one duplication still standing')",
        ),
    );

    let sites = call_sites(tree);
    report.fail_if(
        sites.is_empty(),
        "no AppConfig.choice call site was found — this rule's extraction has gone stale and is comparing \
         nothing (docs/58, 'The one duplication still standing')",
    );

    // Both halves reading is not the same as the JOIN landing, and the join is what this rule is.
    // Every path could resolve to `CrateOwned`, every enum could stop being `: String`, and the two
    // emptiness checks above would still pass while nothing at all was compared. So the pairs that
    // reach the comparison are counted, and a run that compares none says so.
    let mut compared = 0_usize;
    let live = tree.has(TABLE) && tree.has("Sources/SlopDeskVideoProtocol/Settings/AppConfig.swift");

    for site in sites {
        let CallSite {
            path,
            enum_name,
            fallback,
        } = site;
        let Some(stops) = options.get(&path) else {
            report.fail(format!(
                "AppConfig.choice(\"{path}\", …) names a path the key table has no Kind::Choice for — a \
                 setting read through a path nothing declares is answered by its fallback forever (docs/58)",
            ));
            continue;
        };
        let Options::Tokens(stops) = stops else { continue };
        // No `String` raw type: the enum's `rawValue` is a crate table read through a door, so
        // there is nothing here spelled twice. The same conclusion `Options::CrateOwned`
        // reaches, from the other side.
        let Some(cases) = swift_cases(tree, &enum_name) else {
            continue;
        };
        compared += 1;
        report.fail_if(
            cases.is_empty(),
            format!(
                "{enum_name} is declared `: String` but this rule read no cases from it — the extraction \
                 has gone stale and \"{path}\" is now unpinned (docs/58)",
            ),
        );

        let unspellable: Vec<&str> = stops
            .iter()
            .filter(|stop| !cases.contains(*stop))
            .map(String::as_str)
            .collect();
        report.fail_if(
            !unspellable.is_empty(),
            format!(
                "\"{path}\" accepts {} but {enum_name} has no case spelling it — the schema validates that \
                 value and the enum then repairs it to a default, so the stop is unreachable and nothing \
                 says so (docs/58, 'The one duplication still standing')",
                unspellable.join(", "),
            ),
        );

        // The fallback's own token. Swift lower-cases nothing for us, so the case NAME is looked up
        // among the cases by name first — an explicit raw value means the name is not the token.
        let fallback_token = fallback_token(tree, &enum_name, &fallback);
        report.fail_if(
            fallback_token.is_some_and(|token| !stops.contains(&token)),
            format!(
                "AppConfig.choice(\"{path}\", {enum_name}.{fallback}) falls back to a token the table does \
                 not offer — a fallback outside the stops is a second default whatever it spells (docs/58)",
            ),
        );
    }

    report.fail_if(
        live && compared == 0,
        "every choice path resolved to a crate-owned list or a non-String enum, so this rule compared \
         nothing — the join it exists to make has gone stale (docs/58)",
    );
    report
}

/// The raw value of one named case, or `None` when this rule cannot find it.
fn fallback_token(tree: &Tree, enum_name: &str, case: &str) -> Option<String> {
    let opener = format!(r"(?s)\benum {enum_name}\s*:\s*String\b.*?\{{(.*?)\n(?:    )?\}}");
    for (_, source) in tree.under("Sources") {
        let Some(body) = cached(&opener)
            .captures(source.statements())
            .and_then(|caps| caps.get(1))
        else {
            continue;
        };
        let pattern = format!(r"(?m)^\s*case `?{case}`?(?:\s*=\s*\x22([^\x22]*)\x22)?\s*$");
        let caps = cached(&pattern).captures(body.as_str())?;
        return Some(
            caps.get(1)
                .map_or_else(|| case.to_owned(), |m| m.as_str().to_owned()),
        );
    }
    None
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A table with one literal choice, one crate-owned one, and the Swift that reads both.
    fn seeded(fixture: &Fixture) {
        fixture
            .write(
                super::TABLE,
                concat!(
                    "const CLOSE_CONFIRMATION: &[&str] = &[\"process\", \"always\", \"multiple_tabs\"];\n",
                    "const CLIPBOARD: &[&str] = &[\n",
                    "    ClipboardAccess::Ask.token(),\n",
                    "    ClipboardAccess::Allow.token(),\n",
                    "];\n",
                    "pub const KEYS: &[Key] = &[\n",
                    "    Key {\n",
                    "        path: \"shell.close-confirm-window\",\n",
                    "        kind: Kind::Choice {\n",
                    "            default: Some(\"process\"),\n",
                    "            options: CLOSE_CONFIRMATION,\n",
                    "        },\n",
                    "        doc: \"When to confirm before closing a window.\",\n",
                    "    },\n",
                    "    Key {\n",
                    "        path: \"controls.clipboard-read\",\n",
                    "        kind: Kind::Choice {\n",
                    "            default: Some(\"ask\"),\n",
                    "            options: CLIPBOARD,\n",
                    "        },\n",
                    "        doc: \"What the terminal may read.\",\n",
                    "    },\n",
                    "];\n",
                ),
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/CloseConfirmationPolicy.swift",
                concat!(
                    "public enum CloseConfirmationPolicy: String, Codable, CaseIterable {\n",
                    "    case process\n",
                    "    case always\n",
                    "    case multipleTabs = \"multiple_tabs\"\n",
                    "}\n",
                ),
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/ClipboardAccess.swift",
                concat!(
                    "public enum ClipboardAccess: Sendable, CaseIterable, RawRepresentable {\n",
                    "    case allow\n",
                    "    case ask\n",
                    "    public var rawValue: String { ControlTokens.clipboard[index] }\n",
                    "}\n",
                ),
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/SettingsKey.swift",
                concat!(
                    "    AppConfig.current.choice(\"shell.close-confirm-window\", \
                     CloseConfirmationPolicy.process)\n",
                    "    AppConfig.current.choice(\"controls.clipboard-read\", ClipboardAccess.ask)\n",
                ),
            );
    }

    #[test]
    fn a_table_stop_with_no_case_to_land_on_is_a_setting_nobody_can_reach() {
        let fixture = Fixture::new("choice-tokens");
        seeded(&fixture);
        assert!(super::a_choice_enum_spells_exactly_the_tables_stops(&fixture.tree()).is_clean());

        // The drift this rule was written for, in the direction it actually happened: the table
        // hyphenated a token the enum spells with an underscore. Both sides still look right on
        // their own, and the stop is simply unreachable.
        let hyphenated = fixture
            .tree()
            .get(super::TABLE)
            .map(|source| source.text.replace("multiple_tabs", "multiple-tabs"))
            .unwrap_or_default();
        fixture.write(super::TABLE, &hyphenated);
        assert!(!super::a_choice_enum_spells_exactly_the_tables_stops(&fixture.tree()).is_clean());
    }

    /// The tab row's stops are the window row's FIRST TWO — closing one tab can never lose more
    /// than one — so the same enum reads two paths whose sets differ. A case the tab row does
    /// not offer is fine to HAVE (the window row offers it); it is only a fault as that row's
    /// FALLBACK.
    #[test]
    fn a_fallback_outside_the_stops_is_a_second_default() {
        let fixture = Fixture::new("choice-fallback");
        seeded(&fixture);
        fixture
            .append(
                super::TABLE,
                "const CLOSE_CONFIRMATION_TAB: &[&str] = &[\"process\", \"always\"];\n",
            )
            .append(
                "Sources/SlopDeskWorkspaceCore/SettingsKey.swift",
                "    AppConfig.current.choice(\"shell.close-confirm-tab\", \
                 CloseConfirmationPolicy.process)\n",
            );
        let tab_row = "    Key {\n        path: \"shell.close-confirm-tab\",\n        kind: Kind::Choice \
                       {\n            default: Some(\"process\"),\n            options: \
                       CLOSE_CONFIRMATION_TAB,\n        },\n        doc: \"When to confirm before closing a \
                       tab.\",\n    },\n";
        let with_tab = fixture
            .tree()
            .get(super::TABLE)
            .map(|source| {
                source.text.replace(
                    "pub const KEYS: &[Key] = &[\n",
                    &format!("pub const KEYS: &[Key] = &[\n{tab_row}"),
                )
            })
            .unwrap_or_default();
        fixture.write(super::TABLE, &with_tab);
        assert!(super::a_choice_enum_spells_exactly_the_tables_stops(&fixture.tree()).is_clean());

        // The same enum, the same case — and on THIS path a stop the table never offers.
        let swift = fixture
            .tree()
            .get("Sources/SlopDeskWorkspaceCore/SettingsKey.swift")
            .map(|source| {
                source.text.replace(
                    "\"shell.close-confirm-tab\", CloseConfirmationPolicy.process",
                    "\"shell.close-confirm-tab\", CloseConfirmationPolicy.multipleTabs",
                )
            })
            .unwrap_or_default();
        fixture.write("Sources/SlopDeskWorkspaceCore/SettingsKey.swift", &swift);
        assert!(!super::a_choice_enum_spells_exactly_the_tables_stops(&fixture.tree()).is_clean());
    }

    /// The crate-owned half is skipped by CONCLUSION, not by exemption — an enum with no `String`
    /// raw type has no second spelling, so a table built from `token()` calls is not a drift.
    #[test]
    fn a_crate_owned_list_is_not_compared_against_a_computed_raw_value() {
        let fixture = Fixture::new("choice-crate-owned");
        seeded(&fixture);
        // `deny` exists in the crate's table and not in this fixture's Swift enum. If this rule
        // compared them it would fire; it does not, because neither side spells a token here.
        let renamed = fixture
            .tree()
            .get(super::TABLE)
            .map(|source| {
                source.text.replace(
                    "    ClipboardAccess::Allow.token(),\n",
                    "    ClipboardAccess::Deny.token(),\n",
                )
            })
            .unwrap_or_default();
        fixture.write(super::TABLE, &renamed);
        assert!(super::a_choice_enum_spells_exactly_the_tables_stops(&fixture.tree()).is_clean());
    }

    /// The join lands on the REAL tree, and lands on the path the drift was found in.
    ///
    /// A fixture proves the rule CAN fire; only the live tree proves it is pointed at anything.
    /// Both halves are regex extractions over source that is edited daily, and the failure they
    /// share is going quiet: a reformatted table, a renamed call, a `String` raw type traded
    /// for a computed one, and the rule keeps passing while comparing nothing.
    #[test]
    fn the_real_table_and_the_real_call_sites_still_join() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(std::path::Path::parent)
            .expect("repository root is two levels above this crate")
            .to_path_buf();
        let tree = crate::Tree::load(&root).expect("load the repository");

        let table = tree.get(super::TABLE).expect("the key table");
        let options = super::table_options(table.statements());
        let literal = options
            .values()
            .filter(|stops| matches!(stops, super::Options::Tokens(_)))
            .count();
        assert!(literal >= 10, "only {literal} choice paths read as literal stops");

        // A LIVENESS floor for the scanner, not a contract about how many choice rows exist: it
        // catches a parser that stopped matching, which would otherwise pass this test by finding
        // nothing. It moves down when rows are legitimately deleted — four went with the terminal
        // config text on 2026-09-01 (`ligatures`, `bold`, `italic`, `blending`).
        let sites = super::call_sites(&tree);
        assert!(sites.len() >= 18, "only {} choice call sites found", sites.len());

        // The path the drift was found in, spelled the way it is on disk.
        let Some(super::Options::Tokens(stops)) = options.get("shell.close-confirm-window") else {
            panic!("the window close-confirm stops stopped reading as literals");
        };
        assert!(stops.contains("multiple_tabs"), "{stops:?}");
        let cases = super::swift_cases(&tree, "CloseConfirmationPolicy").expect("the Swift enum");
        assert!(cases.contains("multiple_tabs"), "{cases:?}");
    }

    /// The extraction going stale is the failure this crate's `same` exists to prevent, and this
    /// rule's join has two halves that can each go quiet on their own.
    #[test]
    fn an_extraction_that_stopped_reading_anything_fails_loudly() {
        let fixture = Fixture::new("choice-stale");
        seeded(&fixture);
        fixture.write(super::TABLE, "pub const KEYS: &[Key] = &[];\n");
        assert!(!super::a_choice_enum_spells_exactly_the_tables_stops(&fixture.tree()).is_clean());

        let bare = Fixture::new("choice-no-table");
        bare.write("Sources/SlopDeskWorkspaceCore/Anything.swift", "let x = 1\n");
        assert!(!super::a_choice_enum_spells_exactly_the_tables_stops(&bare.tree()).is_clean());
    }
}
