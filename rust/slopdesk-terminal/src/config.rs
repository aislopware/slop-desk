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
    use super::{CONFIG_INTEGRAL_LIMIT, ENV_INTEGRAL_LIMIT, number_text};

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
