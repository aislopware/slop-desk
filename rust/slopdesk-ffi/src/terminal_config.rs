//! The libghostty config text one set of terminal preferences spells.
//!
//! Wraps [`slopdesk_terminal::config`]. The preferences are two dozen strings and a dozen switches,
//! so rather than two dozen `(ptr, len)` pairs they cross as ONE record of named
//! `(offset, length)` runs into a single blob the caller interns — the same shape the keybind door
//! uses for its three runs, widened. The two LISTS, the user's keybind lines and the theme's
//! sixteen palette entries, cross as arrays of those runs rather than as one delimited blob,
//! because a delimiter is a thing a value could contain and a count is not.
//!
//! The answer is text, and it crosses the way every text answer here does: the call reports how
//! many bytes it needs and writes them only if the lent buffer holds them.

use core::ffi::c_uchar;

use slopdesk_terminal::config::{
    ColorSettings, Controls, CursorSettings, ENV_INTEGRAL_LIMIT, FontSettings, TerminalConfig, config_string,
    number_text,
};

use crate::{borrow, deliver, records_of};

/// One run of bytes inside the caller's blob.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskConfigRun {
    /// Where the run starts.
    pub offset: u32,
    /// How many bytes it is.
    pub length: u32,
}

/// The font preferences.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskTerminalFont {
    /// The primary family.
    pub family: SlopDeskConfigRun,
    /// The comma-separated fallback chain.
    pub fallback: SlopDeskConfigRun,
    /// The weight token.
    pub weight: SlopDeskConfigRun,
    /// An explicit bold face family.
    pub family_bold: SlopDeskConfigRun,
    /// An explicit italic face family.
    pub family_italic: SlopDeskConfigRun,
    /// An explicit bold-italic face family.
    pub family_bold_italic: SlopDeskConfigRun,
    /// The ligature mode, as the near side persists it.
    pub ligatures: SlopDeskConfigRun,
    /// The bold face mode.
    pub bold: SlopDeskConfigRun,
    /// The italic face mode.
    pub italic: SlopDeskConfigRun,
    /// The glyph blending mode.
    pub blending: SlopDeskConfigRun,
    /// The point size.
    pub size: f64,
    /// The cell-height percent, meaningful only when `has_cell_height`.
    pub cell_height_percent: f64,
    /// Whether the real faces are matched automatically.
    pub auto_match_weight_style: bool,
    /// Whether ligation extends to alphabetic runs.
    pub ligatures_alphabet: bool,
    /// Whether a cell-height percent was given at all. An absent one is a FLAG, not a sentinel:
    /// zero percent is a real answer — it is what "tight" asks for.
    pub has_cell_height: bool,
}

/// The colour preferences.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskTerminalColors {
    /// A named theme.
    pub theme: SlopDeskConfigRun,
    /// The surface background.
    pub background: SlopDeskConfigRun,
    /// The text colour.
    pub foreground: SlopDeskConfigRun,
    /// The active theme's background, which replaces the one above when non-empty.
    pub background_override: SlopDeskConfigRun,
    /// The active theme's foreground, under the same rule.
    pub foreground_override: SlopDeskConfigRun,
    /// The selection fill.
    pub selection_background: SlopDeskConfigRun,
}

/// The cursor preferences.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskTerminalCursor {
    /// The style token.
    pub style: SlopDeskConfigRun,
    /// The blink tri-state, as the near side persists it.
    pub blink: SlopDeskConfigRun,
    /// The caret colour.
    pub color: SlopDeskConfigRun,
    /// The glyph colour under the caret.
    pub text_color: SlopDeskConfigRun,
    /// The caret opacity.
    pub opacity: f64,
}

/// The control passthrough block.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskTerminalControls {
    /// The OSC 52 read token.
    pub clipboard_read: SlopDeskConfigRun,
    /// The OSC 52 write token.
    pub clipboard_write: SlopDeskConfigRun,
    /// The shift-capture token.
    pub mouse_shift_capture: SlopDeskConfigRun,
    /// The right-click action token.
    pub right_click_action: SlopDeskConfigRun,
    /// The Option-as-Alt token.
    pub macos_option_as_alt: SlopDeskConfigRun,
    /// The scroll multiplier, which drives both axes.
    pub scroll_multiplier: f64,
    /// Selecting copies.
    pub copy_on_select: bool,
    /// A copy drops trailing spaces.
    pub trim_trailing: bool,
    /// Typing clears the selection.
    pub clear_on_typing: bool,
    /// Copying clears the selection.
    pub clear_on_copy: bool,
    /// A dangerous paste is confirmed.
    pub paste_protection: bool,
    /// A bracketed paste is safe.
    pub bracketed_safe: bool,
    /// The pointer hides while typing.
    pub hide_mouse_while_typing: bool,
    /// A click moves the caret.
    pub click_to_move: bool,
    /// A program may capture the mouse.
    pub allow_mouse_capture: bool,
    /// Shift with an arrow adjusts the selection.
    pub shift_arrow_select: bool,
}

/// One terminal's whole configuration.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskTerminalConfig {
    /// The font preferences.
    pub font: SlopDeskTerminalFont,
    /// The colour preferences.
    pub colors: SlopDeskTerminalColors,
    /// The cursor preferences.
    pub cursor: SlopDeskTerminalCursor,
    /// The control block, meaningful only when `has_controls`.
    pub controls: SlopDeskTerminalControls,
    /// The scrollback depth in lines.
    pub scrollback_lines: i64,
    /// Whether the control block is present at all. Absent is not the same as a block of every
    /// switch off: absent emits none of those lines, which is what makes a build from a caller that
    /// has no controls byte-for-byte the build from before controls existed.
    pub has_controls: bool,
}

/// A FACTORY default that is a string, by index: 0 the font family, 1 the weight token, 2 the
/// background, 3 the foreground. Any other index answers empty.
///
/// The defaults cross as data rather than being retyped at the caller: they used to sit in a Swift
/// `init`'s default arguments AND in this crate's test fixture, six values apiece with nothing
/// connecting the two lists.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_terminal_factory_text(
    field: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let text = match field {
        0 => slopdesk_terminal::config::FACTORY_FONT_FAMILY,
        1 => slopdesk_terminal::config::FACTORY_FONT_WEIGHT,
        2 => slopdesk_terminal::config::FACTORY_BACKGROUND,
        3 => slopdesk_terminal::config::FACTORY_FOREGROUND,
        _ => "",
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

/// A FACTORY default that is a number, by index: 0 the point size, 1 the cursor opacity, 2 the
/// scrollback depth in lines. Any other index answers zero.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_terminal_factory_number(field: u8) -> f64 {
    match field {
        0 => slopdesk_terminal::config::FACTORY_FONT_SIZE,
        1 => slopdesk_terminal::config::FACTORY_CURSOR_OPACITY,
        #[expect(
            clippy::cast_precision_loss,
            reason = "a line count this small is exact in f64"
        )]
        2 => slopdesk_terminal::config::FACTORY_SCROLLBACK_LINES as f64,
        _ => 0.0,
    }
}

/// Writes the libghostty config text for `config` into the lent buffer.
///
/// Every run in `config` indexes `text`; the two lists index it too, through their own arrays. Call
/// once with a null buffer to learn the length, then again with that much room — a call that did
/// not fit writes nothing rather than a prefix.
///
/// # Safety
/// `text` must be live for `text_len` bytes for the call, each run array must be null or describe
/// its count of live entries, and `out` must be null or writable for `out_cap`.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_terminal_config_string(
    config: SlopDeskTerminalConfig,
    text: *const c_uchar,
    text_len: usize,
    keybinds: *const SlopDeskConfigRun,
    keybind_count: usize,
    palette: *const SlopDeskConfigRun,
    palette_count: usize,
    out: *mut c_uchar,
    out_cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated on `borrow`, `records_of` and `deliver`. Nothing
    // between them can invalidate a pointer: the call in the middle is pure and allocates its own
    // answer.
    unsafe {
        let blob = borrow(text, text_len);
        let keybind_runs = records_of(keybinds, keybind_count);
        let palette_runs = records_of(palette, palette_count);
        let keybind_lines: Vec<&str> = keybind_runs.iter().map(|run| run_text(blob, *run)).collect();
        let palette_entries: Vec<&str> = palette_runs.iter().map(|run| run_text(blob, *run)).collect();
        let built = config_string(&TerminalConfig {
            font: font_of(blob, config.font),
            colors: colors_of(blob, config.colors, &palette_entries),
            cursor: cursor_of(blob, config.cursor),
            scrollback_lines: config.scrollback_lines,
            keybinds: &keybind_lines,
            controls: config.has_controls.then(|| controls_of(blob, config.controls)),
        });
        deliver(built.as_bytes(), out, out_cap)
    }
}

/// Writes the text a `SLOPDESK_*` environment value is written with into the lent buffer.
///
/// One spelling, two limits. The libghostty config text asks this of itself, at its own limit; the
/// env overlay asks it here, at one that reaches as far as a millisecond count does. Both ask the
/// same question — what a user types for this number — so the rule is written once and the limit is
/// not a thing either side spells.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_settings_env_number_text(
    value: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let text = number_text(value, ENV_INTEGRAL_LIMIT);
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

/// One run's text. A run that leaves the blob, or that is not the UTF-8 the near side interned,
/// reads as empty — which every field here already spells "unset".
fn run_text(blob: &[u8], run: SlopDeskConfigRun) -> &str {
    let start = run.offset as usize;
    let end = start.saturating_add(run.length as usize);
    blob.get(start..end)
        .map_or("", |bytes| core::str::from_utf8(bytes).unwrap_or(""))
}

/// The font settings a record names.
fn font_of(blob: &[u8], font: SlopDeskTerminalFont) -> FontSettings<'_> {
    FontSettings {
        family: run_text(blob, font.family),
        fallback: run_text(blob, font.fallback),
        weight: run_text(blob, font.weight),
        size: font.size,
        family_bold: run_text(blob, font.family_bold),
        family_italic: run_text(blob, font.family_italic),
        family_bold_italic: run_text(blob, font.family_bold_italic),
        auto_match_weight_style: font.auto_match_weight_style,
        ligatures: run_text(blob, font.ligatures),
        ligatures_alphabet: font.ligatures_alphabet,
        bold: run_text(blob, font.bold),
        italic: run_text(blob, font.italic),
        blending: run_text(blob, font.blending),
        cell_height_percent: font.has_cell_height.then_some(font.cell_height_percent),
    }
}

/// The colour settings a record names, over the palette the caller lent.
fn colors_of<'a>(
    blob: &'a [u8],
    colors: SlopDeskTerminalColors,
    palette: &'a [&'a str],
) -> ColorSettings<'a> {
    ColorSettings {
        theme: run_text(blob, colors.theme),
        background: run_text(blob, colors.background),
        foreground: run_text(blob, colors.foreground),
        background_override: run_text(blob, colors.background_override),
        foreground_override: run_text(blob, colors.foreground_override),
        palette,
        selection_background: run_text(blob, colors.selection_background),
    }
}

/// The cursor settings a record names.
fn cursor_of(blob: &[u8], cursor: SlopDeskTerminalCursor) -> CursorSettings<'_> {
    CursorSettings {
        style: run_text(blob, cursor.style),
        blink: run_text(blob, cursor.blink),
        color: run_text(blob, cursor.color),
        text_color: run_text(blob, cursor.text_color),
        opacity: cursor.opacity,
    }
}

/// The control block a record names.
fn controls_of(blob: &[u8], controls: SlopDeskTerminalControls) -> Controls<'_> {
    Controls {
        copy_on_select: controls.copy_on_select,
        trim_trailing: controls.trim_trailing,
        clear_on_typing: controls.clear_on_typing,
        clear_on_copy: controls.clear_on_copy,
        paste_protection: controls.paste_protection,
        bracketed_safe: controls.bracketed_safe,
        clipboard_read: run_text(blob, controls.clipboard_read),
        clipboard_write: run_text(blob, controls.clipboard_write),
        hide_mouse_while_typing: controls.hide_mouse_while_typing,
        mouse_shift_capture: run_text(blob, controls.mouse_shift_capture),
        click_to_move: controls.click_to_move,
        allow_mouse_capture: controls.allow_mouse_capture,
        right_click_action: run_text(blob, controls.right_click_action),
        shift_arrow_select: controls.shift_arrow_select,
        scroll_multiplier: controls.scroll_multiplier,
        macos_option_as_alt: run_text(blob, controls.macos_option_as_alt),
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "the tests call the C entry point, which is what they are for"
    )]

    use super::{
        SlopDeskConfigRun, SlopDeskTerminalColors, SlopDeskTerminalConfig, SlopDeskTerminalCursor,
        SlopDeskTerminalFont, slopdesk_terminal_config_string,
    };

    /// Interns strings the way the near side does, answering a run for each.
    #[derive(Default)]
    struct Blob {
        bytes: Vec<u8>,
    }

    impl Blob {
        fn run(&mut self, text: &str) -> SlopDeskConfigRun {
            #[expect(
                clippy::cast_possible_truncation,
                reason = "a test blob is a handful of font names long"
            )]
            let run = SlopDeskConfigRun {
                offset: self.bytes.len() as u32,
                length: text.len() as u32,
            };
            self.bytes.extend_from_slice(text.as_bytes());
            run
        }
    }

    /// Builds through the door the way the near side does: measure, then fill.
    fn built(config: &SlopDeskTerminalConfig, blob: &Blob, palette: &[SlopDeskConfigRun]) -> String {
        // SAFETY: every buffer is this function's own and lives across both calls.
        unsafe {
            let text = blob.bytes.as_ptr();
            let len = blob.bytes.len();
            let needed = slopdesk_terminal_config_string(
                *config,
                text,
                len,
                core::ptr::null(),
                0,
                palette.as_ptr(),
                palette.len(),
                core::ptr::null_mut(),
                0,
            );
            let mut out = vec![0u8; needed];
            let written = slopdesk_terminal_config_string(
                *config,
                text,
                len,
                core::ptr::null(),
                0,
                palette.as_ptr(),
                palette.len(),
                out.as_mut_ptr(),
                out.len(),
            );
            assert_eq!(written, needed, "the second call fills what the first sized");
            String::from_utf8(out).unwrap_or_default()
        }
    }

    #[test]
    fn the_record_crosses_and_the_text_comes_back_whole() {
        let mut blob = Blob::default();
        let config = SlopDeskTerminalConfig {
            font: SlopDeskTerminalFont {
                family: blob.run("SF Mono"),
                weight: blob.run("regular"),
                ligatures: blob.run("off"),
                bold: blob.run("auto"),
                italic: blob.run("auto"),
                blending: blob.run("default"),
                size: 13.0,
                auto_match_weight_style: true,
                ..SlopDeskTerminalFont::default()
            },
            colors: SlopDeskTerminalColors {
                background: blob.run("22212C"),
                foreground: blob.run("F8F8F2"),
                ..SlopDeskTerminalColors::default()
            },
            cursor: SlopDeskTerminalCursor {
                style: blob.run("block"),
                blink: blob.run("default"),
                opacity: 1.0,
                ..SlopDeskTerminalCursor::default()
            },
            scrollback_lines: 10_000,
            ..SlopDeskTerminalConfig::default()
        };
        assert_eq!(
            built(&config, &blob, &[]),
            "font-family = SF Mono\nfont-size = 13\nfont-style = regular\nfont-feature = \
             -calt,-liga,-dlig\nbackground = 22212C\nforeground = F8F8F2\nselection-foreground = \
             cell-foreground\ncursor-style = block\nscrollback-limit = 2560000\nlink-url = \
             false\nwindow-padding-balance = true"
        );
    }

    #[test]
    fn a_palette_crosses_as_its_own_array_because_a_count_is_not_a_delimiter() {
        let mut blob = Blob::default();
        let mut config = SlopDeskTerminalConfig {
            cursor: SlopDeskTerminalCursor {
                style: blob.run("block"),
                ..SlopDeskTerminalCursor::default()
            },
            ..SlopDeskTerminalConfig::default()
        };
        config.colors.foreground = blob.run("F8F8F2");
        let entries: Vec<SlopDeskConfigRun> = (0..16)
            .map(|index| blob.run(if index == 3 { "403E41" } else { "FF6188" }))
            .collect();
        let text = built(&config, &blob, &entries);
        assert!(text.contains("palette = 3=403E41"));
        assert_eq!(text.lines().filter(|l| l.starts_with("palette = ")).count(), 16);
        // Fifteen of the same entries is not a palette.
        let short = built(&config, &blob, entries.get(..15).unwrap_or_default());
        assert!(!short.contains("palette = "));
    }

    #[test]
    fn a_run_that_leaves_the_blob_reads_as_unset_rather_than_reading_something_else() {
        let mut blob = Blob::default();
        let config = SlopDeskTerminalConfig {
            font: SlopDeskTerminalFont {
                family: SlopDeskConfigRun {
                    offset: 900,
                    length: 4,
                },
                ligatures: blob.run("off"),
                ..SlopDeskTerminalFont::default()
            },
            ..SlopDeskTerminalConfig::default()
        };
        let text = built(&config, &blob, &[]);
        assert!(
            !text.contains("font-family"),
            "a family that is not there is not a family"
        );
    }
}
