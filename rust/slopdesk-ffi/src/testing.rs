//! The two reads every group-delivery door's tests perform, written once.
//!
//! A door that answers a TABLE of words delivers `[u32 length][UTF-8 bytes]` runs behind whatever
//! header it needs, and its tests have to cut them back apart to assert against the wrapped crate.
//! Ten modules writing that cursor walk out is ten places for an off-by-one to live — the same
//! argument the near side's own splitter makes, one language over.

/// Runs a `(out, cap) -> needed` door with the retry `docs/55` §4 describes and returns what it
/// delivered, or an empty vector for the ABI's `None`.
///
/// The first guess is deliberately generous: the retry exists to be CORRECT, and a test that
/// travelled it every time would stop noticing when a door outgrew what the near side asks for.
pub(crate) fn delivered(mut door: impl FnMut(*mut core::ffi::c_uchar, usize) -> usize) -> Vec<u8> {
    let mut out = vec![0_u8; 1 << 14];
    let mut needed = door(out.as_mut_ptr(), out.len());
    if needed > out.len() {
        out = vec![0_u8; needed];
        needed = door(out.as_mut_ptr(), out.len());
    }
    if needed == 0 || needed > out.len() {
        return Vec::new();
    }
    out.get(..needed).unwrap_or_default().to_vec()
}

/// The `count` length-prefixed runs in a delivery, PADDED with empties if it came up short.
///
/// Padding rather than trusting the length, for the reason the near side's reader states: a short
/// delivery means the door and the reader disagree about the layout, and the alternative is a
/// silent off-by-one where every run after the gap wears its neighbour's words.
pub(crate) fn runs(blob: &[u8], count: usize) -> Vec<String> {
    let mut runs = Vec::with_capacity(count);
    let mut cursor = 0_usize;
    while runs.len() < count {
        let Some(header) = blob.get(cursor..cursor + 4) else {
            break;
        };
        let length = header
            .iter()
            .fold(0_usize, |width, byte| width << 8 | usize::from(*byte));
        cursor += 4;
        let Some(text) = blob.get(cursor..cursor + length) else {
            break;
        };
        runs.push(String::from_utf8_lossy(text).into_owned());
        cursor += length;
    }
    while runs.len() < count {
        runs.push(String::new());
    }
    runs
}
