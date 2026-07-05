import Foundation

// MARK: - Dropped content (the classified payload)

/// What an external drag is carrying, once the platform pasteboard has been inspected and reduced to a
/// single semantic value (see `docs/ui-shell/spec/user-interface__drag-and-drop.md`). This is the PURE value the
/// drop policy reasons over — the AppKit / SwiftUI drop layer (E18 WI-5) extracts the raw pasteboard,
/// hands it to ``DropPayloadClassifier``, and gets one of these back (or `nil` for an unsupported /
/// empty drag — validate-then-drop).
///
/// `folder` vs `file` is decided by the platform layer from the file URL's `isDirectory` resource value
/// (this pure layer NEVER touches the disk); `url` is a non-file web URL string; `text` is a plain
/// snippet. The path/URL/text strings are carried verbatim so the actuator (WI-6) can inject them
/// through the existing PTY funnel as VERBATIM UTF-8.
public enum DroppedContent: Equatable, Sendable {
    /// A directory path (host-resolved on actuation; a `cd` / open-in-place target).
    case folder(String)
    /// A regular file path.
    case file(String)
    /// A non-file web URL string (`http(s)://…`, or a bare host the normalizer fixes up later).
    case url(String)
    /// A plain-text snippet to paste into the focused terminal.
    case text(String)
}

// MARK: - Classifier (pasteboard groups → DroppedContent)

/// Maps an inspected drag pasteboard onto a single ``DroppedContent`` (validate-then-drop: an
/// unsupported UTType or an empty/whitespace value yields `nil`, never a crash — CLAUDE.md untrusted
/// input contract; a hostile/empty drag is the normal case, not a fault).
///
/// PURE and headless: it imports no AppKit / UniformTypeIdentifiers. The platform drop layer (WI-5)
/// resolves the real pasteboard types — file URLs (with `isDirectory`), web URLs, plain text — into a
/// ``Payload`` and calls ``classify(_:)``. Precedence is **file → url → text**: a Finder file drag also
/// exposes a text representation of its path, but the file semantics win (you dropped a file, not a
/// string). The first non-empty supported item in precedence order is returned.
public enum DropPayloadClassifier {
    /// One file-URL entry surfaced by the platform layer: the POSIX path plus whether it is a directory.
    /// `isDirectory` is resolved on the platform side (URL resource values / UTType conformance); this
    /// pure layer never stats the disk.
    public struct FileEntry: Equatable, Sendable {
        public var path: String
        public var isDirectory: Bool
        public init(path: String, isDirectory: Bool) {
            self.path = path
            self.isDirectory = isDirectory
        }
    }

    /// The SUPPORTED slice of a drag pasteboard, already extracted by the platform layer. An unsupported
    /// UTType is simply absent here — an all-empty payload classifies to `nil` (validate-then-drop).
    public struct Payload: Equatable, Sendable {
        public var files: [FileEntry]
        public var urls: [String]
        public var text: String?
        public init(files: [FileEntry] = [], urls: [String] = [], text: String? = nil) {
            self.files = files
            self.urls = urls
            self.text = text
        }
    }

    /// Reduce a pasteboard ``Payload`` to one ``DroppedContent`` with file → url → text precedence,
    /// dropping empty/whitespace values along the way. Returns `nil` when nothing supported & non-empty
    /// is present (unsupported UTType / empty drag).
    public static func classify(_ payload: Payload) -> DroppedContent? {
        if let entry = payload.files.first(where: { !isBlank($0.path) }) {
            return entry.isDirectory ? .folder(entry.path) : .file(entry.path)
        }
        if let url = payload.urls.first(where: { !isBlank($0) }) {
            return .url(url)
        }
        if let text = payload.text, !isBlank(text) {
            return .text(text)
        }
        return nil
    }

    /// True when `s` is empty or only whitespace/newlines (the validate-then-drop gate).
    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
