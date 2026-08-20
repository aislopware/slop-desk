import Foundation
import SlopDeskProtocol
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
import UniformTypeIdentifiers // the UTIs AppKit spells as `NSPasteboard.PasteboardType` constants
#endif

/// The conversion between a system pasteboard and a ``MetadataCodec/ClipboardClip`` — both directions,
/// once.
///
/// Clipboard sync has two ends and each had its own copy of this: `HostClipboardPerformer` on the
/// host, `ClipboardSyncEngine` on the client. Same three-way preference (PNG as-is → an image
/// transcoded → non-empty text), same cap check, same transcode, same write. They are
/// the two halves of ONE wire contract, so a drift in either is a drift in the protocol — precisely
/// the shape of the `process::basename` bug `docs/55` §6 records, where two implementations
/// disagreed for a month and neither side could see it.
///
/// They HAD already drifted, in one visible way and it is a privacy asymmetry, not a cosmetic one:
/// the client refuses to PUSH a concealed clip (`org.nspasteboard.ConcealedType` — what password
/// managers set), and the host does NOT refuse to SHIP one back on a `readClipboard` pull. Copy a
/// password on the host and the client applies it to its own pasteboard.
///
/// That asymmetry is preserved here rather than quietly closed — it is a product decision, not a
/// refactor's to make — and it is preserved as a NAMED parameter (`skippingConcealed`) instead of two
/// function bodies, so it is now one word at each call site rather than a difference nobody can see.
///
/// Its own target because the two callers cannot see each other: `SlopDeskHost` is the daemon graph
/// and `SlopDeskWorkspaceCore` is the client graph, and neither depends on the other. The only thing
/// below both is `SlopDeskProtocol`, which is the WIRE and has no business importing AppKit. So this
/// is a leaf: the platform pasteboard + the clip type, nothing else, and hostd links what it already
/// linked.
///
/// **The THIRD end is the phone, and it is in this file for the reason the other two are.** The client
/// half stopped being macOS-only when the phone stopped shipping a "Paste Recent" menu with nothing
/// behind it, and a `UIPasteboard` conversion written anywhere else would be a fourth body of the same
/// wire contract, free to drift exactly the way the first two already had. So the UIKit refusals are
/// the AppKit refusals, spelled against the same UTIs: a concealed clip stays on the device, a file
/// copy means nothing on the other machine, an over-cap clip is dropped, and the board is left
/// untouched in every skip case.
public enum PasteboardClip {
    /// The concealed-clip marker password managers set (the nspasteboard.org convention), as the raw
    /// UTI so BOTH halves can name it — AppKit wraps it in an `NSPasteboard.PasteboardType`, UIKit
    /// compares it against `UIPasteboard.types` as-is.
    public static let concealedTypeIdentifier = "org.nspasteboard.ConcealedType"

    // MARK: - The client's door: a `SystemPasteboard`, whichever framework backs it

    /// The board's current shippable clip, or `nil` when there is nothing to ship.
    ///
    /// Dispatches on the board's TYPE, so there is no gate here: ``SystemPasteboard/board`` is an
    /// `NSPasteboard` on one half and a `UIPasteboard` on the other, and each resolves to its own
    /// overload below.
    ///
    /// ⚠️ A CONTENT read. On iOS that is permitted only where the user asked for a paste — see
    /// ``SystemPasteboard/unattendedContentReadIsPermitted``.
    public static func read(
        _ pasteboard: SystemPasteboard, skippingConcealed: Bool,
    ) -> MetadataCodec.ClipboardClip? {
        read(pasteboard.board, skippingConcealed: skippingConcealed)
    }

    /// Writes `clip` onto `pasteboard`; `false` — board UNTOUCHED — for content that will not decode.
    /// Writing asks no permission on either platform, which is why the host → client direction of
    /// clipboard sync is whole on a phone while the client → host direction is not.
    @discardableResult
    public static func write(
        _ clip: MetadataCodec.ClipboardClip, to pasteboard: SystemPasteboard,
    ) -> Bool {
        write(clip, to: pasteboard.board)
    }

    #if canImport(AppKit)
    /// The concealed-clip marker password managers set, as AppKit names it.
    public static let concealedType = NSPasteboard.PasteboardType(concealedTypeIdentifier)

    /// The pasteboard's current shippable clip, or `nil` when there is nothing to ship.
    ///
    /// Image before text on purpose: the image IS the clip's fidelity ceiling, and an app that copies
    /// a picture usually declares a text flavor too — its caption or its source URL. Taking the text
    /// would silently downgrade the paste.
    ///
    /// `nil` for an empty board, a file copy (a path on one machine means nothing on the other), an
    /// over-cap clip, an image that will not transcode, and — when `skippingConcealed` — a concealed
    /// one. In every case the pasteboard is left untouched.
    public static func read(
        _ pasteboard: NSPasteboard, skippingConcealed: Bool,
    ) -> MetadataCodec.ClipboardClip? {
        let types = pasteboard.types ?? []
        if skippingConcealed, types.contains(concealedType) { return nil }
        guard !types.contains(.fileURL) else { return nil }
        if let png = pasteboard.data(forType: .png) ?? transcodedTIFF(pasteboard) {
            guard png.count <= MetadataCodec.maxClipboardContentBytes else { return nil }
            return MetadataCodec.ClipboardClip(kind: .imagePNG, bytes: png)
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let bytes = Data(text.utf8)
            guard bytes.count <= MetadataCodec.maxClipboardContentBytes else { return nil }
            return MetadataCodec.ClipboardClip(kind: .text, bytes: bytes)
        }
        return nil
    }

    /// Writes `clip` onto `pasteboard`. `false` — with the pasteboard UNTOUCHED — for non-UTF-8 or
    /// empty text, PNG bytes that will not decode, and an unknown future kind byte.
    ///
    /// Validate-then-clear is the whole reason this returns rather than throws away: the decode
    /// happens BEFORE `clearContents`, so a garbage clip arriving over the wire cannot destroy the
    /// clip that is already on the board. The two callers spell the refusal differently (the host
    /// answers ``MetadataStatus/error`` over the wire, the client just drops), which is why the
    /// answer is a `Bool` and not a status.
    ///
    /// The TIFF twin on the image path is not decoration: `public.tiff` is what many apps read, and
    /// Claude Code's Ctrl+V reads the PNG flavor. Declaring both is what makes one write paste
    /// everywhere.
    @discardableResult
    public static func write(_ clip: MetadataCodec.ClipboardClip, to pasteboard: NSPasteboard) -> Bool {
        switch clip.kind {
        case .text:
            guard let text = String(data: clip.bytes, encoding: .utf8), !text.isEmpty else {
                return false
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .imagePNG:
            guard let rep = NSBitmapImageRep(data: clip.bytes) else { return false }
            pasteboard.clearContents()
            pasteboard.setData(clip.bytes, forType: .png)
            if let tiff = rep.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        case nil:
            return false // unknown future kind — refuse, never guess
        }
        return true
    }

    /// The pasteboard's TIFF flavor transcoded to PNG (most app copies declare TIFF, not PNG);
    /// `nil` when there is no TIFF or it will not decode.
    private static func transcodedTIFF(_ pasteboard: NSPasteboard) -> Data? {
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    #elseif canImport(UIKit)
    /// The pasteboard's current shippable clip, in the same three-way preference and with the same
    /// refusals the AppKit half takes — see that half's docs; this is one contract, two spellings.
    public static func read(
        _ pasteboard: UIPasteboard, skippingConcealed: Bool,
    ) -> MetadataCodec.ClipboardClip? {
        let types = pasteboard.types
        if skippingConcealed, types.contains(concealedTypeIdentifier) { return nil }
        guard !types.contains(UTType.fileURL.identifier) else { return nil }
        let raw = pasteboard.data(forPasteboardType: UTType.png.identifier)
        if let png = raw ?? transcodedImage(pasteboard) {
            guard png.count <= MetadataCodec.maxClipboardContentBytes else { return nil }
            return MetadataCodec.ClipboardClip(kind: .imagePNG, bytes: png)
        }
        if let text = pasteboard.string, !text.isEmpty {
            let bytes = Data(text.utf8)
            guard bytes.count <= MetadataCodec.maxClipboardContentBytes else { return nil }
            return MetadataCodec.ClipboardClip(kind: .text, bytes: bytes)
        }
        return nil
    }

    /// Writes `clip` onto `pasteboard`, validate-then-write for the AppKit half's reason: the decode
    /// happens BEFORE anything is set, so a garbage clip off the wire cannot destroy the clip already
    /// on the board.
    ///
    /// No TIFF twin here — `UIPasteboard` resolves `public.png` for every image consumer on the
    /// platform, and `setData` replaces the board's item outright, so the AppKit `clearContents` pair
    /// has no counterpart to spell.
    @discardableResult
    public static func write(_ clip: MetadataCodec.ClipboardClip, to pasteboard: UIPasteboard) -> Bool {
        switch clip.kind {
        case .text:
            guard let text = String(data: clip.bytes, encoding: .utf8), !text.isEmpty else {
                return false
            }
            pasteboard.string = text
        case .imagePNG:
            guard UIImage(data: clip.bytes) != nil else { return false }
            pasteboard.setData(clip.bytes, forPasteboardType: UTType.png.identifier)
        case nil:
            return false // unknown future kind — refuse, never guess
        }
        return true
    }

    /// The pasteboard's image flavor transcoded to PNG (a copy may declare only `public.jpeg` or a
    /// private image type); `nil` when there is no image or it will not encode.
    private static func transcodedImage(_ pasteboard: UIPasteboard) -> Data? {
        pasteboard.image?.pngData()
    }
    #endif
}
