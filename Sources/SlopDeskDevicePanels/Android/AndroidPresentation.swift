// AndroidPresentation — what the Android panel's five surfaces SAY, and every fold either renderer
// would otherwise have taken on its own.
//
// docs/56 stage D, increment 52b, and the same lift increments 47, 49 and 51 did for the checklist,
// the bespoke settings pages and the code panel's four surfaces. The list, the stage, the header, the
// running card and the console had ONE renderer until the Mac drew them in AppKit, so every word in
// them and every phase→drawing answer had a single speller BY ACCIDENT. There are two renderers now,
// so the words and the folds sit here and are single-spelled ON PURPOSE.
//
// ## Why the folds and not just the words
//
// A copy string drifts LOUDLY — somebody reads the phone's screen and the Mac's and sees two
// sentences. An ORDERING drifts silently, and this panel already has three of them that would have
// gone unnoticed for a release:
//
//   * `canEnter(_:)` — the predicate that decides whether a tap on a device opens its mirror at all.
//     It was spelled TWICE inside one file pair already (``AndroidDeviceList``'s `enter(_:)` and
//     ``AndroidRunningCard``'s tap gate), which is exactly one spelling away from a Mac that opens a
//     booting emulator and a phone that refuses it.
//   * `stage(...)` — loading OUTRANKS stalled, which outranks streaming, and the loading caption then
//     asks a SECOND question (is the DEVICE still coming up, or only the mirror). Drawn twice from a
//     prose description, the two halves would have disagreed about which veil a booting AVD gets.
//   * `menu(for:)` — a verb table. One half quietly grows a verb the other has not got, and nothing
//     is red until somebody notices their phone's context menu is shorter than their Mac's.
//
// ## What is NOT here
//
// **No ink, no metric, no font.** `SlopDeskSlate` DEPENDS on `SlopDeskClientCore`, which this target
// sits under, so a token read from here would be a cycle rather than a widening. A reading names its
// own SILHOUETTE (an `SFSymbol`, which both halves already resolve — `Image(systemSymbol:)` on one
// side, `NSImage(systemSymbolName:)` over `.rawValue` on the other) and its own INK ROLE
// (``AndroidInk``), and each renderer spells the hue. The two MEASURED lengths that are not tokens —
// the veil's delay and the fallback aspect — live here, because they were measured once.
//
// **No layout.** Where the trays sit, how a card is framed, which container scrolls: that is the
// renderer's, and the two frameworks are entitled to disagree about it (docs/56 §3, "layout diverges;
// capability does not").
//
// **Nothing shared with the SIMULATOR panel.** The two surfaces look alike and share not one byte of
// protocol — `scrcpy` over `adb` against `baguette`'s websocket, Annex-B against AVC, packed control
// messages against JSON envelopes — so a common device vocabulary here would be an abstraction over a
// coincidence. What they genuinely share is already below them (``DevicePanelRules``,
// ``DevicePanelGeometry``, ``DeviceLogLine``), lifted one fact at a time and never as a family.

import CoreGraphics
import Foundation
import SFSafeSymbols
import SlopDeskWorkspaceCore

// MARK: - The one ink vocabulary the panel speaks in

/// A text ROLE, resolved to a hue by whichever half is drawing.
///
/// Four rungs and one alarm, which is the whole ladder this panel uses. It is a role rather than a
/// colour for the reason at the head of this file, and it is deliberately NOT the design floor's own
/// enum: `SlopDeskSlate` sits above this target, so naming its ladder here would invert the
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
    /// answers a different question — see ``AndroidFamilyMark``'s note about a column of marks.
    case icon
    /// The one hue this panel spends, and only on a fault.
    case err
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
/// each decide which glyph means Recents. The actuation is ``AndroidPresentation/run(_:on:)``, so the
/// switch from verb to model call is written once as well — a table of eight `case`s repeated in two
/// frameworks is the same drift as a table of eight strings.
package struct AndroidStageVerb: Equatable, Sendable {
    package let action: AndroidStageAction
    /// The glyph at rest.
    package let symbol: SFSymbol
    package let help: String
    /// The glyph and the sentence while the thing this verb turns on is ON. `nil` for the six verbs
    /// that do not latch.
    package let latchedSymbol: SFSymbol?
    package let latchedHelp: String?

    package init(
        action: AndroidStageAction, symbol: SFSymbol, help: String,
        latchedSymbol: SFSymbol? = nil, latchedHelp: String? = nil,
    ) {
        self.action = action
        self.symbol = symbol
        self.help = help
        self.latchedSymbol = latchedSymbol
        self.latchedHelp = latchedHelp
    }

    /// The glyph for a latch state — the same answer for a verb that cannot latch.
    package func symbol(latched: Bool) -> SFSymbol {
        latched ? latchedSymbol ?? symbol : symbol
    }

    package func help(latched: Bool) -> String {
        latched ? latchedHelp ?? help : help
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

    package var title: String {
        switch self {
        case .openScreen: "Open Screen"
        case .copyScreenshot: "Copy Screenshot"
        case .shutDown: "Shut Down"
        case .start: "Start"
        case .copySerial: "Copy Serial"
        case .copyName: "Copy Name"
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

    package init(
        _ label: String, _ text: String, copies: String? = nil, ink: AndroidInk,
        isMeasured: Bool = false, showsLabel: Bool = true,
    ) {
        self.label = label
        self.text = text
        self.copies = copies ?? text
        self.ink = ink
        self.isMeasured = isMeasured
        self.showsLabel = showsLabel
    }
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
        case .copyLine: "Copy Line"
        case .copyConsole: "Copy Console"
        case let .filterByTag(tag): "Filter by \(tag)"
        }
    }
}

// MARK: - The folds

@MainActor
package enum AndroidPresentation {
    // MARK: The stage

    /// How long the model may be loading before the veil admits it.
    ///
    /// 600 ms rather than the simulator stage's 400, and measured: a warm emulator's first keyframe
    /// arrives 0.83 s after the request (2026-08-04), because the host has to push the server jar,
    /// start `app_process` and wait for the device's encoder. So the veil DOES appear on an ordinary
    /// selection here — unlike the simulator's 0.09 s case, where any delay at all would have made it
    /// a flash. What the delay still buys is the second selection: a device opened, left and reopened
    /// while the panel is warm comes back faster than this, and flashing grey over it would be the
    /// failure state drawn onto the ordinary case.
    ///
    /// Here rather than at either renderer because it is a MEASUREMENT, and a number measured once
    /// that two files carry is a number that gets tuned in one of them.
    package static let veilDelay: Duration = .milliseconds(600)

    /// The stream is over waiting and there is still no video.
    ///
    /// Distinct from "loading" by the model's own deadline and from "streaming" by
    /// ``AndroidSidebarModel/hasVideo``, which is what makes the stage always resolve into one of
    /// three definite things.
    package static func isStalled(
        hasSelection: Bool, isAwaitingStream: Bool, hasVideo: Bool,
    ) -> Bool {
        hasSelection && !isAwaitingStream && !hasVideo
    }

    /// What stands over the picture, from the veil's own (delayed) state and the model's.
    ///
    /// ⚠️ THE ORDER IS THE RULE. Loading outranks stalled: the two are reachable in the same frame
    /// while a reattempt is in flight, and answering "no video" over a mirror that is being reopened
    /// puts a failure on the ordinary case. `showsLoading` is the VIEW's delayed mirror of
    /// ``AndroidSidebarModel/isAwaitingStream`` rather than the model's own flag — see ``veilDelay``.
    ///
    /// - Parameter deviceIsRunning: `false` only for a device that is still coming up, which is the
    ///   one distinction the caption is allowed to make. `nil` when there is no selected device to
    ///   ask, and then the wait is the mirror's by definition.
    package static func stage(
        showsLoading: Bool, hasSelection: Bool, isAwaitingStream: Bool, hasVideo: Bool,
        deviceIsRunning: Bool?,
    ) -> AndroidStageReading {
        if showsLoading {
            // TWO DIFFERENT WAITS WITH TWO DIFFERENT OWNERS: a mirror the HOST is starting, and a
            // device that is still booting. The model keeps the veil up through both, and the second
            // can be tens of seconds — far too long to blame on "the mirror".
            return .loading(caption: deviceIsRunning == false
                ? "Starting the device…"
                : "Starting the mirror…")
        }
        guard isStalled(
            hasSelection: hasSelection, isAwaitingStream: isAwaitingStream, hasVideo: hasVideo,
        ) else { return .streaming }
        // A stalled mirror is the one failure here that a second attempt genuinely fixes — the jar is
        // pushed, the server is up, the encoder never started — so the stage offers the retry rather
        // than making someone go back to the list and pick the same row again.
        return .stalled(caption: "No video from this device.", retry: "Try Again")
    }

    /// Android's three navigation keys, in the platform's own order — Back, Home, Recents, left to
    /// right, which is where a device with on-screen keys draws them.
    ///
    /// They are a tray of their own because on a gesture-navigation device they have NO on-screen
    /// target to press and are otherwise unreachable from a mirror. Everything a finger can already do
    /// — pulling the shade down, swiping between apps — is deliberately absent from every tray:
    /// `scrcpy` injects real touch events, so those gestures work on the frame itself, and a plate
    /// that duplicates a gesture is a plate that can be pressed by mistake.
    package static let navigationTray: [AndroidStageVerb] = [
        // `BACK_OR_SCREEN_ON` rather than a bare `KEYCODE_BACK`: on a sleeping device the same press
        // wakes it, which is what the hardware key does and what anyone pressing it means.
        AndroidStageVerb(action: .back, symbol: .chevronBackward, help: "Back"),
        AndroidStageVerb(action: .home, symbol: .circle, help: "Home"),
        AndroidStageVerb(action: .recents, symbol: .squareOnSquare, help: "Recent Apps"),
    ]

    /// The second tray: the host-side and protocol-side settings, which have no gesture at all.
    package static let actionTray: [AndroidStageVerb] = [
        // ONE rotate, not a pair. `scrcpy`'s `ROTATE_DEVICE` is a toggle between the device's natural
        // orientation and the other one — there is no left and right to offer, and a pair of arrows
        // would be two buttons doing the same thing.
        AndroidStageVerb(action: .rotate, symbol: .rotateRight, help: "Rotate"),
        AndroidStageVerb(action: .capture, symbol: .cameraViewfinder, help: "Copy Screenshot"),
        // The clipboard hop, ONE WAY. The panel can PUSH the client's clipboard to the device and
        // deliberately cannot pull the device's back — a `GET_CLIPBOARD` makes the device write a
        // reply into the byte stream this panel is decoding as video. See ``AndroidControlMessage``.
        AndroidStageVerb(
            action: .pasteClipboard, symbol: .documentOnClipboard,
            // Not "the Mac's clipboard", which is what this said while there was one renderer: the
            // surface draws on a phone now, and a help string that names the wrong machine is the
            // cheapest possible drift.
            help: "Paste the clipboard into the device",
        ),
        // The device's own backlight, which the mirror does not need. A phone on a desk lighting up
        // the room while somebody mirrors it is a real annoyance, and the stream is unaffected.
        AndroidStageVerb(
            action: .displayPower, symbol: .lightbulb,
            help: "Turn the device's screen off",
            latchedSymbol: .lightbulbSlash,
            latchedHelp: "Turn the device's screen back on",
        ),
    ]

    /// The console plate, deliberately OFF the trays. It LATCHES, and a latched plate is drawn as a
    /// lit key, which reads as lit only against the panel's own tone. Sitting it on a tray would put a
    /// lit key inside a lit tray and cost exactly the signal it exists to carry.
    package static let consoleVerb = AndroidStageVerb(
        action: .console, symbol: .listBulletRectangle, help: "Show logcat",
        latchedSymbol: .listBulletRectangle, latchedHelp: "Hide logcat",
    )

    /// What the panel says when the paste verb finds nothing to paste. A report rather than a silent
    /// no-op, because pressing a plate and getting nothing at all reads as a broken button.
    package static let emptyClipboardReport = "The clipboard has no text."

    /// Run a toolbar verb against the live model.
    ///
    /// Here rather than at either renderer because the verb→call table is a TABLE: eight cases, half
    /// of them one-liners, and the half that is not (the clipboard's guard, the pair of
    /// `AndroidControlMessage` sends behind Back) is where two hand-written switches would diverge
    /// first. What stays with each half is the LATCH — `displayPower` and `console` are view state on
    /// one side and a stored property on the other — so the caller flips its own and passes the
    /// result in.
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
        // The capture is 250 ms and 300 KB (``AndroidDeviceList``'s header has the measurement), which
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

    package static let searchPlaceholder = "Search devices"

    /// The empty list's two sentences, which are two different failures and must not be one.
    package static let noDevices = "No Android devices or emulators on the host."

    package static func noMatches(_ query: String) -> String {
        "No devices match “\(query)”."
    }

    /// The filter, over every field somebody would type: the name, the model, the serial and the
    /// platform version. Case- and diacritic-insensitive through `localizedCaseInsensitiveContains`,
    /// which is the platform's own answer rather than a folded copy of it.
    package static func matches(_ devices: [AndroidDevice], query: String) -> [AndroidDevice] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return devices }
        return devices.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.model ?? "").localizedCaseInsensitiveContains(trimmed)
                || ($0.serial ?? "").localizedCaseInsensitiveContains(trimmed)
                || ($0.release ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// ⚠️ WHETHER A TAP OPENS THE MIRROR AT ALL, and the one predicate in this panel that was already
    /// spelled twice before a second renderer existed.
    ///
    /// A BOOTING emulator may be entered — the stage knows how to wait for a device, and "click, then
    /// watch it come up" is strictly better than "watch the list until clicking works". A physical
    /// device that is attached-but-unusable may NOT: its fix is an authorization dialog on its own
    /// screen, which is not something waiting can do, so the card stays un-clickable rather than
    /// opening onto a wait that can never end.
    package static func canEnter(_ device: AndroidDevice) -> Bool {
        device.isRunning || device.isEmulator && device.serial != nil
    }

    /// The trailing text on a row that is not running: the platform version where the heading has not
    /// already said it, and the SCREEN otherwise.
    ///
    /// The screen is the fact the simulator list could not print — an AVD's `config.ini` is its
    /// definition, not a lookalike's — and it is what tells two similarly-named AVDs apart when they
    /// share a system image.
    package static func subtitle(for device: AndroidDevice, showsVersion: Bool) -> String? {
        if showsVersion, let version = device.versionLabel { return version }
        guard let width = device.width, let height = device.height else { return nil }
        return "\(width) × \(height)"
    }

    /// The one verb an idle row offers, as a sentence.
    package static func startHelp(_ device: AndroidDevice) -> String {
        "Start \(device.name)"
    }

    /// The card's stop plate. A physical device is somebody's phone: this panel mirrors it and does
    /// not power it off, so the plate is simply ABSENT rather than present-and-refusing.
    package static func shutDownHelp(_ device: AndroidDevice) -> String {
        "Shut down \(device.name)"
    }

    /// The emulators a section heading's stop-all control may act on.
    ///
    /// Emulators only, and COUNTED as such: a physical device is not something this panel may power
    /// off, so a control that named every attached device would promise a verb it refuses for half of
    /// them. Offered only where more than one is up, because that is the only place it is a different
    /// verb from the card's own stop button.
    package static func stoppable(in devices: [AndroidDevice]) -> [AndroidDevice] {
        devices.filter { $0.isRunning && $0.isEmulator }
    }

    package static func shutDownAllHelp(count: Int) -> String {
        "Shut down all \(count) running emulators"
    }

    /// A device's context menu, in order.
    ///
    /// A TABLE rather than a pair of `if` blocks per renderer, for the reason at the head of this
    /// file: one half growing a verb the other has not got is silent until somebody compares two
    /// screens. The separator is part of the table because where the line falls is the same kind of
    /// decision as which verbs are above it.
    package static func menu(for device: AndroidDevice) -> [AndroidDeviceMenuEntry] {
        var entries: [AndroidDeviceMenuEntry] = []
        if device.isRunning {
            entries.append(.verb(.openScreen))
            entries.append(.verb(.copyScreenshot))
            if device.isEmulator { entries.append(.verb(.shutDown)) }
        } else if device.avdName != nil {
            entries.append(.verb(.start))
        }
        entries.append(.separator)
        if let serial = device.serial { entries.append(.verb(.copySerial(serial))) }
        entries.append(.verb(.copyName(device.name)))
        return entries
    }

    /// Run a menu verb. Same argument as ``run(_:on:isDisplayOff:)`` — the verb→call table is the part
    /// that drifts, and the two copy verbs carry their own text so neither half re-reads the device.
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
    package static let fallbackAspect: CGFloat = 9.0 / 19.5

    /// The card's screen box at a fixed art HEIGHT, from the device's own aspect ratio, so what varies
    /// between two cards is the shape and nothing else.
    ///
    /// Clamped so an unreported or absurd ratio cannot produce a box wider than the card. The three
    /// lengths are the CALLER's — they are design tokens, and `SlopDeskSlate` sits above this target —
    /// which leaves exactly the arithmetic here: the fallback, the multiply, and the order of the
    /// clamp. That order is the part worth sharing; the numbers are already single-spelled in Slate.
    package static func artWidth(
        for device: AndroidDevice, art: CGFloat, floor: CGFloat, cap: CGFloat,
    ) -> CGFloat {
        let ratio = device.aspectRatio.map { CGFloat($0) } ?? fallbackAspect
        let width = art * ratio
        // `.maximum`/`.minimum`, never `min`/`max` — the stdlib pair compares with `<` and hands back
        // whichever operand won, which makes one NaN anywhere upstream survive as a NaN width.
        return CGFloat.minimum(CGFloat.maximum(width, floor), cap)
    }

    /// The card's tooltip: a verb for a device that can be opened, and its STATE for one that cannot.
    package static func cardHelp(_ device: AndroidDevice) -> String {
        device.isRunning ? "Open \(device.name)" : "\(device.name) — \(explain(device))"
    }

    /// The device's state as a sentence, with the one reading `adb`'s word alone would get wrong: an
    /// EMULATOR that is `offline` is almost always a boot in progress — the serial registers within
    /// seconds of launch and the guest's `adbd` answers ~21 s later (measured 2026-08-07) — and "Not
    /// responding" over a card that is doing exactly what was asked reads as a fault.
    package static func explain(_ device: AndroidDevice) -> String {
        if device.isEmulator, device.state == "offline" { return "Starting up…" }
        return explain(state: device.state)
    }

    /// `adb`'s state word as a sentence. The words are `adb`'s own and mean nothing to most readers —
    /// `unauthorized` in particular reads as a permissions error on the HOST, when what it means is
    /// that a dialog is waiting on the device's screen.
    package static func explain(state: String) -> String {
        switch state {
        case "unauthorized": "Waiting for you to allow debugging on the device"
        case "offline": "Not responding"
        case "authorizing": "Authorizing…"
        case "connecting": "Connecting…"
        case "recovery": "In recovery mode"
        case "sideload": "In sideload mode"
        case "bootloader": "In the bootloader"
        case "device": "Ready"
        default: state
        }
    }

    // MARK: The header

    package static let backHelp = "All Devices"

    /// The facts under the device's name, ordered by how often each is the thing being checked: the
    /// screen, then the density and ABI where they are known, then the SERIAL — which is what every
    /// other tool wants pasted into it.
    ///
    /// THE STREAM'S SIZE IS DELIBERATELY ABSENT. The panel mirrors at a cap
    /// (``AndroidSidebarModel/streamMaxSize``), so the encoded size is a fact about this panel's
    /// REQUEST and not about the device; printing both would be two resolutions in one line, one of
    /// them wrong for every purpose anyone would use it for.
    package static func facts(for device: AndroidDevice) -> [AndroidFact] {
        var facts: [AndroidFact] = []
        if let width = device.width, let height = device.height {
            facts.append(AndroidFact(
                "Screen", "\(width) × \(height)", ink: .secondary, isMeasured: true,
            ))
        }
        if let density = device.density {
            // `420 dpi` rather than the bucket's name (`xxhdpi`): the number is what a layout is
            // reasoned about in, and the bucket is derivable from it while the reverse is not.
            facts.append(AndroidFact("Density", "\(density) dpi", ink: .tertiary, isMeasured: true))
        }
        if let abi = device.abi, !abi.isEmpty {
            // Unlabelled: `arm64-v8a` names itself, and it is here because a native build that refuses
            // to install is almost always this line disagreeing with the APK.
            facts.append(AndroidFact("ABI", abi, ink: .tertiary, showsLabel: false))
        }
        if let serial = device.serial {
            facts.append(AndroidFact(
                "Serial", serial, copies: serial, ink: .tertiary, isMeasured: true,
            ))
        }
        return facts
    }

    /// What a fact's own Copy verb is called. The LABEL names the fact, so the item reads "Copy
    /// Resolution" rather than "Copy" — which is the whole reason a fact carries a label at all.
    package static func copyTitle(_ fact: AndroidFact) -> String {
        "Copy \(fact.label)"
    }

    // MARK: The console

    /// The drawer's caps title. `Logcat`, not "Console": the panel carries the tool's own name because
    /// what it shows is the tool's own output, filter spec and all.
    package static let consoleTitle = "Logcat"
    package static let consoleFilterPlaceholder = "Filter"
    package static let consoleLevelHelp = "Minimum priority — changing it restarts logcat"
    package static let consoleClearHelp = "Clear Console"
    package static let consoleHideHelp = "Hide Console"

    /// The drawer's three plates, as silhouettes. A GLYPH descends for the same reason a word does —
    /// it is what the control says — and it can, because `SFSymbol` is a name rather than an image and
    /// both halves already resolve it (`Image(systemSymbol:)` on one side, `NSImage(systemSymbolName:)`
    /// over `.rawValue` on the other).
    ///
    /// FOLLOW KEEPS ONE GLYPH ACROSS ITS LATCH, unlike the stage's display-power plate. The latch is
    /// already drawn — a latched plate is a lit key — and swapping the arrow for a slashed arrow would
    /// say "off" twice while making the lit state harder to recognise at a glance.
    package static let consoleFollowSymbol = SFSymbol.arrowDownToLine
    package static let consoleClearSymbol = SFSymbol.trash
    package static let consoleHideSymbol = SFSymbol.xmark

    package static func consoleFollowHelp(isFollowing: Bool) -> String {
        isFollowing ? "Following new output" : "Follow new output"
    }

    /// Case-insensitive substring over the whole row — TAG INCLUDED, since "which tag is spamming
    /// this" is the first question anyone asks of a `logcat`, and the tag column is the Android
    /// difference: `logcat` carries the whole system rather than one process.
    package static func visible(_ lines: [DeviceLogLine], filter: String) -> [DeviceLogLine] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return lines }
        return lines.filter {
            $0.message.localizedCaseInsensitiveContains(trimmed)
                || $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Three states, three sentences. "Nothing here" over a console that never connected is the
    /// failure this exists to distinguish — and the order matters: a live filter answers first,
    /// because rows exist and the reader is the reason none are showing.
    package static func consoleEmptyMessage(
        hasLines: Bool, isLogStarted: Bool, level: AndroidLogLevel, filter: String,
    ) -> String {
        if hasLines { return "Nothing matches “\(filter)”." }
        return isLogStarted
            ? "Waiting for output at \(level.title.lowercased()) priority…"
            : "Connecting to logcat…"
    }

    /// One row as plain text — what Copy hands over, for one line and for the whole console.
    package static func plain(_ line: DeviceLogLine) -> String {
        [line.time, line.name, line.message]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A log row's menu. The tag item appears only where there IS a tag, and it is the one filter
    /// action worth a slot: a tag is what somebody actually wants to isolate, and typing it into the
    /// field is the step this removes.
    package static func menu(for line: DeviceLogLine) -> [AndroidLogVerb] {
        var verbs: [AndroidLogVerb] = [.copyLine, .copyConsole]
        if !line.name.isEmpty { verbs.append(.filterByTag(line.name)) }
        return verbs
    }

    /// The tag's ink. COLOUR ONLY FOR A FAILURE — everything healthy is a grey, and the only
    /// difference between the greys is how far back they sit. A warning is a grey too: `logcat` at
    /// warning level on an ordinary Android device is dozens of lines a minute of framework noise, so
    /// tinting it would spend the alarm colour on the state of nothing being wrong.
    ///
    /// It is a ROLE rather than a colour, and it descends rather than staying with either console for
    /// a reason the simulator's twin does not share: `plain` recedes HERE because it holds `logcat`'s
    /// V and D, and does NOT recede over there because `Df` is that grammar's ordinary default. Two
    /// consoles over one severity scale is exactly the pair that drifts once the two are drawn by two
    /// frameworks.
    package static func logInk(_ severity: DeviceLogSeverity) -> AndroidInk {
        switch severity {
        case .fatal,
             .error: .err
        case .warning,
             .info: .secondary
        // `logcat`'s V and D both land in `plain`, and both should recede. `debug` is the unified
        // log's bucket and `logcat` never answers it — it is here so this switch stays exhaustive over
        // one shared ink scale rather than over an alphabet only Android has.
        case .debug,
             .plain: .tertiary
        }
    }
}
