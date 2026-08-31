//! The terminal ENGINE, wrapped — parse, grid and scrollback, with no renderer attached.

/// Feeds `bytes` through a fresh terminal and reports the cursor column it leaves behind.
///
/// A smoke test with a return value rather than a `()` probe: it proves the Zig library linked AND
/// that the grid it maintains is readable from Rust, which a link check alone does not.
#[must_use]
pub fn columns_after(cols: u16, rows: u16, bytes: &[u8]) -> Option<u16> {
    let mut terminal = libghostty_vt::Terminal::new(cols, rows).ok()?;
    terminal.vt_write(bytes);
    terminal.cursor_x().ok()
}

#[cfg(test)]
mod tests {
    /// Proves the Zig library LINKED and its grid is readable from Rust — a link check alone would
    /// pass with a parser that did nothing.
    #[test]
    fn writing_five_columns_leaves_the_cursor_at_five() {
        assert_eq!(super::columns_after(80, 24, b"hello"), Some(5));
    }

    /// And that it is the real parser: a carriage return is an ESCAPE, not a glyph.
    #[test]
    fn a_carriage_return_returns_the_cursor_rather_than_printing() {
        assert_eq!(super::columns_after(80, 24, b"hello\rhi"), Some(2));
    }
}
