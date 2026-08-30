// What a drop IS, as the Swift face of `slopdesk_workspace::drop_payload`, reached through
// `rust/slopdesk-ffi`'s `drop_classify` door.
//
// ## What is not here any more
//
// The precedence and the blank gate: file → url → text, and the trim that drops an empty or
// all-whitespace value on the way past. Both Rust's, beside the `(zone × content)` table they feed
// (`DropActionResolver`). Until `docs/67` this was the one step of `classify → resolve → actuate`
// still decided in Swift, which made one walk's consecutive steps two languages' — the
// one-implementation rule broken at a join. What stays is the vocabulary the actuator speaks and
// the marshalling into one door.

import CSlopDeskFFI
import Foundation

// MARK: - Dropped content (the classified payload)

/// What an external drag is carrying, once the platform pasteboard has been inspected and reduced to a
/// single semantic value (see `docs/ui-shell/spec/user-interface__drag-and-drop.md`). This is the value the
/// drop policy reasons over — each shell's drop layer (AppKit on the Mac, UIKit on the phone) extracts the raw pasteboard,
/// hands it to ``DropPayloadClassifier``, and gets one of these back (or `nil` for an unsupported /
/// empty drag — validate-then-drop).
///
/// `folder` vs `file` is decided by the platform layer from the file URL's `isDirectory` resource value
/// (nothing below the pasteboard ever touches the disk); `url` is a non-file web URL string; `text` is a plain
/// snippet. The path/URL/text strings are carried verbatim so the actuator can inject them
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

// MARK: - Classifier (pasteboard groups → DroppedContent, marshalled)

/// Maps an inspected drag pasteboard onto a single ``DroppedContent``, or `nil` when nothing supported
/// and non-blank is in it (validate-then-drop: a hostile or empty drag is the normal case, not a fault).
///
/// Headless: it imports no AppKit / UniformTypeIdentifiers, and the platform drop layer resolves the
/// real pasteboard types — file URLs (with `isDirectory`), web URLs, plain text — into a ``Payload``
/// before calling ``classify(_:)``. Precedence, the blank gate and the folder/file split are the
/// crate's; see `slopdesk_workspace::drop_payload` for why the order is what it is.
public enum DropPayloadClassifier {
    /// One file-URL entry surfaced by the platform layer: the POSIX path plus whether it is a directory.
    /// `isDirectory` is resolved on the platform side (URL resource values / UTType conformance); nothing
    /// below it stats the disk.
    public struct FileEntry: Equatable, Sendable {
        public var path: String
        public var isDirectory: Bool
        public init(path: String, isDirectory: Bool) {
            self.path = path
            self.isDirectory = isDirectory
        }
    }

    /// The SUPPORTED slice of a drag pasteboard, already extracted by the platform layer. An unsupported
    /// UTType is simply absent here.
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

    /// Reduce a pasteboard ``Payload`` to one ``DroppedContent``.
    public static func classify(_ payload: Payload) -> DroppedContent? {
        // ONE contiguous arena for every lent run. A record per string would need its own nested
        // `withUnsafeBytes`, and a drag's item count is not known until it arrives — so the bytes are
        // gathered once and the records name spans into them, which is a shape that nests exactly twice
        // however many items the pasteboard published.
        var arena: [UInt8] = []
        var spans: [(offset: Int, count: Int)] = []
        func lend(_ text: String) -> Int {
            let bytes = Array(text.utf8)
            spans.append((arena.count, bytes.count))
            arena.append(contentsOf: bytes)
            return spans.count - 1
        }
        let files = payload.files.map { (span: lend($0.path), isDirectory: $0.isDirectory) }
        let urls = payload.urls.map(lend)
        let text = payload.text.map(lend)

        return arena.withUnsafeBufferPointer { arenaBytes in
            func run(_ index: Int) -> SlopDeskDropText {
                let span = spans[index]
                return SlopDeskDropText(
                    bytes: arenaBytes.baseAddress.map { $0 + span.offset },
                    len: span.count,
                )
            }
            let fileRecords = files.map {
                SlopDeskDropFile(path: run($0.span), is_directory: $0.isDirectory)
            }
            let urlRecords = urls.map(run)
            let lentText = text.map(run) ?? SlopDeskDropText(bytes: nil, len: 0)

            var kind: UInt8 = 0
            let (present, value) = fileRecords.withUnsafeBufferPointer { filePointer in
                urlRecords.withUnsafeBufferPointer { urlPointer in
                    classifiedAnswer { out, cap, needed in
                        slopdesk_drop_classify(
                            filePointer.baseAddress, filePointer.count,
                            urlPointer.baseAddress, urlPointer.count,
                            lentText, text != nil, &kind, out, cap, needed,
                        )
                    }
                }
            }
            guard present else { return nil }
            switch UInt32(kind) {
            case SLOPDESK_DROP_CONTENT_FOLDER: return .folder(value)
            case SLOPDESK_DROP_CONTENT_FILE: return .file(value)
            case SLOPDESK_DROP_CONTENT_URL: return .url(value)
            case SLOPDESK_DROP_CONTENT_TEXT: return .text(value)
            default: return nil
            }
        }
    }

    /// Reads the door's two-part answer: presence from the return, the value from `(out, cap)` with
    /// `needed` carrying the retry number. A refusal is `false` and never a zero length — a classified
    /// drag CAN carry an empty value, and the two are different answers.
    private static func classifiedAnswer(
        _ call: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?) -> Bool,
    ) -> (present: Bool, value: String) {
        var out = [UInt8](repeating: 0, count: 256)
        var needed = 0
        var present = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count, &needed) }
        if present, needed > out.count {
            out = [UInt8](repeating: 0, count: needed)
            present = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count, &needed) }
        }
        guard present, needed > 0, needed <= out.count,
              let value = String(bytes: out[0..<needed], encoding: .utf8) else { return (present, "") }
        return (true, value)
    }
}
