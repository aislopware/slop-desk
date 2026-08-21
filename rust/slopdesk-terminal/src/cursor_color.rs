//! The 6-hex ↔ RGB bridge for libghostty's `cursor-color`, on both sides of the colour well.
//!
//! `TerminalPreferences.cursorColor` and `.cursorTextColor` hold a libghostty `cursor-color`
//! string: six hex digits, no leading `#`, empty meaning "follow the theme". [`crate::config`] is
//! what emits that line; this is what a colour WELL reads it as and writes it back from. There are
//! two wells — an `NSColorWell` on the Mac and a `SwiftUI` `ColorPicker` on the phone — so the
//! conversion sits one floor under both halves and each half keeps only its own colour type's
//! channel accessor.
//!
//! Two wells means two chances to spell the same codec, and a second hex parser is exactly the
//! duplicate that keeps passing BOTH halves' tests while rounding one channel differently — the
//! drift class `docs/55` §8 catalogues. The parse, the format, the clamp and the NaN rule are the
//! DECISION, and they are spelled here once.
//!
//! ## Why this JOINS `config` rather than sitting beside it
//!
//! The emitter already answers two of the three questions this module has to ask, and asking them
//! rather than restating them is what keeps the well and the emitter agreeing.
//!
//! Whether six characters are a colour at all is [`crate::config::is_valid_hex`], which exists
//! because libghostty's colour type has no alpha: an 8-digit `rrggbbaa` is not a long form of the
//! same colour, it is a value the parser rejects. What counts as PADDING around a config value is
//! `trim_config_spaces`, and it is what `cursor-color = …` is trimmed with on the way out. A well
//! that accepted a spelling the emitter went on to drop would show a caret colour the terminal
//! never renders, and nothing anywhere would log a word about it.
//!
//! ## Two places the Swift this replaces was not the rule it described
//!
//! Both were found by reading the two implementations against each other, and both are recorded
//! here rather than quietly preserved, because a comment claiming the pair agrees is the most
//! dangerous artifact `docs/55` §8 names.
//!
//! **A leading sign parsed.** The Swift reached `UInt32(trimmed, radix: 16)`, and Swift's integer
//! initialiser accepts an optional `+` or `-` before the digits. So `"+FF880"` is six characters
//! and parses — as `0x0FF880`, a colour nobody typed — and `"-00000"` parses as black. The stated
//! rule is "rejects any non-hex character", `+` is not a hex character, and
//! [`crate::config::is_valid_hex`] refuses both. This is the direction `docs/55` §8's table calls
//! ordinary: one side was written as a parser and the other as a validator.
//!
//! **The trim differs by U+200B.** Foundation's `.whitespaces` is the Unicode `Zs` category plus
//! tab, plus ZERO WIDTH SPACE, which Unicode does not give the `White_Space` property and which
//! `trim_config_spaces` therefore does not strip. So `"\u{200B}FF8800"` used to reach a well as
//! orange and now reads as no colour at all. That is the better answer of the two for the reason
//! the section above gives: the emitter would not have stripped it either, so the config line would
//! have read `cursor-color = \u{200B}FF8800` and libghostty would have dropped it — the well was
//! showing a colour the terminal was never going to paint.

use slopdesk_sanitize::escape;

use crate::config::is_valid_hex;
use crate::keybind::trim_config_spaces;

/// One caret colour as the three `0…255` channels a colour well shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CursorRgb {
    /// The red channel.
    pub red: u8,
    /// The green channel.
    pub green: u8,
    /// The blue channel.
    pub blue: u8,
}

/// Parses a 6-hex RGB string (no leading `#`) into `0…255` channels.
///
/// `None` for an empty string — which is the "Default", follow-the-theme spelling — for the wrong
/// length, and for any non-hex character; the caller then falls back to the effective default
/// colour. Case-insensitive, because a person editing the raw preference types either case and both
/// name the same colour.
#[must_use]
pub fn rgb(text: &str) -> Option<CursorRgb> {
    let trimmed = trim_config_spaces(text);
    if !is_valid_hex(trimmed) {
        return None;
    }
    // Delegated to the crate's own two-characters-to-a-byte rule rather than a `from_str_radix`
    // over the whole string: `from_str_radix` has the same sign-accepting grammar the Swift did,
    // so reaching for it here would have carried the defect above straight over the port.
    let digits = trimmed.as_bytes();
    Some(CursorRgb {
        red: escape::hex_byte(*digits.first()?, *digits.get(1)?)?,
        green: escape::hex_byte(*digits.get(2)?, *digits.get(3)?)?,
        blue: escape::hex_byte(*digits.get(4)?, *digits.get(5)?)?,
    })
}

/// Formats unit RGB doubles into an UPPERCASE 6-hex string with no `#` — exactly the shape
/// [`crate::config`] forwards as `cursor-color = …`.
///
/// Each channel is clamped to `0…1` and NaN becomes `0`; see [`channel`] for why the clamp is
/// written the way it is.
#[must_use]
pub fn hex(red: f64, green: f64, blue: f64) -> String {
    let (red, green, blue) = (channel(red), channel(green), channel(blue));
    format!("{red:02X}{green:02X}{blue:02X}")
}

/// One unit double as a `0…255` byte, rounded to nearest.
///
/// Three details here are load-bearing and none of them is arbitrary.
///
/// NaN answers `0` before the clamp runs, because a NaN channel is a colour space conversion that
/// failed and black is the one answer that cannot be mistaken for a colour the user picked.
///
/// The clamp is `min(1, max(0, value))` in that ORDER, spelled as the IEEE operations rather than
/// as `<`/`>` comparisons, which is `CLAUDE.md`'s bit-exact rule. Written as comparisons the two
/// bounds stop being NaN-faithful and ±infinity stops falling through to `1` and `0`; written in
/// the other order they are a different function at the bounds. Rust's `f64::min`/`f64::max` are
/// Swift's `Double.minimum`/`Double.maximum`, operand for operand.
///
/// The rounding is `f64::round`, which is round-half-AWAY-from-zero, matching Swift's `.rounded()`.
/// It is deliberately not `round_ties_even`: a channel landing exactly on a half is what a slider
/// dragged to the middle of a step produces, and the two rules disagree there by one, which is one
/// hex digit of drift between a colour the user set and the colour that comes back out.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "the clamp bounds the product to 0.0..=255.0 and `round` left it with no fraction"
)]
#[expect(
    clippy::manual_clamp,
    reason = "`CLAUDE.md`'s bit-exact float rule: a comparison that SELECTS a float is `minimum`/`maximum`, \
              and `f64::clamp` is a different operation — it compares with `<`/`>`, propagates NaN rather \
              than answering the other operand, and panics on unordered bounds, which the release profile's \
              `panic = \"abort\"` would turn into a dead client"
)]
fn channel(value: f64) -> u8 {
    if value.is_nan() {
        return 0;
    }
    let clamped = f64::min(1.0, f64::max(0.0, value));
    // A plain multiply, never fused — `CLAUDE.md` again, and the round below reads the product.
    (clamped * 255.0).round() as u8
}

#[cfg(test)]
mod tests {
    use super::{CursorRgb, hex, rgb};

    #[test]
    fn a_valid_six_hex_string_parses_in_either_case_to_the_same_channels() {
        assert_eq!(
            rgb("FF8800"),
            Some(CursorRgb {
                red: 255,
                green: 136,
                blue: 0
            })
        );
        assert_eq!(rgb("ff8800"), rgb("FF8800"), "the codec is case-insensitive");
        assert_eq!(
            rgb("000000"),
            Some(CursorRgb {
                red: 0,
                green: 0,
                blue: 0
            })
        );
        assert_eq!(
            rgb("FFFFFF"),
            Some(CursorRgb {
                red: 255,
                green: 255,
                blue: 255
            })
        );
    }

    #[test]
    fn the_empty_spelling_is_no_colour_rather_than_black() {
        // "Default" — follow the theme. A well that showed black here would be showing a colour the
        // preference does not hold, and saving it would pin the theme's caret to black.
        assert_eq!(rgb(""), None);
        assert_eq!(rgb("   "), None);
        assert_eq!(rgb("\t"), None);
    }

    #[test]
    fn a_wrong_length_or_a_non_hex_character_is_no_colour() {
        assert_eq!(rgb("12345"), None, "five characters");
        assert_eq!(rgb("1234567"), None, "seven");
        assert_eq!(rgb("#FF8800"), None, "the leading hash is not part of the value");
        assert_eq!(rgb("GG0000"), None, "G is not a hex digit");
        assert_eq!(rgb("FFFFFF30"), None, "there is no alpha channel to take");
    }

    #[test]
    fn a_signed_spelling_is_refused_where_the_swift_it_replaced_parsed_one() {
        // The live defect this port found. Swift's `UInt32(_:radix:)` takes an optional sign, so
        // both of these reached a colour well as colours. Neither is six hex digits.
        assert_eq!(rgb("+FF880"), None, "Swift read this as 0x0FF880");
        assert_eq!(rgb("-00000"), None, "and this as black");
    }

    #[test]
    fn the_padding_a_config_value_may_carry_is_trimmed_before_the_length_is_counted() {
        assert_eq!(rgb("  FF8800  "), rgb("FF8800"));
        assert_eq!(
            rgb("\u{3000}FF8800"),
            rgb("FF8800"),
            "an ideographic space is padding the emitter also strips"
        );
        assert_eq!(
            rgb("\u{200B}FF8800"),
            None,
            "a zero-width space is not padding — see the module note"
        );
    }

    #[test]
    fn unit_doubles_format_as_uppercase_six_hex() {
        assert_eq!(hex(1.0, 136.0 / 255.0, 0.0), "FF8800");
        assert_eq!(hex(0.0, 0.0, 0.0), "000000");
        assert_eq!(hex(1.0, 1.0, 1.0), "FFFFFF");
    }

    #[test]
    fn an_out_of_range_channel_clamps_and_a_nan_one_goes_black() {
        assert_eq!(hex(1.5, -0.2, 0.0), "FF0000");
        assert_eq!(
            hex(f64::NAN, f64::INFINITY, 0.0),
            "00FF00",
            "NaN answers before the clamp; infinity falls through it"
        );
        assert_eq!(
            hex(f64::NEG_INFINITY, 0.0, f64::NAN),
            "000000",
            "and negative infinity falls through the other bound"
        );
    }

    #[test]
    fn a_channel_on_a_half_rounds_away_from_zero_rather_than_to_even() {
        // 0.5/255 scales to exactly 0.5. Round-half-to-even would answer 0 and round-half-away
        // answers 1, and Swift's `.rounded()` is the second — so this pins the one hex digit the
        // two rules disagree about.
        assert_eq!(hex(0.5 / 255.0, 0.0, 0.0), "010000");
        assert_eq!(hex(1.5 / 255.0, 0.0, 0.0), "020000");
    }

    #[test]
    fn parse_then_format_is_the_identity_over_the_tokens_the_settings_bed_uses() {
        for token in ["3FA9F5", "37352F", "FCFBF9", "010203", "ABCDEF"] {
            // Asserted as an `Option` rather than unwrapped, so a token that stopped parsing fails
            // this case with its own name instead of tearing the whole suite down on a panic.
            let back = rgb(token).map(|color| {
                hex(
                    f64::from(color.red) / 255.0,
                    f64::from(color.green) / 255.0,
                    f64::from(color.blue) / 255.0,
                )
            });
            assert_eq!(back.as_deref(), Some(token), "round trip drifted for {token}");
        }
    }
}
