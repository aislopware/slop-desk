//! Turning an untrusted client-supplied filename into a safe leaf name, or refusing it.
//!
//! An upload endpoint invites the classic traversal: a peer on the tunnel offers
//! `../../.ssh/authorized_keys`, or an absolute `/etc/…`, and hopes the drop directory is only a
//! prefix. This is the validate-then-drop gate — it keeps ONLY the last path component and rejects
//! anything that cannot be a plain leaf.

/// A safe leaf filename for `raw`, or `None` when it cannot be trusted as one.
#[must_use]
pub fn sanitize(raw: &str) -> Option<String> {
    // The last non-empty component, splitting on BOTH separators: a client on any OS — or a hostile
    // one — may send either, and `a/b/c.txt`, `../../x` and `C:\dir\evil.dll` all collapse here.
    let leaf = raw
        .split(['/', '\\'])
        .rfind(|component| !component.is_empty())
        .unwrap_or(raw);

    let trimmed = leaf.trim();
    if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
        return None;
    }
    // Defence in depth: no residual separator and no NUL, whatever the split did.
    if trimmed.contains('/') || trimmed.contains('\\') || trimmed.contains('\0') {
        return None;
    }
    Some(trimmed.to_owned())
}

#[cfg(test)]
mod tests {
    use super::sanitize;

    #[test]
    fn a_plain_name_survives_unchanged() {
        assert_eq!(sanitize("report.pdf").as_deref(), Some("report.pdf"));
        assert_eq!(sanitize(".gitignore").as_deref(), Some(".gitignore"));
    }

    #[test]
    fn every_path_collapses_to_its_leaf() {
        assert_eq!(sanitize("Users/me/report.pdf").as_deref(), Some("report.pdf"));
        assert_eq!(sanitize("../../etc/passwd").as_deref(), Some("passwd"));
        assert_eq!(sanitize("/etc/passwd").as_deref(), Some("passwd"));
        assert_eq!(sanitize("C:\\Windows\\evil.dll").as_deref(), Some("evil.dll"));
        assert_eq!(sanitize("dir/foo/").as_deref(), Some("foo"));
    }

    #[test]
    fn a_name_that_cannot_be_a_leaf_is_refused() {
        assert_eq!(sanitize(".."), None);
        assert_eq!(sanitize("."), None);
        assert_eq!(sanitize(""), None);
        assert_eq!(sanitize("   "), None);
        assert_eq!(sanitize("evil\0.txt"), None);
        assert_eq!(sanitize("///"), None);
    }
}
