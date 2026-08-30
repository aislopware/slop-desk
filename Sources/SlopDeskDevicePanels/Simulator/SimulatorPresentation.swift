// SimulatorPresentation — the Swift FACE of `slopdesk_devicepanel::simulator`.
//
// Every word the Simulators surface says, every fold behind its seven surfaces and all of its bezel
// arithmetic is Rust now. What is left here is marshalling, the enums a `switch` in a view body
// reads, and the one asynchronous rule that is genuinely a view's.
//
// ## What moved, and what the move was for
//
// docs/56 stage D lifted these rules out of two renderers into one Swift file, because the list, the
// running card, the stage, the header, the console drawer, the location popover and the bezel had a
// single speller BY ACCIDENT until the Mac drew them itself. That fixed the two-RENDERER drift and
// left the two-LANGUAGE one: the rules were Swift while the console's own grammar was already Rust,
// and `CLAUDE.md`'s default is that a rule lives in Rust unless SwiftUI or AppKit is the reason it
// cannot. None of these is a drawing. So:
//
//   * `rowSubtitle` → `simulator::row_subtitle`, whose ⚠️ THE TRANSITION OUTRANKS THE SUPPRESSION is
//     the ordering a second renderer would have re-derived from prose and got backwards.
//   * `stage`, `menu`, `facts`, `buttonLabel`, `pixels`, `shortenedUDID` → one door each.
//   * `footprint` and `fit` → `simulator::{footprint, bezel_fit}`. Geometry crosses because it is
//     arithmetic about ARTWORK rather than a design token, and the clamp is done in IEEE `min`, so
//     one NaN upstream cannot survive as a NaN scale.
//   * The orientation cycle, its wire spellings, its titles and its view angle → `simulator::
//     Orientation`. The wire spellings are the SERVER's own, measured against a live one; it rejects
//     the whole body on one bad field, so a plausible synonym costs the entire request.
//
// ## What is still Swift, and why each one is
//
// **``loadingVeil(isAwaiting:)``.** A `Task.sleep` and a cancellation check — structured concurrency
// on the renderer's own task, which is exactly the "it must be Swift" case. The NUMBER it waits is
// the crate's, and the WAIT itself is ``DeviceVeilWait``, which every stage that has a veil shares.
//
// **``matches(_:query:)`` and ``Console/visible(_:filter:)``.** Already Rust, through
// ``DeviceRowFilter`` — what stays is which FIELDS a row lends it.
//
// **The ink, stage and verb enums.** They are the shape a `switch` in a view body reads; the crate
// answers the byte that picks the case. A hue is still neither side's — `SlopDeskSlate` DEPENDS on
// this target, so a colour cannot descend and each renderer spells its own.
//
// ## The one thing the crossing costs
//
// SF Symbols cross as NAMES, so ``SimulatorPlateReading`` reconstitutes an `SFSymbol` from a
// `rawValue` and every call site keeps its type. What is gone is the compile-time check
// `SFSafeSymbols` gave a Swift literal; ``DevicePanelSymbolTests`` is that check, relocated.

import CoreGraphics
import CSlopDeskFFI
import Foundation
import SFSafeSymbols
import SlopDeskWorkspaceModel

// MARK: - The one ink vocabulary the surfaces speak in

/// Which TIER of the text ladder a run of words sits on, or that it is the panel's one alarm.
///
/// A role, not a hue — `SlopDeskSlate` depends on this target, so a colour cannot descend. The Mac
/// resolves these against `Slate.Native.Text`/`Slate.Native.StatusInk` and the phone against
/// `Slate.Text`/`Slate.StatusInk`, and the mapping is four lines on each half.
///
/// ⚠️ `alarm` IS THE ONLY COLOUR THIS PANEL HAS. Three of its surfaces broke that rule independently
/// before 2026-08-04 — a green "Live" dot in the header, green info lines in the console, a coloured
/// status pill — and the rule the removals left behind is worth stating where both halves read it: a
/// hue means SOMETHING IS WRONG, and nothing else. Healthy states ride luminance and weight.
package enum SimulatorInk: Equatable, Sendable {
    case primary
    case secondary
    case tertiary
    case alarm

    /// The role for a crate byte. A byte no build wrote reads as ``tertiary``, the rung that recedes
    /// — the safe answer, because the alternative spends this panel's one alarm colour on something
    /// nothing is known about.
    package init(crateByte: UInt8) {
        switch Int32(crateByte) {
        case SLOPDESK_SIMULATOR_INK_PRIMARY: self = .primary
        case SLOPDESK_SIMULATOR_INK_SECONDARY: self = .secondary
        case SLOPDESK_SIMULATOR_INK_ALARM: self = .alarm
        default: self = .tertiary
        }
    }
}

// MARK: - One control on the toolbar, the console strip or the header

/// A plate's SILHOUETTE and its tooltip — the two halves of a control that are not a drawing.
///
/// The symbol arrives as a NAME and is reconstituted here, so the call sites keep the closed type
/// they had. ``symbolName`` is the same value spelled for `NSImage(systemSymbolName:)`, so the
/// AppKit half needs no second lookup table.
package struct SimulatorPlateReading: Equatable, Sendable {
    package let symbol: SFSymbol
    package let help: String

    package var symbolName: String { symbol.rawValue }

    package init(_ symbol: SFSymbol, _ help: String) {
        self.symbol = symbol
        self.help = help
    }
}

// MARK: - One measured fact under the device's name

/// One entry of the header's fact line — see `SlateFactLine` for the four rules the line itself keeps.
///
/// The TINT is a role here rather than a colour, and `isMeasured` stays a fact about the VALUE (it was
/// measured, so it renders in the instrument face) rather than a styling flag: the distinction is what
/// makes a line tell a reader which of its parts were read off an instrument.
package struct SimulatorFact: Equatable, Sendable {
    /// Names the fact, in title case — the tooltip, the Copy verb, and the row's identity within one
    /// line, which is what lets a line animate a fact in or out without reshuffling.
    package let label: String
    /// What is drawn. May be an abbreviation of ``copies`` (a shortened UDID, a rounded figure).
    package let text: String
    /// What Copy hands over — the WHOLE value, never the abbreviation. The reason the short form is
    /// safe to draw at all is that the full one is one right-click away.
    package let copies: String
    package let ink: SimulatorInk
    /// Measured facts render mono; named ones render in the system face.
    package let isMeasured: Bool
    /// Whether the label is DRAWN ahead of the value. False for a fact that only appears when it is
    /// abnormal — its presence is the news, and the width is worth more to its neighbours.
    package let showsLabel: Bool
}

// MARK: - What the stage is showing

/// The stage's three definite situations. A stage with no picture on it says WHICH of the two reasons
/// that is, rather than leaving the reader an empty rectangle to interpret — an empty rectangle, a
/// black screenshot and a dead stream are pixel-identical.
package enum SimulatorStageState: Equatable, Sendable {
    /// The device is on screen; draw the bezel (or the bare rect) and nothing over it.
    case live
    /// A veil with a spinner and this caption. Delayed — see ``SimulatorPresentation/veilDelay``.
    case starting(String)
    /// A veil with this caption and a retry button labelled ``SimulatorPresentation/retryTitle``.
    case stalled(String)
}

/// One entry of a device's context menu. A VALUE rather than each half typing the same five titles in
/// the same order: the menu differs by exactly one branch (booted or not), and a renderer holding
/// loose strings is a renderer that can be handed them in the other order.
/// `Hashable` so a `ForEach` can key on the verb itself — the phone's menu is a builder over this list,
/// and an index key would rebuild the wrong button when the booted branch changes shape.
package enum SimulatorDeviceVerb: Hashable, Sendable, CaseIterable {
    case openScreen
    case copyScreenshot
    case shutdown
    case boot
    /// A rule, not a verb — the cut between what acts on the DEVICE and what copies a fact about it.
    case separator
    case copyUDID
    case copyName

    /// `nil` for the separator, which has no words. The crate's slot for it is empty BY
    /// CONSTRUCTION, which is what this reads.
    package var title: String? {
        let title = SimulatorVocabulary.words[19 + Int(crateByte)]
        return title.isEmpty ? nil : title
    }

    var crateByte: Int32 {
        switch self {
        case .openScreen: SLOPDESK_SIMULATOR_VERB_OPEN_SCREEN
        case .copyScreenshot: SLOPDESK_SIMULATOR_VERB_COPY_SCREENSHOT
        case .shutdown: SLOPDESK_SIMULATOR_VERB_SHUTDOWN
        case .boot: SLOPDESK_SIMULATOR_VERB_BOOT
        case .separator: SLOPDESK_SIMULATOR_VERB_SEPARATOR
        case .copyUDID: SLOPDESK_SIMULATOR_VERB_COPY_UDID
        case .copyName: SLOPDESK_SIMULATOR_VERB_COPY_NAME
        }
    }

    /// `nil` for a byte no build of the crate wrote, which drops the row rather than mounting an
    /// item whose press would do something else.
    init?(crateByte: UInt8) {
        guard let verb = Self.allCases.first(where: { $0.crateByte == Int32(crateByte) })
        else { return nil }
        self = verb
    }
}

// MARK: - The crate's tables, read out once

/// Every fixed string and every plate the crate publishes, read ONCE into a table.
///
/// A door per string inside a view body was measured too expensive when the settings catalogue did
/// it, so each table crosses in ONE delivery. PADDED, never trusted: ``DevicePanelBlob/texts(_:)``
/// fills a short delivery with empties rather than shifting, so a crate and a face that disagree
/// about the layout lose ONE field instead of wearing each other's from the gap onward.
enum SimulatorVocabulary {
    /// The 34 fields `slopdesk_simulator_words` documents, in its order.
    static let words: [String] = {
        var blob = DevicePanelBlob { out, cap in slopdesk_simulator_words(out, cap) }
        return blob.texts(34)
    }()

    /// The 14 plates `slopdesk_simulator_plates` documents. The latching ones cross as a PAIR, off
    /// then on, which is why the accessors below index them two at a time.
    static let plates: [SimulatorPlateReading] = {
        var blob = DevicePanelBlob { out, cap in slopdesk_simulator_plates(out, cap) }
        let count = blob.count16()
        return (0..<count).map { _ in
            let strings = blob.texts(2)
            return SimulatorPlateReading(SFSymbol(rawValue: strings[0]), strings[1])
        }
    }()

    /// One sentence that carries a value. One door rather than eight, because eight doors that each
    /// format one value into one template would be eight sites restating the same marshalling.
    static func phrase(_ id: Int32, value: String = "", count: Int = 0) -> String {
        devicePanelLend(value) { bytes, len in
            wsDelivered(capacity: 128) { out, cap in
                slopdesk_simulator_phrase(UInt8(id), bytes, len, count, out, cap)
            } ?? ""
        }
    }
}

// MARK: - The folds and the words

package enum SimulatorPresentation {
    // MARK: The device list

    package static let searchPlaceholder = SimulatorVocabulary.words[0]

    /// What the list draws in place of rows when the HOST has none. Distinct from ``noMatches(_:)``
    /// because "there are no devices" and "your filter hid them all" are different sentences and the
    /// second one is actionable.
    package static let noDevices = SimulatorVocabulary.words[1]

    package static func noMatches(_ query: String) -> String {
        SimulatorVocabulary.phrase(SLOPDESK_SIMULATOR_PHRASE_NO_MATCHES, value: query)
    }

    /// The filter, over the two fields a shelf of simulators is told apart by: the device's name and
    /// its runtime.
    ///
    /// The predicate underneath is ``DeviceRowFilter``'s — already Rust, shared with both consoles
    /// and the Android list. What stays here is which FIELDS a simulator row lends it.
    package static func matches(_ devices: [SimulatorDevice], query: String) -> [SimulatorDevice] {
        DeviceRowFilter.surviving(devices, query: query) { device, fields in
            fields.add(device.name)
            fields.add(device.runtime)
        }
    }

    /// The trailing text on a shut-down device's row: the live state while the device is CHANGING, the
    /// runtime when it is not and the heading has not already said it, and nothing at all otherwise.
    ///
    /// ⚠️ THE TRANSITION OUTRANKS THE SUPPRESSION. A device spends seconds in `Booting`, and showing
    /// its runtime through that is the panel claiming nothing is happening while something is. A
    /// renderer that read only "does the heading already say the runtime" would draw the quiet answer
    /// for exactly the row worth watching.
    package static func rowSubtitle(_ device: SimulatorDevice, showsRuntime: Bool) -> String? {
        devicePanelLend(device.state) { state, stateLen in
            devicePanelLend(device.runtime) { runtime, runtimeLen in
                wsDelivered(capacity: 64) { out, cap in
                    slopdesk_simulator_row_subtitle(
                        state, stateLen, device.isBooted, runtime, runtimeLen, showsRuntime,
                        out, cap,
                    )
                }
            }
        }
    }

    /// The verbs a device's context menu offers, in order. `Open Screen` and `Copy Screenshot` need a
    /// running device; `Boot` is the whole menu for one that is not.
    ///
    /// The UDID cut is below them: the UDID is what every other tool wants — `xcrun simctl`, a test
    /// invocation, a bug report — and it is far too long to put in a row, which is the whole reason
    /// that cut exists.
    package static func menu(for device: SimulatorDevice) -> [SimulatorDeviceVerb] {
        devicePanelKinds(capacity: 8) { out, cap in
            slopdesk_simulator_device_menu(device.isBooted, out, cap)
        }
        .compactMap(SimulatorDeviceVerb.init(crateByte:))
    }

    package static func bootHelp(_ device: SimulatorDevice) -> String {
        SimulatorVocabulary.phrase(SLOPDESK_SIMULATOR_PHRASE_BOOT_HELP, value: device.name)
    }

    package static func openHelp(_ device: SimulatorDevice) -> String {
        SimulatorVocabulary.phrase(SLOPDESK_SIMULATOR_PHRASE_OPEN_HELP, value: device.name)
    }

    package static func shutdownHelp(_ device: SimulatorDevice) -> String {
        SimulatorVocabulary.phrase(SLOPDESK_SIMULATOR_PHRASE_SHUTDOWN_HELP, value: device.name)
    }

    /// Offered only once MORE THAN ONE device is up: with one running it is the same click as that
    /// card's own stop button under a longer name.
    package static func shutdownAllHelp(_ count: Int) -> String {
        SimulatorVocabulary.phrase(SLOPDESK_SIMULATOR_PHRASE_SHUTDOWN_ALL_HELP, count: count)
    }

    // MARK: The device header

    package static let backHelp = SimulatorVocabulary.words[2]

    /// `1206 × 2622`. The MULTIPLICATION SIGN, not a lowercase x — this sits in a row of measured
    /// figures and a letter standing in for an operator is the detail that makes a panel look
    /// improvised.
    package static func pixels(_ size: CGSize) -> String {
        wsDelivered(capacity: 32) { out, cap in
            slopdesk_simulator_pixels(Double(size.width), Double(size.height), out, cap)
        } ?? ""
    }

    /// The leading block of a UDID, which is what a person reads to tell two devices apart. The full
    /// value is 36 characters and would own the line; Copy hands over the whole thing. Cut on a
    /// CHARACTER boundary, which is the crate's job rather than a `prefix(8)` here.
    package static func shortenedUDID(_ udid: String) -> String {
        devicePanelLend(udid) { bytes, len in
            wsDelivered(capacity: 64) { out, cap in
                slopdesk_simulator_shortened_udid(bytes, len, out, cap)
            } ?? ""
        }
    }

    /// What a fact's own Copy verb is called. The LABEL names the fact, so the item reads "Copy
    /// Resolution" rather than "Copy" — which is the whole reason a fact carries a label at all.
    package static func copyTitle(_ fact: SimulatorFact) -> String {
        SimulatorVocabulary.phrase(SLOPDESK_SIMULATOR_PHRASE_COPY_TITLE, value: fact.label)
    }

    package static func orientationTitle(_ orientation: SimulatorOrientation) -> String {
        SimulatorVocabulary.words[26 + Int(orientation.crateByte)]
    }

    /// The header's fact line, in order — and WHICH facts are present at all, which is the half a
    /// second renderer would have re-derived.
    ///
    /// Ordered by how often it is the thing being checked: the pixel size, then anything abnormal,
    /// then the short UDID. Orientation and position appear ONLY when they have something to say — a
    /// portrait device and a device using live GPS are the ordinary case, and printing them would
    /// spend the line's width on the absence of news.
    ///
    /// The RUNTIME is deliberately absent: it rides the title beside the name, where it names the
    /// device ("iPhone 17 Pro · iOS 26.5"). On this line it was one dot-separated figure among four,
    /// which is where the thing you are actually looking for goes to hide.
    ///
    /// The pinned position is NOT accented. It appears only when a position is pinned, so its presence
    /// already says the device is lying about where it is, and the toolbar plate that pinned it is
    /// latched six points below — two accents for one state inside one band is the colour noise this
    /// header lost its status dot over.
    package static func facts(
        device: SimulatorDevice,
        resolution: CGSize?,
        orientation: SimulatorOrientation,
        pinnedLocation: SimulatorCoordinate?,
    ) -> [SimulatorFact] {
        var blob = devicePanelLend(device.udid) { udid, udidLen in
            devicePanelLend(pinnedLocation?.readout ?? "") { readout, readoutLen in
                DevicePanelBlob { out, cap in
                    slopdesk_simulator_facts(
                        udid, udidLen, resolution != nil,
                        Double(resolution?.width ?? 0), Double(resolution?.height ?? 0),
                        orientation.crateByte, readout, readoutLen, out, cap,
                    )
                }
            }
        }
        return (0..<blob.count16()).map { _ in
            let ink = SimulatorInk(crateByte: blob.byte())
            let isMeasured = blob.byte() != 0
            let showsLabel = blob.byte() != 0
            let strings = blob.texts(3)
            return SimulatorFact(
                label: strings[0], text: strings[1], copies: strings[2],
                ink: ink, isMeasured: isMeasured, showsLabel: showsLabel,
            )
        }
    }

    // MARK: The toolbar

    /// Three trays and a trailing pair: turn it, drive it, capture it — then look at it. The GROUPING
    /// is part of the answer, not decoration: ten loose plates in a row read as texture rather than as
    /// verbs, and the inspect pair stays OFF the trays because both of them LATCH, and a lit key only
    /// reads as lit against the panel's own tone rather than inside a lit tray.
    ///
    /// NOTIFICATION CENTRE AND LOCK ARE NOT HERE (user-directed 2026-08-04). Both were, because the
    /// server offers the verb — which is not a reason. Nobody driving an app reaches for the shade or
    /// the lock screen, and both are DESTRUCTIVE to the thing you are actually doing: a mis-click
    /// blanks the device and costs a wake and a swipe to undo. The server still accepts
    /// `pull-down-to-notification-center` and `lock`; only what this panel puts under the pointer
    /// changed.
    package enum Toolbar {
        package static let rotateLeft = SimulatorVocabulary.plates[0]
        package static let rotateRight = SimulatorVocabulary.plates[1]
        package static let home = SimulatorVocabulary.plates[2]
        /// A TOGGLE, and the tooltip says so. Measured 2026-08-04 against a booted device: the verb is
        /// the swipe-up-and-hold gesture, so it opens the card stack from an app or the home screen
        /// and DISMISSES it when the stack is already up — and on a device with nothing backgrounded
        /// it does nothing visible, exactly like the hardware. Neither this nor
        /// `swipe-to-app-switcher` is an idempotent "show".
        package static let appSwitcher = SimulatorVocabulary.plates[3]
        package static let screenshot = SimulatorVocabulary.plates[4]

        /// The demo status bar's plate, which is latched while the override is in force.
        package static func statusBar(isOverridden: Bool) -> SimulatorPlateReading {
            SimulatorVocabulary.plates[isOverridden ? 6 : 5]
        }

        /// Latched while a position is pinned, so the toolbar says the device is somewhere else
        /// without anyone opening the popover to find out. The header carries the actual coordinate;
        /// this is the glance.
        package static func location(isPinned: Bool) -> SimulatorPlateReading {
            SimulatorVocabulary.plates[isPinned ? 8 : 7]
        }

        /// A ruled list, not a terminal prompt: this opens a READER over the device's output, and the
        /// `>_` glyph promises a place to type. (`.terminal` is also the Terminal.app icon and
        /// deprecated at this target.)
        package static func console(isOpen: Bool) -> SimulatorPlateReading {
            SimulatorVocabulary.plates[isOpen ? 10 : 9]
        }
    }

    // MARK: The stage

    package static let startingCaption = SimulatorVocabulary.words[17]
    package static let stalledCaption = SimulatorVocabulary.words[18]

    /// The stage's one TEXT button, and the one failure here that a second attempt genuinely fixes —
    /// the socket is fine, the encoder never started — so the stage offers it rather than making
    /// someone go back to the list and pick the same row again.
    package static let retryTitle = SimulatorVocabulary.words[3]

    /// Which of the three things the stage is doing.
    ///
    /// ⚠️ THE ORDER IS THE RULE, and it is the crate's. `showsLoading` first, because it is the
    /// DELAYED mirror of the model's own awaiting flag (see ``loadingVeil(isAwaiting:)``) and outranks
    /// a stall that has not been waited out yet; then the stall, which is defined by the model's
    /// deadline having passed with no video; then live. Asked in any other order the stage shows "no
    /// video" for the 90 ms before the first keyframe of every single selection.
    ///
    /// - Parameters:
    ///   - showsLoading: the renderer's own delayed copy of `isAwaitingStream`, never the raw flag.
    ///   - hasVideo: ``SimulatorSidebarModel/hasVideo`` — DECODABLE video, not "a frame arrived". The
    ///     seed does not count: a seed-only stream is a photograph of a device nobody is driving.
    package static func stage(
        isSelected: Bool, showsLoading: Bool, isAwaitingStream: Bool, hasVideo: Bool,
    ) -> SimulatorStageState {
        let state = slopdesk_simulator_stage(isSelected, showsLoading, isAwaitingStream, hasVideo)
        let caption = SimulatorVocabulary.words[16 + Int(state)]
        switch Int32(state) {
        case SLOPDESK_SIMULATOR_STAGE_STARTING: return .starting(caption)
        case SLOPDESK_SIMULATOR_STAGE_STALLED: return .stalled(caption)
        default: return .live
        }
    }

    /// How long the model may be loading before the veil admits it.
    ///
    /// MEASURED: a booted device's first keyframe lands 0.09 s after the socket opens, so a veil with
    /// no delay would flash grey over the bezel on every single selection — the whole failure being
    /// drawn onto the ordinary case. This delay is the entire reason a renderer keeps its own copy of
    /// the loading state instead of reading the model's. The NUMBER is the crate's, because a value
    /// measured once that two files carry is a value that gets re-tuned in one of them.
    package static let veilDelay: Duration = .milliseconds(Int(slopdesk_simulator_veil_delay_ms()))

    /// This panel's veil wait, which is ``DeviceVeilWait/state(isAwaiting:after:)`` with this
    /// panel's own measured delay already inside — calling the door beats passing it its own number.
    ///
    /// The SHAPE is shared with the Android stage and the NUMBER deliberately is not: 400 ms was
    /// measured against this server's 0.09 s first keyframe and the bridge's 600 ms against its own
    /// 0.83 s, and merging them would throw away both measurements.
    package static func loadingVeil(isAwaiting: Bool) async -> Bool? {
        await DeviceVeilWait.state(isAwaiting: isAwaiting, after: veilDelay)
    }

    /// What a failed read of a dropped file says. The server routes a dropped file by EXTENSION — an
    /// `.app`/`.ipa` is installed, an image or video lands in Photos — so this side accepts any file
    /// and lets the server classify it; getting that taxonomy wrong locally would reject the one build
    /// someone wanted. The only local failure is not being able to read the bytes at all.
    package static func unreadableDrop(_ fileName: String) -> String {
        SimulatorVocabulary.phrase(SLOPDESK_SIMULATOR_PHRASE_UNREADABLE_DROP, value: fileName)
    }

    // MARK: The console drawer

    package enum Console {
        package static let title = SimulatorVocabulary.words[4]
        package static let filterPlaceholder = SimulatorVocabulary.words[5]
        package static let levelHelp = SimulatorVocabulary.words[6]
        package static let clear = SimulatorVocabulary.plates[11]
        package static let hide = SimulatorVocabulary.plates[12]
        package static let copyLine = SimulatorVocabulary.words[7]
        package static let copyConsole = SimulatorVocabulary.words[8]

        /// FOLLOW IS A LATCH, not an inferred scroll position — the usual "stick to the bottom until
        /// the reader scrolls away" needs a scroll offset this deployment target does not report, and
        /// a latch is legible at rest and cannot disagree with reality.
        ///
        /// ONE GLYPH ACROSS THE LATCH, which is why the crate ships the plate once and the two
        /// sentences beside it: a latched plate is already drawn as a lit key, and swapping the arrow
        /// for a slashed arrow would say "off" twice.
        package static func follow(isFollowing: Bool) -> SimulatorPlateReading {
            SimulatorPlateReading(
                SimulatorVocabulary.plates[13].symbol,
                SimulatorVocabulary.words[isFollowing ? 9 : 10],
            )
        }

        /// Case-insensitive substring over the whole row — PROCESS INCLUDED, since "which process is
        /// spamming this" is as common a question as "where is my message".
        ///
        /// The predicate is ``DeviceRowFilter``'s, shared with the Android console and both device
        /// lists; what stays here is WHICH two fields a unified-log row lends it.
        package static func visible(_ lines: [DeviceLogLine], filter: String) -> [DeviceLogLine] {
            DeviceRowFilter.surviving(lines, query: filter) { line, fields in
                fields.add(line.message)
                fields.add(line.name)
            }
        }

        /// Three states, three sentences. "Nothing here" over a console that never connected is the
        /// failure this exists to distinguish, and the order is why: a non-empty history with nothing
        /// visible is the FILTER's doing and must be said first, or a narrowed console reads as a dead
        /// one.
        package static func empty(
            hasLines: Bool, isStarted: Bool, level: SimulatorLogLevel, filter: String,
        ) -> String {
            devicePanelLend(level.title) { title, titleLen in
                devicePanelLend(filter) { needle, needleLen in
                    wsDelivered(capacity: 128) { out, cap in
                        slopdesk_simulator_console_empty_message(
                            hasLines, isStarted, title, titleLen, needle, needleLen, out, cap,
                        )
                    } ?? ""
                }
            }
        }

        /// One row as plain text — what Copy Line and Copy Console hand over.
        package static func plain(_ line: DeviceLogLine) -> String { line.plain }

        /// The process name's ink. COLOUR ONLY FOR A FAULT — everything healthy is a grey, and the only
        /// difference between the greys is how far back they sit.
        ///
        /// Info used to be green (user-directed 2026-08-04). Info is the ordinary case: a busy device
        /// emits hundreds of info lines a second, so the rule spent the console's one alarm colour on
        /// the state of nothing being wrong, and a wall half-green made the handful of red lines it
        /// exists to surface no easier to find. Debug still recedes, because a debug line IS
        /// lower-value than the default and luminance is the channel for that — the ONE rung where
        /// this answer differs from the Android console's, and it is only legible as a difference
        /// because both matches are exhaustive over the same Rust severity scale.
        package static func ink(for severity: DeviceLogSeverity) -> SimulatorInk {
            SimulatorInk(crateByte: slopdesk_simulator_log_ink(severity.rawValue))
        }
    }

    // MARK: The location popover

    package enum Location {
        package static let title = SimulatorVocabulary.words[11]
        /// The format every map app copies to the clipboard, shown as the placeholder because that is
        /// where a coordinate typed into this field almost always comes from.
        package static let placeholder = SimulatorVocabulary.words[12]
        package static let set = SimulatorVocabulary.words[13]
        package static let clear = SimulatorVocabulary.words[14]
        /// Absent while nothing is pinned — a control that undoes nothing is a control that has to be
        /// reasoned about before it is ignored — which is why this pair is a fold rather than two
        /// labels a renderer picks between.
        package static let live = SimulatorVocabulary.words[15]

        package static func pinned(_ coordinate: SimulatorCoordinate) -> String {
            SimulatorVocabulary.phrase(
                SLOPDESK_SIMULATOR_PHRASE_LOCATION_PINNED, value: coordinate.readout,
            )
        }
    }

    // MARK: The bezel's geometry

    /// The box a TURNED device has to fit into.
    ///
    /// A rotation does not change layout on either framework, so fitting a quarter-turned phone
    /// against the panel's real bounds sizes it to a width it will not occupy and the device overflows
    /// the column sideways. Swapping the bounds first is what makes a landscape device fill the panel
    /// the way a portrait one does.
    package static func footprint(_ bounds: CGSize, turned: Bool) -> CGSize {
        var room = [Double](repeating: 0, count: 2)
        room.withUnsafeMutableBufferPointer { out in
            slopdesk_simulator_footprint(
                Double(bounds.width), Double(bounds.height), turned, out.baseAddress,
            )
        }
        return CGSize(width: room[0], height: room[1])
    }

    /// Aspect-FIT, and never above 1: a bezel blown past its artwork's own size is a soft, resampled
    /// device body, which looks worse than the same body drawn small and sharp.
    ///
    /// It fits the BLEED rect, never the viewport — side buttons protrude past the body
    /// (``SimulatorChrome/bleed``), and fitting the viewport alone clips them at the panel's edge.
    package static func fit(_ content: CGSize, in bounds: CGSize) -> CGFloat {
        CGFloat(slopdesk_simulator_bezel_fit(
            Double(content.width), Double(content.height),
            Double(bounds.width), Double(bounds.height),
        ))
    }

    /// The server's button ids are wire tokens (`volume-up`, `action`). Spelled out for the tooltip
    /// rather than shown raw — and titled from the id when it is one this build has not seen, so a new
    /// button is still labelled with something.
    package static func buttonLabel(for id: String) -> String {
        devicePanelLend(id) { bytes, len in
            wsDelivered(capacity: 64) { out, cap in
                slopdesk_simulator_button_label(bytes, len, out, cap)
            } ?? ""
        }
    }

    // MARK: The one input number both screen surfaces read

    /// The floor between two-finger envelopes, in seconds.
    ///
    /// MEASURED 2026-08-04: `touch2-move` occupies the server for 25 ms, a thousand times what a
    /// `touch1-move` costs, so the two-finger path is rate-limited on BOTH halves — the Mac's
    /// synthesized magnify and the phone's real second finger alike. The crate carries the number in
    /// MILLISECONDS, which is the unit it was measured in; the division is this line and nowhere else.
    package static let pinchInterval = Double(slopdesk_simulator_pinch_interval_ms()) / 1000
}
