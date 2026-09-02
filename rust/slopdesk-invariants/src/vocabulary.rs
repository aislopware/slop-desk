//! A `NAME = NUMBER` table spelled in both languages, compared as a set.
//!
//! This is the commonest cross-language shape in the whole gate and the one with the quietest
//! failure: nothing DECODES through these constants. Every value is length-prefixed and an unknown
//! byte is kept verbatim, so a number invented independently on the two ends decodes perfectly
//! cleanly into the WRONG MEANING — a client asking for a rename and a host performing a close, or
//! a field that renders as a plausible value it never held. There is no decoder anywhere that would
//! notice, which is why the comparison lives in a gate.
//!
//! It is a module rather than a [`crate::claim::Claim`] because the two halves need NORMALISING
//! before they can be compared, and normalisation is where the judgement is: the two languages
//! spell the same entry `focusMRU` and `FOCUS_MRU`, and neither spelling is wrong. Upper-casing and
//! dropping the separators is what makes the capitalisation conventions cancel so only the byte is
//! left.

use std::collections::BTreeSet;

use crate::report::Report;
use crate::text;
use crate::tree::Tree;

/// One table, its two spellings, and the floor below which the extraction is assumed stale.
#[derive(Clone, Copy, Debug)]
pub struct Vocabulary {
    /// What the table is called in a diagnostic.
    pub label: &'static str,
    /// The Swift file.
    pub swift: &'static str,
    /// The pattern whose two captures are a Swift entry's name and number.
    pub swift_pattern: &'static str,
    /// The Rust file.
    pub rust: &'static str,
    /// The pattern whose two captures are a Rust entry's name and number.
    pub rust_pattern: &'static str,
    /// How few entries mean the extraction has gone stale rather than the table having shrunk.
    ///
    /// The floor is the only thing standing between this comparison and the healthiest-looking pass
    /// the gate can print: two patterns that both stopped matching agree perfectly.
    pub minimum: usize,
    /// The doc section a reader should open when this fires.
    pub doc: &'static str,
}

/// Compares the two spellings, upper-cased and separator-free, and says which side has the extra.
pub fn agrees(tree: &Tree, report: &mut Report, vocab: &Vocabulary) {
    let (Some(swift_source), Some(rust_source)) = (
        report.source(tree, vocab.swift, "one side of a vocabulary lives there"),
        report.source(tree, vocab.rust, "one side of a vocabulary lives there"),
    ) else {
        return;
    };

    let swift_set = normalise(text::capture_pairs(
        swift_source.statements(),
        vocab.swift_pattern,
    ));
    let rust_set = normalise(text::capture_pairs(rust_source.statements(), vocab.rust_pattern));

    report.fail_if(
        swift_set.len() < vocab.minimum,
        format!(
            "only {} {} found in {} — the extraction in this gate has gone stale",
            swift_set.len(),
            vocab.label,
            vocab.swift,
        ),
    );
    if swift_set != rust_set {
        let only_swift: Vec<_> = swift_set.difference(&rust_set).cloned().collect();
        let only_rust: Vec<_> = rust_set.difference(&swift_set).cloned().collect();
        report.fail(format!(
            "{} and {} disagree about {} — Swift alone has [{}], Rust alone has [{}] ({})",
            vocab.swift,
            vocab.rust,
            vocab.label,
            only_swift.join(" "),
            only_rust.join(" "),
            vocab.doc,
        ));
    }
}

/// `NAME=NUMBER`, upper-cased with separators dropped.
fn normalise(pairs: Vec<(String, String)>) -> BTreeSet<String> {
    pairs
        .into_iter()
        .map(|(name, number)| {
            let name: String = name.chars().filter(|c| *c != '_').collect();
            format!("{}={number}", name.to_uppercase())
        })
        .collect()
}

/// A table whose entries live inside NAMED SECTIONS, compared as `SECTION.NAME=NUMBER`.
///
/// The document field vocabulary is this shape: the same short name (`title`, `kind`) appears in
/// several tables with different numbers, so a flat set would collide entries that are not the same
/// entry, and two tables that swapped a number whole would compare equal.
#[derive(Clone, Copy, Debug)]
pub struct SectionedVocabulary {
    /// What the table is called in a diagnostic.
    pub label: &'static str,
    /// The Swift file.
    pub swift: &'static str,
    /// The pattern whose one capture opens a Swift section.
    pub swift_section: &'static str,
    /// The pattern whose two captures are a Swift entry's name and number.
    pub swift_entry: &'static str,
    /// The Rust file.
    pub rust: &'static str,
    /// The pattern whose one capture opens a Rust section.
    pub rust_section: &'static str,
    /// The pattern whose two captures are a Rust entry's name and number.
    pub rust_entry: &'static str,
    /// How few entries mean the extraction has gone stale.
    pub minimum: usize,
    /// The doc section a reader should open when this fires.
    pub doc: &'static str,
}

/// Compares two sectioned tables, section names and entry names both normalised.
pub fn sections_agree(tree: &Tree, report: &mut Report, vocab: &SectionedVocabulary) {
    let (Some(swift_source), Some(rust_source)) = (
        report.source(tree, vocab.swift, "one side of a vocabulary lives there"),
        report.source(tree, vocab.rust, "one side of a vocabulary lives there"),
    ) else {
        return;
    };

    let swift_set = sectioned(swift_source.statements(), vocab.swift_section, vocab.swift_entry);
    let rust_set = sectioned(rust_source.statements(), vocab.rust_section, vocab.rust_entry);

    report.fail_if(
        swift_set.len() < vocab.minimum,
        format!(
            "only {} {} found in {} — the extraction in this gate has gone stale",
            swift_set.len(),
            vocab.label,
            vocab.swift,
        ),
    );
    report.same_set(vocab.label, &swift_set, &rust_set);
}

/// Walks a file section by section, emitting `SECTION.NAME=NUMBER`.
///
/// A section runs until a line that starts at column zero closes it — `^\}` in both languages —
/// which is the same range awk was walking, kept because it is what both files' formatting
/// guarantees and neither language's parser is worth writing here.
fn sectioned(haystack: &str, section: &str, entry: &str) -> BTreeSet<String> {
    let (section_re, entry_re, close_re) = (text::cached(section), text::cached(entry), text::cached(r"^\}"));
    let mut out = BTreeSet::new();
    let mut current: Option<String> = None;
    for line in haystack.lines() {
        if let Some(caps) = section_re.captures(line) {
            current = caps.get(1).map(|m| strip(m.as_str()));
            continue;
        }
        if close_re.is_match(line) {
            current = None;
            continue;
        }
        let (Some(table), Some(caps)) = (current.as_ref(), entry_re.captures(line)) else {
            continue;
        };
        if let (Some(name), Some(number)) = (caps.get(1), caps.get(2)) {
            out.insert(format!("{table}.{}={}", strip(name.as_str()), number.as_str()));
        }
    }
    out
}

/// Upper-cased, separators dropped — what makes `focusMRU` and `FOCUS_MRU` the same name.
fn strip(name: &str) -> String {
    name.chars()
        .filter(|c| *c != '_')
        .flat_map(char::to_uppercase)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{SectionedVocabulary, Vocabulary, agrees, sections_agree};
    use crate::report::Report;
    use crate::tests::Fixture;

    const FLAT: Vocabulary = Vocabulary {
        label: "verbs",
        swift: "Sources/V.swift",
        swift_pattern: r"case ([a-zA-Z]+) = ([0-9]+)",
        rust: "rust/v/src/lib.rs",
        rust_pattern: r"^\s+([A-Z][A-Za-z]+) = ([0-9]+),",
        minimum: 2,
        doc: "docs/45",
    };

    /// The two capitalisation conventions must cancel, or the gate reports a naming choice as a
    /// drift and gets itself deleted.
    #[test]
    fn the_two_spellings_of_one_name_are_the_same_name() {
        let fixture = Fixture::new("vocab-case");
        fixture
            .write("Sources/V.swift", "case focusMRU = 3\ncase title = 4\n")
            .write(
                "rust/v/src/lib.rs",
                "pub enum V {\n    FocusMru = 3,\n    Title = 4,\n}\n",
            );
        let mut report = Report::new();
        agrees(&fixture.tree(), &mut report, &FLAT);
        assert!(report.is_clean(), "{report:?}");
    }

    /// The floor is the only thing between this and two patterns that both stopped matching.
    #[test]
    fn an_extraction_that_went_stale_says_so_rather_than_agreeing() {
        let fixture = Fixture::new("vocab-stale");
        fixture
            .write("Sources/V.swift", "// the enum was renamed away\nlet x = 1\n")
            .write("rust/v/src/lib.rs", "pub enum V {}\n");
        let mut report = Report::new();
        agrees(&fixture.tree(), &mut report, &FLAT);
        assert!(
            report.violations().iter().any(|v| v.contains("gone stale")),
            "{report:?}"
        );
    }

    /// The reason the sectioned form exists: the same short name in two tables is two entries, and
    /// a flat set would call a swapped pair equal.
    #[test]
    fn the_same_name_in_two_sections_is_two_entries() {
        let fixture = Fixture::new("vocab-sections");
        fixture
            .write(
                "Sources/F.swift",
                "public enum WorkspacePaneField {\n    static let title: UInt8 = 1\n}\npublic enum \
                 WorkspaceTabField {\n    static let title: UInt8 = 2\n}\n",
            )
            .write(
                "rust/f/src/fields.rs",
                "pub mod pane {\n    pub const TITLE: u8 = 1;\n}\npub mod tab {\n    pub const TITLE: u8 = \
                 2;\n}\n",
            );
        let mut report = Report::new();
        sections_agree(&fixture.tree(), &mut report, &SECTIONED);
        assert!(report.is_clean(), "{report:?}");

        // The two tables swap their numbers. A flat set would still hold {TITLE=1, TITLE=2}.
        fixture.write(
            "rust/f/src/fields.rs",
            "pub mod pane {\n    pub const TITLE: u8 = 2;\n}\npub mod tab {\n    pub const TITLE: u8 = \
             1;\n}\n",
        );
        let mut report = Report::new();
        sections_agree(&fixture.tree(), &mut report, &SECTIONED);
        assert!(
            report.violations().iter().any(|v| v.contains("disagrees")),
            "{report:?}"
        );
    }

    /// The revert this guards against is one character wide — `statements()` back to `code()` — and
    /// nothing else in the crate would notice, because both views drop a WHOLE comment line and the
    /// difference is only a trailing one. A retired entry left in prose at the end of a live line
    /// is exactly what a vocabulary must not accept: the far side still spells it, so the two
    /// sets agree over a constant that no longer exists.
    #[test]
    fn a_retired_entry_left_in_a_trailing_comment_does_not_make_the_two_sides_agree() {
        let fixture = Fixture::new("vocab-comment");
        fixture
            .write(
                "Sources/F.swift",
                "public enum WorkspacePaneField {\n    static let title: UInt8 = 1\n}\npublic enum \
                 WorkspaceTabField {\n    static let title: UInt8 = 2\n    static let other: UInt8 = 3\n}\n",
            )
            .write(
                "rust/f/src/fields.rs",
                "pub mod pane {\n    pub const TITLE: u8 = 1;\n}\npub mod tab {\n    pub const OTHER: u8 = \
                 3;  // pub const TITLE: u8 = 2; retired\n}\n",
            );
        let mut report = Report::new();
        sections_agree(&fixture.tree(), &mut report, &SECTIONED);
        assert!(
            report.violations().iter().any(|v| v.contains("disagrees")),
            "{report:?}"
        );

        // And the same tree with the entry actually declared is clean, so the assertion above is
        // reading the comment rather than some other difference between the two files.
        fixture.write(
            "rust/f/src/fields.rs",
            "pub mod pane {\n    pub const TITLE: u8 = 1;\n}\npub mod tab {\n    pub const OTHER: u8 = 3;\n \
             pub const TITLE: u8 = 2;\n}\n",
        );
        let mut report = Report::new();
        sections_agree(&fixture.tree(), &mut report, &SECTIONED);
        assert!(report.is_clean(), "{report:?}");
    }

    const SECTIONED: SectionedVocabulary = SectionedVocabulary {
        label: "document fields",
        swift: "Sources/F.swift",
        swift_section: r"^public enum Workspace([A-Za-z]+)Field \{",
        swift_entry: r"static let ([A-Za-z]+): UInt8 = ([0-9]+)",
        rust: "rust/f/src/fields.rs",
        rust_section: r"^pub mod ([a-z_]+) \{",
        rust_entry: r"pub const ([A-Z_0-9]+): u8 = ([0-9]+);",
        minimum: 2,
        doc: "docs/45 §5.3",
    };
}
