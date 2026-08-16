import CSlopDeskFFI
import Foundation
import SlopDeskArena

/// How a ``HostWindowRecord`` crosses the FFI boundary, spelled once.
///
/// Every door that carries window records takes them as `SlopDeskControlRecord` rows naming
/// `(offset, length)` spans in one arena — the codebase's ONE flat record type (docs/55 §4c). Three
/// call sites need that marshalling: the control codec's encode, the client's chunk assembler and
/// the host's feed cache. This is it, so a fourth cannot invent a fourth layout.
///
/// A `String` crosses as UTF-8 bytes in the arena and comes back through `String(bytes:encoding:)`;
/// a span that does not fit the arena reads as empty rather than trapping, because the same shape
/// carries decoded wire input on the client side.
public extension HostWindowRecord {
    /// This record flattened into a row, its three strings appended to `arena`.
    func row(into arena: inout Data) -> SlopDeskControlRecord {
        var row = SlopDeskControlRecord()
        row.id = windowID
        row.width = widthPt
        row.height = heightPt
        row.flags = flags.rawValue
        row.display_index = displayIndex
        (row.name_offset, row.name_length) = Self.intern(appName, into: &arena)
        (row.title_offset, row.title_length) = Self.intern(title, into: &arena)
        (row.bundle_offset, row.bundle_length) = Self.intern(bundleID, into: &arena)
        return row
    }

    /// The record one row describes.
    static func of(_ row: SlopDeskControlRecord, arena: Data) -> Self {
        Self(
            windowID: row.id, widthPt: row.width, heightPt: row.height,
            flags: HostWindowFlags(rawValue: row.flags), displayIndex: row.display_index,
            bundleID: span(arena, row.bundle_offset, row.bundle_length),
            appName: span(arena, row.name_offset, row.name_length),
            title: span(arena, row.title_offset, row.title_length),
        )
    }

    /// A whole list flattened: the rows, and the one arena their spans name.
    static func rows(_ records: [Self]) -> (rows: [SlopDeskControlRecord], arena: Data) {
        var arena = Data()
        let rows = records.map { record in record.row(into: &arena) }
        return (rows, arena)
    }

    /// Appends one string's UTF-8 and answers where it landed — ``ArenaText/intern(_:into:)``.
    private static func intern(_ value: String, into arena: inout Data) -> (UInt32, UInt32) {
        let span = ArenaText.intern(value, into: &arena)
        return (span.offset, span.length)
    }

    /// One arena span as the string it holds — ``ArenaText/text(_:offset:length:)``.
    private static func span(_ arena: Data, _ offset: UInt32, _ length: UInt32) -> String {
        ArenaText.text(arena, offset: Int(offset), length: Int(length))
    }
}
