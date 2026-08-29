// ClientPasteboard — the one door onto THIS device's system pasteboard, and the only Swift left in
// the clipboard path.
//
// Everything below the door is `rust/slopdesk-apple-pasteboard` (`NSPasteboard` on one slice,
// `UIPasteboard` on the other) over `rust/slopdesk-clipboard` (the four rules about what may leave a
// machine), which is the SAME crate the host reads out of. That is the point of the port: the client
// end and the host end used to be two implementations of one wire contract in two languages, free to
// drift, and they HAD drifted. Now the only thing that is per-end is the argument
// `skippingConcealed` — the client refuses to push a concealed clip, the host does not refuse to
// ship one back — and it is one word at one call site rather than a difference nobody can see.
//
// So there is no platform fork in this file and no `#if canImport(AppKit)` anywhere in it. There is
// nothing to fork: `slopdesk_clipboard_*` is one surface, and which framework answers it is decided
// when the slice is compiled.
//
// ⚠️ THE ONE ASYMMETRY THAT IS NECESSITY. macOS lets a background poll read the pasteboard's CONTENT
// freely. iOS has not since iOS 16: an unattended read of content the app did not write, with no
// system paste gesture behind it, raises a modal "Allow Paste?" alert. A one-second poll would put
// that alert on screen once per new clip. ``unattendedContentReadIsPermitted`` is that platform fact
// and both tick loops branch on it — they track the change count everywhere (which discloses
// nothing) and read CONTENT only where it costs the user nothing. On iOS the content read happens
// instead on the paths the user asked for a paste on (``WorkspaceStore/currentLocalClipboard()``),
// where the alert is the paste they just requested rather than an ambush.
//
// The PROBES are the other half of that sentence and they are members of their own: ``hasText()``
// and ``isSyncable`` answer from the types the board's owner DECLARED, so a renderer that only needs
// to grey a button out, or a caller that owes the privacy refusal on text it already holds, has
// something to ask that is not the content. Neither prompts on either platform.

import CSlopDeskFFI
import Foundation
import SlopDeskArena
import SlopDeskProtocol

/// One system pasteboard, named. The empty name is the machine's own board; any other name is a
/// private board the system makes on demand.
///
/// The name exists because the general pasteboard is machine-global shared state: a parallel xctest
/// worker's copy test, or the developer's own ⌘C while a local run is in flight, clobbers anything a
/// test asserts on. ``shared`` resolves that fork once — and it resolves it HERE rather than behind
/// the door, because "am I running under XCTest" is a fact about the Swift test harness and nothing
/// Rust should be asked to guess.
public struct ClientPasteboard: Sendable {
    /// The board's name; empty for the machine's own.
    public let name: String

    public init(name: String) {
        self.name = name
    }

    /// The pasteboard every client-side "Copy" writes and every paste provider reads: the machine's
    /// own board in the app, a per-PROCESS board under XCTest (mirrors ``SettingsKey/store``).
    ///
    /// The per-process board is cleared on first use because a pid the system reused hands back
    /// whatever the last run of that pid left on it. It is not released at exit: `releaseGlobally`
    /// has no `objc2` binding, and reaching the selector by hand is the raw Objective-C
    /// `docs/57` §2 keeps out of the Apple crates — so an empty named board per test pid outlives
    /// the run in the pasteboard server, which costs nothing a login does not reclaim.
    public static let shared: ClientPasteboard = {
        guard NSClassFromString("XCTestCase") != nil else { return Self(name: "") }
        let suite = Self(
            name: "slopdesk.tests.pid\(ProcessInfo.processInfo.processIdentifier)",
        )
        suite.clear()
        return suite
    }()

    // MARK: - What the platform allows

    /// Whether an UNATTENDED read of a board's CONTENT is free of a user-visible consequence — see
    /// the file header. True on macOS, false on iOS. The probes below never raise the alert on
    /// either platform.
    public static var unattendedContentReadIsPermitted: Bool {
        slopdesk_clipboard_unattended_read_is_permitted()
    }

    /// The UTI a password manager marks a concealed clip with, asked for rather than typed.
    ///
    /// Nothing in the shipping app names it — the refusal is `rust/slopdesk-clipboard`'s and
    /// ``isSyncable`` is how anyone asks about it. It is public because a SUITE proving the refusal
    /// has to put a concealed clip on a board, and the only other way to spell that is a literal in
    /// Swift: a third copy of a UTI that would keep passing against a marker the fold had stopped
    /// recognising. `one-pasteboard-clip` bans that literal outright, which is only a rule anybody
    /// can follow because this exists (the same trade `ClipboardPasteMenu/previewLimit` makes).
    public static let concealedTypeIdentifier = ffiAnswerText { out, cap in
        slopdesk_clipboard_concealed_type(out, cap)
    }

    // MARK: - Probes (no content crosses, no alert)

    /// Advances on every write by anybody. The whole of a clipboard poll, and the half of it iOS
    /// still permits unattended.
    public var changeCount: Int {
        Int(lending { slopdesk_clipboard_change_count($0, $1) })
    }

    /// Whether this board's content may leave the device: not a CONCEALED clip (a password
    /// manager's `org.nspasteboard.ConcealedType`) and not a FILE copy (a path means nothing on the
    /// other machine). Answered from the DECLARED types, so a caller that already holds text
    /// somebody else read attended still owes the privacy refusal and can take it without a second
    /// content read — the one thing this file rations.
    public var isSyncable: Bool {
        lending { slopdesk_clipboard_is_syncable($0, $1) }
    }

    /// Whether the board holds plain text AT ALL, WITHOUT reading it — the ENABLEMENT question.
    /// Anything deciding whether a paste affordance is LIT asks this; only the paste itself asks
    /// ``plainText``.
    public var hasPlainText: Bool {
        lending { slopdesk_clipboard_has_text($0, $1) }
    }

    // MARK: - Content

    /// The board's plain-text head, or `nil` when it holds something else.
    ///
    /// ⚠️ A CONTENT read. On iOS, only call it where the user asked for a paste.
    public var plainText: String? {
        let text = ffiAnswerText { out, cap in
            lending { slopdesk_clipboard_read_text($0, $1, out, cap) }
        }
        return text.isEmpty ? nil : text
    }

    /// The board's current shippable clip, or `nil` when there is nothing to ship: an empty board, a
    /// file copy, an over-cap clip, an image that will not transcode, and — when `skippingConcealed`
    /// — a concealed one. The board is left untouched in every case.
    ///
    /// Image before text on purpose, and that preference lives in Rust with the refusals: an app
    /// that copies a picture usually declares a text flavour too (its caption, its source URL), and
    /// taking the text would silently downgrade the paste.
    ///
    /// ⚠️ A CONTENT read, for ``plainText``'s reason.
    public func clip(skippingConcealed: Bool) -> MetadataCodec.ClipboardClip? {
        // `[kind byte][content]`, so the kind and the bytes are ONE answer: two doors could
        // disagree and apply PNG bytes as text. Zero bytes is "nothing to ship" — unmistakable,
        // since a clip is at least a kind byte plus one.
        let answer = ffiAnswerBytes { out, cap in
            lending { slopdesk_clipboard_read($0, $1, skippingConcealed, out, cap) }
        }
        guard let kind = answer.first else { return nil }
        return MetadataCodec.ClipboardClip(kindByte: kind, bytes: Data(answer.dropFirst()))
    }

    /// The shippable clip for text the caller ALREADY HOLDS, or `nil` when there is nothing to ship.
    ///
    /// The attended-read door. A platform that refuses an unattended content read runs its push half
    /// on the reads the user asked for, and by then the text is in hand — re-reading the board
    /// through ``clip(skippingConcealed:)`` would spend a permission already spent. The CONCEALED
    /// and FILE refusals are deliberately not here: the caller takes those from ``isSyncable``,
    /// which needs no content read. This answers only what a clip made of text is allowed to be.
    public static func clip(forAttendedText text: String) -> MetadataCodec.ClipboardClip? {
        guard ffiLend(text, { slopdesk_clipboard_text_is_shippable($0.baseAddress, $0.count) })
        else { return nil }
        return MetadataCodec.ClipboardClip(kind: .text, bytes: Data(text.utf8))
    }

    // MARK: - Writes (validate first, so a bad clip cannot destroy a good one)

    /// Writes a host clip onto this board; `false` — board UNTOUCHED — for non-UTF-8 or empty text,
    /// PNG bytes that will not decode, and an unknown future kind byte.
    ///
    /// Validate-then-clear is why this answers rather than throws away: the decode happens BEFORE
    /// anything is cleared, so a garbage clip arriving over the wire cannot destroy the clip a
    /// person put there. The two ends spell the refusal differently (the host answers
    /// ``MetadataStatus/error``, the client just drops), which is why the answer is a `Bool`.
    @discardableResult
    public func apply(_ clip: MetadataCodec.ClipboardClip) -> Bool {
        clip.bytes.withUnsafeContent { bytes, count in
            lending { slopdesk_clipboard_write($0, $1, clip.kindByte, bytes, count) }
        }
    }

    /// Replaces this board's contents with `text`; `false` — board UNTOUCHED — for empty text.
    @discardableResult
    public func write(_ text: String) -> Bool {
        ffiLend(text) { lent in
            lending { slopdesk_clipboard_write_text($0, $1, lent.baseAddress, lent.count) }
        }
    }

    /// Drops everything on this board.
    public func clear() {
        lending { slopdesk_clipboard_clear($0, $1) }
    }

    // MARK: - The app-wide copy funnel

    /// The one client-side "copy" — every ⌘C affordance in the tree lands here, on ``shared``.
    public static func write(_ text: String) {
        shared.write(text)
    }

    /// What is on the clipboard as text, or `nil` when it holds something else.
    ///
    /// The read side of "paste into the device": the Android panel takes THIS machine's clipboard
    /// and sends it, rather than asking the device for its own — a `GET_CLIPBOARD` would make the
    /// device write a reply into the video stream (see `AndroidControlMessage`).
    public static func text() -> String? { shared.plainText }

    /// Whether the board holds text AT ALL, WITHOUT reading it — the question ENABLEMENT asks.
    public static func hasText() -> Bool { shared.hasPlainText }

    /// The copy funnel for a captured FRAME, in any format the system decoder reads.
    ///
    /// Answers whether the write happened, so a caller can tell "those bytes were not an image" from
    /// "it is on the clipboard" — a truncated capture is a server problem worth reporting, not a
    /// silent no-op — and a `false` never touches the board.
    ///
    /// Format-blind on purpose: the Android panel hands it PNG and the simulator panel JPEG, and
    /// both system decoders sniff either. Returning `Bool` rather than a decoded image is what let
    /// the two panels' MODELS out of the platform-specific targets (docs/56): a domain model can say
    /// "copy this frame" without naming an `NSImage`.
    @discardableResult
    public static func writeImage(_ bytes: Data) -> Bool {
        bytes.withUnsafeContent { raw, count in
            ffiLend(shared.name) { lent in
                slopdesk_clipboard_write_image(lent.baseAddress, lent.count, raw, count)
            }
        }
    }

    /// Lends this board's name for the length of one door call, and nothing longer.
    private func lending<T>(_ door: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        ffiLend(name) { door($0.baseAddress, $0.count) }
    }
}

private extension Data {
    /// Lends these bytes as `(ptr, len)` for the length of one door call.
    ///
    /// Empty `Data` lends the null pair, which every door reads as the same nothing a zero length
    /// is — so an empty clip never needs a branch of its own at the call sites above.
    func withUnsafeContent<T>(_ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        withUnsafeBytes { raw in
            body(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }
}
