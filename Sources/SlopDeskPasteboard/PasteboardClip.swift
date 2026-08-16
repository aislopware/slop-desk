#if os(macOS)
import AppKit
import Foundation
import SlopDeskProtocol

/// The conversion between an `NSPasteboard` and a ``MetadataCodec/ClipboardClip`` — both directions,
/// once.
///
/// Clipboard sync has two ends and each had its own copy of this: `HostClipboardPerformer` on the
/// host, `ClipboardSyncEngine` on the client. Same three-way preference (PNG as-is → TIFF transcoded
/// → non-empty text), same cap check, same TIFF transcode, same PNG-plus-TIFF-twin write. They are
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
/// is a leaf: AppKit + the clip type, nothing else, and hostd links what it already linked.
public enum PasteboardClip {
    /// The concealed-clip marker password managers set (the nspasteboard.org convention).
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

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
}
#endif
