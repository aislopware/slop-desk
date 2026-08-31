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
    /// A SOURCE tree, cloned at a pinned commit. Not a program: nothing is exec'd and no
    /// `.prefix/bin` symlink is minted. It exists because one dependency is consumed as source
    /// rather than as a binary — `libghostty-vt-sys`'s `build.rs` compiles ghostty itself, and the
    /// only way to stop it reaching the network at build time is to hand it a tree that is already
    /// there (`GHOSTTY_SOURCE_DIR`).
    Git,
}

impl Kind {
    /// The spelling this kind carries in the lock file.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::TarGz => "tar.gz",
            Self::Zip => "zip",
            Self::File => "file",
            Self::Git => "git",
        }
    }

    /// The inverse, over the four spellings the lock file may use.
    fn parse(field: &str) -> Option<Self> {
        match field {
            "tar.gz" => Some(Self::TarGz),
            "zip" => Some(Self::Zip),
            "file" => Some(Self::File),
            "git" => Some(Self::Git),
            _ => None,
        }
    }

    /// How long this kind's `digest` field is, in hex digits.
    ///
    /// The two lengths are two different one-way functions, and conflating them is the mistake this
    /// method exists to make impossible: an archive is pinned by the SHA-256 of its bytes, a clone
    /// by the commit it is checked out at. A git commit is CONTENT-ADDRESSED over the whole tree,
    /// which is why a source pin does not also carry a tarball digest — and why it must not be
    /// pinned by one, since GitHub's generated archives are not guaranteed byte-stable.
    #[must_use]
    pub const fn digest_hex_len(self) -> usize {
        match self {
            Self::TarGz | Self::Zip | Self::File => SHA256_HEX_LEN,
            Self::Git => GIT_SHA_HEX_LEN,
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
    /// stripped. For [`Kind::File`], the path under `vendor/`. For [`Kind::Git`] it is not an
    /// executable at all but the SENTINEL the clone is checked for — `build.zig` for a Zig source
    /// tree — which is what turns "the directory exists" into "the tree is the one we wanted".
    pub binary: String,
    /// The exact release asset, or for [`Kind::Git`] the repository to clone. Never a `latest`
    /// alias.
    pub url: String,
    /// Lowercase hex, verified on every provision: the SHA-256 of the archive for the downloadable
    /// kinds, the COMMIT for [`Kind::Git`]. Two different one-way functions over two different
    /// things, which is why the length is [`Kind::digest_hex_len`] rather than a constant, and why
    /// this field is not called `sha256`.
    pub digest: String,
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
const SHA256_HEX_LEN: usize = 64;

/// A git commit SHA in lowercase hex. Never abbreviated: a short SHA is ambiguous by construction,
/// and a pin that can become ambiguous is not a pin.
const GIT_SHA_HEX_LEN: usize = 40;

/// Parses every record in `text`, in file order.
///
/// Blank lines and `#`-leading lines are comments and are skipped — the lock file's prose is most
/// of its bytes, and the reason each pin is what it is lives there rather than in a changelog.
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
            "expected {FIELDS} `|`-separated fields (name|version|kind|binary|url|digest), got {}",
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
    let digest = field(5)?;

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
            "unknown kind `{kind_text}` — expected tar.gz, zip, file or git"
        ))
    })?;
    // Length is checked AGAINST THE KIND, so a 64-hex tarball digest pasted onto a `git` record —
    // the likeliest way to mis-edit this file — is caught here rather than as a clone that checks
    // out a commit nobody has.
    let want = kind.digest_hex_len();
    if digest.len() != want || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(fault(format!(
            "`digest` is not {want} hex digits (kind `{}`): `{digest}`",
            kind.as_str()
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
        digest: digest.to_ascii_lowercase(),
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
        assert_eq!(pin.digest.len(), 64);
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
    fn an_unknown_kind_names_the_four_that_are_known() {
        let text = ONE.replace("|zip|", "|tar.bz2|");
        let error = parse(&text).expect_err("the kind fails");
        assert!(
            error.reason.contains("tar.gz, zip, file or git"),
            "{}",
            error.reason
        );
    }

    #[test]
    fn a_digest_that_is_not_sixty_four_hex_digits_is_refused() {
        for bad in ["", "abc", &"z".repeat(64), &"a".repeat(63), &"a".repeat(65)] {
            let text = format!("adb|37.0.1|zip|adb|https://example.invalid/p.zip|{bad}");
            assert!(parse(&text).is_err(), "{bad:?} must not parse");
        }
    }

    /// The source kind, and the field whose meaning it changes.
    const SOURCE: &str = "ghostty|22d13172|git|build.zig|https://example.invalid/g.git|\
                          22d13172cde98a0a4dda05d3d6a3fcb0dd8ed018";

    #[test]
    fn a_git_record_parses_with_a_commit_rather_than_a_tarball_digest() {
        let pins = parse(SOURCE).unwrap_or_default();
        let pin = pins.first().expect("one record");
        assert_eq!(pin.kind, Kind::Git);
        assert_eq!(pin.binary, "build.zig", "the sentinel, not an executable");
        assert_eq!(pin.digest.len(), 40);
    }

    /// The likeliest mis-edit in both directions: a 64-hex tarball digest pasted onto a `git`
    /// record, and a 40-hex commit left on an archive one. Each is caught by the OTHER kind's
    /// length, which is the whole reason the length is a function of the kind.
    #[test]
    fn a_digest_of_the_wrong_length_for_its_kind_is_refused() {
        let sha256 = "a".repeat(64);
        let commit = "b".repeat(40);

        let source_with_sha = SOURCE.replace("22d13172cde98a0a4dda05d3d6a3fcb0dd8ed018", &sha256);
        let error = parse(&source_with_sha).expect_err("64 hex on a git record fails");
        assert!(error.reason.contains("not 40 hex digits"), "{}", error.reason);

        let archive_with_commit = format!("adb|37.0.1|zip|adb|https://example.invalid/p.zip|{commit}");
        let error = parse(&archive_with_commit).expect_err("40 hex on a zip record fails");
        assert!(error.reason.contains("not 64 hex digits"), "{}", error.reason);
    }

    #[test]
    fn every_kind_declares_a_digest_length_that_matches_its_spelling() {
        for (kind, len) in [
            (Kind::TarGz, 64),
            (Kind::Zip, 64),
            (Kind::File, 64),
            (Kind::Git, 40),
        ] {
            assert_eq!(kind.digest_hex_len(), len, "{}", kind.as_str());
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
        assert_eq!(pin.digest, lower, "stored lowercase whatever the file said");

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
