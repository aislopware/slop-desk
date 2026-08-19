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
        let index = UInt8(position)
        let mac = half.isMac
        return (0..<slopdesk_settings_layout_group_count(index, mac)).compactMap { position in
            guard let timing = SettingsCatalog.ApplyTiming(
                rawValue: slopdesk_settings_layout_group_timing(index, mac, position),
            ) else { return nil }
            // An absent title is a real answer here, not a marshalling slip: a self-drawing group
            // has none. The TIMING is what says the position resolved to a group at all.
            return Group(
                title: string { slopdesk_settings_layout_group_title(index, mac, position, $0, $1) } ?? "",
                rows: rows(index, mac, position),
                timing: timing,
            )
        }
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

    /// The rows of one group, read position by position.
    private static func rows(_ section: UInt8, _ mac: Bool, _ group: Int) -> [Row] {
        (0..<slopdesk_settings_layout_row_count(section, mac, group)).compactMap { position in
            guard let control = control(section, mac, group, position) else { return nil }
            let key = string { slopdesk_settings_layout_row_key(section, mac, group, position, $0, $1) } ?? ""
            return Row(
                key: key,
                label: label(for: key),
                subtitle: string { slopdesk_settings_layout_row_subtitle(section, mac, group, position, $0, $1) } ?? "",
                control: control,
            )
        }
    }

    /// One row's control: a kind, plus at most one numeric and one string payload.
    private static func control(_ section: UInt8, _ mac: Bool, _ group: Int, _ row: Int) -> Control? {
        let glyph = string { slopdesk_settings_layout_row_glyph(section, mac, group, row, $0, $1) }
        let argument = slopdesk_settings_layout_row_control_argument(section, mac, group, row)
        switch slopdesk_settings_layout_row_control(section, mac, group, row) {
        case UInt8(SLOPDESK_SETTINGS_CONTROL_TOGGLE):
            return glyph.map(Control.toggle(glyph:))
        case UInt8(SLOPDESK_SETTINGS_CONTROL_MENU):
            return SettingsCatalog.Group(rawValue: argument).map { .menu(group: $0, glyph: glyph) }
        case UInt8(SLOPDESK_SETTINGS_CONTROL_CARDS):
            return SettingsCatalog.Group(rawValue: argument).map { .cards(group: $0) }
        case UInt8(SLOPDESK_SETTINGS_CONTROL_SLIDER):
            return SettingsCatalog.Ladder(rawValue: argument).map { .slider(ladder: $0) }
        case UInt8(SLOPDESK_SETTINGS_CONTROL_STEPPER):
            return SettingsCatalog.Stepper(rawValue: argument).map { .stepper(range: $0) }
        case UInt8(SLOPDESK_SETTINGS_CONTROL_TEXT):
            return .text(glyph: glyph)
        case UInt8(SLOPDESK_SETTINGS_CONTROL_NOTE):
            return .note
        case UInt8(SLOPDESK_SETTINGS_CONTROL_BESPOKE):
            return string { slopdesk_settings_layout_row_bespoke_id(section, mac, group, row, $0, $1) }
                .map(Control.bespoke(id:))
        default:
            // `SLOPDESK_SETTINGS_LAYOUT_NONE`, or a kind this build predates. Dropping the row is the
            // honest answer: a renderer cannot invent a widget it has no case for.
            return nil
        }
    }

    /// Reads one delivered string, retrying at the size the door named. `nil` for a zero length, which
    /// every door uses for "there is nothing here" — a row with no glyph, a control with no bespoke id.
    private static func string(_ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String? {
        var out = [UInt8](repeating: 0, count: inlineCapacity)
        var written = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
        guard written > 0 else { return nil }
        if written > out.count {
            out = [UInt8](repeating: 0, count: written)
            written = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
            guard written > 0, written <= out.count else { return nil }
        }
        return String(bytes: out.prefix(written), encoding: .utf8)
    }

    /// Long enough for every group title and glyph; a subtitle is a sentence and overflows it, which
    /// makes the door report its size so the reader asks again.
    private static let inlineCapacity = 64
}
