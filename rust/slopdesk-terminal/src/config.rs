//! The `ghostty` config-file text one set of terminal preferences spells.
//!
//! Upstream Ghostty's `key = value` config vocabulary is one this project deliberately still speaks
//! — the same newline-separated syntax a `~/.config/ghostty/config` file holds. This builds that
//! text: every rule about which key a preference maps to, which value is skipped rather than
//! emitted blank, and what ORDER the lines arrive in lives here, because the order is load-bearing
//! — `background` after `theme` is what makes the explicit colour win, and the palette after
//! `foreground` is what makes the theme's sixteen entries win over both.
//!
//! ## What the caller resolves and what this resolves
//! Preferences are enums on the near side, bound to a UI and to persistence, and they cross as the
//! raw values they persist as — `"primary-only"`, `"macos-like"`, `"block_hollow"`. Turning one of
//! those into the `ghostty` config key it actuates is this module's job, not the caller's: the near
//! side hands over what the user picked, and every token this text carries is written here. An
//! unrecognised raw value takes the branch that emits NOTHING, which is what a preference that
//! predates or postdates this build should do.
//!
//! ## Absent, empty, and zero
//! An empty family, theme or colour is SKIPPED rather than emitted blank: `font-family =` with
//! nothing after it clears `ghostty`'s own default instead of leaving it alone, so "unset" has to
//! mean "no line". That is why every optional text field can cross as an empty string — empty
//! already means absent for all of them. The two fields where absent and present-but-empty would
//! differ are the cell-height percent, which crosses as an [`Option`], and the control block, which
//! crosses as one too: a build with no controls is byte-for-byte the build from before controls
//! existed.

use crate::keybind::trim_config_spaces;

/// The per-line byte estimate that converts the user's "scrollback lines" into `ghostty`'s BYTE
/// `scrollback-limit`. Generous, so the user gets at least the lines they asked for.
pub const BYTES_PER_SCROLLBACK_LINE: i64 = 256;

/// How many entries a palette must declare — the ANSI indices 0 through 15 — before any of it is
/// emitted.
pub const PALETTE_COUNT: usize = 16;

/// The font half of the preferences.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct FontSettings<'a> {
    /// The primary family. Empty skips the whole family chain, fallbacks included.
    pub family: &'a str,
    /// The fallback families, comma-separated, in order. Each becomes its own repeated
    /// `font-family` line, because `ghostty` has no `font-family-fallback` key.
    pub fallback: &'a str,
    /// The weight token (`font-style`). Empty emits no line.
    pub weight: &'a str,
    /// Point size.
    pub size: f64,
    /// An explicit bold face family, honoured only when [`Self::auto_match_weight_style`] is off.
    pub family_bold: &'a str,
    /// An explicit italic face family, under the same gate.
    pub family_italic: &'a str,
    /// An explicit bold-italic face family, under the same gate.
    pub family_bold_italic: &'a str,
    /// Whether the real bold/italic faces are picked automatically. On, the three explicit families
    /// are not emitted at all — the UI only offers them when it is off.
    pub auto_match_weight_style: bool,
    /// The ligature mode: `off`, `calt` or `dlig`.
    pub ligatures: &'a str,
    /// Whether ligation extends to alphabetic runs. Only meaningful while ligatures are on.
    pub ligatures_alphabet: bool,
    /// The bold face mode: `auto`, `off`, `primary-only` or `synthetic`.
    pub bold: &'a str,
    /// The italic face mode, from the same vocabulary.
    pub italic: &'a str,
    /// The glyph blending mode: `default` or `macos-like`.
    pub blending: &'a str,
    /// The `adjust-cell-height` percent, or [`None`] to leave the cell height to the font. The
    /// caller resolves its own line-height mode to this number because the mode has a second reader
    /// on that side; the clamp and the formatting are here.
    pub cell_height_percent: Option<f64>,
}

/// The colour half.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ColorSettings<'a> {
    /// A named theme. Empty emits no line — named themes are not bundled, so the explicit colours
    /// below are the whole theme.
    pub theme: &'a str,
    /// The surface background, 6-hex without a leading `#`.
    pub background: &'a str,
    /// The text colour, same form.
    pub foreground: &'a str,
    /// The active theme's background, which REPLACES [`Self::background`] when non-empty.
    pub background_override: &'a str,
    /// The active theme's foreground, under the same rule.
    pub foreground_override: &'a str,
    /// The sixteen ANSI palette entries. Any count other than [`PALETTE_COUNT`], or any entry that
    /// is not clean 6-hex, drops the palette WHOLE rather than emitting the good half.
    pub palette: &'a [&'a str],
    /// The selection fill, 6-hex. Empty or malformed emits no line; the paired
    /// `selection-foreground` always emits, because a cell keeping its own glyph colour under the
    /// highlight is not a preference.
    pub selection_background: &'a str,
}

/// The cursor half.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct CursorSettings<'a> {
    /// The style token, already a `ghostty` config value (`block`, `block_hollow`, `bar`,
    /// `underline`).
    pub style: &'a str,
    /// The blink tri-state: `on` and `off` emit the explicit bool, anything else — `default`
    /// included — emits no line and leaves the decision to DEC mode 12.
    pub blink: &'a str,
    /// The caret colour, 6-hex. Empty follows the foreground.
    pub color: &'a str,
    /// The glyph colour under the caret. Empty follows the background.
    pub text_color: &'a str,
    /// The caret opacity. Always emitted — it is a number, so it has no "unset".
    pub opacity: f64,
}

/// The control passthrough block: what the pointer, the clipboard and the selection do.
///
/// Present as a whole or not at all. Every token field is already a `ghostty` config value,
/// resolved by the caller from a multi-state preference the way
/// [`FontSettings::cell_height_percent`] is.
#[expect(
    clippy::struct_excessive_bools,
    reason = "each is one switch in the Controls pane, and they combine rather than exclude"
)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Controls<'a> {
    /// Selecting text copies it to the pasteboard.
    pub copy_on_select: bool,
    /// A copy drops the trailing spaces of each line.
    pub trim_trailing: bool,
    /// Typing clears the selection.
    pub clear_on_typing: bool,
    /// Copying clears the selection.
    pub clear_on_copy: bool,
    /// A paste that looks dangerous is confirmed first.
    pub paste_protection: bool,
    /// A bracketed paste is treated as safe.
    pub bracketed_safe: bool,
    /// The OSC 52 READ token: `allow`, `deny` or `ask`.
    pub clipboard_read: &'a str,
    /// The OSC 52 WRITE token, same vocabulary.
    pub clipboard_write: &'a str,
    /// The pointer hides while typing.
    pub hide_mouse_while_typing: bool,
    /// The `mouse-shift-capture` token: `false`, `true`, `always` or `never`.
    pub mouse_shift_capture: &'a str,
    /// A click moves the shell's caret.
    pub click_to_move: bool,
    /// A program may capture the mouse.
    pub allow_mouse_capture: bool,
    /// The `right-click-action` token. The deleted libghostty fork owned the bare right click end
    /// to end once this crossed to it; with the fork gone,
    /// `crate::surface::right_click_intercepts_as_paste` reads the same token directly to make
    /// the one decision (paste vs. forward) that still needs a pre-click answer.
    pub right_click_action: &'a str,
    /// Shift with an arrow adjusts the selection. Off does not mean "emit nothing" — the vendored
    /// fork binds these by default, so off has to unbind them or the arrows never reach the
    /// program.
    pub shift_arrow_select: bool,
    /// The scroll multiplier. It drives BOTH axes while keeping `ghostty`'s own 1:3 ratio between
    /// them, so the default multiplier reproduces stock scrolling rather than a third of it.
    pub scroll_multiplier: f64,
    /// The `macos-option-as-alt` token: `false`, `true`, `left` or `right`.
    pub macos_option_as_alt: &'a str,
}

/// One terminal's whole configuration.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct TerminalConfig<'a> {
    /// The font settings.
    pub font: FontSettings<'a>,
    /// The colour settings.
    pub colors: ColorSettings<'a>,
    /// The cursor settings.
    pub cursor: CursorSettings<'a>,
    /// The scrollback depth in LINES. Non-positive means none; the conversion to bytes is here.
    pub scrollback_lines: i64,
    /// The user's own `keybind` lines, appended verbatim. One whose trimmed form is empty is
    /// skipped.
    pub keybinds: &'a [&'a str],
    /// The control block, or [`None`] for a build that emits none of it.
    pub controls: Option<Controls<'a>>,
}

/// The preferences a FRESH INSTALL carries.
///
/// These are the product defaults, and they are here rather than at the caller because the caller
/// is a Swift `init`'s default arguments and a Rust test fixture, which used to spell the same six
/// values apiece with nothing connecting the two lists. A default IS a rule: it decides what the
/// terminal looks like for everyone who never opens Settings.
///
/// Every field not named here is the type's own [`Default`] — an empty string or a false, which is
/// "the user has not chosen" rather than a value anyone picked.
#[must_use]
pub const fn factory<'a>() -> TerminalConfig<'a> {
    TerminalConfig {
        font: FontSettings {
            family: FACTORY_FONT_FAMILY,
            weight: FACTORY_FONT_WEIGHT,
            size: FACTORY_FONT_SIZE,
            auto_match_weight_style: true,
            ligatures: "off",
            bold: "auto",
            italic: "auto",
            blending: "default",
            fallback: "",
            family_bold: "",
            family_italic: "",
            family_bold_italic: "",
            ligatures_alphabet: false,
            cell_height_percent: None,
        },
        colors: ColorSettings {
            background: FACTORY_BACKGROUND,
            foreground: FACTORY_FOREGROUND,
            theme: "",
            background_override: "",
            foreground_override: "",
            palette: &[],
            selection_background: "",
        },
        cursor: CursorSettings {
            style: "block",
            blink: "default",
            opacity: FACTORY_CURSOR_OPACITY,
            color: "",
            text_color: "",
        },
        scrollback_lines: FACTORY_SCROLLBACK_LINES,
        keybinds: &[],
        controls: None,
    }
}

/// The primary font family a fresh install carries.
pub const FACTORY_FONT_FAMILY: &str = "SF Mono";
/// The weight token a fresh install carries.
pub const FACTORY_FONT_WEIGHT: &str = "regular";
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

/// The `ghostty` config-file text for `config`.
///
/// The lines arrive in one fixed order — font, then theme and colours, then cursor, then the
/// structural facts, then keybinds, then controls — and the same input always spells the same
/// bytes, so a caller can compare two builds to decide whether the surface needs reloading.
#[must_use]
pub fn config_string(config: &TerminalConfig<'_>) -> String {
    let mut lines: Vec<String> = Vec::new();
    append_font(&mut lines, &config.font);
    append_colors(&mut lines, &config.colors);
    append_cursor(&mut lines, &config.cursor);
    lines.push(format!(
        "scrollback-limit = {}",
        scrollback_limit_bytes(config.scrollback_lines)
    ));
    // SlopDesk detects, highlights and opens links itself (`TerminalLinkDetector`, already Rust per
    // `docs/68`), so turning on `ghostty`'s own built-in regex link matcher would only draw a
    // second underline under the same span. OSC 8 hyperlinks are a different set and are
    // untouched. A structural fact about who owns link rendering, not a preference.
    lines.push("link-url = false".to_owned());
    // A pane's viewport is never an exact multiple of the cell size, and the default dumps the
    // whole remainder on the right and bottom, which reads as an off-centre grid inside an even
    // gutter. Also structural: no preference gates it.
    lines.push("window-padding-balance = true".to_owned());
    for keybind in config.keybinds {
        if !trim_config_spaces(keybind).is_empty() {
            lines.push(format!("keybind = {keybind}"));
        }
    }
    if let Some(controls) = config.controls {
        append_controls(&mut lines, &controls, &config.cursor);
    }
    lines.join("\n")
}

/// The BYTE `scrollback-limit` a line count asks for. A non-positive count is none rather than a
/// trap, and the multiply wraps rather than panicking on a count no buffer could hold.
#[must_use]
pub const fn scrollback_limit_bytes(lines: i64) -> i64 {
    let safe = if lines > 0 { lines } else { 0 };
    safe.wrapping_mul(BYTES_PER_SCROLLBACK_LINE)
}

/// Whether `value` is a 6-digit hex colour with no leading `#`.
///
/// `ghostty`'s colour type is RGB with no alpha, so an 8-digit `rrggbbaa` is not a long form of
/// the same colour — it is a value the parser rejects, and one this drops before it can.
#[must_use]
pub fn is_valid_hex(value: &str) -> bool {
    value.len() == 6 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// The fallback families a comma-separated list names, trimmed, in order, with the empty ones
/// dropped — so `"PingFang SC, , Symbols Nerd Font"` names two.
fn fallback_families(raw: &str) -> impl Iterator<Item = &str> {
    raw.split(',')
        .map(trim_config_spaces)
        .filter(|name| !name.is_empty())
}

/// The font lines: the family chain, the size, the weight, and the parity block.
fn append_font(lines: &mut Vec<String>, font: &FontSettings<'_>) {
    // The primary family leads, and the fallbacks are repeated `font-family` lines after it. An
    // empty primary suppresses the chain entirely, because the FIRST such line is the primary and
    // there is no way to spell "no primary, these fallbacks".
    let family = trim_config_spaces(font.family);
    if !family.is_empty() {
        lines.push(format!("font-family = {family}"));
        for fallback in fallback_families(font.fallback) {
            lines.push(format!("font-family = {fallback}"));
        }
    }
    lines.push(format!("font-size = {}", format_size(font.size)));
    let weight = trim_config_spaces(font.weight);
    if !weight.is_empty() {
        lines.push(format!("font-style = {weight}"));
    }
    append_font_parity(lines, font);
}

/// The parity block — the per-face families, the ligature features, the face modes, the cell height
/// and the thickening.
fn append_font_parity(lines: &mut Vec<String>, font: &FontSettings<'_>) {
    if !font.auto_match_weight_style {
        for (key, family) in [
            ("font-family-bold", font.family_bold),
            ("font-family-italic", font.family_italic),
            ("font-family-bold-italic", font.family_bold_italic),
        ] {
            let face = trim_config_spaces(family);
            if !face.is_empty() {
                lines.push(format!("{key} = {face}"));
            }
        }
    }
    // `font-feature` is the one key emitted unconditionally. Fonts that ship programming ligatures
    // turn `calt` on in their own GSUB table, so "ligatures off" has to SAY so — emitting nothing
    // would leave them ligated.
    let mut features: Vec<&str> = match font.ligatures {
        "calt" => vec!["calt"],
        "dlig" => vec!["calt", "dlig"],
        // `off`, and anything this build does not recognise, disables.
        _ => vec!["-calt", "-liga", "-dlig"],
    };
    if font.ligatures != "off" && font.ligatures_alphabet {
        features.push("liga");
    }
    lines.push(format!("font-feature = {}", features.join(",")));
    // A face mode either disables the face outright or contributes a token to the SINGLE combined
    // synthetic-style key; `auto` does neither.
    for (kind, mode) in [("bold", font.bold), ("italic", font.italic)] {
        if mode == "off" {
            lines.push(format!("font-style-{kind} = false"));
        }
    }
    let mut synthetic: Vec<String> = Vec::new();
    for (kind, mode) in [("bold", font.bold), ("italic", font.italic)] {
        match mode {
            // Disable synthesis for this style: the flag set seeds from all-true and only the named
            // flag flips, so this is "the primary face or nothing".
            "primary-only" => synthetic.push(format!("no-{kind}")),
            // Re-assert the default-on synthesis. `ghostty` would synthesize anyway; the explicit
            // token makes the choice self-documenting and survives a future default flip.
            "synthetic" => synthetic.push(kind.to_owned()),
            _ => {},
        }
    }
    if !synthetic.is_empty() {
        lines.push(format!("font-synthetic-style = {}", synthetic.join(",")));
    }
    if let Some(percent) = font.cell_height_percent {
        lines.push(format!(
            "adjust-cell-height = {}%",
            format_size(clamp_cell_height_percent(percent))
        ));
    }
    if font.blending == "macos-like" {
        lines.push("font-thicken = true".to_owned());
    }
}

/// The theme, the two colours that override it, the palette and the selection.
fn append_colors(lines: &mut Vec<String>, colors: &ColorSettings<'_>) {
    let theme = trim_config_spaces(colors.theme);
    if !theme.is_empty() {
        lines.push(format!("theme = {theme}"));
    }
    // After the theme, so they win over it — which is what actually pins the surface, since a named
    // theme is not bundled and will not resolve.
    let background = resolved(colors.background_override, colors.background);
    if !background.is_empty() {
        lines.push(format!("background = {background}"));
    }
    let foreground = resolved(colors.foreground_override, colors.foreground);
    if !foreground.is_empty() {
        lines.push(format!("foreground = {foreground}"));
    }
    if colors.palette.len() == PALETTE_COUNT && colors.palette.iter().all(|hex| is_valid_hex(hex)) {
        for (index, hex) in colors.palette.iter().enumerate() {
            lines.push(format!("palette = {index}={hex}"));
        }
    }
    // Keep each cell's own glyph colour under the selection fill. The default path uses the WINDOW
    // background as the foreground, which reads as an invert of the whole span.
    lines.push("selection-foreground = cell-foreground".to_owned());
    let selection = trim_config_spaces(colors.selection_background);
    if is_valid_hex(selection) {
        lines.push(format!("selection-background = {selection}"));
    }
}

/// The cursor style and its optional blink.
fn append_cursor(lines: &mut Vec<String>, cursor: &CursorSettings<'_>) {
    lines.push(format!("cursor-style = {}", cursor.style));
    // `ghostty`'s blink is an optional bool: no line is the third state, and it means the program
    // decides through DEC mode 12.
    match cursor.blink {
        "on" => lines.push("cursor-style-blink = true".to_owned()),
        "off" => lines.push("cursor-style-blink = false".to_owned()),
        _ => {},
    }
}

/// The control block, in the order the Controls pane reads top to bottom.
fn append_controls(lines: &mut Vec<String>, controls: &Controls<'_>, cursor: &CursorSettings<'_>) {
    // `copy-on-select` is a tri-state, not a bool: on names the pasteboard it copies to.
    lines.push(format!(
        "copy-on-select = {}",
        if controls.copy_on_select {
            "clipboard"
        } else {
            "false"
        }
    ));
    for (key, flag) in [
        ("clipboard-trim-trailing-spaces", controls.trim_trailing),
        ("selection-clear-on-typing", controls.clear_on_typing),
        ("selection-clear-on-copy", controls.clear_on_copy),
        ("clipboard-paste-protection", controls.paste_protection),
        ("clipboard-paste-bracketed-safe", controls.bracketed_safe),
    ] {
        lines.push(format!("{key} = {}", bool_token(flag)));
    }
    lines.push(format!("clipboard-read = {}", controls.clipboard_read));
    lines.push(format!("clipboard-write = {}", controls.clipboard_write));
    lines.push(format!(
        "mouse-hide-while-typing = {}",
        bool_token(controls.hide_mouse_while_typing)
    ));
    lines.push(format!("mouse-shift-capture = {}", controls.mouse_shift_capture));
    lines.push(format!(
        "cursor-click-to-move = {}",
        bool_token(controls.click_to_move)
    ));
    lines.push(format!(
        "mouse-reporting = {}",
        bool_token(controls.allow_mouse_capture)
    ));
    lines.push(format!("right-click-action = {}", controls.right_click_action));
    // One multiplier, both axes, and `ghostty`'s own 1:3 ratio between them preserved — the
    // discrete factor is three times the precision one, so the default multiplier reproduces stock
    // wheel scrolling instead of a third of it. A plain multiply, never fused.
    let precision = format_size(controls.scroll_multiplier);
    let discrete = format_size(controls.scroll_multiplier * 3.0);
    lines.push(format!(
        "mouse-scroll-multiplier = precision:{precision},discrete:{discrete}"
    ));
    lines.push(format!("macos-option-as-alt = {}", controls.macos_option_as_alt));
    // The cursor colours ride the control block rather than the render lines, under the same
    // "empty means follow the theme" rule as background and foreground. The opacity is a number, so
    // it always emits.
    let color = trim_config_spaces(cursor.color);
    if !color.is_empty() {
        lines.push(format!("cursor-color = {color}"));
    }
    let text = trim_config_spaces(cursor.text_color);
    if !text.is_empty() {
        lines.push(format!("cursor-text = {text}"));
    }
    lines.push(format!("cursor-opacity = {}", format_size(cursor.opacity)));
    // Off has to unbind rather than stay silent: the vendored fork binds these four by default, so
    // emitting nothing would leave the default live and the arrows would never reach the program.
    for direction in ["left", "right", "up", "down"] {
        let action = if controls.shift_arrow_select {
            format!("adjust_selection:{direction}")
        } else {
            "unbind".to_owned()
        };
        lines.push(format!("keybind = shift+{direction}={action}"));
    }
}

/// The override if it has anything in it, else the fallback — both trimmed, so an override of
/// nothing but spaces keeps the colour it was meant to replace.
fn resolved<'a>(over: &'a str, fallback: &'a str) -> &'a str {
    let trimmed = trim_config_spaces(over);
    if trimmed.is_empty() {
        trim_config_spaces(fallback)
    } else {
        trimmed
    }
}

/// The `true` / `false` token a `ghostty` config boolean takes.
const fn bool_token(flag: bool) -> &'static str {
    if flag { "true" } else { "false" }
}

/// A clamp of a cell-height percent into a band a cell can survive — roughly a half-height to a
/// triple-height cell.
///
/// The bounds are IEEE minimum and maximum, which return the other operand when one is NaN, so a
/// NaN multiplier resolves to the upper bound rather than crossing into the config text as `nan%`.
/// That is the wanted behaviour HERE, where the question is "what number does a nonsense multiplier
/// become"; it is the opposite of what an ordered comparison would do, and the opposite of what a
/// reprojection window wants, where a NaN must pass through rather than be swallowed.
/// Not `f64::clamp`, which PROPAGATES a NaN input — the one answer this must not give.
#[must_use]
pub const fn clamp_cell_height_percent(percent: f64) -> f64 {
    percent.min(200.0).max(-50.0)
}

/// The limit past which a config value stops being written as a plain integer. A point size, a
/// percent or a multiplier never comes near it.
pub const CONFIG_INTEGRAL_LIMIT: f64 = 1e9;

/// The limit for an environment value, which carries milliseconds as well as ratios and so is given
/// the whole range a `Double` spells exactly.
pub const ENV_INTEGRAL_LIMIT: f64 = 1e15;

/// A number as a config value spells it, at the config limit.
fn format_size(value: f64) -> String {
    number_text(value, CONFIG_INTEGRAL_LIMIT)
}

/// A number as a settings value spells it: integral values without a decimal point, everything else
/// as the shortest text that reads back as the same number.
///
/// One spelling, two limits. The `ghostty` config text and the `SLOPDESK_*` env overlay ask the
/// same question — "what does a user type for this number" — and answer it identically inside their
/// own range; only where an integer stops being written as one do they differ, so the limit is the
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
    use super::{
        Controls, ENV_INTEGRAL_LIMIT, config_string, factory, format_size, is_valid_hex, number_text,
        scrollback_limit_bytes,
    };

    /// The value one key carries in a built config.
    fn value<'a>(config: &'a str, key: &str) -> Option<&'a str> {
        config
            .lines()
            .find_map(|line| line.strip_prefix(key)?.strip_prefix(" = "))
    }

    #[test]
    fn the_factory_preferences_spell_exactly_these_lines() {
        let config = config_string(&factory());
        assert_eq!(
            config,
            "font-family = SF Mono\nfont-size = 13\nfont-style = regular\nfont-feature = \
             -calt,-liga,-dlig\nbackground = 22212C\nforeground = F8F8F2\nselection-foreground = \
             cell-foreground\ncursor-style = block\nscrollback-limit = 2560000\nlink-url = \
             false\nwindow-padding-balance = true"
        );
    }

    #[test]
    fn an_empty_family_takes_the_fallback_chain_with_it() {
        let mut config = factory();
        config.font.family = "  ";
        config.font.fallback = "PingFang SC, , Symbols Nerd Font";
        assert!(!config_string(&config).contains("font-family"));
        config.font.family = "JetBrains Mono";
        let built = config_string(&config);
        let families: Vec<&str> = built
            .lines()
            .filter_map(|line| line.strip_prefix("font-family = "))
            .collect();
        assert_eq!(
            families,
            ["JetBrains Mono", "PingFang SC", "Symbols Nerd Font"],
            "the primary leads and each non-empty fallback repeats the key"
        );
    }

    #[test]
    fn the_colour_that_overrides_the_theme_comes_after_it() {
        let mut config = factory();
        config.colors.theme = "Light";
        config.colors.background_override = "2D2A2E";
        config.colors.foreground_override = "   ";
        let built = config_string(&config);
        let theme = built.lines().position(|line| line.starts_with("theme = "));
        let background = built.lines().position(|line| line.starts_with("background = "));
        assert!(theme < background, "background must be able to win");
        assert_eq!(value(&built, "background"), Some("2D2A2E"));
        assert_eq!(
            value(&built, "foreground"),
            Some("F8F8F2"),
            "an override of nothing but spaces keeps the colour it would have replaced"
        );
    }

    #[test]
    fn a_palette_is_emitted_whole_or_not_at_all() {
        let good = ["FF6188"; 16];
        let mut config = factory();
        config.colors.palette = &good;
        let built = config_string(&config);
        assert_eq!(built.lines().filter(|l| l.starts_with("palette = ")).count(), 16);
        assert!(built.contains("palette = 0=FF6188"));
        assert!(built.contains("palette = 15=FF6188"));

        let short = ["FF6188"; 15];
        config.colors.palette = &short;
        assert!(!config_string(&config).contains("palette = "));

        let mut bad = ["FF6188"; 16];
        bad[7] = "#GG0000";
        config.colors.palette = &bad;
        assert!(
            !config_string(&config).contains("palette = "),
            "one bad entry drops the palette rather than half of it"
        );
    }

    #[test]
    fn an_eight_digit_selection_colour_is_not_a_long_form_of_a_six_digit_one() {
        assert!(is_valid_hex("403E41"));
        assert!(!is_valid_hex("FFFFFF30"), "there is no alpha channel to take");
        assert!(!is_valid_hex("#GG0000"));
        assert!(!is_valid_hex("nope"));
        let mut config = factory();
        config.colors.selection_background = "FFFFFF30";
        let built = config_string(&config);
        assert!(!built.contains("selection-background"));
        assert!(
            built.contains("selection-foreground = cell-foreground"),
            "the paired line is unconditional"
        );
    }

    #[test]
    fn the_blink_that_is_neither_on_nor_off_writes_no_line() {
        let mut config = factory();
        for (blink, expected) in [
            ("default", None),
            ("on", Some("true")),
            ("off", Some("false")),
            // A raw value from a build that is not this one takes the same branch as `default`.
            ("sometimes", None),
        ] {
            config.cursor.blink = blink;
            assert_eq!(
                value(&config_string(&config), "cursor-style-blink"),
                expected,
                "blink {blink}"
            );
        }
    }

    #[test]
    fn the_face_modes_collapse_into_one_synthetic_key() {
        let mut config = factory();
        config.font.bold = "primary-only";
        config.font.italic = "synthetic";
        let built = config_string(&config);
        assert_eq!(value(&built, "font-synthetic-style"), Some("no-bold,italic"));
        assert!(!built.contains("font-style-bold"));

        config.font.bold = "off";
        config.font.italic = "off";
        let disabled = config_string(&config);
        assert_eq!(value(&disabled, "font-style-bold"), Some("false"));
        assert_eq!(value(&disabled, "font-style-italic"), Some("false"));
        assert!(
            !disabled.contains("font-synthetic-style"),
            "a disabled face is disabled, not synthesized"
        );
    }

    #[test]
    fn ligatures_off_says_so_because_a_font_may_ligate_on_its_own() {
        let mut config = factory();
        for (mode, alphabet, expected) in [
            ("off", false, "-calt,-liga,-dlig"),
            ("off", true, "-calt,-liga,-dlig"),
            ("calt", false, "calt"),
            ("calt", true, "calt,liga"),
            ("dlig", false, "calt,dlig"),
            ("dlig", true, "calt,dlig,liga"),
        ] {
            config.font.ligatures = mode;
            config.font.ligatures_alphabet = alphabet;
            assert_eq!(
                value(&config_string(&config), "font-feature"),
                Some(expected),
                "{mode} with alphabet {alphabet}"
            );
        }
    }

    #[test]
    fn a_cell_height_a_cell_could_not_survive_lands_on_a_bound() {
        let mut config = factory();
        for (percent, expected) in [
            (0.0, "0%"),
            (20.0, "20%"),
            (50.0, "50%"),
            (-50.0, "-50%"),
            (9800.0, "200%"),
            (-1000.0, "-50%"),
            // A nonsense multiplier becomes the upper bound, never `nan%`.
            (f64::NAN, "200%"),
        ] {
            config.font.cell_height_percent = Some(percent);
            assert_eq!(
                value(&config_string(&config), "adjust-cell-height"),
                Some(expected),
                "percent {percent}"
            );
        }
        config.font.cell_height_percent = None;
        assert!(!config_string(&config).contains("adjust-cell-height"));
    }

    #[test]
    fn the_scroll_multiplier_keeps_the_ratio_between_the_two_axes() {
        let mut config = factory();
        config.controls = Some(Controls {
            scroll_multiplier: 1.0,
            clipboard_read: "ask",
            clipboard_write: "allow",
            mouse_shift_capture: "false",
            right_click_action: "context-menu",
            macos_option_as_alt: "false",
            ..Controls::default()
        });
        assert_eq!(
            value(&config_string(&config), "mouse-scroll-multiplier"),
            Some("precision:1,discrete:3"),
            "the default multiplier reproduces stock scrolling, not a third of it"
        );
        if let Some(controls) = config.controls.as_mut() {
            controls.scroll_multiplier = 2.5;
        }
        assert_eq!(
            value(&config_string(&config), "mouse-scroll-multiplier"),
            Some("precision:2.5,discrete:7.5")
        );
    }

    #[test]
    fn a_selection_arrow_that_is_off_is_unbound_rather_than_unmentioned() {
        let mut config = factory();
        config.controls = Some(Controls {
            shift_arrow_select: true,
            ..Controls::default()
        });
        let on = config_string(&config);
        assert!(on.contains("keybind = shift+left=adjust_selection:left"));
        assert!(on.contains("keybind = shift+down=adjust_selection:down"));
        if let Some(controls) = config.controls.as_mut() {
            controls.shift_arrow_select = false;
        }
        let off = config_string(&config);
        assert!(
            off.contains("keybind = shift+left=unbind"),
            "the fork binds these by default, so off has to say unbind"
        );
    }

    #[test]
    fn a_build_with_no_controls_is_the_build_from_before_controls_existed() {
        let mut config = factory();
        config.keybinds = &["cmd+d=new_split:right"];
        let bare = config_string(&config);
        config.controls = Some(Controls::default());
        let with = config_string(&config);
        assert!(with.starts_with(&bare), "the control block only ever appends");
        for key in [
            "copy-on-select",
            "clipboard-read",
            "mouse-reporting",
            "cursor-opacity",
        ] {
            assert!(!bare.contains(key), "{key} must be absent without controls");
        }
    }

    #[test]
    fn a_keybind_of_nothing_but_spaces_is_not_a_keybind() {
        let mut config = factory();
        config.keybinds = &["cmd+d=new_split:right", "  ", "cmd+w=close_surface"];
        let built = config_string(&config);
        let binds: Vec<&str> = built
            .lines()
            .filter_map(|line| line.strip_prefix("keybind = "))
            .collect();
        assert_eq!(binds, ["cmd+d=new_split:right", "cmd+w=close_surface"]);
    }

    #[test]
    fn a_scrollback_no_buffer_could_hold_is_none_rather_than_a_trap() {
        assert_eq!(scrollback_limit_bytes(0), 0);
        assert_eq!(scrollback_limit_bytes(-5), 0);
        assert_eq!(scrollback_limit_bytes(1), 256);
        assert_eq!(scrollback_limit_bytes(10_000), 2_560_000);
        // The wrap is the documented answer, not a panic in a release build and a panic in a debug
        // one.
        assert_eq!(scrollback_limit_bytes(i64::MAX), i64::MAX.wrapping_mul(256));
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
