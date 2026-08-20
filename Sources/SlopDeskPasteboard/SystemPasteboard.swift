// SystemPasteboard — the one door onto THIS device's system pasteboard, on both halves of the client.
//
// `ClipboardMonitor` and `ClipboardSyncEngine` both named `NSPasteboard` in their signatures, so both
// files carried a whole-file `#if os(macOS)` and the phone shipped the "Paste Recent" menu with nothing
// behind it. The gate was SCOPE, not necessity — `NSPasteboard.changeCount` / `.string(forType:)` map
// 1:1 onto `UIPasteboard.changeCount` / `.string`, and the sync engine ABOVE the board is transport-only.
//
// So the fork lives here, at the pasteboard-read level, exactly the way ``ClientPasteboard`` already
// forks `write` / `text` / `writeImage` — one actuator with two framework spellings, rather than two
// copies of the tick logic that reads it (docs/56 §3: an actuator that draws nothing belongs with the
// logic it actuates for). What this type is NOT is a second clip conversion: ``PasteboardClip`` remains
// the one file that turns a board into a ``MetadataCodec/ClipboardClip`` and back, and it now answers
// for a `UIPasteboard` in the same body of code it answers for an `NSPasteboard`.
//
// ⚠️ THE ONE ASYMMETRY THAT IS NECESSITY, AND IT IS NOT COSMETIC. macOS lets a background poll read the
// pasteboard's CONTENT freely. iOS does not: since iOS 16 an unattended read of `UIPasteboard.string` /
// `.image` / `.data(forPasteboardType:)` — content the app did not itself write, with no system paste
// gesture behind it — raises a modal "Allow Paste?" alert. A one-second poll would put that alert on
// screen once per new clip, unprompted, which is worse than the missing feature. `changeCount` and the
// `has*` probes do NOT prompt. ``unattendedContentReadIsPermitted`` is that fact, spelled once, and both
// tick loops branch on it: they keep tracking the count everywhere and read the CONTENT only where a
// read costs the user nothing. On iOS the content read happens instead on the paths the user asked for a
// paste on — ``WorkspaceStore/currentLocalClipboard()`` — where the alert is the paste the user just
// requested rather than an ambush.

import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A system pasteboard, in the two shapes clipboard sync needs below the clip conversion: the raw
/// `changeCount` tick and the plain-text head. The clip round trip is ``PasteboardClip``'s, which takes
/// one of these directly.
public struct SystemPasteboard {
    #if canImport(AppKit)
    /// The underlying board. Exposed because ``PasteboardClip`` dispatches on its TYPE, and because a
    /// caller that genuinely needs AppKit (the host performer, a test asserting on a named board) is
    /// not forced to go round this type.
    public let board: NSPasteboard

    public init(_ board: NSPasteboard) {
        self.board = board
    }

    /// Whether an UNATTENDED read of this board's content is free of a user-visible consequence — see
    /// the file header. AppKit: yes, which is why the Mac's monitor has always been a plain poll.
    public static let unattendedContentReadIsPermitted = true

    /// The board's plain-text head, or `nil` when it holds something else.
    public var plainText: String? { board.string(forType: .string) }
    #elseif canImport(UIKit)
    /// The underlying board. Exposed for the same reasons the AppKit half exposes its own.
    public let board: UIPasteboard

    public init(_ board: UIPasteboard) {
        self.board = board
    }

    /// Whether an UNATTENDED read of this board's content is free of a user-visible consequence — see
    /// the file header. UIKit: NO. This is the fact the two tick loops branch on.
    public static let unattendedContentReadIsPermitted = false

    /// The board's plain-text head, or `nil` when it holds something else. A CONTENT read: only call it
    /// where the user asked for a paste (see the header).
    public var plainText: String? { board.string }
    #endif

    /// Advances on every write by anyone. The whole poll is this one integer read — and on iOS it is
    /// the half of the poll the system still allows, because it discloses no content.
    ///
    /// Outside the fork above because both frameworks spell it the same; the `board` it reads is the
    /// one the fork chose.
    public var changeCount: Int { board.changeCount }
}
