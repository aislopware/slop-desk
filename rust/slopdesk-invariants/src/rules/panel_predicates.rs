//! One search predicate, one minted voice, one level array, one cursor label.
//!
//! Ported from the deleted `check-supervisor.sh`. Four rules about the device panels and the design
//! floor under them, and each guards a copy that a test cannot catch parting from its twin: the
//! copy a test holds is not the copy the other shell runs, the memo and the builder agree by
//! construction, the two spellings of one setting sit a scroll apart on the same page.
//!
//! ⚠️ EVERY PHONE PATH IN THIS MODULE WAS RE-AIMED ON 2026-08-28, and the WHY matters more than the
//! rename. `3f11c6e6` deleted the entire `SwiftUI` iOS client without touching this ledger, so
//! every rule below spent a week reporting "… is gone" about a subject that had not been withdrawn
//! — it had been REWRITTEN. That verdict is the worst kind a ratchet can give: it is red, so nobody
//! reads it as vacuous, and it is wrong, so nobody can act on it. The `UIKit` twins landed in the
//! same directories under the settled `Phone*` convention (`292e2548`, `8f738207`), carrying the
//! same responsibility and, as it turns out, the same type names with the same prefix. The rules
//! now name those. The break-test fixtures moved with them: a fixture still spelling the dead name
//! proves the rule against a subject the tree does not have, which is how a rule goes green on
//! nothing.

use crate::claim::{Claim, Extract, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The one file that asks the crate for the row predicate.
const ROW_FILTER: &str = "Sources/SlopDeskDevicePanels/Shared/DeviceRowFilter.swift";
/// Where the instrument voice is minted, and memoized.
const SLATE_DESIGN: &str = "Sources/SlopDeskSlate/SlateDesign.swift";
/// The console's level menu, which is androidd's array or it is a second list.
const ANDROID_LOG_LEVEL: &str = "Sources/SlopDeskDevicePanels/Android/AndroidLogLevel.swift";
/// The cursor style, which has one label and it is the catalog's.
const TERMINAL_PREFS: &str = "Sources/SlopDeskVideoProtocol/Settings/TerminalPreferences.swift";
/// The Swift keycode face, which used to spell thirteen of the crate's numbers a second time.
const ANDROID_KEYCODE_SWIFT: &str = "Sources/SlopDeskDevicePanels/Android/AndroidKeycode.swift";
/// The one table that says what Android number a functional key is.
const ANDROID_KEYCODE_RUST: &str = "rust/slopdesk-devicepanel/src/panel_key.rs";

/// ONE search-box predicate for both device panels, both drawings
///
/// `localizedCaseInsensitiveContains` was spelled SIX times over "does any field of this row
/// contain what was typed" — twice in `AndroidPresentation` (the list, the console) and once each
/// in the four simulator views, two `SwiftUI` and two `AppKit`. Only one of the six was ever
/// reached by a test, which is the drift class `docs/55` §8 is about: the copy a test holds is not
/// the copy the other shell runs, and nothing can notice them parting. They route through
/// `DeviceRowFilter` → `slopdesk_ws_binding_row_matches` → `slopdesk_workspace::binding_search`
/// now, which is the rule the palette, Settings and the keybindings editor were already using.
///
/// It is also 8–13× off. Scratch `swiftc -O` harness against the shipped `macos-arm64` slice, at
/// `SimulatorSidebarModel.logCapacity` = 600 console rows, two runs agreeing, blob build INCLUDED:
///
/// | corpus | before | after |
/// | --- | --- | --- |
/// | needle hits | 873.8 / 876.9 µs | 111.6 / 110.4 µs |
/// | needle misses | 1661.8 / 1624.6 µs | 131.2 / 128.5 µs |
///
/// A miss is the state every keystroke passes through, and the drawer repaints on every arriving
/// log line.
///
/// The ban is by FILE, not tree-wide: `DeviceRowFilterTests` and `PasteSafetyAnalyzerTests` both
/// call it on purpose — the first to hold the fold's ASCII answer against the platform's
/// normalizing one, the second to read a warning sentence — and neither is a panel. The corpus is
/// floored first — a ban over a file that was
/// renamed away passes silently, and this one names seven files across three targets, which is
/// exactly the shape that rots.
///
/// One thing worth recording about how it read while it was landing: the rule was RED for the
/// length of the change, naming `PhoneSimulatorConsoleView.swift` while the four simulator-view
/// edits were still pending, because the two UI targets belonged to other owners. A ban that spans
/// targets one agent cannot edit reads as a false positive exactly once, at the half-applied
/// moment, and is not one.
#[must_use]
pub fn one_device_panel_predicate(tree: &Tree) -> Report {
    /// Every file that used to spell the predicate, plus the one that asks for it now.
    const CORPUS: &[&str] = &[
        "Sources/SlopDeskDevicePanels/Android/AndroidPresentation.swift",
        "Sources/SlopDeskDevicePanels/Simulator/SimulatorPresentation.swift",
        ROW_FILTER,
        "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorConsoleView.swift",
        "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorDeviceList.swift",
        "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorConsoleView.swift",
        "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorDeviceList.swift",
    ];

    let mut claims: Vec<Claim> = CORPUS
        .iter()
        .map(|path| {
            Claim::Exists {
                path,
                message: "a renamed file would let the device-panel filter ban below pass without reading \
                          anything",
            }
        })
        .collect();
    claims.push(Claim::NoneOf {
        paths: CORPUS,
        pattern: r"localizedCaseInsensitiveContains",
        view: View::Code,
        message: "a device panel spells localizedCaseInsensitiveContains again ({files}) — the search \
                  predicate is DeviceRowFilter, and it was six copies of three lines",
    });
    claims.push(Claim::Matches {
        path: ROW_FILTER,
        pattern: r"slopdesk_ws_binding_row_matches\(",
        view: View::Statements,
        message: "DeviceRowFilter no longer calls slopdesk_ws_binding_row_matches — the predicate is \
                  rust/slopdesk-workspace/src/binding_search.rs and is not to be re-spelled in Swift",
    });
    check_all(tree, &claims)
}

/// The instrument voice is minted ONCE per rung
///
/// `Slate.Typeface.instrumentNative` is the `AppKit`/`UIKit` half of the mono voice, and it was the
/// only font accessor in its file with no cache in front of it. The asymmetry is what makes it a
/// defect rather than a slow function: `macDevicePanelLabel` picks between
/// `.systemFont(ofSize:weight:)` and this one on a single ternary, and `+systemFont:` is cached BY
/// THE FRAMEWORK while `NSFont(descriptor:size:)` builds a CoreText font from scratch every time.
/// Nothing in either language recorded that one arm of that ternary was two hundred times the
/// other.
///
/// Measured in a scratch `swiftc -O` harness (NOT in the tree; two runs agreeing to 1.5%), per
/// call:
///
/// | arm | cost |
/// | --- | --- |
/// | mono-INSTALLED (the shipping configuration) | 7 122 – 7 343 ns |
/// | …of which `NSFont(descriptor:size:)` alone | 7 142 – 7 406 ns |
/// | SF Mono fallback (no `JetBrains` Mono) | 2 091 – 2 118 ns |
/// | out of the table | 23 – 34 ns |
/// | `MacPaneDivider`'s three runs, per divider/frame | 21 400 ns → 69 ns (~310×) |
///
/// Those three are the ratio readout's leading/dot/trailing runs, which reach here through
/// `macInstrumentString`; `applyReadout` cuts them for a hidden readout for exactly this reason,
/// and that guard covers N−1 seams but not the one being dragged.
///
/// THE FAILURE MODE THE GATE EXISTS FOR is that none of this is visible to a test: every call
/// returns the correct font, the memo and the builder agree by construction, and the only trace is
/// the frame rate while a divider is dragged. So what is pinned is the SHAPE — that the accessor
/// goes through the table, and that the expensive builder is reachable from exactly one place.
///
/// The build site is COUNTED rather than merely required, for the reason the vocabulary gates give:
/// a presence check agrees with itself while a second copy appears beside the first, and 0 — the
/// extraction having gone stale — must fail rather than read as compliance.
///
/// Break-tested against the real tree by putting each pre-fix spelling back. All four fire, each on
/// its own rule only: the accessor no longer reading the table, `@MainActor` dropped off the store,
/// the descriptor inlined into the accessor, and a second `withFamily(mono)` growing beside the
/// first.
#[must_use]
pub fn the_instrument_voice_is_minted_once(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: SLATE_DESIGN,
            pattern: r"^ *if let struck = mintedInstruments\[rung\] \{ return struck \}$",
            view: View::Statements,
            message: "instrumentNative stopped reading mintedInstruments — it is 7.1 µs a call cold and 30 \
                      ns out of the table",
        },
        Claim::Matches {
            path: SLATE_DESIGN,
            pattern: r"^ *@MainActor private static var mintedInstruments: \[InstrumentRung: SlateNativeFont\] = \[:\]$",
            view: View::Statements,
            message: "mintedInstruments lost its @MainActor (or its type) — the only alternatives are a \
                      lock or no memo at all",
        },
        Claim::Exactly {
            path: SLATE_DESIGN,
            pattern: r"fontDescriptor\.withFamily\(mono\)",
            count: 1,
            view: View::Statements,
            message: "the instrument face is built in {found} places, not 1 — mintInstrument is the only \
                      one allowed, and 0 means this extraction has gone stale",
        },
        Claim::LacksWithin {
            path: SLATE_DESIGN,
            start: r"^ *package static func instrumentNative\(",
            end: r"^ *\}$",
            pattern: r"fontDescriptor",
            view: View::Raw,
            message: "instrumentNative mints a font outside mintInstrument — the memo is being walked around",
        },
    ])
}

/// The Android console's level filter is androidd's array, not a second list
///
/// A Swift `AndroidLogLevel` that goes back to spelling its own letters did once, and it drifted
/// short — five letters against androidd's six — so `F` was a filter the menu could not produce
/// while `logcat_level` was validating against a set that contained it. Nothing failed: the console
/// just had no way to ask for fatal. The set crosses through `slopdesk_android_log_level_letter`
/// now, and this is what keeps it crossing.
///
/// The named constants (`.info`, `.fatal`) are allowed, and `AndroidLogLevelTests` pins each
/// against the crossed set. What is NOT allowed is the type going back to an `enum`, because an
/// enum's case list cannot be built from a table at run time — that keyword IS the second copy.
#[must_use]
pub fn the_android_level_filter_is_androidds(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: ANDROID_LOG_LEVEL,
            pattern: r"slopdesk_android_log_level_letter",
            view: View::Statements,
            message: "AndroidLogLevel no longer reads androidd's level array — the menu is a second list \
                      again (docs/48)",
        },
        Claim::Lacks {
            path: ANDROID_LOG_LEVEL,
            pattern: r"^ *(package|public|internal)? *enum +AndroidLogLevel",
            view: View::Raw,
            message: "AndroidLogLevel is an enum again — a case list cannot come from androidd's array, so \
                      it is a second copy of it",
        },
    ])
}

/// The cursor style has ONE label
///
/// A display name growing back on `TerminalPreferences.CursorStyle` happened once, reading "Block
/// (hollow)" against `settings_catalog`'s "Hollow" for the same token — and both were on the same
/// Settings page, the catalog's at the picker and this one at the ✎ row that jumps to it. One
/// setting, two words, a scroll apart.
///
/// Comments stripped for the usual reason: the enum's doc quotes both spellings to record which one
/// survived, and the check is about the CODE.
#[must_use]
pub fn the_cursor_style_has_one_label(tree: &Tree) -> Report {
    check_all(tree, &[Claim::Lacks {
        path: TERMINAL_PREFS,
        pattern: r"Block \(hollow\)|displayName",
        view: View::Code,
        message: "TerminalPreferences names a cursor style again — the label is settings_catalog's \
                  CURSOR_STYLES (docs/56)",
    }])
}

/// The Android keycode table only ever shrinks
///
/// `FunctionalKey::android_keycode` in `panel_key.rs` is the one table that says what Android
/// number a functional key is. `AndroidKeycode.swift` used to spell thirteen of those numbers a
/// second time, and every one of them was reached by nothing: the panel's live path gets its
/// keycode from the door (`AndroidKeycode(bigEndian(...))`), and the only named constants anything
/// presses are `.home` and `.appSwitch`, which the Rust table does not carry.
///
/// A dead duplicate of a live number is worse than a live one — it reads as authoritative and it
/// can never be caught disagreeing, because no input ever reaches both copies (`docs/55` §8). So
/// the SHAPE is pinned rather than the names: how many literals the Swift face spells that the
/// crate already answers, against a mark that only goes down.
///
/// The count is ZERO and the mark is set there, so the ratchet has reached its floor. Both sides
/// are DERIVED: a list of banned numbers maintained here would drift from the Rust table the first
/// time a key was added, which is the same defect the rule exists to catch.
#[must_use]
pub fn the_android_keycode_table_only_shrinks(tree: &Tree) -> Report {
    check_all(tree, &[Claim::Overlap {
        label: "Android keycodes",
        left: Extract::statements(ANDROID_KEYCODE_RUST, r"Some\(([0-9]+)\)"),
        right: Extract::statements(ANDROID_KEYCODE_SWIFT, r"Self\(([0-9]+)\)"),
        mark: 0,
        message: "AndroidKeycode.swift spells {found} keycode(s) panel_key.rs already answers ({shared}) — \
                  the table only shrinks (docs/55 §8)",
    }])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The seven-file corpus, all of it routed through the shared filter.
    fn panels(fixture: &Fixture) {
        for path in [
            "Sources/SlopDeskDevicePanels/Android/AndroidPresentation.swift",
            "Sources/SlopDeskDevicePanels/Simulator/SimulatorPresentation.swift",
            "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorConsoleView.swift",
            "Sources/SlopDeskPhoneUI/Panel/Simulator/PhoneSimulatorDeviceList.swift",
            "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorConsoleView.swift",
            "Sources/SlopDeskMacUI/Panel/Simulator/MacSimulatorDeviceList.swift",
        ] {
            fixture.write(
                path,
                "let visible = rows.filter { DeviceRowFilter.matches($0, needle) }\n",
            );
        }
        fixture.write(
            super::ROW_FILTER,
            "static func matches(_ row: Row, _ needle: String) -> Bool \
             {\nslopdesk_ws_binding_row_matches(row.fields, needle) }\n",
        );
    }

    #[test]
    fn a_seventh_copy_of_the_predicate_is_red() {
        let fixture = Fixture::new("panel-filter");
        panels(&fixture);
        assert!(super::one_device_panel_predicate(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskDevicePanels/Android/AndroidPresentation.swift",
            "let visible = rows.filter { $0.name.localizedCaseInsensitiveContains(needle) }\n",
        );
        assert!(!super::one_device_panel_predicate(&fixture.tree()).is_clean());

        // And the one caller that keeps the other six honest.
        panels(&fixture);
        fixture.write(super::ROW_FILTER, "static func matches() -> Bool { false }\n");
        assert!(!super::one_device_panel_predicate(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_short_filter_corpus_is_red() {
        // Six of seven reads clean under the ban alone, which is why the corpus is floored by name;
        // its own fixture, because writes accumulate.
        let fixture = Fixture::new("panel-filter-short");
        fixture.write(
            super::ROW_FILTER,
            "slopdesk_ws_binding_row_matches(row.fields, needle)\n",
        );
        assert!(!super::one_device_panel_predicate(&fixture.tree()).is_clean());
    }

    /// The accessor reading its table, and the one build site behind it.
    fn slate(fixture: &Fixture) {
        fixture.write(
            super::SLATE_DESIGN,
            "        package static func instrumentNative(\n\
             \x20           _ size: CGFloat, weight: SlateNativeFont.Weight = .regular,\n\
             \x20       ) -> SlateNativeFont {\n\
             \x20           let rung = InstrumentRung(size: size, weight: weight)\n\
             \x20           if let struck = mintedInstruments[rung] { return struck }\n\
             \x20           let made = mintInstrument(size, weight: weight)\n\
             \x20           mintedInstruments[rung] = made\n\
             \x20           return made\n\
             \x20       }\n\
             \x20       @MainActor private static var mintedInstruments: [InstrumentRung: SlateNativeFont] = [:]\n\
             \x20       private static func mintInstrument(_ s: CGFloat, weight w: SlateNativeFont.Weight) -> SlateNativeFont {\n\
             \x20           let d = SlateNativeFont.systemFont(ofSize: s, weight: w).fontDescriptor.withFamily(mono)\n\
             \x20           return SlateNativeFont(descriptor: d, size: s) ?? .systemFont(ofSize: s)\n\
             \x20       }\n",
        );
    }

    #[test]
    fn a_font_minted_around_the_table_is_red() {
        let fixture = Fixture::new("panel-slate");
        slate(&fixture);
        assert!(super::the_instrument_voice_is_minted_once(&fixture.tree()).is_clean());

        // The descriptor inlined into the accessor — the memo walked around, with the FONT still
        // right, which is why no test sees it.
        fixture.write(
            super::SLATE_DESIGN,
            "        package static func instrumentNative(\n\x20           _ size: CGFloat, weight: \
             SlateNativeFont.Weight = .regular,\n\x20       ) -> SlateNativeFont {\n\x20           let rung \
             = InstrumentRung(size: size, weight: weight)\n\x20           if let struck = \
             mintedInstruments[rung] { return struck }\n\x20           let d = \
             SlateNativeFont.systemFont(ofSize: size, weight: weight).fontDescriptor\n\x20           return \
             SlateNativeFont(descriptor: d, size: size)!\n\x20       }\n\x20       @MainActor private \
             static var mintedInstruments: [InstrumentRung: SlateNativeFont] = [:]\n\x20       private \
             static func mintInstrument(_ s: CGFloat, weight w: SlateNativeFont.Weight) -> SlateNativeFont \
             {\n\x20           let d = SlateNativeFont.systemFont(ofSize: s, weight: \
             w).fontDescriptor.withFamily(mono)\n\x20           return SlateNativeFont(descriptor: d, size: \
             s) ?? .systemFont(ofSize: s)\n\x20       }\n",
        );
        assert!(!super::the_instrument_voice_is_minted_once(&fixture.tree()).is_clean());

        // A second build site beside the first, which a presence check would agree with.
        slate(&fixture);
        fixture.append(
            super::SLATE_DESIGN,
            "        private static func other() -> NSFontDescriptor {\n\x20           \
             SlateNativeFont.systemFont(ofSize: 12).fontDescriptor.withFamily(mono)\n\x20       }\n",
        );
        assert!(!super::the_instrument_voice_is_minted_once(&fixture.tree()).is_clean());

        // And the store losing its @MainActor, whose only alternatives are a lock or no memo.
        slate(&fixture);
        fixture.write(
            super::SLATE_DESIGN,
            "        package static func instrumentNative(\n\
             \x20       ) -> SlateNativeFont {\n\
             \x20           if let struck = mintedInstruments[rung] { return struck }\n\
             \x20           return mintInstrument(size, weight: weight)\n\
             \x20       }\n\
             \x20       private static var mintedInstruments: [InstrumentRung: SlateNativeFont] = [:]\n\
             \x20       private static func mintInstrument(_ s: CGFloat) -> SlateNativeFont {\n\
             \x20           let d = SlateNativeFont.systemFont(ofSize: s).fontDescriptor.withFamily(mono)\n\
             \x20           return SlateNativeFont(descriptor: d, size: s)!\n\
             \x20       }\n",
        );
        assert!(!super::the_instrument_voice_is_minted_once(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_second_level_list_is_red() {
        let fixture = Fixture::new("panel-levels");
        fixture.write(
            super::ANDROID_LOG_LEVEL,
            "package struct AndroidLogLevel {\n\x20   let letter = \
             slopdesk_android_log_level_letter(index)\n}\n",
        );
        assert!(super::the_android_level_filter_is_androidds(&fixture.tree()).is_clean());

        // An enum's case list cannot come from a table at run time, so the keyword IS the copy.
        fixture.write(
            super::ANDROID_LOG_LEVEL,
            "package enum AndroidLogLevel: String {\n\x20   case verbose = \"V\"\n\x20   let letter = \
             slopdesk_android_log_level_letter(index)\n}\n",
        );
        assert!(!super::the_android_level_filter_is_androidds(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_second_cursor_label_is_red() {
        let fixture = Fixture::new("panel-cursor");
        fixture.write(
            super::TERMINAL_PREFS,
            "/// The picker used to read \"Block (hollow)\" here and \"Hollow\" in the catalog.\npublic \
             enum CursorStyle: String { case blockHollow }\n",
        );
        // The doc quotes both spellings to record which one survived; the check is about the CODE.
        assert!(super::the_cursor_style_has_one_label(&fixture.tree()).is_clean());

        fixture.write(
            super::TERMINAL_PREFS,
            "public enum CursorStyle: String { case blockHollow\n\x20   var displayName: String { \"Block \
             (hollow)\" } }\n",
        );
        assert!(!super::the_cursor_style_has_one_label(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_keycode_spelled_twice_is_red() {
        let fixture = Fixture::new("panel-keycodes");
        fixture
            .write(
                super::ANDROID_KEYCODE_RUST,
                "match self {\n    Self::Up => Some(19),\n    Self::Down => Some(20),\n\x20   Self::Enter \
                 => Some(66),\n}\n",
            )
            .write(
                super::ANDROID_KEYCODE_SWIFT,
                "static let home = Self(3)\nstatic let appSwitch = Self(187)\n",
            );
        assert!(super::the_android_keycode_table_only_shrinks(&fixture.tree()).is_clean());

        // A dead duplicate reads as authoritative and can never be caught disagreeing, because no
        // input ever reaches both copies.
        fixture.write(
            super::ANDROID_KEYCODE_SWIFT,
            "static let home = Self(3)\nstatic let appSwitch = Self(187)\nstatic let enter = Self(66)\n",
        );
        assert!(!super::the_android_keycode_table_only_shrinks(&fixture.tree()).is_clean());

        // And a broken extraction, which at a mark of zero reads exactly like success.
        fixture.write(
            super::ANDROID_KEYCODE_SWIFT,
            "static let home = Self(rawValue: 3)\n",
        );
        assert!(!super::the_android_keycode_table_only_shrinks(&fixture.tree()).is_clean());
    }
}
