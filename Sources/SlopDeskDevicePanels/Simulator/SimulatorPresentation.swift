// SimulatorPresentation — what the Simulators surface SAYS, and which of its situations a state picks.
//
// docs/56 stage D, increment 52a, and the same lift increments 47, 49 and 51 did for the checklist, the
// bespoke settings pages and the panel's own body. The seven surfaces below the Simulators tab —
// the list, the running card, the stage, the device header, the console drawer, the location popover
// and the bezel — had ONE renderer until the Mac drew them itself, so every word in them and every
// fold behind them had a single speller BY ACCIDENT. There are two renderers now, so the words and the
// folds moved down here and are single-spelled ON PURPOSE.
//
// ## Why this file, and not one beside each drawing
//
// The precedent is ``CodePanelPresentation``, and the argument is the one increment 51 made about
// ORDER: `workbench(…)`'s four questions are not interchangeable, and drawn twice from a prose
// description that ordering had ALREADY drifted between the two halves. The same shape recurs here at
// least four times — the row's subtitle suppression, the stage's three states, the console's three
// empty sentences, and which facts the header prints — and each is a rule a second renderer would
// re-derive from the same paragraph and get subtly wrong.
//
// It sits in `SlopDeskDevicePanels` rather than in `SlopDeskClientCore` because everything it names is
// this target's: ``SimulatorDevice``, ``SimulatorOrientation``, ``SimulatorCoordinate``,
// ``DeviceLogSeverity``. `CodePanelPresentation` took the dependency the other way for the opposite
// reason — it needed `CodeSidebarPhase` too, and one vocabulary spread over two targets would have
// needed a third file to hold the shared record.
//
// ## What is NOT here
//
// **No ink, no metric, no font.** `SlopDeskSlate` DEPENDS on this target, so a token read from here
// would be a cycle rather than a widening — the residue increments 47 and 49 both recorded. What
// descends instead is a ROLE (``SimulatorInk``) and a SILHOUETTE (an `SFSymbol`, which is a name, not
// a picture); each renderer spells the hue and mounts the image type its framework has. The measured
// GEOMETRY that is not a design token — the bezel's fit, the footprint swap a turned device needs —
// does descend, because those are facts about the artwork rather than rungs on a ladder.
//
// **No view, no `some View`.** This target declares no `View` type at all and the supervisor greps for
// it. A record here is a value; drawing it is the half's own problem.
//
// **No socket, no poll, no `.task`.** Those are ``SimulatorSidebarModel``'s. The one asynchronous rule
// that IS here — ``loadingVeil(isAwaiting:)`` — is here because it is a DECISION about what a reader
// is shown and when, and getting it wrong is a grey rectangle flashed over every selection on one
// platform only.

import CoreGraphics
import Foundation
import SFSafeSymbols

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
}

// MARK: - One control on the toolbar, the console strip or the header

/// A plate's SILHOUETTE and its tooltip — the two halves of a control that are not a drawing.
///
/// The symbol travels as an `SFSymbol` rather than as a `String` for the reason
/// ``SimulatorDeviceKind/symbol`` already travels that way: it is a closed set the compiler can check,
/// and a mistyped glyph name is a plate that silently draws nothing. ``symbolName`` is the same value
/// spelled for `NSImage(systemSymbolName:)`, so the AppKit half needs no second lookup table.
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

    package init(
        _ label: String, _ text: String, copies: String? = nil, ink: SimulatorInk,
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

    /// `nil` for the separator, which has no words.
    package var title: String? {
        switch self {
        case .openScreen: "Open Screen"
        case .copyScreenshot: "Copy Screenshot"
        case .shutdown: "Shut Down"
        case .boot: "Boot"
        case .separator: nil
        case .copyUDID: "Copy UDID"
        case .copyName: "Copy Name"
        }
    }
}

// MARK: - The folds and the words

package enum SimulatorPresentation {
    // MARK: The device list

    package static let searchPlaceholder = "Search devices"

    /// What the list draws in place of rows when the HOST has none. Distinct from ``noMatches(_:)``
    /// because "there are no devices" and "your filter hid them all" are different sentences and the
    /// second one is actionable.
    package static let noDevices = "No simulator devices on the host."

    package static func noMatches(_ query: String) -> String { "No devices match “\(query)”." }

    /// The trailing text on a shut-down device's row: the live state while the device is CHANGING, the
    /// runtime when it is not and the heading has not already said it, and nothing at all otherwise.
    ///
    /// ⚠️ THE TRANSITION OUTRANKS THE SUPPRESSION. A device spends seconds in `Booting`, and showing
    /// its runtime through that is the panel claiming nothing is happening while something is. A
    /// renderer that read only "does the heading already say the runtime" would draw the quiet answer
    /// for exactly the row worth watching.
    package static func rowSubtitle(_ device: SimulatorDevice, showsRuntime: Bool) -> String? {
        let settled = device.state.isEmpty
            || device.isBooted
            || device.state.caseInsensitiveCompare("Shutdown") == .orderedSame
        if !settled { return device.state }
        return showsRuntime && !device.runtime.isEmpty ? device.runtime : nil
    }

    /// The verbs a device's context menu offers, in order. `Open Screen` and `Copy Screenshot` need a
    /// running device; `Boot` is the whole menu for one that is not.
    package static func menu(for device: SimulatorDevice) -> [SimulatorDeviceVerb] {
        let acts: [SimulatorDeviceVerb] = device.isBooted
            ? [.openScreen, .copyScreenshot, .shutdown]
            : [.boot]
        // The UDID is what every other tool wants — `xcrun simctl`, a test invocation, a bug report —
        // and it is far too long to put in a row, which is the whole reason this cut exists.
        return acts + [.separator, .copyUDID, .copyName]
    }

    package static func bootHelp(_ device: SimulatorDevice) -> String { "Boot \(device.name)" }
    package static func openHelp(_ device: SimulatorDevice) -> String { "Open \(device.name)" }
    package static func shutdownHelp(_ device: SimulatorDevice) -> String {
        "Shut down \(device.name)"
    }

    /// Offered only once MORE THAN ONE device is up: with one running it is the same click as that
    /// card's own stop button under a longer name.
    package static func shutdownAllHelp(_ count: Int) -> String {
        "Shut down all \(count) running devices"
    }

    // MARK: The device header

    package static let backHelp = "All Devices"

    /// `1206 × 2622`. The MULTIPLICATION SIGN, not a lowercase x — this sits in a row of measured
    /// figures and a letter standing in for an operator is the detail that makes a panel look
    /// improvised.
    package static func pixels(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    /// The leading block of a UDID, which is what a person reads to tell two devices apart. The full
    /// value is 36 characters and would own the line; Copy hands over the whole thing.
    package static func shortenedUDID(_ udid: String) -> String { String(udid.prefix(8)) }

    /// What a fact's own Copy verb is called. The LABEL names the fact, so the item reads "Copy
    /// Resolution" rather than "Copy" — which is the whole reason a fact carries a label at all.
    ///
    /// It is here rather than in the renderer for the reason every other word in this file is: the Mac
    /// draws an `NSMenuItem` and the phone a `Button`, and a title spelled at each of them is a title
    /// that can drift. Increment 53 found exactly that — the AppKit half had built the string itself
    /// while the Android half, which is the same sentence, already asked ``AndroidPresentation``.
    package static func copyTitle(_ fact: SimulatorFact) -> String {
        "Copy \(fact.label)"
    }

    package static func orientationTitle(_ orientation: SimulatorOrientation) -> String {
        switch orientation {
        case .portrait: "Portrait"
        case .landscapeLeft: "Landscape Left"
        case .landscapeRight: "Landscape Right"
        case .portraitUpsideDown: "Upside Down"
        }
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
        var facts: [SimulatorFact] = []
        if let resolution {
            facts.append(SimulatorFact(
                "Resolution", pixels(resolution), ink: .secondary, isMeasured: true,
            ))
        }
        if orientation != .portrait {
            // Unlabelled: "Landscape Left" names itself, and it prints at all only because the device
            // is not upright.
            facts.append(SimulatorFact(
                "Orientation", orientationTitle(orientation), copies: orientation.wireValue,
                ink: .tertiary, showsLabel: false,
            ))
        }
        if let pinnedLocation {
            // "Simulated Location" is three words wide in a column that has none to spare, and the
            // shorter label the toolbar plate already uses does the naming.
            facts.append(SimulatorFact(
                "Simulated Location", pinnedLocation.readout,
                ink: .secondary, isMeasured: true, showsLabel: false,
            ))
        }
        facts.append(SimulatorFact(
            "UDID", shortenedUDID(device.udid), copies: device.udid,
            ink: .tertiary, isMeasured: true,
        ))
        return facts
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
        package static let rotateLeft = SimulatorPlateReading(.rotateLeft, "Rotate Left")
        package static let rotateRight = SimulatorPlateReading(.rotateRight, "Rotate Right")
        package static let home = SimulatorPlateReading(.house, "Home")
        /// A TOGGLE, and the tooltip says so. Measured 2026-08-04 against a booted device: the verb is
        /// the swipe-up-and-hold gesture, so it opens the card stack from an app or the home screen
        /// and DISMISSES it when the stack is already up — and on a device with nothing backgrounded
        /// it does nothing visible, exactly like the hardware. Neither this nor
        /// `swipe-to-app-switcher` is an idempotent "show".
        package static let appSwitcher = SimulatorPlateReading(
            .squareOnSquare, "App Switcher — press again to dismiss",
        )
        package static let screenshot = SimulatorPlateReading(.cameraViewfinder, "Copy Screenshot")

        /// The demo status bar's plate, which is latched while the override is in force.
        package static func statusBar(isOverridden: Bool) -> SimulatorPlateReading {
            SimulatorPlateReading(
                .clock,
                isOverridden ? "Restore the real status bar" : "Demo status bar (9:41)",
            )
        }

        /// Latched while a position is pinned, so the toolbar says the device is somewhere else
        /// without anyone opening the popover to find out. The header carries the actual coordinate;
        /// this is the glance.
        package static func location(isPinned: Bool) -> SimulatorPlateReading {
            SimulatorPlateReading(.location, isPinned ? "Simulated location" : "Simulate a location")
        }

        /// A ruled list, not a terminal prompt: this opens a READER over the device's output, and the
        /// `>_` glyph promises a place to type. (`.terminal` is also the Terminal.app icon and
        /// deprecated at this target.)
        package static func console(isOpen: Bool) -> SimulatorPlateReading {
            SimulatorPlateReading(
                .listBulletRectangle, isOpen ? "Hide the device log" : "Show the device log",
            )
        }
    }

    // MARK: The stage

    package static let startingCaption = "Starting the stream…"
    package static let stalledCaption = "No video from this device."

    /// The stage's one TEXT button, and the one failure here that a second attempt genuinely fixes —
    /// the socket is fine, the encoder never started — so the stage offers it rather than making
    /// someone go back to the list and pick the same row again.
    package static let retryTitle = "Try Again"

    /// Which of the three things the stage is doing.
    ///
    /// ⚠️ THE ORDER IS THE RULE. `showsLoading` first, because it is the DELAYED mirror of the model's
    /// own awaiting flag (see ``loadingVeil(isAwaiting:)``) and outranks a stall that has not been
    /// waited out yet; then the stall, which is defined by the model's deadline having passed with no
    /// video; then live. Asked in any other order the stage shows "no video" for the 90 ms before the
    /// first keyframe of every single selection.
    ///
    /// - Parameters:
    ///   - showsLoading: the renderer's own delayed copy of `isAwaitingStream`, never the raw flag.
    ///   - hasVideo: ``SimulatorSidebarModel/hasVideo`` — DECODABLE video, not "a frame arrived". The
    ///     seed does not count: a seed-only stream is a photograph of a device nobody is driving.
    package static func stage(
        isSelected: Bool, showsLoading: Bool, isAwaitingStream: Bool, hasVideo: Bool,
    ) -> SimulatorStageState {
        if showsLoading { return .starting(startingCaption) }
        if isSelected, !isAwaitingStream, !hasVideo { return .stalled(stalledCaption) }
        return .live
    }

    /// How long the model may be loading before the veil admits it.
    ///
    /// MEASURED: a booted device's first keyframe lands 0.09 s after the socket opens, so a veil with
    /// no delay would flash grey over the bezel on every single selection — the whole failure being
    /// drawn onto the ordinary case. This delay is the entire reason a renderer keeps its own copy of
    /// the loading state instead of reading the model's.
    package static let veilDelay: Duration = .milliseconds(400)

    /// Whether the veil should be showing: LATE on the way up, immediate on the way down. `nil` means
    /// the wait was cancelled and the caller must not write anything.
    ///
    /// The asymmetry is the whole point. A caller re-runs this whenever `isAwaiting` changes and
    /// cancels the previous run, so a pending veil for a stream that arrived in time never appears at
    /// all; waiting on the way DOWN would instead leave grey over a picture that is already there.
    ///
    /// The SHAPE is shared with the Android stage (`DevicePanelChrome.loadingVeilState`) and the
    /// NUMBER deliberately is not: 400 ms was measured against this server's 0.09 s first keyframe and
    /// the bridge's 600 ms against its own 0.83 s, and merging them would throw away both
    /// measurements. That is why the delay is baked in here rather than passed.
    package static func loadingVeil(isAwaiting: Bool) async -> Bool? {
        guard isAwaiting else { return false }
        try? await Task.sleep(for: veilDelay)
        guard !Task.isCancelled else { return nil }
        return true
    }

    /// What a failed read of a dropped file says. The server routes a dropped file by EXTENSION — an
    /// `.app`/`.ipa` is installed, an image or video lands in Photos — so this side accepts any file
    /// and lets the server classify it; getting that taxonomy wrong locally would reject the one build
    /// someone wanted. The only local failure is not being able to read the bytes at all.
    package static func unreadableDrop(_ fileName: String) -> String {
        "Could not read \(fileName)."
    }

    // MARK: The console drawer

    package enum Console {
        package static let title = "Console"
        package static let filterPlaceholder = "Filter"
        package static let levelHelp = "Minimum log level — changing it re-subscribes"
        package static let clear = SimulatorPlateReading(.trash, "Clear Console")
        package static let hide = SimulatorPlateReading(.xmark, "Hide Console")
        package static let copyLine = "Copy Line"
        package static let copyConsole = "Copy Console"

        /// FOLLOW IS A LATCH, not an inferred scroll position — the usual "stick to the bottom until
        /// the reader scrolls away" needs a scroll offset this deployment target does not report, and
        /// a latch is legible at rest and cannot disagree with reality.
        package static func follow(isFollowing: Bool) -> SimulatorPlateReading {
            SimulatorPlateReading(
                .arrowDownToLine, isFollowing ? "Following new output" : "Follow new output",
            )
        }

        /// Three states, three sentences. "Nothing here" over a console that never connected is the
        /// failure this exists to distinguish, and the order is why: a non-empty history with nothing
        /// visible is the FILTER's doing and must be said first, or a narrowed console reads as a dead
        /// one.
        package static func empty(
            hasLines: Bool, isStarted: Bool, level: SimulatorLogLevel, filter: String,
        ) -> String {
            if hasLines { return "Nothing matches “\(filter)”." }
            return isStarted
                ? "Waiting for output at \(level.title.lowercased()) level…"
                : "Connecting to the device log…"
        }

        /// One row as plain text — what Copy Line and Copy Console hand over. The row's own layout puts
        /// the three fields in columns; the copy joins them with a space, and drops the empty ones so
        /// an unparsed banner copies as itself rather than with two leading spaces.
        package static func plain(_ line: DeviceLogLine) -> String {
            [line.time, line.name, line.message]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        /// The process name's ink. COLOUR ONLY FOR A FAULT — everything healthy is a grey, and the only
        /// difference between the greys is how far back they sit.
        ///
        /// Info used to be green (user-directed 2026-08-04). Info is the ordinary case: a busy device
        /// emits hundreds of info lines a second, so the rule spent the console's one alarm colour on
        /// the state of nothing being wrong, and a wall half-green made the handful of red lines it
        /// exists to surface no easier to find. Debug still recedes, because a debug line IS
        /// lower-value than the default and luminance is the channel for that.
        package static func ink(for severity: DeviceLogSeverity) -> SimulatorInk {
            switch severity {
            case .fatal,
                 .error: .alarm
            case .debug: .tertiary
            // `warning` is `logcat`'s bucket and the unified log never answers it — it is here so this
            // switch stays exhaustive over one shared ink scale rather than over an alphabet only the
            // simulator has.
            case .info,
                 .warning,
                 .plain: .secondary
            }
        }
    }

    // MARK: The location popover

    package enum Location {
        package static let title = "Simulated Location"
        /// The format every map app copies to the clipboard, shown as the placeholder because that is
        /// where a coordinate typed into this field almost always comes from.
        package static let placeholder = "37.334886, -122.008988"
        package static let set = "Set"
        package static let clear = "Clear"
        /// Absent while nothing is pinned — a control that undoes nothing is a control that has to be
        /// reasoned about before it is ignored — which is why this pair is a fold rather than two
        /// labels a renderer picks between.
        package static let live = "The device is using live values."

        package static func pinned(_ coordinate: SimulatorCoordinate) -> String {
            "Pinned to \(coordinate.readout)"
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
        turned ? CGSize(width: bounds.height, height: bounds.width) : bounds
    }

    /// Aspect-FIT, and never above 1: a bezel blown past its artwork's own size is a soft, resampled
    /// device body, which looks worse than the same body drawn small and sharp.
    ///
    /// It fits the BLEED rect, never the viewport — side buttons protrude past the body
    /// (``SimulatorChrome/bleed``), and fitting the viewport alone clips them at the panel's edge.
    package static func fit(_ content: CGSize, in bounds: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0
        else { return 0 }
        return min(bounds.width / content.width, bounds.height / content.height, 1)
    }

    /// The server's button ids are wire tokens (`volume-up`, `action`). Spelled out for the tooltip
    /// rather than shown raw — and titled from the id when it is one this build has not seen, so a new
    /// button is still labelled with something.
    package static func buttonLabel(for id: String) -> String {
        switch id {
        case "power": "Power"
        case "volume-up": "Volume Up"
        case "volume-down": "Volume Down"
        case "action": "Action Button"
        case "home": "Home"
        case "lock": "Lock"
        case "digital-crown": "Digital Crown"
        case "side-button": "Side Button"
        default: id.split(separator: "-").map(\.capitalized).joined(separator: " ")
        }
    }

    // MARK: The one input number both screen surfaces read

    /// The floor between two-finger envelopes, in seconds.
    ///
    /// MEASURED 2026-08-04: `touch2-move` occupies the server for 25 ms, a thousand times what a
    /// `touch1-move` costs, so the two-finger path is rate-limited on BOTH halves — the Mac's
    /// synthesized magnify and the phone's real second finger alike. Here rather than at either
    /// surface because it is one measurement about the SERVER, and a number two files carry is a number
    /// that gets re-tuned in one of them.
    package static let pinchInterval: TimeInterval = 0.04
}
