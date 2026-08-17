//! A JSON subset, for the files this product writes to itself.
//!
//! **This is not the wire, and its existence is not a crack in the manual-binary rule.** That rule
//! is about frames on a socket, where a byte of framing overhead is a byte of latency. This module
//! serves the opposite case: a persistence file read once at start by the process that wrote it,
//! where determinism and being readable in a diff are the only things that matter and latency is
//! not measurable.
//!
//! It lives in the DOMAIN crate rather than the wire one because both of this product's persistence
//! files are domain values — the host's document cells and the client's workspace tree — and the
//! domain crate is the one both ends already depend on.
//!
//! ## Why hand-written rather than a crate
//!
//! Not the supply chain. That was the original reason and it is DEAD: `src/secrets.rs` took
//! `regex`, which pulls a far larger tree than `serde_json` would, so "this crate has no
//! third-party dependency" stopped being true and cannot be the argument any more.
//!
//! What is left is the WRITER, and it is enough. Every byte here is pinned to what Swift's
//! `.prettyPrinted` wrote, because both persistence files are already on disk in that spelling:
//! a space either side of the `:`, `U+007F` escaped, and `U+0008`/`U+000C` spelled long as
//! `\u0008`/`\u000c`. `serde_json` disagrees on all three — measured, not assumed: it writes
//! `"a":`, emits DEL raw, and shortens to `\b`/`\f`. So the swap is a
//! whole-file diff on every user's first save — and buying it back means a hand-written `Formatter`
//! impl, which is most of what would have been deleted, re-added with a dependency underneath it.
//! The parser could go alone, but a parser and a writer that disagree about the same file's shape
//! is a worse thing to own than either half.
//!
//! Revisit if the on-disk spelling is ever allowed to change for another reason — then the whole
//! module goes at once.
//!
//! ## Sorted keys are structural
//!
//! An object is a [`BTreeMap`], so the key order in the output is the keys' own order rather than
//! insertion order. That is the same move the document's cell map makes for the same reason: Swift
//! asked its encoder for `.sortedKeys` so two saves of one value would be byte-identical, and a
//! sorted container makes it a property of the type rather than a flag somebody must remember to
//! pass.
//!
//! ## What it refuses
//!
//! Nesting past [`MAX_DEPTH`] and trailing bytes after the top-level value. The depth cap is doing
//! the job `JSONDecoder`'s own ~512-level container bound did on the Swift side: a hand-edited file
//! nested a million deep must fail cleanly rather than unwind through the parser's recursion into
//! the stack guard.

use std::collections::BTreeMap;
use std::fmt;

/// Why a document would not parse.
///
/// One variant with a hint rather than a taxonomy: nothing branches on WHICH syntax fault a
/// hand-edited file has — every one of them means the same thing, which is that the caller falls
/// back to the default and keeps the old file aside.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JsonError {
    /// A short human-readable reason, for logs only.
    pub hint: &'static str,
}

impl JsonError {
    /// A fault under a short reason.
    #[must_use]
    pub const fn from_hint(hint: &'static str) -> Self {
        Self { hint }
    }
}

impl fmt::Display for JsonError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "malformed json: {}", self.hint)
    }
}

impl std::error::Error for JsonError {}

/// Result alias for this module.
pub type Result<T> = core::result::Result<T, JsonError>;

/// The deepest nesting a parsed document may carry.
///
/// Far above any shape this crate writes — the state file is three levels — and far below what
/// would trouble the parser's own recursion.
pub const MAX_DEPTH: usize = 64;

/// One JSON value.
///
/// [`Self::Integer`] is separate from [`Self::Number`] on purpose: a version tag and a field byte
/// are integers, and routing them through `f64` would print `1` as `1.0` and silently round
/// anything past 2^53.
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    /// `null`.
    Null,
    /// `true` / `false`.
    Bool(bool),
    /// A literal with no fraction or exponent that fits an `i64`.
    Integer(i64),
    /// Any other numeric literal.
    Number(f64),
    /// A string, already unescaped.
    String(String),
    /// An array.
    Array(Vec<Self>),
    /// An object, keyed in sorted order.
    Object(BTreeMap<String, Self>),
}

impl Json {
    /// The object's entries, if this is an object.
    #[must_use]
    pub const fn object(&self) -> Option<&BTreeMap<String, Self>> {
        match self {
            Self::Object(map) => Some(map),
            _ => None,
        }
    }

    /// The array's elements, if this is an array.
    #[must_use]
    pub fn array(&self) -> Option<&[Self]> {
        match self {
            Self::Array(items) => Some(items),
            _ => None,
        }
    }

    /// The string's contents, if this is a string.
    #[must_use]
    pub fn string(&self) -> Option<&str> {
        match self {
            Self::String(text) => Some(text),
            _ => None,
        }
    }

    /// The value as an integer.
    ///
    /// A whole [`Self::Number`] answers too — a hand-edited file writing `1.0` where a version tag
    /// belongs means the same thing a person meant by `1`.
    #[must_use]
    pub fn integer(&self) -> Option<i64> {
        match self {
            Self::Integer(value) => Some(*value),
            #[expect(
                clippy::cast_possible_truncation,
                reason = "the range check immediately above is what makes the cast exact"
            )]
            Self::Number(value) if value.fract() == 0.0 && value.abs() <= 9_007_199_254_740_992.0 => {
                Some(*value as i64)
            },
            _ => None,
        }
    }

    /// The named member of an object.
    #[must_use]
    pub fn get(&self, key: &str) -> Option<&Self> {
        self.object()?.get(key)
    }
}

/// Builds an object from its members.
///
/// A free function rather than a macro so the call site stays greppable.
#[must_use]
pub fn object<const N: usize>(members: [(&str, Json); N]) -> Json {
    Json::Object(
        members
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect(),
    )
}

// ---------------------------------------------------------------------------------------------- //
// Writing
// ---------------------------------------------------------------------------------------------- //

/// Renders a value as indented JSON with a trailing newline.
///
/// Two spaces per level and a space either side of the `:`, which is what Swift's `.prettyPrinted`
/// wrote — kept so a file this build writes still reads like the files already on disk rather than
/// showing up as a whole-file diff on the first save after the port.
#[must_use]
pub fn to_pretty_string(value: &Json) -> String {
    let mut out = String::new();
    write_value(&mut out, value, 0);
    out.push('\n');
    out
}

fn write_value(out: &mut String, value: &Json, depth: usize) {
    match value {
        Json::Null => out.push_str("null"),
        Json::Bool(true) => out.push_str("true"),
        Json::Bool(false) => out.push_str("false"),
        Json::Integer(number) => out.push_str(&number.to_string()),
        Json::Number(number) => out.push_str(&number_literal(*number)),
        Json::String(text) => write_string(out, text),
        Json::Array(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push_str("[\n");
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push_str(",\n");
                }
                indent(out, depth + 1);
                write_value(out, item, depth + 1);
            }
            out.push('\n');
            indent(out, depth);
            out.push(']');
        },
        Json::Object(members) => {
            if members.is_empty() {
                out.push_str("{}");
                return;
            }
            out.push_str("{\n");
            for (index, (key, member)) in members.iter().enumerate() {
                if index > 0 {
                    out.push_str(",\n");
                }
                indent(out, depth + 1);
                write_string(out, key);
                out.push_str(" : ");
                write_value(out, member, depth + 1);
            }
            out.push('\n');
            indent(out, depth);
            out.push('}');
        },
    }
}

fn indent(out: &mut String, depth: usize) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

/// A finite `f64` in its shortest round-tripping form.
///
/// Non-finite is `null`: JSON has no NaN or infinity, and a writer that emitted one would produce a
/// file its own parser rejects. Nothing in this crate can reach here with one — the geometry is
/// sanitized long before it is persisted — so the branch is a floor, not a policy.
fn number_literal(number: f64) -> String {
    if !number.is_finite() {
        return "null".to_owned();
    }
    // `{:?}` is the shortest representation that parses back to the same bits, and it keeps the `.0`
    // that tells a reader the field is a float.
    format!("{number:?}")
}

/// One lowercase hex digit for a nibble — the case `\u` escapes are conventionally written in.
fn hex_digit(nibble: u32) -> char {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    char::from(
        usize::try_from(nibble)
            .ok()
            .and_then(|index| DIGITS.get(index).copied())
            .unwrap_or(b'0'),
    )
}

fn write_string(out: &mut String, text: &str) {
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if control < ' ' || control == '\u{7f}' => {
                // The one shape JSON has for a control byte. `format!` would allocate a `String`
                // per character in a hot-ish loop; four pushes do not.
                out.push_str("\\u00");
                out.push(hex_digit((control as u32 >> 4) & 0x0F));
                out.push(hex_digit(control as u32 & 0x0F));
            },
            other => out.push(other),
        }
    }
    out.push('"');
}

// ---------------------------------------------------------------------------------------------- //
// Parsing
// ---------------------------------------------------------------------------------------------- //

/// Parses one whole JSON document.
///
/// Trailing bytes after the top-level value are a fault rather than ignored: a file with a second
/// document glued to the end is corrupt, and reading only the first half of it would restore half a
/// workspace.
///
/// # Errors
/// [`JsonError`] for any syntax fault, and for nesting past [`MAX_DEPTH`].
pub fn parse(input: &str) -> Result<Json> {
    let mut cursor = Cursor {
        rest: input,
        depth: 0,
    };
    cursor.skip_whitespace();
    let value = cursor.value()?;
    cursor.skip_whitespace();
    if !cursor.rest.is_empty() {
        return Err(JsonError::from_hint("trailing bytes after the document"));
    }
    Ok(value)
}

struct Cursor<'a> {
    rest: &'a str,
    depth: usize,
}

impl Cursor<'_> {
    fn skip_whitespace(&mut self) {
        self.rest = self.rest.trim_start_matches([' ', '\t', '\n', '\r']);
    }

    fn peek(&self) -> Option<char> {
        self.rest.chars().next()
    }

    /// Consumes a literal, or answers whether it was there.
    fn eat(&mut self, literal: &str) -> bool {
        match self.rest.strip_prefix(literal) {
            Some(rest) => {
                self.rest = rest;
                true
            },
            None => false,
        }
    }

    fn value(&mut self) -> Result<Json> {
        if self.depth > MAX_DEPTH {
            return Err(JsonError::from_hint("nested past the depth cap"));
        }
        match self.peek() {
            Some('{') => self.object(),
            Some('[') => self.array(),
            Some('"') => Ok(Json::String(self.string()?)),
            Some('t') if self.eat("true") => Ok(Json::Bool(true)),
            Some('f') if self.eat("false") => Ok(Json::Bool(false)),
            Some('n') if self.eat("null") => Ok(Json::Null),
            Some(first) if first == '-' || first.is_ascii_digit() => self.number(),
            _ => Err(JsonError::from_hint("expected a value")),
        }
    }

    fn object(&mut self) -> Result<Json> {
        if !self.eat("{") {
            return Err(JsonError::from_hint("expected '{'"));
        }
        self.depth += 1;
        let mut members = BTreeMap::new();
        self.skip_whitespace();
        if self.eat("}") {
            self.depth -= 1;
            return Ok(Json::Object(members));
        }
        loop {
            self.skip_whitespace();
            let key = self.string()?;
            self.skip_whitespace();
            if !self.eat(":") {
                return Err(JsonError::from_hint("expected ':' after a key"));
            }
            self.skip_whitespace();
            let value = self.value()?;
            // A repeated key keeps the LAST occurrence, which is what every mainstream parser does
            // and what a hand-edit appending a corrected line means.
            members.insert(key, value);
            self.skip_whitespace();
            if self.eat(",") {
                continue;
            }
            if self.eat("}") {
                self.depth -= 1;
                return Ok(Json::Object(members));
            }
            return Err(JsonError::from_hint("expected ',' or '}'"));
        }
    }

    fn array(&mut self) -> Result<Json> {
        if !self.eat("[") {
            return Err(JsonError::from_hint("expected '['"));
        }
        self.depth += 1;
        let mut items = Vec::new();
        self.skip_whitespace();
        if self.eat("]") {
            self.depth -= 1;
            return Ok(Json::Array(items));
        }
        loop {
            self.skip_whitespace();
            items.push(self.value()?);
            self.skip_whitespace();
            if self.eat(",") {
                continue;
            }
            if self.eat("]") {
                self.depth -= 1;
                return Ok(Json::Array(items));
            }
            return Err(JsonError::from_hint("expected ',' or ']'"));
        }
    }

    fn string(&mut self) -> Result<String> {
        if !self.eat("\"") {
            return Err(JsonError::from_hint("expected a string"));
        }
        let mut out = String::new();
        loop {
            let Some(character) = self.peek() else {
                return Err(JsonError::from_hint("unterminated string"));
            };
            self.advance(character.len_utf8());
            match character {
                '"' => return Ok(out),
                '\\' => out.push(self.escape()?),
                control if control < ' ' => {
                    return Err(JsonError::from_hint("raw control byte in a string"));
                },
                other => out.push(other),
            }
        }
    }

    fn escape(&mut self) -> Result<char> {
        let Some(marker) = self.peek() else {
            return Err(JsonError::from_hint("unterminated escape"));
        };
        self.advance(marker.len_utf8());
        match marker {
            '"' => Ok('"'),
            '\\' => Ok('\\'),
            '/' => Ok('/'),
            'b' => Ok('\u{8}'),
            'f' => Ok('\u{c}'),
            'n' => Ok('\n'),
            'r' => Ok('\r'),
            't' => Ok('\t'),
            'u' => self.unicode_escape(),
            _ => Err(JsonError::from_hint("unknown escape")),
        }
    }

    /// A `\uXXXX` escape, joining a surrogate pair when one follows.
    fn unicode_escape(&mut self) -> Result<char> {
        let first = self.hex4()?;
        // A high surrogate is only half a scalar; the low half must follow as its own escape.
        if (0xD800..0xDC00).contains(&first) {
            if !self.eat("\\u") {
                return Err(JsonError::from_hint("lone high surrogate"));
            }
            let second = self.hex4()?;
            if !(0xDC00..0xE000).contains(&second) {
                return Err(JsonError::from_hint("bad surrogate pair"));
            }
            let scalar = 0x1_0000 + ((first - 0xD800) << 10) + (second - 0xDC00);
            return char::from_u32(scalar)
                .ok_or_else(|| JsonError::from_hint("surrogate pair is not a scalar"));
        }
        char::from_u32(first).ok_or_else(|| JsonError::from_hint("escape is not a scalar"))
    }

    fn hex4(&mut self) -> Result<u32> {
        let digits: String = self.rest.chars().take(4).collect();
        if digits.len() != 4 {
            return Err(JsonError::from_hint("truncated \\u escape"));
        }
        let value =
            u32::from_str_radix(&digits, 16).map_err(|_ignored| JsonError::from_hint("bad \\u escape"))?;
        self.advance(digits.len());
        Ok(value)
    }

    fn number(&mut self) -> Result<Json> {
        let end = self
            .rest
            .find(|character: char| !matches!(character, '0'..='9' | '-' | '+' | '.' | 'e' | 'E'))
            .unwrap_or(self.rest.len());
        let Some(literal) = self.rest.get(..end) else {
            return Err(JsonError::from_hint("bad number"));
        };
        let exact = !literal.contains(['.', 'e', 'E']);
        let parsed = if exact {
            literal.parse::<i64>().map(Json::Integer).ok()
        } else {
            None
        };
        let value = match parsed {
            Some(integer) => integer,
            // A literal too wide for `i64`, or one with a fraction, falls to `f64`. Losing precision
            // there is the format's own limit, not a decision this parser gets to make.
            None => {
                Json::Number(
                    literal
                        .parse::<f64>()
                        .map_err(|_ignored| JsonError::from_hint("bad number"))?,
                )
            },
        };
        self.advance(end);
        Ok(value)
    }

    fn advance(&mut self, bytes: usize) {
        self.rest = self.rest.get(bytes..).unwrap_or("");
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a refused parse in a round-trip test has nothing to return"
    )]

    use std::collections::BTreeMap;

    use super::{Json, MAX_DEPTH, object, parse, to_pretty_string};

    #[test]
    fn every_scalar_round_trips() {
        let document = object([
            ("null", Json::Null),
            ("yes", Json::Bool(true)),
            ("no", Json::Bool(false)),
            ("count", Json::Integer(-17)),
            ("ratio", Json::Number(0.5)),
            ("text", Json::String("hi".to_owned())),
            ("list", Json::Array(vec![Json::Integer(1), Json::Integer(2)])),
        ]);
        let Ok(back) = parse(&to_pretty_string(&document)) else {
            panic!("what this module wrote, it reads");
        };
        assert_eq!(back, document);
    }

    #[test]
    fn the_keys_come_out_sorted_whatever_order_they_went_in() {
        let document = object([
            ("version", Json::Integer(1)),
            ("entries", Json::Array(vec![])),
            ("alpha", Json::Integer(0)),
        ]);
        let text = to_pretty_string(&document);
        let Some(alpha) = text.find("alpha") else {
            panic!("the key is in the output");
        };
        let Some(entries) = text.find("entries") else {
            panic!("the key is in the output");
        };
        let Some(version) = text.find("version") else {
            panic!("the key is in the output");
        };
        assert!(
            alpha < entries && entries < version,
            "two saves must be byte-identical"
        );
    }

    #[test]
    fn the_shape_is_two_space_indented_with_a_spaced_colon() {
        let document = object([("a", Json::Integer(1))]);
        assert_eq!(to_pretty_string(&document), "{\n  \"a\" : 1\n}\n");
    }

    #[test]
    fn an_integer_stays_an_integer_rather_than_printing_as_a_float() {
        assert_eq!(to_pretty_string(&Json::Integer(1)), "1\n");
        assert_eq!(to_pretty_string(&Json::Number(1.0)), "1.0\n");
    }

    #[test]
    fn a_non_finite_number_writes_as_null_rather_than_a_file_we_cannot_read() {
        for hostile in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let text = to_pretty_string(&Json::Number(hostile));
            assert_eq!(text, "null\n");
            assert!(
                parse(&text).is_ok(),
                "the writer never emits what the parser refuses"
            );
        }
    }

    #[test]
    fn a_whole_float_answers_the_integer_accessor() {
        assert_eq!(Json::Number(1.0).integer(), Some(1));
        assert_eq!(Json::Number(1.5).integer(), None);
        assert_eq!(Json::Integer(9).integer(), Some(9));
    }

    #[test]
    fn escapes_survive_both_directions() {
        let awkward = "quote\" back\\ tab\t newline\n bell\u{7} emoji😀";
        let document = Json::String(awkward.to_owned());
        let text = to_pretty_string(&document);
        assert!(
            !text.contains('\t'),
            "a raw control byte in a string is not valid JSON"
        );
        let Ok(Json::String(back)) = parse(&text) else {
            panic!("the escape round trips");
        };
        assert_eq!(back, awkward);
    }

    #[test]
    fn a_surrogate_pair_decodes_to_one_scalar() {
        let Ok(Json::String(text)) = parse("\"\\ud83d\\ude00\"") else {
            panic!("the pair is one emoji");
        };
        assert_eq!(text, "😀");
    }

    #[test]
    fn a_lone_surrogate_is_refused_rather_than_replaced() {
        assert!(parse("\"\\ud83d\"").is_err());
        assert!(parse("\"\\udc00\"").is_err());
    }

    #[test]
    fn trailing_bytes_fail_the_whole_document() {
        assert!(parse("{} {}").is_err(), "half a workspace is worse than none");
        assert!(parse("1 2").is_err());
    }

    #[test]
    fn a_pathologically_deep_document_fails_soft() {
        let deep = "[".repeat(MAX_DEPTH + 50) + &"]".repeat(MAX_DEPTH + 50);
        assert!(parse(&deep).is_err(), "the stack guard is not the error handler");
        let shallow = "[".repeat(MAX_DEPTH - 1) + &"]".repeat(MAX_DEPTH - 1);
        assert!(parse(&shallow).is_ok());
    }

    #[test]
    fn whitespace_anywhere_it_is_legal_is_ignored() {
        let Ok(value) = parse("  {\n\t\"a\"  :  [ 1 , 2 ]\r\n}  ") else {
            panic!("a pretty-printed file parses");
        };
        assert_eq!(
            value.get("a").and_then(Json::array),
            Some([Json::Integer(1), Json::Integer(2)].as_slice()),
        );
    }

    #[test]
    fn every_truncation_of_a_real_document_is_refused_rather_than_read_as_half() {
        let text = to_pretty_string(&object([
            (
                "entries",
                Json::Array(vec![object([("id", Json::String("x".to_owned()))])]),
            ),
            ("version", Json::Integer(1)),
        ]));
        // Up to but NOT including the whole document — the last byte is the trailing newline, and a
        // document minus its newline is still a document.
        for cut in 1..text.trim_end().len() {
            let Some(prefix) = text.get(..cut) else { continue };
            if prefix.trim().is_empty() {
                continue;
            }
            assert!(
                parse(prefix).is_err(),
                "a truncated file must not decode: {prefix:?}"
            );
        }
    }

    #[test]
    fn a_repeated_key_keeps_the_last_one() {
        let Ok(value) = parse("{\"a\": 1, \"a\": 2}") else {
            panic!("a repeated key is not a syntax error");
        };
        assert_eq!(value.get("a"), Some(&Json::Integer(2)));
    }

    #[test]
    fn the_empty_containers_print_flat() {
        assert_eq!(to_pretty_string(&Json::Array(vec![])), "[]\n");
        assert_eq!(to_pretty_string(&Json::Object(BTreeMap::new())), "{}\n");
    }

    #[test]
    fn a_literal_too_wide_for_an_integer_falls_to_a_float_rather_than_failing() {
        let Ok(value) = parse("123456789012345678901234567890") else {
            panic!("the format's own limit is not a parse error");
        };
        assert!(matches!(value, Json::Number(_)));
    }
}
