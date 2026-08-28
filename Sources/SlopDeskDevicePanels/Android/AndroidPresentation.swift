// AndroidPresentation — the Swift FACE of `slopdesk_devicepanel::android`.
//
// Every word this panel says and every fold behind its five surfaces is Rust now. What is left here
// is marshalling and two actuations: the tables are read out of the crate ONCE into `static let`s,
// and the folds are one door call each.
//
// ## What moved, and what the move was for
//
// docs/56 stage D lifted these rules out of two renderers into one Swift file, because the list, the
// stage, the header, the running card and the console had a single speller BY ACCIDENT until the Mac
// drew them in AppKit. That fixed the two-RENDERER drift and left the two-LANGUAGE one: the rules
// were Swift, the Android bridge's codec and both console grammars were already Rust, and
// `CLAUDE.md`'s default is that a rule lives in Rust unless SwiftUI or AppKit is the reason it
// cannot. None of these is a drawing. So:
//
//   * `canEnter` / `isRunning` / `isAttachedButUnusable` / `stoppable` → `android::*`, and they cross
//     as ONE bitfield over the RAW `(has_serial, state, is_emulator)` triple. The rule is
//     `has_serial && state == "device"`; half of it spelled at a call site is the drift this port
//     exists to end, and `AndroidDevice` no longer spells any of it.
//   * `stage(...)` → `android::stage`, whose four-flag order IS the rule (loading outranks stalled,
//     and the loading caption then asks a SECOND question), with 62 lines of Rust tests on it.
//   * `menu(for:)`, the two trays, the console plate, the fact line, every sentence → one delivery
//     each, framed as `[u32 length][UTF-8 bytes]` runs. ``DevicePanelBlob`` is the cursor.
//
// ## What is still Swift, and why each one is
//
// **``run(_:on:isDisplayOff:)`` and ``run(_:device:on:enter:)``.** A verb→call table over
// `AndroidSidebarModel`, which is a `@MainActor` observable object with `Task`s in it. The KIND that
// picks the branch crosses; the branch itself is Swift because everything it touches is.
//
// **``matches(_:query:)`` and ``visible(_:filter:)``.** Already Rust, through ``DeviceRowFilter`` —
// what stays is which FIELDS a row lends, which is this panel's own fact about its own record.
//
// **The ink and stage enums.** They are the shape a `switch` in a SwiftUI body reads; the crate
// answers the byte that picks the case. A hue is still neither side's — `SlopDeskSlate` sits ABOVE
// this target, so the role descends and each renderer spells the colour.
//
// ## The one thing the crossing costs
//
// SF Symbols cross as NAMES. `SFSymbol` is `RawRepresentable` with a public `init(rawValue:)`, so a
// crossed name reconstitutes and every call site keeps its type — but the compile-time check
// `SFSafeSymbols` gave a Swift literal is gone, because the literal is gone. ``DevicePanelSymbolTests``
// is that check, relocated: it resolves every crossed name through `NSImage(systemSymbolName:)`.

import CoreGraphics
import CSlopDeskFFI
import Foundation
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The one ink vocabulary the panel speaks in

/// A text ROLE, resolved to a hue by whichever half is drawing.
///
/// Four rungs and one alarm, which is the whole ladder this panel uses. It is a role rather than a
/// colour because `SlopDeskSlate` sits above this target, so naming its ladder here would invert the
/// dependency the split is built on.
package enum AndroidInk: Equatable, Sendable {
    /// The thing being read — a device's name, a log message's own line.
    case primary
    /// A supporting line: a summary, a caption, a log body.
    case secondary
    /// A fact, a label, a resting verb — the rung a column of them can sit in without becoming a rule
    /// down the leading edge.
    case tertiary
    /// A silhouette. The same value as ``secondary`` on both halves today, and named apart because it
    /// answers a different question — see ``macAndroidFamilyMark(_:)`` / ``phoneAndroidFamilyMark(_:)``
    /// and their note about a column of marks.
    case icon
    /// The one hue this panel spends, and only on a fault.
    case err

    /// The role for a crate byte. A byte no build wrote reads as ``tertiary``, which is the rung that
    /// RECEDES — the safe answer, because the alternative spends the panel's one alarm colour on
    /// something nothing is known about.
    package init(crateByte: UInt8) {
        switch Int32(crateByte) {
        case SLOPDESK_ANDROID_INK_PRIMARY: self = .primary
        case SLOPDESK_ANDROID_INK_SECONDARY: self = .secondary
        case SLOPDESK_ANDROID_INK_ICON: self = .icon
        case SLOPDESK_ANDROID_INK_ERR: self = .err
        default: self = .tertiary
        }
    }
}

// MARK: - The stage

/// What the mirroring stage is showing, once the veil's delay has been waited out.
///
/// THREE DEFINITE THINGS, never an indicator with no end. A stage with no picture on it says which of
/// the two reasons that is, because an empty rectangle and a dead stream are pixel-identical and the
/// ambiguous object IS the rectangle.
package enum AndroidStageReading: Equatable, Sendable {
    /// Nothing over the picture.
    case streaming
    /// The veil, with a spinner and one line.
    case loading(caption: String)
    /// The veil, with one line and the retry the failure actually fixes.
    case stalled(caption: String, retry: String)
}

/// One control on the stage's toolbar: what it DOES, what it looks like, and what the pointer is told.
///
/// A verb rather than a closure because the two renderers build their plates differently and must not
/// each decide which glyph means Recents. The actuation is ``AndroidPresentation/run(_:on:isDisplayOff:)``,
/// so the switch from verb to model call is written once as well.
package struct AndroidStageVerb: Equatable, Sendable {
    package let action: AndroidStageAction
    /// The glyph at rest.
    package let symbol: SFSymbol
    package let help: String
    /// The glyph and the sentence while the thing this verb turns on is ON. A verb that does not latch
    /// repeats its own pair, which is why the crate needs no presence flag for it.
    package let latchedSymbol: SFSymbol
    package let latchedHelp: String

    /// The glyph for a latch state — the same answer for a verb that cannot latch.
    package func symbol(latched: Bool) -> SFSymbol {
        latched ? latchedSymbol : symbol
    }

    package func help(latched: Bool) -> String {
        latched ? latchedHelp : help
    }
}

/// The eight things the stage's toolbar can ask of a device.
///
/// `Hashable` because it is a tray's row IDENTITY on both halves — SwiftUI's `ForEach(_:id:)` and the
/// AppKit half's plate table both key on the action rather than on the whole verb, so that a help
/// string changing cannot rebuild a control the pointer is inside.
package enum AndroidStageAction: Hashable, Sendable {
    case back
    case home
    case recents
    case rotate
    case capture
    case pasteClipboard
    /// The DEVICE's own backlight, not the mirror's — see the verb's help.
    case displayPower
    case console

    /// `nil` for a byte no build of the crate wrote, which drops the plate rather than mounting one
    /// whose press would do something else.
    init?(crateByte: UInt8) {
        switch Int32(crateByte) {
        case SLOPDESK_ANDROID_ACTION_BACK: self = .back
        case SLOPDESK_ANDROID_ACTION_HOME: self = .home
        case SLOPDESK_ANDROID_ACTION_RECENTS: self = .recents
        case SLOPDESK_ANDROID_ACTION_ROTATE: self = .rotate
        case SLOPDESK_ANDROID_ACTION_CAPTURE: self = .capture
        case SLOPDESK_ANDROID_ACTION_PASTE_CLIPBOARD: self = .pasteClipboard
        case SLOPDESK_ANDROID_ACTION_DISPLAY_POWER: self = .displayPower
        case SLOPDESK_ANDROID_ACTION_CONSOLE: self = .console
        default: return nil
        }
    }
}

// MARK: - The device list

/// One entry of a device's context menu. `separator` is a case rather than a `nil` row because the
/// rule is about the LINE, not about a missing verb.
package enum AndroidDeviceMenuEntry: Equatable, Sendable {
    case separator
    case verb(AndroidDeviceVerb)
}

/// A verb a device row offers, with the text it carries where the text is the device's own.
package enum AndroidDeviceVerb: Equatable, Sendable {
    case openScreen
    case copyScreenshot
    case shutDown
    case start
    /// `adb -s`, an install target, a bug report — every other tool wants this one.
    case copySerial(String)
    case copyName(String)

    /// The crate's title for this verb. The two copy verbs carry their own text and the crate does
    /// not: the serial and the name are the caller's own row, which is the panel boundary's ordinary
    /// rule (`docs/55` §8).
    package var title: String {
        AndroidVocabulary.menuTitles[menuSlot]
    }

    /// Where this verb's title sits in the crate's menu-title run.
    private var menuSlot: Int {
        switch self {
        case .openScreen: Int(SLOPDESK_ANDROID_MENU_OPEN_SCREEN)
        case .copyScreenshot: Int(SLOPDESK_ANDROID_MENU_COPY_SCREENSHOT)
        case .shutDown: Int(SLOPDESK_ANDROID_MENU_SHUT_DOWN)
        case .start: Int(SLOPDESK_ANDROID_MENU_START)
        case .copySerial: Int(SLOPDESK_ANDROID_MENU_COPY_SERIAL)
        case .copyName: Int(SLOPDESK_ANDROID_MENU_COPY_NAME)
        }
    }
}

// MARK: - The header's facts

/// One MEASURED fact under the device's name — the value half of what `SlateFactLine` draws, with the
/// hue replaced by a role so it can live below the design floor.
///
/// `copies` is the WHOLE value and `text` may abbreviate it; the reason a short form is safe to draw
/// at all is that the full one is one right-click away.
package struct AndroidFact: Equatable, Sendable, Identifiable {
    /// Names the fact, in title case — the tooltip, the Copy verb, and the row's identity within one
    /// line, which is what lets a line animate a fact in or out without reshuffling.
    package let label: String
    package let text: String
    package let copies: String
    package let ink: AndroidInk
    /// Measured facts render in the instrument face; named ones render in the system face, so the line
    /// itself tells you which of its parts were read off a machine (MERIDIAN L2).
    package let isMeasured: Bool
    /// Whether the grey label is DRAWN ahead of the value. False for a fact whose presence is already
    /// the news.
    package let showsLabel: Bool

    package var id: String { label }
}

// MARK: - The console

/// One entry of a log row's context menu. `filterByTag` carries the tag because the verb NAMES it —
/// "Filter by ActivityManager" is the whole reason the item is worth a menu slot.
/// `Hashable` so a renderer that builds menus from a collection can identify a verb by itself; the
/// three cases are already distinct by value, so there is nothing to synthesise beyond the tag.
package enum AndroidLogVerb: Hashable, Sendable {
    case copyLine
    case copyConsole
    case filterByTag(String)

    package var title: String {
        switch self {
        case .copyLine: AndroidVocabulary.words[26]
        case .copyConsole: AndroidVocabulary.words[27]
        case let .filterByTag(tag):
            AndroidVocabulary.phrase(SLOPDESK_ANDROID_PHRASE_FILTER_BY_TAG, value: tag)
        }
    }
}

// MARK: - The face

/// The crate's tables and its one templated sentence, read out ONCE and reachable from anywhere.
///
/// Deliberately NOT inside ``AndroidPresentation``, which is `@MainActor` because two of its folds
/// drive `AndroidSidebarModel`. A word is not main-actor state — ``AndroidLogVerb/title`` and
/// ``AndroidDeviceVerb/title`` are plain value members, and isolating the table they read would put
/// an actor hop behind a `String` that has been fixed since process start.
enum AndroidVocabulary {
    /// Every fixed word, in the order `slopdesk_android_words` documents. Read ONCE — a door per
    /// string inside a SwiftUI body was measured too expensive when the settings catalogue did it,
    /// and this table is 28 strings that never change within a process.
    ///
    /// PADDED, never trusted: ``DevicePanelBlob/texts(_:)`` fills a short delivery with empties
    /// rather than shifting, so a crate and a face that disagree about the layout lose ONE word
    /// instead of wearing each other's from the gap onward.
    static let words: [String] = {
        var blob = DevicePanelBlob { out, cap in slopdesk_android_words(out, cap) }
        return blob.texts(28)
    }()

    /// The seven ``AndroidDeviceMenuEntry`` titles, in the crate's byte order. Slot `0` is the
    /// separator's and is empty by construction.
    static let menuTitles = Array(words[19..<26])

    /// Every toolbar plate the crate publishes, with the tray it belongs to.
    private static let plates: [(tray: Int32, verb: AndroidStageVerb)] = {
        var blob = DevicePanelBlob { out, cap in slopdesk_android_stage_verbs(out, cap) }
        let count = blob.count16()
        var plates: [(tray: Int32, verb: AndroidStageVerb)] = []
        plates.reserveCapacity(count)
        for _ in 0..<count {
            let tray = Int32(blob.byte())
            let action = AndroidStageAction(crateByte: blob.byte())
            let strings = blob.texts(4)
            guard let action else { continue }
            plates.append((tray, AndroidStageVerb(
                action: action,
                symbol: SFSymbol(rawValue: strings[0]),
                help: strings[1],
                latchedSymbol: SFSymbol(rawValue: strings[2]),
                latchedHelp: strings[3],
            )))
        }
        return plates
    }()

    /// The plates of one tray, in the crate's order. The TRAY byte is what lets this side rebuild
    /// three groups from one list without knowing the counts — a plate moving between trays is a
    /// design decision, and it belongs where the rest of the design decisions are.
    static func tray(_ id: Int32) -> [AndroidStageVerb] {
        plates.filter { $0.tray == id }.map(\.verb)
    }

    /// One door rather than six, because six doors that each format one value into one template
    /// would be six sites restating the same marshalling.
    static func phrase(_ id: Int32, value: String = "", count: Int = 0) -> String {
        devicePanelLend(value) { bytes, len in
            wsDelivered(capacity: 128) { out, cap in
                slopdesk_android_phrase(UInt8(id), bytes, len, count, out, cap)
            } ?? ""
        }
    }
}

@MainActor
package enum AndroidPresentation {
    // MARK: The stage

    /// How long the model may be loading before the veil admits it.
    ///
    /// 600 ms rather than the simulator stage's 400, and MEASURED — the crate carries the number and
    /// the measurement together, so a value measured once is not a value two files can re-tune.
    package static let veilDelay: Duration = .milliseconds(Int(slopdesk_android_veil_delay_ms()))

    /// What stands over the picture, from the veil's own (delayed) state and the model's.
    ///
    /// ⚠️ THE ORDER IS THE RULE, and it is the crate's: loading outranks stalled, because the two are
    /// reachable in the same frame while a reattempt is in flight and answering "no video" over a
    /// mirror that is being reopened puts a failure on the ordinary case. `showsLoading` is the VIEW's
    /// delayed mirror of ``AndroidSidebarModel/isAwaitingStream`` rather than the model's own flag.
    ///
    /// - Parameter deviceIsRunning: `false` only for a device that is still coming up, which is the
    ///   one distinction the caption is allowed to make. `nil` when there is no selected device to
    ///   ask, and then the wait is the mirror's by definition.
    package static func stage(
        showsLoading: Bool, hasSelection: Bool, isAwaitingStream: Bool, hasVideo: Bool,
        deviceIsRunning: Bool?,
    ) -> AndroidStageReading {
        let reading = slopdesk_android_stage(
            showsLoading, hasSelection, isAwaitingStream, hasVideo,
            deviceIsRunning != nil, deviceIsRunning ?? false,
        )
        let caption = AndroidVocabulary.words[15 + Int(reading)]
        switch Int32(reading) {
        case SLOPDESK_ANDROID_STAGE_STALLED:
            return .stalled(caption: caption, retry: AndroidVocabulary.words[3])
        case SLOPDESK_ANDROID_STAGE_STARTING_DEVICE,
             SLOPDESK_ANDROID_STAGE_STARTING_MIRROR:
            return .loading(caption: caption)
        default:
            return .streaming
        }
    }

    /// Android's three navigation keys, in the platform's own order — Back, Home, Recents, left to
    /// right, which is where a device with on-screen keys draws them.
    ///
    /// They are a tray of their own because on a gesture-navigation device they have NO on-screen
    /// target to press and are otherwise unreachable from a mirror. Everything a finger can already do
    /// — pulling the shade down, swiping between apps — is deliberately absent from every tray:
    /// `scrcpy` injects real touch events, so those gestures work on the frame itself, and a plate
    /// that duplicates a gesture is a plate that can be pressed by mistake.
    package static let navigationTray = AndroidVocabulary.tray(SLOPDESK_ANDROID_TRAY_NAVIGATION)

    /// The second tray: the host-side and protocol-side settings, which have no gesture at all.
    package static let actionTray = AndroidVocabulary.tray(SLOPDESK_ANDROID_TRAY_ACTION)

    /// The console plate, deliberately OFF the trays. It LATCHES, and a latched plate is drawn as a
    /// lit key, which reads as lit only against the panel's own tone. Sitting it on a tray would put a
    /// lit key inside a lit tray and cost exactly the signal it exists to carry.
    package static let consoleVerb = AndroidVocabulary.tray(SLOPDESK_ANDROID_TRAY_CONSOLE)[0]

    /// What the panel says when the paste verb finds nothing to paste. A report rather than a silent
    /// no-op, because pressing a plate and getting nothing at all reads as a broken button.
    package static let emptyClipboardReport = AndroidVocabulary.words[4]

    /// Run a toolbar verb against the live model.
    ///
    /// One of the two folds that stay Swift: every branch touches `AndroidSidebarModel`, which is a
    /// `@MainActor` observable with `Task`s in it. What crosses is the KIND that picks the branch.
    ///
    /// - Parameter isDisplayOff: the latch AFTER the press, so the call says what the device should do
    ///   rather than what the button just did.
    package static func run(
        _ action: AndroidStageAction, on model: AndroidSidebarModel, isDisplayOff: Bool = false,
    ) {
        switch action {
        case .back: model.send(AndroidControlMessage.pressBack())
        case .home: model.press(.home)
        case .recents: model.press(.appSwitch)
        case .rotate: model.rotate()
        // The capture is 250 ms and 300 KB (``SlopDeskMacUI/MacAndroidDeviceList`` and
        // ``SlopDeskPhoneUI/PhoneAndroidDeviceList`` carry the measurement in their headers), which
        // is why it is a press rather than a poll. Asked for once, it is worth every millisecond.
        case .capture: Task { await model.copyScreenshot() }
        case .pasteClipboard:
            guard let text = ClientPasteboard.text(), !text.isEmpty else {
                model.report(emptyClipboardReport)
                return
            }
            model.setClipboard(text, paste: true)
        case .displayPower: model.setDisplayPower(on: !isDisplayOff)
        case .console: model.toggleConsole()
        }
    }

    // MARK: The device list

    package static let searchPlaceholder = AndroidVocabulary.words[0]

    /// The empty list's two sentences, which are two different failures and must not be one.
    package static let noDevices = AndroidVocabulary.words[1]

    package static func noMatches(_ query: String) -> String {
        AndroidVocabulary.phrase(SLOPDESK_ANDROID_PHRASE_NO_MATCHES, value: query)
    }

    /// The filter, over every field somebody would type: the name, the model, the serial and the
    /// platform version.
    ///
    /// The predicate is ``DeviceRowFilter``'s — already Rust. What stays here is WHICH fields an
    /// Android row lends it, which is this panel's own fact about its own record.
    package static func matches(_ devices: [AndroidDevice], query: String) -> [AndroidDevice] {
        DeviceRowFilter.surviving(devices, query: query) { device, fields in
            fields.add(device.name)
            fields.add(device.model ?? "")
            fields.add(device.serial ?? "")
            fields.add(device.release ?? "")
        }
    }

    /// ⚠️ WHETHER A TAP OPENS THE MIRROR AT ALL, and the one predicate in this panel that was already
    /// spelled twice before a second renderer existed.
    ///
    /// A BOOTING emulator may be entered — the stage knows how to wait for a device, and "click, then
    /// watch it come up" is strictly better than "watch the list until clicking works". A physical
    /// device that is attached-but-unusable may NOT: its fix is an authorization dialog on its own
    /// screen, which is not something waiting can do.
    package static func canEnter(_ device: AndroidDevice) -> Bool {
        device.flags & UInt8(SLOPDESK_ANDROID_DEVICE_CAN_ENTER) != 0
    }

    /// The trailing text on a row that is not running: the platform version where the heading has not
    /// already said it, and the SCREEN otherwise.
    ///
    /// The screen is the fact the simulator list could not print — an AVD's `config.ini` is its
    /// definition, not a lookalike's — and it is what tells two similarly-named AVDs apart when they
    /// share a system image.
    package static func subtitle(for device: AndroidDevice, showsVersion: Bool) -> String? {
        devicePanelLend(device.versionLabel ?? "") { label, labelLen in
            wsDelivered(capacity: 64) { out, cap in
                slopdesk_android_subtitle(
                    label, labelLen, showsVersion && device.versionLabel != nil,
                    Int64(device.width ?? 0), Int64(device.height ?? 0), out, cap,
                )
            }
        }
    }

    /// The one verb an idle row offers, as a sentence.
    package static func startHelp(_ device: AndroidDevice) -> String {
        AndroidVocabulary.phrase(SLOPDESK_ANDROID_PHRASE_START_HELP, value: device.name)
    }

    /// The card's stop plate. A physical device is somebody's phone: this panel mirrors it and does
    /// not power it off, so the plate is simply ABSENT rather than present-and-refusing.
    package static func shutDownHelp(_ device: AndroidDevice) -> String {
        AndroidVocabulary.phrase(SLOPDESK_ANDROID_PHRASE_SHUT_DOWN_HELP, value: device.name)
    }

    /// The emulators a section heading's stop-all control may act on.
    ///
    /// Emulators only, and the crate says which: a physical device is not something this panel may
    /// power off, so a control that named every attached device would promise a verb it refuses for
    /// half of them.
    package static func stoppable(in devices: [AndroidDevice]) -> [AndroidDevice] {
        devices.filter { $0.flags & UInt8(SLOPDESK_ANDROID_DEVICE_IS_STOPPABLE) != 0 }
    }

    package static func shutDownAllHelp(count: Int) -> String {
        AndroidVocabulary.phrase(SLOPDESK_ANDROID_PHRASE_SHUT_DOWN_ALL_HELP, count: count)
    }

    /// A device's context menu, in order.
    ///
    /// A TABLE, and the crate's: one half growing a verb the other has not got is silent until
    /// somebody compares two screens. The separator is part of the table because where the line falls
    /// is the same kind of decision as which verbs are above it. The two copy verbs take their text
    /// from the ROW — the crate answers kinds, because the caller already holds the strings.
    package static func menu(for device: AndroidDevice) -> [AndroidDeviceMenuEntry] {
        let kinds = devicePanelLend(device.state) { state, stateLen in
            devicePanelKinds(capacity: 8) { out, cap in
                slopdesk_android_device_menu(
                    device.serial != nil, state, stateLen, device.isEmulator,
                    device.avdName != nil, out, cap,
                )
            }
        }
        return kinds.compactMap { kind in
            switch Int32(kind) {
            case SLOPDESK_ANDROID_MENU_SEPARATOR: .separator
            case SLOPDESK_ANDROID_MENU_OPEN_SCREEN: .verb(.openScreen)
            case SLOPDESK_ANDROID_MENU_COPY_SCREENSHOT: .verb(.copyScreenshot)
            case SLOPDESK_ANDROID_MENU_SHUT_DOWN: .verb(.shutDown)
            case SLOPDESK_ANDROID_MENU_START: .verb(.start)
            case SLOPDESK_ANDROID_MENU_COPY_SERIAL: device.serial.map { .verb(.copySerial($0)) }
            case SLOPDESK_ANDROID_MENU_COPY_NAME: .verb(.copyName(device.name))
            default: nil
            }
        }
    }

    /// Run a menu verb. The other fold that stays Swift, for ``run(_:on:isDisplayOff:)``'s reason.
    ///
    /// `enter` is the ONE verb handed back rather than run here, and deliberately: opening a device is
    /// the panel's drill between its two depths, and each half carries that move in its own framework
    /// (a `withAnimation` transaction on the phone, a layer animation on the Mac). Routing it through
    /// here would run the selection OUTSIDE whichever transaction is meant to carry it, which is a
    /// drill that cuts instead of sliding.
    package static func run(
        _ verb: AndroidDeviceVerb, device: AndroidDevice, on model: AndroidSidebarModel,
        enter: (AndroidDevice) -> Void,
    ) {
        switch verb {
        case .openScreen: enter(device)
        case .copyScreenshot: Task { await model.copyScreenshot(of: device.key) }
        case .shutDown: Task { await model.shutdown(device) }
        case .start: Task { await model.boot(device) }
        case let .copySerial(serial): ClientPasteboard.write(serial)
        case let .copyName(name): ClientPasteboard.write(name)
        }
    }

    /// A click on a device that is not running STARTS it — the same intent a click on a running card
    /// carries, one step earlier. Refused while a lifecycle verb is already in flight for that key,
    /// because the row's spinner holds until the boot is VISIBLE in the list
    /// (``AndroidSidebarModel/boot(_:)``) and a second press would queue a second launch against the
    /// same AVD, which the emulator refuses with a lock error that reads as a broken panel.
    package static func open(_ device: AndroidDevice, on model: AndroidSidebarModel) {
        guard !model.pending.contains(device.key) else { return }
        Task { await model.boot(device) }
    }

    // MARK: The running card

    /// 9:19.5 — the proportions of essentially every current Android phone, and the right guess for a
    /// device that has not said.
    package static let fallbackAspect = CGFloat(slopdesk_android_fallback_aspect())

    /// The card's screen box at a fixed art HEIGHT, from the device's own aspect ratio, so what varies
    /// between two cards is the shape and nothing else.
    ///
    /// Clamped so an unreported or absurd ratio cannot produce a box wider than the card. The three
    /// lengths are the CALLER's — they are design tokens, and `SlopDeskSlate` sits above this target —
    /// which leaves the arithmetic to the crate: the fallback, the multiply, and the ORDER of the
    /// clamp, done in IEEE `max`/`min` so one NaN upstream cannot survive as a NaN width.
    package static func artWidth(
        for device: AndroidDevice, art: CGFloat, floor: CGFloat, cap: CGFloat,
    ) -> CGFloat {
        CGFloat(slopdesk_android_art_width(
            device.aspectRatio ?? 0, Double(art), Double(floor), Double(cap),
        ))
    }

    /// The card's tooltip: a verb for a device that can be opened, and its STATE for one that cannot.
    package static func cardHelp(_ device: AndroidDevice) -> String {
        devicePanelLend(device.name) { name, nameLen in
            devicePanelLend(device.state) { state, stateLen in
                wsDelivered(capacity: 128) { out, cap in
                    slopdesk_android_card_help(
                        name, nameLen, device.serial != nil, state, stateLen, device.isEmulator,
                        out, cap,
                    )
                } ?? ""
            }
        }
    }

    /// The device's state as a sentence, with the one reading `adb`'s word alone would get wrong: an
    /// EMULATOR that is `offline` is almost always a boot in progress — the serial registers within
    /// seconds of launch and the guest's `adbd` answers ~21 s later (measured 2026-08-07) — and "Not
    /// responding" over a card that is doing exactly what was asked reads as a fault.
    package static func explain(_ device: AndroidDevice) -> String {
        explain(state: device.state, isEmulator: device.isEmulator)
    }

    /// `adb`'s state word as a sentence. The words are `adb`'s own and mean nothing to most readers —
    /// `unauthorized` in particular reads as a permissions error on the HOST, when what it means is
    /// that a dialog is waiting on the device's screen. A word this build has not seen answers ITSELF.
    package static func explain(state: String, isEmulator: Bool = false) -> String {
        devicePanelLend(state) { bytes, len in
            wsDelivered(capacity: 64) { out, cap in
                slopdesk_android_explain(bytes, len, isEmulator, out, cap)
            } ?? ""
        }
    }

    // MARK: The header

    package static let backHelp = AndroidVocabulary.words[2]

    /// The facts under the device's name, ordered by how often each is the thing being checked: the
    /// screen, then the density and ABI where they are known, then the SERIAL — which is what every
    /// other tool wants pasted into it.
    ///
    /// THE STREAM'S SIZE IS DELIBERATELY ABSENT. The panel mirrors at a cap
    /// (``AndroidSidebarModel/streamMaxSize``), so the encoded size is a fact about this panel's
    /// REQUEST and not about the device; printing both would be two resolutions in one line, one of
    /// them wrong for every purpose anyone would use it for.
    package static func facts(for device: AndroidDevice) -> [AndroidFact] {
        var blob = devicePanelLend(device.abi ?? "") { abi, abiLen in
            devicePanelLend(device.serial ?? "") { serial, serialLen in
                DevicePanelBlob { out, cap in
                    slopdesk_android_facts(
                        Int64(device.width ?? 0), Int64(device.height ?? 0),
                        Int64(device.density ?? 0), abi, abiLen, serial, serialLen, out, cap,
                    )
                }
            }
        }
        return (0..<blob.count16()).map { _ in
            let ink = AndroidInk(crateByte: blob.byte())
            let isMeasured = blob.byte() != 0
            let showsLabel = blob.byte() != 0
            let strings = blob.texts(3)
            return AndroidFact(
                label: strings[0], text: strings[1], copies: strings[2],
                ink: ink, isMeasured: isMeasured, showsLabel: showsLabel,
            )
        }
    }

    /// What a fact's own Copy verb is called. The LABEL names the fact, so the item reads "Copy
    /// Resolution" rather than "Copy" — which is the whole reason a fact carries a label at all.
    package static func copyTitle(_ fact: AndroidFact) -> String {
        AndroidVocabulary.phrase(SLOPDESK_ANDROID_PHRASE_COPY_TITLE, value: fact.label)
    }

    // MARK: The console

    /// The drawer's caps title. `Logcat`, not "Console": the panel carries the tool's own name because
    /// what it shows is the tool's own output, filter spec and all.
    package static let consoleTitle = AndroidVocabulary.words[5]
    package static let consoleFilterPlaceholder = AndroidVocabulary.words[6]
    package static let consoleLevelHelp = AndroidVocabulary.words[7]
    package static let consoleClearHelp = AndroidVocabulary.words[8]
    package static let consoleHideHelp = AndroidVocabulary.words[9]

    /// The drawer's three plates, as silhouettes. A GLYPH descends for the same reason a word does —
    /// it is what the control says — and it can, because an SF Symbol is a NAME rather than an image.
    ///
    /// FOLLOW KEEPS ONE GLYPH ACROSS ITS LATCH, unlike the stage's display-power plate. The latch is
    /// already drawn — a latched plate is a lit key — and swapping the arrow for a slashed arrow would
    /// say "off" twice while making the lit state harder to recognise at a glance.
    package static let consoleFollowSymbol = SFSymbol(rawValue: AndroidVocabulary.words[10])
    package static let consoleClearSymbol = SFSymbol(rawValue: AndroidVocabulary.words[11])
    package static let consoleHideSymbol = SFSymbol(rawValue: AndroidVocabulary.words[12])

    package static func consoleFollowHelp(isFollowing: Bool) -> String {
        isFollowing ? AndroidVocabulary.words[13] : AndroidVocabulary.words[14]
    }

    /// Case-insensitive substring over the whole row — TAG INCLUDED, since "which tag is spamming
    /// this" is the first question anyone asks of a `logcat`, and the tag column is the Android
    /// difference: `logcat` carries the whole system rather than one process.
    ///
    /// The predicate is ``DeviceRowFilter``'s, shared with the simulator console and both device
    /// lists; what stays here is WHICH two fields a `logcat` row lends it.
    package static func visible(_ lines: [DeviceLogLine], filter: String) -> [DeviceLogLine] {
        DeviceRowFilter.surviving(lines, query: filter) { line, fields in
            fields.add(line.message)
            fields.add(line.name)
        }
    }

    /// Three states, three sentences. "Nothing here" over a console that never connected is the
    /// failure this exists to distinguish — and the order matters: a live filter answers first,
    /// because rows exist and the reader is the reason none are showing.
    package static func consoleEmptyMessage(
        hasLines: Bool, isLogStarted: Bool, level: AndroidLogLevel, filter: String,
    ) -> String {
        devicePanelLend(level.title) { title, titleLen in
            devicePanelLend(filter) { needle, needleLen in
                wsDelivered(capacity: 128) { out, cap in
                    slopdesk_android_console_empty_message(
                        hasLines, isLogStarted, title, titleLen, needle, needleLen, out, cap,
                    )
                } ?? ""
            }
        }
    }

    /// One row as plain text — what Copy hands over, for one line and for the whole console.
    package static func plain(_ line: DeviceLogLine) -> String { line.plain }

    /// A log row's menu. The tag item appears only where there IS a tag, and it is the one filter
    /// action worth a slot: a tag is what somebody actually wants to isolate, and typing it into the
    /// field is the step this removes.
    package static func menu(for line: DeviceLogLine) -> [AndroidLogVerb] {
        let kinds = devicePanelKinds(capacity: 4) { out, cap in
            slopdesk_android_log_menu(!line.name.isEmpty, out, cap)
        }
        return kinds.compactMap { kind in
            switch Int32(kind) {
            case SLOPDESK_ANDROID_LOG_COPY_LINE: .copyLine
            case SLOPDESK_ANDROID_LOG_COPY_CONSOLE: .copyConsole
            case SLOPDESK_ANDROID_LOG_FILTER_BY_TAG: .filterByTag(line.name)
            default: nil
            }
        }
    }

    /// The tag's ink. COLOUR ONLY FOR A FAILURE — everything healthy is a grey, and the only
    /// difference between the greys is how far back they sit. A warning is a grey too: `logcat` at
    /// warning level on an ordinary Android device is dozens of lines a minute of framework noise, so
    /// tinting it would spend the alarm colour on the state of nothing being wrong.
    ///
    /// The crate answers it rather than this file for a reason the simulator's twin does not share:
    /// `plain` recedes HERE because it holds `logcat`'s V and D, and does NOT recede over there
    /// because `Df` is that grammar's ordinary default. Two consoles over one severity scale is
    /// exactly the pair that drifts, and it is only legible as a difference because both matches are
    /// exhaustive over the same Rust enum.
    package static func logInk(_ severity: DeviceLogSeverity) -> AndroidInk {
        AndroidInk(crateByte: slopdesk_android_log_ink(severity.rawValue))
    }
}

// MARK: - The device's own state, asked once

package extension AndroidDevice {
    /// The four things the panel asks about this device's state, as the crate's bitfield.
    ///
    /// ONE crossing rather than four: they are four reads of the SAME two fields, and a caller that
    /// asked them separately would cross `adb`'s state word four times per row per redraw.
    var flags: UInt8 {
        devicePanelLend(state) { bytes, len in
            slopdesk_android_device_flags(serial != nil, bytes, len, isEmulator)
        }
    }

    /// Running AND reachable. A device that is `unauthorized` is attached but will refuse every
    /// shell, so it must not offer a mirror button that can only fail.
    var isRunning: Bool {
        flags & UInt8(SLOPDESK_ANDROID_DEVICE_IS_RUNNING) != 0
    }

    /// Attached but not usable — the state that needs an explanation rather than an action. The user
    /// has to accept a debugging prompt on the device itself; nothing this panel sends can do it.
    var isAttachedButUnusable: Bool {
        flags & UInt8(SLOPDESK_ANDROID_DEVICE_IS_ATTACHED_BUT_UNUSABLE) != 0
    }

    /// The screen's physical proportions, or `nil` for a device that has not reported them. Used to
    /// draw the frame before the first video packet names a size — otherwise a freshly-opened device
    /// is a blank rectangle of the wrong shape for as long as the encoder takes to start.
    var aspectRatio: Double? {
        let ratio = slopdesk_android_aspect_ratio(Int64(width ?? 0), Int64(height ?? 0))
        return ratio > 0 ? ratio : nil
    }

    /// The one-line fact under the headline: what this device IS, in the terms someone picking one out
    /// of a list needs. Assembled from whatever is known rather than templated, so a row missing a
    /// field reads as a shorter sentence instead of one with a hole in it.
    var summary: String {
        devicePanelLend(release ?? "") { release, releaseLen in
            devicePanelLend(manufacturer ?? "") { maker, makerLen in
                devicePanelLend(model ?? "") { model, modelLen in
                    wsDelivered(capacity: 128) { out, cap in
                        slopdesk_android_summary(
                            release, releaseLen, Int64(apiLevel ?? 0),
                            Int64(width ?? 0), Int64(height ?? 0), isEmulator,
                            maker, makerLen, model, modelLen, out, cap,
                        )
                    } ?? ""
                }
            }
        }
    }
}
