import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

// SettingsCatalog — the near side of what Settings OFFERS.
//
// A settings page is two things stacked. One is a control — a card grid, a menu row, a slider —
// which is a view and belongs to whichever framework is drawing it. The other is the ANSWER to
// "what can this be set to, what is each choice called, and what does the number read as", which is
// the same on a phone as on a Mac and is not a view at all. Everything here is the second thing, and
// none of it decides anything: the sections and their order, every group's choices and their honest
// captions, the ladders' stops and their readouts all live in `slopdesk_workspace::settings_catalog`.
//
// THE TOKEN IS THE CONTRACT. Each choice crosses as the value the store PERSISTS — the Swift enum's
// `rawValue` — and ``SettingsCatalog/options(_:as:)`` rebuilds the enum from it. A catalog that
// carried case indices instead would silently re-point a row at a different value the first time a
// case was inserted on either side. The cost is that a token nothing parses is DROPPED, which is why
// `SettingsOptionCatalogTests` pins every group against its enum's `allCases`: a dropped option is
// invisible in a card grid, since there is no "…" to hint at what is missing.

/// One choice in a settings group: the value it writes, its label, and an optional caption.
///
/// `Sendable` over a `Sendable` value — pure, immutable option data, reachable from any isolation
/// without a `@MainActor` hop.
package struct SettingsOption<Value: Hashable & Sendable>: Identifiable, Sendable {
    package let value: Value
    package let label: String
    /// A short qualifier on the label, where a choice needs to be honest about a caveat ("same as
    /// End today", "only if busy"). `nil` for the common case.
    package let caption: String?

    /// The one-line form a `.menu` `Picker` shows — the label with the caveat folded in. It is a
    /// CROSSED field, not a local concat: where the en dash goes and what a captionless row reads as
    /// are rules, and `slopdesk_settings_option_menu_label` is where they live.
    package let menuLabel: String

    package var id: Value { value }

    package init(_ value: Value, _ label: String, caption: String?, menuLabel: String) {
        self.value = value
        self.label = label
        self.caption = caption
        self.menuLabel = menuLabel
    }
}

/// The option lists, the taxonomy and the scalar ladders, read across the boundary.
package enum SettingsCatalog {
    /// Which control's worth of choices. The raw values are the boundary's own case indices.
    package enum Group: UInt8, Sendable, CaseIterable {
        case cursorStyle = 0
        case newTabPosition = 1
        case density = 2
        case windowSize = 3
        case desktopPresentation = 4
        case optionAsAlt = 5
        case rightClickAction = 6
        case onLaunch = 7
        case closeConfirmation = 8
        case closeConfirmationTab = 9
        case notifyWhileForeground = 10
        case workingDirectory = 11
        case linkCmdClick = 12
        case linkCmdShiftClick = 13
        case autoDetectLinkSchemes = 14
        case autoHideTabsPanel = 15
        case cursorBlink = 16
        case clipboardAccess = 17
        case lineHeight = 18
        case fontLigatures = 19
        case fontStyleMode = 20
        case fontBlending = 21
        case videoPacer = 22
    }

    /// A group's choices, in the order they render, rebuilt as `Value`.
    ///
    /// A token `Value` cannot parse is DROPPED rather than substituted — a wrong option is worse
    /// than a missing one, and `SettingsOptionCatalogTests` is what makes sure none ever is.
    package static func options<Value: RawRepresentable & Hashable & Sendable>(
        _ group: Group,
        as _: Value.Type = Value.self,
    ) -> [SettingsOption<Value>] where Value.RawValue == String {
        tokens(group).compactMap { row in
            guard let value = Value(rawValue: row.token) else { return nil }
            return SettingsOption(value, row.label, caption: row.caption, menuLabel: row.menuLabel)
        }
    }

    /// A group's choices with their raw tokens as the value — for the groups the store persists as
    /// a bare string rather than through an enum (theme density is the only one).
    package static func stringOptions(_ group: Group) -> [SettingsOption<String>] {
        tokens(group).map { SettingsOption($0.token, $0.label, caption: $0.caption, menuLabel: $0.menuLabel) }
    }

    /// One group's rows exactly as the catalog holds them.
    package static func tokens(
        _ group: Group,
    ) -> [(token: String, label: String, caption: String?, menuLabel: String)] {
        (0..<slopdesk_settings_option_count(group.rawValue)).map { index in
            (
                token: string { slopdesk_settings_option_token(group.rawValue, index, $0, $1) } ?? "",
                label: string { slopdesk_settings_option_label(group.rawValue, index, $0, $1) } ?? "",
                caption: string { slopdesk_settings_option_caption(group.rawValue, index, $0, $1) },
                menuLabel: string { slopdesk_settings_option_menu_label(group.rawValue, index, $0, $1) } ?? "",
            )
        }
    }

    /// What one persisted token is CALLED — for a readout that shows the current choice without
    /// drawing the control (the all-settings index's jump row). Falls back to the token itself,
    /// which is the honest answer for a value no option in the group names.
    package static func label(_ group: Group, for token: String) -> String {
        tokens(group).first { $0.token == token }?.label ?? token
    }

    /// The `density` tokens the store persists, named rather than spelled. Density is the one group
    /// with no Swift enum behind it, so these are what keep the picker, the two `?? comfortable`
    /// fallbacks and the card art's compact test on one spelling.
    package static var densityComfortable: String {
        string { slopdesk_settings_density_token(false, $0, $1) } ?? ""
    }

    package static var densityCompact: String {
        string { slopdesk_settings_density_token(true, $0, $1) } ?? ""
    }

    // MARK: The taxonomy

    /// One settings section — a row in the Mac's navigator and a row in the phone's list.
    package struct Section: Identifiable, Sendable, Equatable {
        /// The routed identifier.
        package let id: String
        /// The row label.
        package let title: String
        /// The row glyph, as an SF Symbol name.
        package let systemImage: String
    }

    /// The whole taxonomy, in the one order both lists render.
    package static let sections: [Section] = (0..<slopdesk_settings_section_count()).map { index in
        Section(
            id: string { slopdesk_settings_section_id(index, $0, $1) } ?? "",
            title: string { slopdesk_settings_section_title(index, $0, $1) } ?? "",
            systemImage: string { slopdesk_settings_section_symbol(index, $0, $1) } ?? "",
        )
    }

    /// One section by its routed identifier, for a caller holding the id rather than the row.
    package static func section(_ id: String) -> Section? { sections.first { $0.id == id } }

    // MARK: Apply timing

    /// When a setting takes effect, surfaced as a chip so the distinction is a data attribute rather
    /// than prose. The raw values are the boundary's own case indices.
    package enum ApplyTiming: UInt8, Sendable, CaseIterable {
        /// Applies immediately — a terminal reload, a theme, a republished keybinding.
        case live = 0
        /// A HOST-read flag shipped over the sidecar, which applies on the next host connection.
        case reconnect = 1

        package var label: String {
            SettingsCatalog.string { slopdesk_settings_timing_label(rawValue, $0, $1) } ?? ""
        }

        package var symbol: String {
            SettingsCatalog.string { slopdesk_settings_timing_symbol(rawValue, $0, $1) } ?? ""
        }
    }

    // MARK: The ladders

    /// Which slider. The raw values are the boundary's own case indices.
    package enum Ladder: UInt8, Sendable, CaseIterable {
        case scrollback = 0
        case scrollMultiplier = 1
        case busyDelay = 2
        case videoSharpen = 3

        /// The settable range. Empty for a ladder the boundary does not know, which no case is.
        package var range: ClosedRange<Double> {
            let bounds = slopdesk_settings_ladder(rawValue)
            guard bounds.known, bounds.min <= bounds.max else { return 0...0 }
            return bounds.min...bounds.max
        }

        /// The slider's granularity.
        package var step: Double { slopdesk_settings_ladder(rawValue).step }

        /// The magnitude stops, in order — the values a user actually picks, so "back to normal" is
        /// one tap rather than a drag hunt.
        package var presets: [(label: String, value: Double)] {
            (0..<slopdesk_settings_ladder_preset_count(rawValue)).compactMap { index in
                let value = slopdesk_settings_ladder_preset_value(rawValue, index)
                // NaN is the door's "no such stop" — zero would be indistinguishable from the busy
                // delay's own `Instant`.
                guard value.isFinite else { return nil }
                let label = SettingsCatalog.string {
                    slopdesk_settings_ladder_preset_label(rawValue, index, $0, $1)
                }
                guard let label else { return nil }
                return (label: label, value: value)
            }
        }

        /// What the slider's current value reads as.
        package func readout(_ value: Double) -> String {
            SettingsCatalog.string { slopdesk_settings_ladder_readout(rawValue, value, $0, $1) } ?? ""
        }
    }

    // MARK: The stepper ranges

    /// Which numeric field. The raw values are the boundary's own case indices.
    ///
    /// The ``Ladder`` sibling. A ladder exists where the useful values are a handful of magnitudes;
    /// a range exists where the value is a literal the reader already knows the meaning of, and
    /// every number in it is as reasonable as its neighbour. A range is named for the UNIT it
    /// counts, not for a setting — the four window fields are two pairs sharing two ranges, and what
    /// tells Columns from Rows is the row's label.
    package enum Stepper: UInt8, Sendable, CaseIterable {
        case windowCells = 0
        case windowPixels = 1
        case fontPoints = 2
        case videoQp = 3
        case videoFecParity = 4
        case videoFecGroup = 5

        /// The settable range. Empty for a range the boundary does not know, which no case is.
        package var range: ClosedRange<Int> {
            let bounds = slopdesk_settings_stepper(rawValue)
            guard bounds.known, bounds.min <= bounds.max else { return 0...0 }
            return Int(bounds.min)...Int(bounds.max)
        }

        /// The same range for a field the model holds as a `Double`.
        package var doubleRange: ClosedRange<Double> {
            let whole = range
            return Double(whole.lowerBound)...Double(whole.upperBound)
        }

        /// How far one click moves it.
        package var step: Int { Int(slopdesk_settings_stepper(rawValue).step) }

        /// What follows the number — `" px"`, or nothing for a bare count.
        package var unit: String {
            SettingsCatalog.string { slopdesk_settings_stepper_unit(rawValue, $0, $1) } ?? ""
        }

        /// What the value reads as after the row's own label.
        package func readout(_ value: Int) -> String { "\(value)\(unit)" }

        /// The same, for a field the model holds as a `Double`. A whole value prints as a whole
        /// number, so `13.0` reads `13`; a fractional one prints as it is rather than rounding, so a
        /// size typed as `13.5` in the flat index does not read back here as a value nothing holds.
        /// Spelled without a formatter on purpose — this is a number, not a localised quantity, and
        /// it has to match the token the config bridge parses.
        package func readout(_ value: Double) -> String {
            let whole = value.rounded(.towardZero)
            return value == whole ? readout(Int(whole)) : "\(value)\(unit)"
        }
    }

    // MARK: The crossing

    /// Reads one delivered string at this catalog's inline size. `nil` for a zero length, which
    /// every door uses for "there is nothing here". The retry is ``wsDelivered(capacity:_:)``'s;
    /// what is named here is only how much of an answer this catalog expects to fit.
    private static func string(_ door: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> String? {
        wsDelivered(capacity: inlineCapacity, door)
    }

    /// Long enough for every label and readout the catalog holds; a longer one makes the door report
    /// its size and the reader ask again.
    private static let inlineCapacity = 64
}
