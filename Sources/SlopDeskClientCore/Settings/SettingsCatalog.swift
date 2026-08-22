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
    /// are rules, and `settings_catalog::OptionRow::menu_label` is where they live — it rides the same
    /// delivery as the label it folds.
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
    ///
    /// Read out of ``groupRows``, so this is ZERO crossings after the first touch of the catalog —
    /// see that property for why memoising is honest here and what it is worth.
    package static func tokens(
        _ group: Group,
    ) -> [(token: String, label: String, caption: String?, menuLabel: String)] {
        groupRows[Int(group.rawValue)]
    }

    /// Every group's rows, read once.
    ///
    /// The catalog is twenty-three `&'static` tables on the far side and this is what they look like
    /// on this one — a pure function of a constant, with no store, no defaults and no platform in
    /// it. ``sections`` has been a `static let` for exactly that reason since it was written; this is
    /// the same argument for the bigger table.
    ///
    /// It is worth stating what it cost NOT to be one. ``tokens(_:)`` is what ``options(_:as:)``,
    /// ``stringOptions(_:)`` and ``label(_:for:)`` all forward to, so naming ONE token rebuilt the
    /// whole group — and every reader above them sits in a `SwiftUI` `body` or an `NSView` rebuild:
    /// `AllSettingsListView`'s token picker (per keystroke in its search field, and again on every
    /// one of its ~55 `@Default` writes), `MacAllSettingsIndex.refill` (per keystroke, explicitly —
    /// `sendsWholeSearchString` is off), and every phone settings page's `control(_:)` (per render
    /// pass). Against the tables that is 23 groups, 67 options, `1 + 4n` per group ⇒ **291 doors**,
    /// paid again on every one of those events.
    ///
    /// The crossings were the cheap half, which is the same thing `slopdesk_settings_layout_page`
    /// found one register up. A door costs ~1 ns; a door that answers a STRING costs what the near
    /// side spends around it — a 64-byte `[UInt8]` and a `String` per field. Measured with `swiftc -O`
    /// against the shipped `SlopDeskFFI.xcframework` (two runs agreeing inside 1%):
    ///
    /// | | old | new |
    /// | --- | --- | --- |
    /// | one group (`cursorStyle`, 4 options) | 2.71 µs | 0.46 µs |
    /// | one group (`rightClickAction`, 5) | 3.30 µs | 0.54 µs |
    /// | all 23 groups | **51.3 µs** | 10.4 µs |
    /// | a memoised read | — | **0 ns** (an array subscript) |
    ///
    /// So the port itself is ~5× on the marshalling, and the `let` is what turns the remaining 10 µs
    /// into a once-per-process cost. Every reader listed above now pays an array subscript.
    ///
    /// Indexed by ``Group`` raw value, and `Group` is `CaseIterable` with contiguous raw values from
    /// zero, so the subscript in ``tokens(_:)`` is total.
    private static let groupRows: [[(token: String, label: String, caption: String?, menuLabel: String)]] =
        Group.allCases.sorted { $0.rawValue < $1.rawValue }.map(rows(of:))

    /// One group, in ONE crossing.
    ///
    /// The layout is `slopdesk_ffi::settings_options`'s: a big-endian option count, then four
    /// length-prefixed strings per option — token, label, caption, menu label, in render order.
    ///
    /// A zero-length caption is NO caption, which is what the deleted per-field door answered too:
    /// it delivered nothing for a choice with no caveat AND for a choice whose caveat was empty, and
    /// this side read both back as `nil`. Keeping the conflation is what makes this a marshalling
    /// change rather than a behaviour one.
    private static func rows(
        of group: Group,
    ) -> [(token: String, label: String, caption: String?, menuLabel: String)] {
        let blob = delivered(group)
        guard blob.count >= countBytes else { return [] }
        let count = Int(blob[0]) << 8 | Int(blob[1])
        let text = wsRuns(Array(blob[countBytes...]), count: count * optionFieldCount)
        return (0..<count).map { index in
            let field = index * optionFieldCount
            let caption = text[field + 2]
            return (
                token: text[field],
                label: text[field + 1],
                caption: caption.isEmpty ? nil : caption,
                menuLabel: text[field + 3],
            )
        }
    }

    /// The group's bytes, retrying at the size the door named.
    ///
    /// There is no pointer scope to put the retry inside — the only argument is a scalar, so the one
    /// borrowed buffer is the one being resized, and reallocating `out` inside its own
    /// `withUnsafeMutableBufferPointer` is what that rule forbids rather than what it asks for. The
    /// wrapped table is pure, so the second call cannot disagree with the first.
    private static func delivered(_ group: Group) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: groupInlineCapacity)
        var written = out.withUnsafeMutableBufferPointer {
            slopdesk_settings_option_group(group.rawValue, $0.baseAddress, $0.count)
        }
        guard written > 0 else { return [] }
        if written > out.count {
            out = [UInt8](repeating: 0, count: written)
            written = out.withUnsafeMutableBufferPointer {
                slopdesk_settings_option_group(group.rawValue, $0.baseAddress, $0.count)
            }
            guard written > 0, written <= out.count else { return [] }
        }
        return Array(out.prefix(written))
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
    /// `let` rather than a computed `var` for ``groupRows``' reason: the answer is a Rust `const`, and
    /// the two of these are read from `SettingsIndexPresentation.dedicatedValue` and from the theme
    /// card's is-this-the-compact-one test — both per render.
    package static let densityComfortable: String =
        string { slopdesk_settings_density_token(false, $0, $1) } ?? ""

    package static let densityCompact: String =
        string { slopdesk_settings_density_token(true, $0, $1) } ?? ""

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

    /// The sections a settings search field shows for `needle`, in the order ``sections`` renders —
    /// the whole list for a blank one, which is the zero state.
    ///
    /// The search belongs beside the taxonomy, and until now it was not: ``sections`` has crossed the
    /// boundary since it was written, but each face above it wrote its own `lowercased().contains(…)`
    /// over the answer, so the list was Rust's and the rule over the list was Swift's — four times.
    /// That is `docs/55` §8's drift class, and §8's point is that this class is not ranked by cost:
    /// on cost alone the filter is ~750 ns per keystroke over eight sections and would never be worth
    /// a door. What is worth it is that "which sections does this needle name" stops having two
    /// answers, so a title that starts folding differently cannot mean one thing on the Mac and
    /// another on the phone.
    ///
    /// The needle is passed RAW. The far side folds ASCII case itself, so a caller neither lowercases
    /// nor trims first — and must not, since doing so would be the third spelling of the rule.
    ///
    /// One caveat worth naming where the callers can see it: this folds ASCII case and nothing else,
    /// while `localizedCaseInsensitiveContains` normalises and case-FOLDS — `ﬁle` holds `file`,
    /// `straße` holds `strasse`, NFC agrees with NFD. It does NOT fold diacritics, whatever this
    /// comment used to say: probed 2026-08-22, `Café` does not hold `cafe`, and only
    /// `localizedStandardContains` reaches that far. The two therefore agree on ASCII and only on
    /// ASCII. Every section title is ASCII and `slopdesk-workspace` pins that in a test, so the
    /// substitution is exact here — but it is not a general-purpose replacement for a locale-aware
    /// search over user text.
    package static func sections(matching needle: String) -> [Section] {
        var typed = Array(needle.utf8)
        // The arithmetic bound: no more sections can match than there are, so §4's retry is
        // unreachable rather than merely unlikely.
        var places = [UInt32](repeating: 0, count: sections.count)
        let matched = typed.withUnsafeMutableBufferPointer { text in
            places.withUnsafeMutableBufferPointer { out in
                slopdesk_settings_sections_matching(
                    text.baseAddress, text.count, out.baseAddress, out.count,
                )
            }
        }
        guard matched <= places.count else { return sections }
        return places.prefix(matched).compactMap { place in
            let index = Int(place)
            return sections.indices.contains(index) ? sections[index] : nil
        }
    }

    // MARK: Apply timing

    /// When a setting takes effect, surfaced as a chip so the distinction is a data attribute rather
    /// than prose. The raw values are the boundary's own case indices.
    package enum ApplyTiming: UInt8, Sendable, CaseIterable {
        /// Applies immediately — a terminal reload, a theme, a republished keybinding.
        case live = 0
        /// A HOST-read flag shipped over the sidecar, which applies on the next host connection.
        case reconnect = 1

        package var label: String { Self.chips[Int(rawValue)].label }

        package var symbol: String { Self.chips[Int(rawValue)].symbol }

        /// Both chips, read once. `SettingsControls.timingFooter` draws one per GROUP per render —
        /// ~10 per settings page per pass, for two pairs of words that are `&'static` on the far side.
        private static let chips: [(label: String, symbol: String)] = allCases
            .sorted { $0.rawValue < $1.rawValue }
            .map { timing in
                (
                    label: SettingsCatalog.string { slopdesk_settings_timing_label(timing.rawValue, $0, $1) } ?? "",
                    symbol: SettingsCatalog
                        .string { slopdesk_settings_timing_symbol(timing.rawValue, $0, $1) } ?? "",
                )
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
        package var range: ClosedRange<Double> { Self.shapes[Int(rawValue)].range }

        /// The slider's granularity.
        package var step: Double { Self.shapes[Int(rawValue)].step }

        /// The magnitude stops, in order — the values a user actually picks, so "back to normal" is
        /// one tap rather than a drag hunt.
        package var presets: [(label: String, value: Double)] { Self.shapes[Int(rawValue)].presets }

        /// Every ladder's shape, read once.
        ///
        /// Each of the three above was a door per read, and a slider row reads all three — so a page
        /// carrying `busyDelay` crossed 11 times per render pass just to draw its stops, and the Mac's
        /// row builder read `range` TWICE. None of it can change: the ladder table is `&'static`. What
        /// stays a per-call door is ``readout(_:)``, which takes the live value and so has a different
        /// answer every frame of a drag — that one is the crossing this port has no quarrel with.
        private typealias Shape = (
            range: ClosedRange<Double>, step: Double, presets: [(label: String, value: Double)],
        )

        private static let shapes: [Shape] =
            allCases.sorted { $0.rawValue < $1.rawValue }.map { ladder in
                let bounds = slopdesk_settings_ladder(ladder.rawValue)
                let known = bounds.known && bounds.min <= bounds.max
                return (
                    range: known ? bounds.min...bounds.max : 0...0,
                    step: bounds.step,
                    presets: ladder.crossedPresets,
                )
            }

        /// The stops as the boundary hands them over — `1 + 2n` crossings, paid once by ``shapes``.
        private var crossedPresets: [(label: String, value: Double)] {
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
        package var range: ClosedRange<Int> { Self.shapes[Int(rawValue)].range }

        /// The same range for a field the model holds as a `Double`.
        package var doubleRange: ClosedRange<Double> { Self.shapes[Int(rawValue)].doubleRange }

        /// How far one click moves it.
        package var step: Int { Self.shapes[Int(rawValue)].step }

        /// Every range's shape, read once — ``Ladder/shapes``' argument at the stepper. A stepper row
        /// reads `range` (or `doubleRange`) and `step`, and the Mac's builder reads the range twice.
        private static let shapes: [(range: ClosedRange<Int>, doubleRange: ClosedRange<Double>, step: Int)] =
            allCases.sorted { $0.rawValue < $1.rawValue }.map { stepper in
                let bounds = slopdesk_settings_stepper(stepper.rawValue)
                let known = bounds.known && bounds.min <= bounds.max
                let whole = known ? Int(bounds.min)...Int(bounds.max) : 0...0
                return (
                    range: whole,
                    doubleRange: Double(whole.lowerBound)...Double(whole.upperBound),
                    step: Int(bounds.step),
                )
            }

        /// What the value reads as after the row's own label.
        package func readout(_ value: Int) -> String { readout(Double(value)) }

        /// The same, for a field the model holds as a `Double` — one door for both, because the
        /// whole-vs-fractional rule is one rule.
        ///
        /// Both were COMPOSED here until 2026-08-20, out of a `unit` door and a `\(value)`, against
        /// a `Stepper::readout` in the crate that composed the same string and had no door at all.
        /// The two had already stopped agreeing: only this side knew that `13.0` must read `13`.
        package func readout(_ value: Double) -> String {
            SettingsCatalog.string { slopdesk_settings_stepper_readout(rawValue, value, $0, $1) } ?? ""
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

    /// The delivery's option count, in front of the strings.
    private static let countBytes = 2
    /// Per option, in the flat string run: token, label, caption, menu label.
    private static let optionFieldCount = 4

    /// Past the widest group — Font → Style & Rendering, measured at 240 bytes — so the retry in
    /// ``delivered(_:)`` is a correctness property rather than a second crossing.
    /// `every_group_fits_the_near_sides_first_guess` in `rust/slopdesk-ffi/src/settings_options.rs`
    /// is what fails if a new option ever pushes past it, on the side that can measure it.
    private static let groupInlineCapacity = 1024
}
