//! What a fresh install's terminal settings are, and how a settings number is spelled.
//!
//! ## The config-file EMITTER that used to live here is gone
//!
//! This module built a `ghostty`-style `key = value` text — the same newline-separated syntax a
//! `~/.config/ghostty/config` file holds — because the deleted fork applied its settings by handing
//! that text to `ghostty_config_load_string`. The renderer that replaced the fork takes typed doors
//! instead, so the text had no parser on the other end and was built, published and dropped on
//! every settings change. `docs/68` argues the boundary; what the doors bought in practice is that
//! a `scrollback-limit` of 10 000 now means ten thousand ROWS rather than whatever a
//! 256-byte-per-line estimate happened to buy, because the engine's own limit is a row count.
//!
//! What survives is what had a second reader all along: the FACTORY constants, which
//! `slopdesk-settings`' table publishes as each row's default, and [`number_text`], which spells a
//! number the way a user types one.
//!
//! ## The font SPEC, and why the parsing is here rather than in Core Text's crate
//!
//! [`FontSpec`] is every `terminal.font-*` row resolved into the one value `FontStack::new` takes.
//! It lives here because the two ends that must agree about it are `slopdesk-settings`, which
//! declares the rows, and `slopdesk-apple-text`, which resolves them into faces — and the second
//! forbids nothing but reaches Core Text, so anything that can be decided without a framework call
//! is decided on this side and arrives already checked. That is the whole of
//! [`FontFeature::parse`]: `-calt` is a string a user typed, `(b"calt", 0)` is a fact, and turning
//! one into the other is text work that a crate full of `unsafe` should never be doing.
//!
//! The feature syntax is `ghostty`'s, deliberately and to the letter — `feat`, `+feat`, `-feat`,
//! `feat=2`, `feat on`, `feat off`, quoted names, comma-separated lists, invalid settings silently
//! ignored — because a user who has a `font-feature` line that works in ghostty should be able to
//! paste it here. It is also, as ghostty's own documentation notes, the `font-feature-settings` CSS
//! property's syntax.

/// The primary font family a fresh install carries.
pub const FACTORY_FONT_FAMILY: &str = "SF Mono";
/// The point size a fresh install carries.
pub const FACTORY_FONT_SIZE: f64 = 13.0;
/// The background a fresh install carries.
pub const FACTORY_BACKGROUND: &str = "22212C";
/// The foreground a fresh install carries.
pub const FACTORY_FOREGROUND: &str = "F8F8F2";
/// The cursor opacity a fresh install carries.
pub const FACTORY_CURSOR_OPACITY: f64 = 1.0;
/// The scrollback depth, in lines, a fresh install carries.
pub const FACTORY_SCROLLBACK_LINES: i64 = 10_000;

/// How hard a thickened stroke is drawn when nothing says otherwise, `0`–`255`.
///
/// `ghostty`'s own default for `font-thicken-strength`, and its scale: `0` is not "no thickening"
/// but the LIGHTEST thickening, because the setting only reads at all once `font-thicken` is on.
pub const FACTORY_FONT_THICKEN_STRENGTH: i64 = 255;

/// The cell height multiplier a fresh install carries — the face's own.
pub const FACTORY_LINE_HEIGHT: f64 = 1.0;

/// One OpenType feature setting: which four-letter feature, and what it is set to.
///
/// The tag is four bytes rather than a `String` because an OpenType tag IS four bytes — `calt`,
/// `ss01`, `liga` — and both readers want it that way: Core Text takes a four-character
/// `CFString`, and holding anything else would mean re-checking downstream what
/// [`FontFeature::parse`] already checked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FontFeature {
    /// The four ASCII bytes naming the feature.
    tag: [u8; 4],
    /// What it is set to. `0` disables, `1` enables, and anything else selects an alternate the
    /// face itself numbers.
    value: u32,
}

impl FontFeature {
    /// One setting as a user wrote it, or `None` for anything that is not one.
    ///
    /// The grammar is `ghostty`'s, and the module header says why. In full: an optional `+` or `-`
    /// sign, a tag that may be wrapped in single or double quotes, and an optional value written
    /// either after an `=` or after whitespace, as a number or as `on`/`off`. A bare tag enables.
    ///
    /// `None` rather than an error because ghostty's rule for this row is "the syntax is fairly
    /// loose, but invalid settings will be silently ignored" — and the reason it is the right rule
    /// survives the port: this is a list, one bad entry in it should cost that entry rather than
    /// the whole line, and there is no settings GUI to report a diagnostic to.
    #[must_use]
    pub fn parse(setting: &str) -> Option<Self> {
        let setting = setting.trim();
        let (sign, rest) = match setting.as_bytes().first() {
            Some(b'-') => (Some(0), &setting[1..]),
            Some(b'+') => (Some(1), &setting[1..]),
            _ => (None, setting),
        };
        // `=` first, so `feat = 3` splits on the sign rather than on the space before it; only when
        // there is no `=` at all does whitespace separate the tag from its value.
        let split = rest
            .split_once('=')
            .or_else(|| rest.split_once(char::is_whitespace));
        let (name, written) = match split {
            Some((name, value)) => (name, Some(value)),
            None => (rest, None),
        };
        let tag = Self::tag_of(name)?;
        let value = match (sign, written.map(str::trim)) {
            // A sign and a value at once (`-calt=1`) contradict each other; refusing is the honest
            // answer, and it is the only shape here where the two halves can disagree at all.
            (Some(_), Some(value)) if !value.is_empty() => return None,
            (Some(signed), _) => signed,
            (None, None) => 1,
            (None, Some(value)) => Self::value_of(value)?,
        };
        Some(Self { tag, value })
    }

    /// The four ASCII bytes naming the feature.
    #[must_use]
    pub const fn tag(&self) -> [u8; 4] {
        self.tag
    }

    /// The feature's setting: `0` off, `1` on, higher for a numbered alternate.
    #[must_use]
    pub const fn value(&self) -> u32 {
        self.value
    }

    /// A tag as written — unquoted, and refused unless it is exactly four printable ASCII bytes.
    ///
    /// Four is not a house rule: `CTFontDescriptor`'s OpenType feature tag is a four-character
    /// string, so a longer or shorter one has nowhere to go. Quotes are stripped because the syntax
    /// is CSS's, where the name is quoted.
    fn tag_of(name: &str) -> Option<[u8; 4]> {
        let name = name.trim();
        let name = name
            .strip_prefix('"')
            .and_then(|rest| rest.strip_suffix('"'))
            .or_else(|| name.strip_prefix('\'').and_then(|rest| rest.strip_suffix('\'')))
            .unwrap_or(name);
        let bytes: [u8; 4] = name.as_bytes().try_into().ok()?;
        bytes.iter().all(u8::is_ascii_graphic).then_some(bytes)
    }

    /// A value as written: a number, or one of the two words ghostty spells a bool with.
    fn value_of(written: &str) -> Option<u32> {
        match written {
            "on" | "true" => Some(1),
            "off" | "false" => Some(0),
            number => number.parse().ok(),
        }
    }
}

/// Every `terminal.font-*` row resolved into the one value a font stack is built from.
///
/// One struct rather than ten arguments, and it is the STASHED value as well as the argument: the
/// surface keeps the spec it last built with, so "did anything about the font change" is one
/// comparison instead of ten that a new row would have to be remembered to join.
///
/// A style family left EMPTY is not "no bold" — it means "whatever the primary family's own bold
/// cut is", which is what a user who never set the row wants and what the family resolution below
/// falls back to. Refusing a style outright is `ghostty`'s separate `font-style` row, which is not
/// ported: the terminal has no way to ask for a face it was told to refuse.
#[derive(Debug, Clone, PartialEq)]
pub struct FontSpec {
    /// The primary family. Index 0 of every face chain, and the face the grid is measured from.
    pub family: String,
    /// The family to draw BOLD with, or empty to take the primary family's own bold cut.
    pub bold: String,
    /// The family to draw ITALIC with, on [`Self::bold`]'s terms.
    pub italic: String,
    /// The family to draw BOLD ITALIC with, on [`Self::bold`]'s terms.
    pub bold_italic: String,
    /// Families to try, in order, for a character the primary family cannot map — ahead of the
    /// system's own cascade rather than instead of it.
    pub fallback: Vec<String>,
    /// OpenType features applied to every face in the chain. `-calt` is how ligatures go away.
    pub features: Vec<FontFeature>,
    /// Whether every glyph is stroked as well as filled, which is what makes a face read heavier on
    /// a dark background.
    pub thicken: bool,
    /// How hard, `0`–`255`, when [`Self::thicken`] is set. See [`FACTORY_FONT_THICKEN_STRENGTH`].
    pub thicken_strength: u8,
    /// The point size, before the display's contents scale.
    pub point_size: f64,
    /// The cell height as a multiple of the face's natural one.
    pub line_height: f64,
}

impl Default for FontSpec {
    fn default() -> Self {
        Self {
            family: FACTORY_FONT_FAMILY.to_owned(),
            bold: String::new(),
            italic: String::new(),
            bold_italic: String::new(),
            fallback: Vec::new(),
            features: Vec::new(),
            thicken: false,
            #[expect(
                clippy::cast_possible_truncation,
                reason = "the constant is the u8 the row is bounded to; the width is the settings table's"
            )]
            thicken_strength: FACTORY_FONT_THICKEN_STRENGTH as u8,
            point_size: FACTORY_FONT_SIZE,
            line_height: FACTORY_LINE_HEIGHT,
        }
    }
}

impl FontSpec {
    /// Every `terminal.font-feature` entry read into settings, later entries winning.
    ///
    /// One entry may hold a comma-separated LIST, which is ghostty's own affordance and the reason
    /// this is not simply a `map`: `-calt, -liga, -dlig` is the line a user pastes to turn
    /// ligatures off, and it is one row's value rather than three.
    ///
    /// A tag set twice keeps its LAST setting rather than both. Core Text merges a feature array
    /// itself, so two settings for one tag would be resolved somewhere neither the user nor this
    /// crate can see; deciding here means the file reads top-to-bottom, like every other setting.
    #[must_use]
    pub fn features_of<S: AsRef<str>>(entries: &[S]) -> Vec<FontFeature> {
        let mut features: Vec<FontFeature> = Vec::new();
        for setting in entries
            .iter()
            .flat_map(|entry| entry.as_ref().split(','))
            .filter_map(FontFeature::parse)
        {
            match features.iter_mut().find(|held| held.tag() == setting.tag()) {
                Some(held) => *held = setting,
                None => features.push(setting),
            }
        }
        features
    }
}

/// The limit past which a config value stops being written as a plain integer. A point size, a
/// percent or a multiplier never comes near it.
pub const CONFIG_INTEGRAL_LIMIT: f64 = 1e9;

/// The limit for an environment value, which carries milliseconds as well as ratios and so is given
/// the whole range a `Double` spells exactly.
pub const ENV_INTEGRAL_LIMIT: f64 = 1e15;

/// A number as a settings value spells it: integral values without a decimal point, everything else
/// as the shortest text that reads back as the same number.
///
/// One spelling, two limits. The settings file and the `SLOPDESK_*` env overlay ask the same
/// question — "what does a user type for this number" — and answer it identically inside their own
/// range; only where an integer stops being written as one do they differ, so the limit is the
/// argument and the rule is not written twice.
///
/// The domain is the one settings values live in — point sizes, opacities, percents, multipliers,
/// milliseconds. Outside it, past `integral_limit` or into an exponent, this stays decimal where a
/// `%g`-style formatter would switch to scientific notation; a reader rejects such a value either
/// way.
#[must_use]
pub fn number_text(value: f64, integral_limit: f64) -> String {
    #[expect(
        clippy::float_cmp,
        reason = "the comparison IS the integrality test — an exact equality is the question asked"
    )]
    let integral = value.is_finite() && value == value.round() && value.abs() < integral_limit;
    if integral {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the value was just shown to be integral and inside the limit, so the cast is exact"
        )]
        return (value as i64).to_string();
    }
    if value.is_nan() {
        return "nan".to_owned();
    }
    if value.is_infinite() {
        return if value < 0.0 { "-inf" } else { "inf" }.to_owned();
    }
    let mut text = format!("{value}");
    // A finite non-integral value always has a point already; a value only lands here without one
    // by being too large for the integral branch, and such a number is written with a fractional
    // part so it reads back as a floating value rather than an integer.
    if !text.contains(['.', 'e']) {
        text.push_str(".0");
    }
    text
}

#[cfg(test)]
mod tests {
    use super::{CONFIG_INTEGRAL_LIMIT, ENV_INTEGRAL_LIMIT, FontFeature, FontSpec, number_text};

    /// A feature's tag and value, as the test wants to read them.
    fn feature(setting: &str) -> Option<(String, u32)> {
        let parsed = FontFeature::parse(setting)?;
        Some((String::from_utf8(parsed.tag().to_vec()).ok()?, parsed.value()))
    }

    /// Every spelling ghostty's own documentation lists, because a line that works there is a line
    /// a user will paste here.
    #[test]
    fn a_feature_is_written_the_five_ways_ghostty_writes_one() {
        for enabling in ["calt", "+calt", "calt=1", "calt on", "calt = 1", "calt true"] {
            assert_eq!(feature(enabling), Some(("calt".to_owned(), 1)), "{enabling}");
        }
        for disabling in ["-calt", "calt=0", "calt off", "calt 0", "calt false"] {
            assert_eq!(feature(disabling), Some(("calt".to_owned(), 0)), "{disabling}");
        }
        // A numbered alternate, which is the whole reason the value is not a bool.
        assert_eq!(feature("ss01=2"), Some(("ss01".to_owned(), 2)));
        assert_eq!(feature("cv01 4"), Some(("cv01".to_owned(), 4)));
        // CSS spells the name quoted, and ghostty says so explicitly.
        assert_eq!(feature("\"liga\" 0"), Some(("liga".to_owned(), 0)));
        assert_eq!(feature("'liga'"), Some(("liga".to_owned(), 1)));
        assert_eq!(feature("  -dlig  "), Some(("dlig".to_owned(), 0)));
    }

    /// An OpenType tag is four bytes, and a setting that is not one has nowhere to go — Core Text's
    /// feature tag is a four-character string. Ignored silently, per the row's own rule.
    #[test]
    fn a_setting_that_is_not_one_is_ignored_rather_than_guessed_at() {
        for broken in [
            "",
            "cal",
            "ligatures",
            "calt=x",
            "calt=-1",
            "-calt=1",
            "+calt=0",
            "ca t",
            "=1",
        ] {
            assert_eq!(feature(broken), None, "{broken}");
        }
    }

    /// The line a user pastes to turn ligatures off is ONE row's value, and the last setting for a
    /// tag is the one that stands.
    #[test]
    fn a_comma_separated_row_is_a_list_and_the_last_setting_for_a_tag_wins() {
        let features = FontSpec::features_of(&["-calt, -liga, -dlig"]);
        assert_eq!(features.len(), 3);
        assert!(features.iter().all(|held| held.value() == 0));

        let features = FontSpec::features_of(&["calt=1", "not a tag", "-calt", "ss01=2"]);
        assert_eq!(
            features
                .iter()
                .map(|held| (held.tag(), held.value()))
                .collect::<Vec<_>>(),
            vec![(*b"calt", 0), (*b"ss01", 2)],
            "the second `calt` replaces the first in place rather than being appended after it",
        );
    }

    /// A fresh install draws the factory family at the factory size in the face's own cell, with
    /// nothing switched on that a user did not ask for.
    #[test]
    fn a_default_spec_is_the_factory_face_and_nothing_else() {
        let spec = FontSpec::default();
        assert_eq!(spec.family, super::FACTORY_FONT_FAMILY);
        assert!(spec.bold.is_empty() && spec.italic.is_empty() && spec.bold_italic.is_empty());
        assert!(spec.fallback.is_empty() && spec.features.is_empty());
        assert!(!spec.thicken);
    }

    /// A number as the settings file spells it.
    fn format_size(value: f64) -> String {
        number_text(value, CONFIG_INTEGRAL_LIMIT)
    }

    #[test]
    fn the_two_limits_differ_only_where_an_integer_stops_being_written_as_one() {
        // A settings value in the range a user types reads the same at either limit.
        for value in [13.0, 14.5, 0.6, 60.0, 1.0] {
            assert_eq!(
                format_size(value),
                number_text(value, ENV_INTEGRAL_LIMIT),
                "{value}"
            );
        }
        // A millisecond count past a billion is still a count at the env limit, and stops being
        // written as one at the config limit — the one place the two answers part.
        assert_eq!(number_text(2e9, ENV_INTEGRAL_LIMIT), "2000000000");
        assert_eq!(format_size(2e9), "2000000000.0");
    }

    #[test]
    fn an_integral_number_is_written_without_a_point() {
        assert_eq!(format_size(13.0), "13");
        assert_eq!(format_size(14.5), "14.5");
        assert_eq!(format_size(0.6), "0.6");
        assert_eq!(format_size(-0.0), "0");
        assert_eq!(format_size(f64::NAN), "nan");
        assert_eq!(format_size(f64::INFINITY), "inf");
        assert_eq!(format_size(f64::NEG_INFINITY), "-inf");
    }
}
