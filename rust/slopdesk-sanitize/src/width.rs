//! Display width and the DEC special-graphics map.
//!
//! A pragmatic wcwidth subset — good column maths for the TUIs agents actually read, and pinned
//! rather than derived so a Unicode-table bump can never silently move a pane's columns.

/// DEC special-graphics (line drawing) — `ESC ( 0` maps ASCII `` ` ``…`~` to box characters.
#[must_use]
pub const fn dec_graphic(scalar: u32) -> Option<char> {
    Some(match scalar {
        0x60 => '\u{25C6}', // ` ◆
        0x61 => '\u{2592}', // a ▒
        0x66 => '\u{00B0}', // f °
        0x67 => '\u{00B1}', // g ±
        0x6A => '\u{2518}', // j ┘
        0x6B => '\u{2510}', // k ┐
        0x6C => '\u{250C}', // l ┌
        0x6D => '\u{2514}', // m └
        0x6E => '\u{253C}', // n ┼
        0x6F => '\u{23BA}', // o ⎺
        0x70 => '\u{23BB}', // p ⎻
        0x71 => '\u{2500}', // q ─
        0x72 => '\u{23BC}', // r ⎼
        0x73 => '\u{23BD}', // s ⎽
        0x74 => '\u{251C}', // t ├
        0x75 => '\u{2524}', // u ┤
        0x76 => '\u{2534}', // v ┴
        0x77 => '\u{252C}', // w ┬
        0x78 => '\u{2502}', // x │
        0x79 => '\u{2264}', // y ≤
        0x7A => '\u{2265}', // z ≥
        0x7B => '\u{03C0}', // { π
        0x7C => '\u{2260}', // | ≠
        0x7D => '\u{00A3}', // } £
        0x7E => '\u{00B7}', // ~ ·
        _ => return None,
    })
}

/// Display width of a scalar: 0 (combining/format), 2 (East Asian wide + emoji), else 1.
///
/// **The only width table in the tree.** There were two — this one and a second in
/// `slopdesk-terminal`'s link scan — and they disagreed in both directions: this one knew the
/// Arabic, Hebrew and Thai combining marks the other did not, the other knew the
/// `Default_Ignorable` set this one did not, and the other widened three ranges of narrow
/// pictographs. A screen model measuring a Thai line one way while the cursor, the link underline
/// and the hint badge measure it another is the same bug the vi motions were moved to fix, one
/// layer up. `slopdesk_terminal::link::scalar_cells` reads this now.
#[must_use]
pub const fn scalar_width(scalar: u32) -> usize {
    // Everything below the first zero-width scalar (U+00AD SOFT HYPHEN) is width 1 — the ASCII fast
    // path skips the whole cascade for the common case.
    if scalar < 0x00AD {
        return 1;
    }
    match scalar {
        // Combining marks, whose width belongs to the base they attach to.
        0x0300..=0x036F
        | 0x0483..=0x0489
        | 0x0591..=0x05BD
        | 0x0610..=0x061A
        | 0x064B..=0x065F
        | 0x06D6..=0x06DC
        | 0x0E31
        | 0x0E34..=0x0E3A
        | 0x1AB0..=0x1AFF
        | 0x1DC0..=0x1DFF
        | 0x20D0..=0x20FF
        | 0xFE20..=0xFE2F
        // Hangul Jamo medial and final: the fillers and the trailing jamo compose onto the leading
        // one at U+1100..U+115F, which stays WIDE below.
        | 0x1160..=0x11FF
        // Default_Ignorable_Code_Point, spelled out rather than pulled from a Unicode crate: the
        // set is small, stable, and a dependency here would buy nothing this table does not.
        | 0x00AD
        // (U+034F COMBINING GRAPHEME JOINER is default-ignorable too, and already zero above.)
        | 0x061C
        | 0x17B4..=0x17B5
        | 0x180B..=0x180E
        | 0x200B..=0x200F
        | 0x202A..=0x202E
        | 0x2060..=0x206F
        | 0x3164
        | 0xFE00..=0xFE0F
        | 0xFEFF
        | 0xFFA0
        | 0xFFF0..=0xFFF8
        | 0x1BCA0..=0x1BCA3
        | 0x1D173..=0x1D17A
        | 0xE0000..=0xE0FFF => 0,
        0x1100..=0x115F
        | 0x231A..=0x231B
        | 0x2329..=0x232A
        | 0x23E9..=0x23EC
        | 0x25FD..=0x25FE
        | 0x2614..=0x2615
        | 0x2648..=0x2653
        | 0x267F
        | 0x2693
        | 0x26A1
        | 0x26AA..=0x26AB
        | 0x26BD..=0x26BE
        | 0x26C4..=0x26C5
        | 0x26CE
        | 0x26D4
        | 0x26EA
        | 0x26F2..=0x26F3
        | 0x26F5
        | 0x26FA
        | 0x26FD
        | 0x2705
        | 0x270A..=0x270B
        | 0x2728
        | 0x274C
        | 0x274E
        | 0x2753..=0x2755
        | 0x2757
        | 0x2795..=0x2797
        | 0x27B0
        | 0x27BF
        | 0x2B1B..=0x2B1C
        | 0x2B50
        | 0x2B55
        | 0x2E80..=0x303E
        | 0x3041..=0x33FF
        | 0x3400..=0x4DBF
        | 0x4E00..=0x9FFF
        | 0xA000..=0xA4CF
        | 0xA960..=0xA97F
        | 0xAC00..=0xD7A3
        | 0xF900..=0xFAFF
        | 0xFE30..=0xFE4F
        | 0xFF00..=0xFF60
        | 0xFFE0..=0xFFE6
        | 0x1F004
        | 0x1F0CF
        | 0x1F18E
        | 0x1F191..=0x1F19A
        | 0x1F200..=0x1F2FF
        | 0x1F300..=0x1F64F
        | 0x1F680..=0x1F6FF
        | 0x1F900..=0x1F9FF
        | 0x1FA70..=0x1FAFF
        | 0x20000..=0x2FFFD
        | 0x30000..=0x3FFFD => 2,
        _ => 1,
    }
}

#[cfg(test)]
mod tests {
    use super::{dec_graphic, scalar_width};

    #[test]
    fn ascii_is_one_column_and_skips_the_cascade() {
        for scalar in 0x20..0x7F_u32 {
            assert_eq!(scalar_width(scalar), 1);
        }
    }

    #[test]
    fn combining_marks_are_zero_and_cjk_is_two() {
        assert_eq!(scalar_width(0x0301), 0, "combining acute");
        assert_eq!(scalar_width(0xFE0F), 0, "variation selector 16");
        assert_eq!(scalar_width(0x4E00), 2, "CJK");
        assert_eq!(scalar_width(0x1F600), 2, "emoji");
        assert_eq!(scalar_width(0x00E9), 1, "precomposed latin");
    }

    /// The ranges that used to be in ONE of the two tables and not the other. Each of these was a
    /// column the screen model and the hint overlay disagreed about.
    #[test]
    fn the_ranges_the_two_tables_disagreed_about_answer_once() {
        // Known only to this table before: the marks a Thai, Hebrew or Arabic line is written with.
        for zero in [0x0E31, 0x0591, 0x064B, 0x0483, 0x06D6] {
            assert_eq!(scalar_width(zero), 0, "{zero:#x} attaches to its base");
        }
        // Known only to the link scan's table before: the Default_Ignorable set.
        for zero in [0x00AD, 0x034F, 0x061C, 0x3164, 0xFEFF, 0x2060, 0x202A, 0xE0001] {
            assert_eq!(scalar_width(zero), 0, "{zero:#x} is default-ignorable");
        }
        // The Hangul split the two tables straddled: the leading jamo carries the cell, the medial
        // and final compose onto it.
        assert_eq!(scalar_width(0x1100), 2, "choseong is the wide one");
        assert_eq!(scalar_width(0x115F), 2, "choseong filler holds a cell");
        assert_eq!(scalar_width(0x1160), 0, "jungseong filler composes");
        assert_eq!(scalar_width(0x11A8), 0, "jongseong composes");
        // The pictographs the link scan widened by painting U+1F300..U+1FAFF with one brush.
        assert_eq!(scalar_width(0x1F650), 1, "ornamental dingbats are narrow");
        assert_eq!(scalar_width(0x1F700), 1, "alchemical symbols are narrow");
        assert_eq!(scalar_width(0x1F800), 1, "supplemental arrows-C are narrow");
        // …and the ones it was right about.
        assert_eq!(scalar_width(0x1F600), 2);
        assert_eq!(scalar_width(0x1F9D1), 2);
        assert_eq!(scalar_width(0x1FA70), 2);
    }

    /// The fast path moved from U+0300 down to U+00AD when the soft hyphen joined the zero list;
    /// everything it still skips must really be one column.
    #[test]
    fn the_fast_path_covers_only_what_is_one_column() {
        for scalar in 0x00_u32..0x00AD {
            assert_eq!(
                scalar_width(scalar),
                1,
                "{scalar:#x} is below the first zero-width scalar"
            );
        }
    }

    #[test]
    fn the_graphics_map_covers_the_box_drawing_run_and_nothing_else() {
        assert_eq!(dec_graphic(0x71), Some('\u{2500}'), "q → ─");
        assert_eq!(dec_graphic(0x78), Some('\u{2502}'), "x → │");
        assert_eq!(dec_graphic(0x41), None, "A is not remapped");
    }
}
