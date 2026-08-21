import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceCore

// MARK: - SettingsLayout (the near side of a settings page's SHAPE)

/// Which groups a settings page shows, in what order, what each row is, and — the reason this exists
/// rather than being spelled in a view — which platform each of those belongs to.
///
/// `slopdesk_workspace::settings_layout` holds the table; this reads it.
///
/// ## A platform gate is a VALUE here
///
/// The macOS Settings window had thirty-seven `#if os(macOS)` directives threaded through one 2100-line
/// `body`. Every one of them was a fact about a group ("there is no Dock on iOS") wearing a compiler
/// directive's clothes, and in that form it could not be read, counted or tested — the two UI halves
/// could not even agree on how many there were. Here it is a `Platform` field on the Rust side and a ``Half`` argument on this one: ``groups(_:for:)`` filters
/// by the half that asked, and NEITHER renderer carries a gate. That is what lets `SlopDeskMacUI` keep
/// its "not one `#if os(...)`" rule while still drawing the macOS-only groups (docs/56 §3).
///
/// ## What each renderer still owns
///
/// Two things, and they are the two that genuinely cannot cross. A ``Row/key`` names a setting but
/// carries no BINDING — `@Default(.onLaunch)` is a Swift property wrapper over `UserDefaults` — so
/// key → binding stays a `switch` in each half, exactly as `AllSettingsListView.inlineControl(for:)`
/// already is. And a ``Control`` names a widget KIND, not a widget; what a toggle looks like is the
/// half's own business, which is the whole point of splitting them.
///
/// GOLDEN-SAFE: metadata only. Nothing here reads or writes a value or touches a wire codec.
package enum SettingsLayout {
    /// Which half draws a group or a row.
    ///
    /// The renderer does not choose: it passes its own identity to ``groups(_:for:)`` and receives what it
    /// draws. The table's `Mac` and `Phone` mark the settings whose BACKING is absent on the other platform — a
    /// Dock, `LaunchServices` deep-links, `NSSound`. Nothing is hidden merely because a small screen is
    /// crowded: docs/56 §3 says layout diverges and capability does not.
    public enum Half: Sendable {
        case mac
        case phone

        /// What the boundary calls this half.
        var isMac: Bool { self == .mac }
    }

    /// What a row DRAWS. Which widget suits a given setting is a design decision, so it is in the
    /// table rather than in whichever half happened to be written first.
    public enum Control: Equatable, Sendable {
        /// A switch, with the leading SF Symbol the group's icon rail runs through.
        case toggle(glyph: String)
        /// A one-line pop-up menu over an option group.
        case menu(group: SettingsCatalog.Group, glyph: String?)
        /// A row of selectable cards over an option group — art per option, for options that differ
        /// in a way a word cannot show.
        case cards(group: SettingsCatalog.Group)
        /// A slider with preset stops over a scalar ladder.
        case slider(ladder: SettingsCatalog.Ladder)
        /// A plus/minus numeric field over a stepper range — the slider's sibling, for a value whose
        /// useful settings are any literal count rather than a handful of magnitudes.
        case stepper(range: SettingsCatalog.Stepper)
        /// A free-text field.
        case text(glyph: String?)
        /// Prose belonging to the group rather than to a setting — a footnote explaining why a
        /// choice the reader might expect is not offered. The words are the row's ``Row/subtitle``.
        case note
        /// A group the renderer draws itself, named by id.
        case bespoke(id: String)
    }

    /// One row on a settings page.
    public struct Row: Identifiable, Sendable {
        /// The setting this row edits, or `""` for a ``Control/bespoke(id:)`` group. The renderer maps
        /// it to a binding; the LABEL comes from the row table, so it is never spelled twice.
        public let key: String
        /// The row's name, in the page register — `AllSettingsCatalog`'s `pageLabel` for this key.
        public let label: String
        /// The gray line under the label. Deliberately NOT the flat index's description (docs/56 §18).
        public let subtitle: String
        /// What the row draws.
        public let control: Control

        /// A row that edits a setting is that key; one that does not is what it draws (a bespoke id)
        /// or what it says (a note's words). Every row has exactly one of the three, so a `ForEach`
        /// over a group never sees a duplicate.
        public var id: String {
            if !key.isEmpty { return key }
            if case let .bespoke(bespokeID) = control { return bespokeID }
            return subtitle
        }
    }

    /// One titled group of rows.
    public struct Group: Identifiable, Sendable {
        /// The group header, or EMPTY for a group that supplies its own.
        ///
        /// A headerless group is a whole surface rather than a list of rows — the font specimen, the
        /// live cursor preview — so a renderer places its single ``Control/bespoke(id:)`` row without
        /// wrapping it in a section of its own. ``drawsItsOwnHeader`` is how to ask.
        public let title: String
        /// The rows the asking half draws, in reading order.
        public let rows: [Row]
        /// The footer saying when an edit here takes effect.
        public let timing: SettingsCatalog.ApplyTiming

        /// Whether the group draws its own header, and therefore its own section.
        public var drawsItsOwnHeader: Bool { title.isEmpty }

        /// Whether any row here edits a setting, which is what makes ``timing`` worth stating. A group
        /// of nothing but bespoke surfaces has no edit for a timing to describe — the surface inside
        /// says when its own changes land, if it has any.
        public var editsASetting: Bool { rows.contains { !$0.key.isEmpty } }

        public var id: String { title.isEmpty ? rows.first?.id ?? "" : title }
    }

    /// The groups one page shows to one half, in render order — already filtered, so a renderer that
    /// walks this cannot draw a group the other platform owns.
    /// `section` is a ``SettingsCatalog/Section`` id (`"general"`, `"appearance"`, …). It crosses as
    /// that section's POSITION in `SettingsCatalog.sections`, which is the numbering the boundary uses
    /// for every section-keyed door.
    public static func groups(_ section: String, for half: Half) -> [Group] {
        guard let position = SettingsCatalog.sections.firstIndex(where: { $0.id == section }) else { return [] }
        return page(UInt8(position), half.isMac)
    }

    /// What a setting is CALLED on a page, by its key.
    ///
    /// The flat index's `pageLabel`, which is the register a row is set in — deliberately not its
    /// `label` (the index's own, longer form) and not its `description` (docs/56 §18). Named here rather
    /// than at each row because a BESPOKE surface draws settings too: the cursor group's style and blink
    /// rows are inside `cursor-preview` rather than described by the table, and they must still be called
    /// what the table would have called them. Three call sites had this lookup typed out before increment
    /// 49 — here, `SettingsControls.settingLabel(_:)` and the Mac's cursor surface.
    ///
    /// Falls back to the key, which is the honest answer for a setting the catalog does not advertise.
    package static func label(for key: String) -> String {
        AllSettingsCatalog.entries.first { $0.key == key }?.pageLabel ?? key
    }

    // MARK: The crossing

    /// One page, in ONE crossing.
    ///
    /// It used to read position by position: a group count, then a timing, a title and a row count per
    /// group, then six more doors per row — `1 + 3G + 6R` calls for one question, and Appearance is
    /// nine groups and twenty-three rows. Both renderers call ``groups(_:for:)`` from inside a body
    /// they re-evaluate whenever a `@Default` on the page changes, so that walk ran again on every
    /// toggle flip and on every frame of a slider drag. Worse, the far side re-derived the whole page
    /// to answer each of those calls — `row_at` filters the flat table into a fresh array and then
    /// filters that group's rows into a second one — so ~166 crossings did ~166 filters of the table
    /// and ~330 allocations to read 23 rows. `slopdesk_settings_layout_page` answers with the page.
    ///
    /// Empty for a section index no section has, which is what §4's `0` means and what the caller
    /// already got from the group-count door.
    private static func page(_ section: UInt8, _ mac: Bool) -> [Group] {
        let blob = delivered(section, mac)
        guard blob.count >= headerBytes else { return [] }
        let groupCount = be16(blob, 0)
        let rowTotal = be16(blob, 2)
        let rowBase = headerBytes + groupCount * groupRecordBytes
        let stringBase = rowBase + rowTotal * rowRecordBytes
        // The fixed records are read by arithmetic, so a delivery that does not carry all of them is
        // refused whole rather than walked into. The strings after them are padded instead — see
        // ``splitLengthPrefixed(_:count:)`` for why the two truncations are handled differently.
        guard blob.count >= stringBase else { return [] }
        let text = splitLengthPrefixed(
            Array(blob[stringBase...]), count: groupCount + rowTotal * rowFieldCount,
        )
        var out: [Group] = []
        out.reserveCapacity(groupCount)
        var row = 0
        for index in 0..<groupCount {
            let record = headerBytes + index * groupRecordBytes
            let first = row
            // Clamped to the total the header promised. One pass on the far side writes both counts,
            // so they cannot disagree — but this is the one place where "cannot happen" is read out
            // of a buffer instead of out of a type, and a reader that trusted the per-group sum would
            // index past the fixed records rather than draw a short page.
            row = min(row + be16(blob, record + 1), rowTotal)
            // A timing this build has no case for drops the group — but only AFTER its rows have been
            // stepped over, or every group below it would take its neighbour's rows.
            guard let timing = SettingsCatalog.ApplyTiming(rawValue: blob[record]) else { continue }
            // An absent title is a real answer here, not a marshalling slip: a self-drawing group has
            // none. The TIMING is what says the position resolved to a group at all.
            out.append(Group(
                title: text[index],
                rows: rows(blob, text, groupCount: groupCount, rowBase: rowBase, from: first, upTo: row),
                timing: timing,
            ))
        }
        return out
    }

    /// The rows a group owns, read out of the one delivery the page arrived in.
    private static func rows(
        _ blob: [UInt8], _ text: [String],
        groupCount: Int, rowBase: Int, from first: Int, upTo end: Int,
    ) -> [Row] {
        (first..<end).compactMap { position in
            let record = rowBase + position * rowRecordBytes
            let field = groupCount + position * rowFieldCount
            guard let control = control(
                kind: blob[record], argument: blob[record + 1],
                glyph: text[field + 2], bespoke: text[field + 3],
            ) else { return nil }
            let key = text[field]
            return Row(key: key, label: label(for: key), subtitle: text[field + 1], control: control)
        }
    }

    /// One row's control: a kind, plus at most one numeric and one string payload.
    ///
    /// A zero-length string is NO string, which is the reading the ten field doors this replaced
    /// already had — they answered an absent glyph and an empty one with the same zero-length
    /// delivery, so keeping the conflation is what makes this a marshalling change and not a
    /// behaviour one.
    private static func control(kind: UInt8, argument: UInt8, glyph: String, bespoke: String) -> Control? {
        let symbol = glyph.isEmpty ? nil : glyph
        switch kind {
        case UInt8(SLOPDESK_SETTINGS_CONTROL_TOGGLE):
            return symbol.map(Control.toggle(glyph:))
        case UInt8(SLOPDESK_SETTINGS_CONTROL_MENU):
            return SettingsCatalog.Group(rawValue: argument).map { .menu(group: $0, glyph: symbol) }
        case UInt8(SLOPDESK_SETTINGS_CONTROL_CARDS):
            return SettingsCatalog.Group(rawValue: argument).map { .cards(group: $0) }
        case UInt8(SLOPDESK_SETTINGS_CONTROL_SLIDER):
            return SettingsCatalog.Ladder(rawValue: argument).map { .slider(ladder: $0) }
        case UInt8(SLOPDESK_SETTINGS_CONTROL_STEPPER):
            return SettingsCatalog.Stepper(rawValue: argument).map { .stepper(range: $0) }
        case UInt8(SLOPDESK_SETTINGS_CONTROL_TEXT):
            return .text(glyph: symbol)
        case UInt8(SLOPDESK_SETTINGS_CONTROL_NOTE):
            return .note
        case UInt8(SLOPDESK_SETTINGS_CONTROL_BESPOKE):
            return bespoke.isEmpty ? nil : .bespoke(id: bespoke)
        default:
            // `SLOPDESK_SETTINGS_LAYOUT_NONE`, or a kind this build predates. Dropping the row is the
            // honest answer: a renderer cannot invent a widget it has no case for.
            return nil
        }
    }

    /// The page's bytes, retrying at the size the door named.
    ///
    /// There is no pointer scope to put the retry inside, unlike `RailRowsBuilder`'s: every input here
    /// is a scalar, so the only borrowed buffer is the one being resized — and reallocating `out`
    /// inside its own `withUnsafeMutableBufferPointer` is what that rule forbids, not what it asks
    /// for. The wrapped table is pure, so the second call cannot disagree with the first.
    private static func delivered(_ section: UInt8, _ mac: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: inlineCapacity)
        var written = out.withUnsafeMutableBufferPointer {
            slopdesk_settings_layout_page(section, mac, $0.baseAddress, $0.count)
        }
        guard written > 0 else { return [] }
        if written > out.count {
            out = [UInt8](repeating: 0, count: written)
            written = out.withUnsafeMutableBufferPointer {
                slopdesk_settings_layout_page(section, mac, $0.baseAddress, $0.count)
            }
            guard written > 0, written <= out.count else { return [] }
        }
        return Array(out.prefix(written))
    }

    /// The delivery's `count` length-prefixed strings, padded with empties if it came up short.
    ///
    /// Padding rather than trusting the length: a short delivery means the door and this reader
    /// disagree about the layout, and the alternative to padding is a silent off-by-one where every
    /// row after the gap renders its neighbour's words.
    private static func splitLengthPrefixed(_ blob: [UInt8], count: Int) -> [String] {
        var fields: [String] = []
        fields.reserveCapacity(count)
        var cursor = blob.startIndex
        while fields.count < count, blob.distance(from: cursor, to: blob.endIndex) >= 4 {
            var length = 0
            for offset in 0..<4 { length = length << 8 | Int(blob[cursor + offset]) }
            cursor += 4
            guard blob.distance(from: cursor, to: blob.endIndex) >= length else { break }
            // The producer is `slopdesk_workspace::settings_layout`, so these bytes are a Rust
            // `&'static str`'s and cannot be invalid UTF-8. A failable init would add a branch meaning
            // "this row has no label", which is a wrong answer rather than a cautious one.
            // swiftlint:disable:next optional_data_string_conversion
            fields.append(String(decoding: blob[cursor..<(cursor + length)], as: UTF8.self))
            cursor += length
        }
        while fields.count < count { fields.append("") }
        return fields
    }

    /// One big-endian pair of bytes at `offset` — every count in the delivery is one.
    private static func be16(_ blob: [UInt8], _ offset: Int) -> Int {
        Int(blob[offset]) << 8 | Int(blob[offset + 1])
    }

    /// The delivery's two counts: how many groups, then how many rows across all of them.
    private static let headerBytes = 4
    /// Per group: a timing byte and its row count.
    private static let groupRecordBytes = 3
    /// Per row: a control kind and its numeric argument.
    private static let rowRecordBytes = 2
    /// Per row, in the flat string run: key, subtitle, glyph, bespoke id.
    private static let rowFieldCount = 4

    /// Past the widest page — Controls on a Mac, measured at 3676 bytes — so the retry above is a
    /// correctness property rather than a second crossing every settings render pays.
    /// `every_page_fits_the_near_sides_first_guess` in `rust/slopdesk-ffi/src/settings_layout.rs` is
    /// what fails if a new group ever pushes past it, on the side that can measure it.
    private static let inlineCapacity = 4096
}
