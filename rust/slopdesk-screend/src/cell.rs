//! One grid cell and the SGR state stamped onto it.
//!
//! The shapes here are load-bearing for two things beyond storage: cell EQUALITY is what the
//! renderer's trailing trim and the transcript's blank-row test mean by "blank", and the style
//! is what the renderer diffs to decide whether to emit an SGR run at all.

/// One SGR colour: the terminal default, an indexed palette entry, or 24-bit RGB.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum SgrColor {
    /// The terminal's own foreground/background — nothing is emitted for it.
    #[default]
    Default,
    /// A palette index (0–255).
    Indexed(u8),
    /// 24-bit truecolour.
    Rgb(u8, u8, u8),
}

/// The attribute state a cell was printed with (and the parser's live state between prints).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "SGR IS a set of independent flags — packing them would only cost them their names"
)]
pub struct CellStyle {
    /// Foreground colour.
    pub fg: SgrColor,
    /// Background colour.
    pub bg: SgrColor,
    /// SGR 1.
    pub bold: bool,
    /// SGR 2.
    pub dim: bool,
    /// SGR 3.
    pub italic: bool,
    /// SGR 4 (and 21, which xterm renders as an underline).
    pub underline: bool,
    /// SGR 5/6.
    pub blink: bool,
    /// SGR 7.
    pub inverse: bool,
    /// SGR 8.
    pub hidden: bool,
    /// SGR 9.
    pub strikethrough: bool,
}

impl CellStyle {
    /// The plain (all-default) style.
    pub const PLAIN: Self = Self {
        fg: SgrColor::Default,
        bg: SgrColor::Default,
        bold: false,
        dim: false,
        italic: false,
        underline: false,
        blink: false,
        inverse: false,
        hidden: false,
        strikethrough: false,
    };

    /// The BCE fill style: an erase/scroll fill takes the CURRENT BACKGROUND only (xterm
    /// background-colour-erase) — never the foreground or the flags.
    #[must_use]
    pub const fn erase_fill(&self) -> Self {
        Self {
            bg: self.bg,
            ..Self::PLAIN
        }
    }
}

/// A cell's text.
///
/// One `char` covers every cell a terminal actually prints; `Composed` exists only for a base
/// character that later collected combining marks, and `Empty` is the CONTINUATION half of a wide
/// pair (which renders as nothing — the lead paints both columns).
#[derive(Clone, PartialEq, Eq, Debug)]
#[allow(
    variant_size_differences,
    reason = "the wide variant IS the point: a Box<str> keeps the composed case out of line, so the enum is \
              16 bytes and a whole grid stays one flat allocation per row"
)]
pub enum CellText {
    /// A single scalar.
    Char(char),
    /// A base scalar plus combining marks.
    Composed(Box<str>),
    /// Nothing — the continuation half of a wide pair.
    Empty,
}

impl Default for CellText {
    fn default() -> Self {
        Self::Char(' ')
    }
}

impl CellText {
    /// Appends this text to `out`.
    pub fn push_to(&self, out: &mut String) {
        match self {
            Self::Char(c) => out.push(*c),
            Self::Composed(s) => out.push_str(s),
            Self::Empty => {},
        }
    }

    /// The text, or a single space when it is empty — the form the renderer prints, because a
    /// zero-byte cell would leave the receiving terminal's cursor where it was.
    #[must_use]
    pub fn or_space(&self) -> String {
        match self {
            Self::Char(c) => c.to_string(),
            Self::Composed(s) => s.as_ref().to_owned(),
            Self::Empty => " ".to_owned(),
        }
    }

    /// Appends a combining scalar, promoting a single char to a composed run.
    pub fn append_combining(&mut self, scalar: char) {
        match self {
            Self::Char(base) => {
                let mut composed = String::with_capacity(8);
                composed.push(*base);
                composed.push(scalar);
                *self = Self::Composed(composed.into_boxed_str());
            },
            Self::Composed(existing) => {
                let mut composed = existing.as_ref().to_owned();
                composed.push(scalar);
                *self = Self::Composed(composed.into_boxed_str());
            },
            Self::Empty => {
                *self = Self::Composed(scalar.to_string().into_boxed_str());
            },
        }
    }
}

/// One grid cell. A wide (2-column) character occupies its lead cell plus a CONTINUATION cell
/// that renders as nothing; overwriting either half blanks the partner.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Cell {
    /// What the cell shows.
    pub text: CellText,
    /// True for the second column of a wide pair.
    pub is_continuation: bool,
    /// The attributes it was printed with.
    pub style: CellStyle,
}

impl Cell {
    /// The default cell — a plain space. This exact value is what "blank" means to the renderer's
    /// trailing trim, the transcript's blank-row test and the scrollback join guard.
    #[must_use]
    pub fn blank() -> Self {
        Self::default()
    }

    /// A blank cell in `style`'s erase colours (xterm BCE).
    #[must_use]
    pub const fn erase_fill(style: &CellStyle) -> Self {
        Self {
            text: CellText::Char(' '),
            is_continuation: false,
            style: style.erase_fill(),
        }
    }

    /// Whether this is the fully-default cell.
    #[must_use]
    pub fn is_blank(&self) -> bool {
        self == &Self::default()
    }
}
