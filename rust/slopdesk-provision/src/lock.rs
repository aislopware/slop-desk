//! The pin file, parsed.
//!
//! `tools.lock` is six `|`-separated fields per record, and the shell that used to read it was one
//! `IFS='|' read -r name version kind binary url sha` loop. That loop cannot fail: a line with five
//! fields silently leaves `sha` empty, a line with seven silently packs the tail into it, and both
//! reach the digest check as a mismatch against a URL — which reads as a corrupt download and is
//! not one. A parser that names the line and the field is the whole reason this module exists.

use core::fmt;

/// How a pinned dependency arrives.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// A gzipped tarball with exactly one top-level directory, which is stripped.
    TarGz,
    /// A zip archive with exactly one top-level directory, which is stripped.
    Zip,
    /// Committed under `vendor/` and never downloaded — verified against the pin in place.
    File,
}

impl Kind {
    /// The spelling this kind carries in the lock file.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::TarGz => "tar.gz",
            Self::Zip => "zip",
            Self::File => "file",
        }
    }

    /// The inverse, over the three spellings the lock file may use.
    fn parse(field: &str) -> Option<Self> {
        match field {
            "tar.gz" => Some(Self::TarGz),
            "zip" => Some(Self::Zip),
            "file" => Some(Self::File),
            _ => None,
        }
    }
}

/// One pinned dependency.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pin {
    /// The provisioned command; becomes `.prefix/bin/<name>`, and is what a locator searches for.
    pub name: String,
    /// The upstream release, and the directory under `.prefix/<name>/` — so two versions sit side
    /// by side and a rollback is a relink rather than a re-download.
    pub version: String,
    /// How it arrives.
    pub kind: Kind,
    /// The executable's path INSIDE the extracted tree, after the single top-level directory is
    /// stripped. For [`Kind::File`], the path under `vendor/`.
    pub binary: String,
    /// The exact release asset. Never a `latest` alias.
    pub url: String,
    /// The SHA-256, lowercase hex, verified on every provision.
    pub sha256: String,
}

/// Why a lock file could not be read, with the line that did it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    /// The 1-based line number, so the message points at something a reader can open.
    pub line: usize,
    /// What was wrong with it.
    pub reason: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(out, "tools.lock line {}: {}", self.line, self.reason)
    }
}

impl std::error::Error for ParseError {}

/// The number of `|`-separated fields a record carries.
const FIELDS: usize = 6;

/// A SHA-256 in lowercase hex.
const DIGEST_HEX_LEN: usize = 64;

/// Parses every record in `text`, in file order.
///
/// Blank lines and `#`-leading lines are comments and are skipped — the lock file's prose is most of
/// its bytes, and the reason each pin is what it is lives there rather than in a changelog.
///
/// # Errors
/// Returns the first malformed record, naming its line and what was wrong with it. Deliberately
/// fail-fast rather than accumulating: a lock file with one bad line is a lock file nobody has run,
/// and provisioning half of it is worse than provisioning none.
pub fn parse(text: &str) -> Result<Vec<Pin>, ParseError> {
    let mut pins = Vec::new();
    for (index, raw) in text.lines().enumerate() {
        let line = index + 1;
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        pins.push(parse_record(trimmed, line)?);
    }
    Ok(pins)
}

/// One non-comment line.
fn parse_record(line_text: &str, line: usize) -> Result<Pin, ParseError> {
    let fault = |reason: String| ParseError { line, reason };
    let fields: Vec<&str> = line_text.split('|').map(str::trim).collect();
    if fields.len() != FIELDS {
        return Err(fault(format!(
            "expected {FIELDS} `|`-separated fields (name|version|kind|binary|url|sha256), got {}",
            fields.len()
        )));
    }
    // Indexed reads are what `indexing_slicing` bars, and the length check above is exactly the
    // proof it wants stated — so read through `get` and let a `None` be the same fault as a short
    // line rather than restating the invariant as a panic.
    let field = |at: usize| -> Result<&str, ParseError> {
        fields
            .get(at)
            .copied()
            .ok_or_else(|| fault(format!("field {at} is missing")))
    };
    let name = field(0)?;
    let version = field(1)?;
    let kind_text = field(2)?;
    let binary = field(3)?;
    let url = field(4)?;
    let sha256 = field(5)?;

    for (label, value) in [
        ("name", name),
        ("version", version),
        ("binary", binary),
        ("url", url),
    ] {
        if value.is_empty() {
            return Err(fault(format!("`{label}` is empty")));
        }
    }
    let kind = Kind::parse(kind_text).ok_or_else(|| {
        fault(format!(
            "unknown kind `{kind_text}` — expected tar.gz, zip or file"
        ))
    })?;
    if sha256.len() != DIGEST_HEX_LEN || !sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(fault(format!(
            "`sha256` is not {DIGEST_HEX_LEN} hex digits: `{sha256}`"
        )));
    }
    Ok(Pin {
        name: name.to_owned(),
        version: version.to_owned(),
        kind,
        binary: binary.to_owned(),
        url: url.to_owned(),
        // Lowercased so a pin typed in upper hex compares equal to a computed digest, which is
        // always lowercase. The file is the human's, the comparison is not.
        sha256: sha256.to_ascii_lowercase(),
    })
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::panic,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{Kind, parse};

    const ONE: &str = "adb|37.0.1|zip|adb|https://example.invalid/p.zip|\
                       ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d";

    #[test]
    fn a_record_parses_into_its_six_fields() {
        let pins = parse(ONE).unwrap_or_default();
        let pin = pins.first().expect("one record");
        assert_eq!(pin.name, "adb");
        assert_eq!(pin.version, "37.0.1");
        assert_eq!(pin.kind, Kind::Zip);
        assert_eq!(pin.binary, "adb");
        assert_eq!(pin.url, "https://example.invalid/p.zip");
        assert_eq!(pin.sha256.len(), 64);
    }

    #[test]
    fn comments_and_blank_lines_are_not_records() {
        let text = format!("# a note\n\n   \n{ONE}\n# trailing\n");
        assert_eq!(parse(&text).unwrap_or_default().len(), 1);
    }

    #[test]
    fn an_empty_lock_holds_no_pins() {
        assert!(parse("").unwrap_or_default().is_empty());
        assert!(parse("# nothing but prose\n").unwrap_or_default().is_empty());
    }

    /// The shape the shell could not report: a short line silently emptied `sha`, and a long one
    /// silently packed the tail into it. Both now name the line.
    #[test]
    fn a_wrong_field_count_names_the_line() {
        let text = format!("{ONE}\nadb|37.0.1|zip|adb|https://example.invalid/p.zip\n");
        let error = parse(&text).expect_err("the short line fails");
        assert_eq!(error.line, 2);
        assert!(error.reason.contains("got 5"), "{}", error.reason);

        let long = format!("{ONE}|extra");
        let error = parse(&long).expect_err("the long line fails");
        assert!(error.reason.contains("got 7"), "{}", error.reason);
    }

    #[test]
    fn an_unknown_kind_names_the_three_that_are_known() {
        let text = ONE.replace("|zip|", "|tar.bz2|");
        let error = parse(&text).expect_err("the kind fails");
        assert!(error.reason.contains("tar.gz, zip or file"), "{}", error.reason);
    }

    #[test]
    fn a_digest_that_is_not_sixty_four_hex_digits_is_refused() {
        for bad in ["", "abc", &"z".repeat(64), &"a".repeat(63), &"a".repeat(65)] {
            let text = format!(
                "adb|37.0.1|zip|adb|https://example.invalid/p.zip|{bad}"
            );
            assert!(parse(&text).is_err(), "{bad:?} must not parse");
        }
    }

    /// A digest is compared, not read — a pin typed in upper hex names the same bytes. The KIND is
    /// not given the same latitude: it is a keyword with three spellings, and accepting `ZIP` would
    /// be inventing a fourth.
    #[test]
    fn an_upper_case_digest_compares_against_a_lower_case_one() {
        let lower = ONE.rsplit('|').next().expect("the digest field").to_owned();
        let text = ONE.replace(&lower, &lower.to_ascii_uppercase());
        let pins = parse(&text).unwrap_or_default();
        let pin = pins.first().expect("one record");
        assert_eq!(pin.sha256, lower, "stored lowercase whatever the file said");

        let shouty = ONE.replace("|zip|", "|ZIP|");
        assert!(parse(&shouty).is_err(), "a kind is a keyword, not free text");
    }

    #[test]
    fn an_empty_required_field_names_itself() {
        let text = ONE.replacen("adb|", "|", 1);
        let error = parse(&text).expect_err("the empty name fails");
        assert!(error.reason.contains("`name` is empty"), "{}", error.reason);
    }

    #[test]
    fn surrounding_whitespace_is_not_part_of_a_field() {
        let text = ONE.replace('|', " | ");
        let pins = parse(&text).unwrap_or_default();
        assert_eq!(pins.first().map(|pin| pin.name.as_str()), Some("adb"));
    }

    /// The repository's own lock file must parse — the one test that fails when a pin is edited
    /// into a shape the reader cannot take.
    #[test]
    fn the_repositorys_own_lock_parses() {
        let text = include_str!("../../../ThirdParty/tools/tools.lock");
        let pins = parse(text).unwrap_or_else(|error| panic!("{error}"));
        assert!(pins.len() >= 4, "the four panel dependencies are pinned");
        assert!(pins.iter().any(|pin| pin.name == "code-server"));
        assert!(pins.iter().any(|pin| pin.kind == Kind::File));
    }
}
