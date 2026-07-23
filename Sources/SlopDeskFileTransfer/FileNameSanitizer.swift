import Foundation

/// Turns an untrusted client-supplied filename into a safe leaf name, or rejects it.
///
/// A file-upload endpoint invites the classic path-traversal attack: a peer on the tunnel could
/// offer `../../.ssh/authorized_keys` or an absolute `/etc/…` to escape the drop directory. This is
/// the validate-then-drop gate — it keeps ONLY the last path component and rejects anything that
/// cannot be a plain leaf (`.`, `..`, empty, or a name still bearing a separator after the split).
public enum FileNameSanitizer {
    /// Returns a safe leaf filename for `raw`, or `nil` if it cannot be trusted as one.
    public static func sanitize(_ raw: String) -> String? {
        // Take the last path component — collapses `a/b/c.txt` and `../../x` down to their leaf.
        // Split on BOTH separators: a client on any OS (or a hostile one) may send either.
        let leaf = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? raw

        let trimmed = leaf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        // Defense in depth: no residual separator, no NUL, no leading dot-dot.
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else { return nil }
        return trimmed
    }
}
