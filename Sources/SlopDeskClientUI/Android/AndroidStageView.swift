// AndroidStageView — the whole mirroring surface ON THE PHONE: what device this is, the device
// itself, what you can do to it, and what it is saying.
//
// iOS-ONLY SINCE docs/56 INCREMENT 52b. The Mac's half is ``SlopDeskMacUI/MacAndroidStageView``, in
// AppKit, and this file is the phone's renderer rather than a shared one — the split's ruling, applied
// to the fourth panel surface. What is NOT duplicated is anything a reader reads or a state decides:
// every word here, the veil's fold, the toolbar's two trays and the verb→model table are
// ``AndroidPresentation``'s and are asked for rather than spelled.
//
// THREE BANDS, top to bottom, exactly as the simulator stage has them and for the same reasons: the
// top bar names the thing the other two are about and carries the verbs that act on it; the device is
// the lit content; the console is what the device just said, so it goes below rather than beside and
// the tap-watch-read loop stays one column. ONE surface under all three: the panel sinks to the
// window's cream ground (ONE ISLAND, law 1) and hairlines tell the bands apart — see
// ``SimulatorStageView`` for why the two-surface MERIDIAN L5 split retired on 2026-08-08.
//
// NO BEZEL, and it is not an omission. The simulator panel seats its stream inside the real device
// body because `baguette` serves per-model chrome artwork. Nothing equivalent exists for Android: the
// device set is every phone ever made, and drawing a generic rounded rectangle around the frame would
// be a claim about a device's shape that is right for none of them. What the bezel BOUGHT there — the
// side buttons under the pointer where the eye expects them — is bought here by the toolbar, which is
// where those buttons already had to live anyway.
//
// THE TOOLBAR IS THE THREE NAVIGATION KEYS PLUS WHAT HAS NO GESTURE, and which verbs those are is
// ``AndroidPresentation/navigationTray`` and ``AndroidPresentation/actionTray`` — a tray is an ordered
// list, and an ordering drawn twice from prose drifts. Everything a finger can already do is
// deliberately absent from both.
//
// NO DROP TARGET (yet). The simulator stage installs a dropped `.app` because its server routes files
// by extension. The equivalent here is `adb install`, which is a different verb with a different
// failure mode (a signature mismatch, a downgrade, an ABI the device cannot run) and deserves its own
// reporting rather than being smuggled in as a drop.

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

struct AndroidStageView: View {
    @Bindable var model: AndroidSidebarModel

    /// The veil's own state, which is the model's loading state DELAYED — see
    /// ``AndroidPresentation/veilDelay``.
    @State private var showsLoading = false
    @State private var isRetryHovering = false
    /// The device's own backlight, as last set from here. Local because `scrcpy` has no read side for
    /// it: this is what the next press toggles, not a claim about the device.
    @State private var isDisplayOff = false

    var body: some View {
        VStack(spacing: 0) {
            headerLayer
            device
                .background(Slate.Surface.field)
                .overlay { stageState }
                .animation(Slate.Anim.smallFade, value: reading)
                .task(id: model.isAwaitingStream) { await followLoading() }
            console
        }
    }

    // MARK: Identity

    /// A container so the band can animate its own absence — a device can leave the list under the
    /// panel, and the band it names goes with it. `.animation` on the conditional itself would be
    /// attached to the view that just stopped existing.
    private var headerLayer: some View {
        VStack(spacing: 0) { header }
            .animation(Slate.Anim.smallFade, value: model.selectedDevice?.key)
    }

    @ViewBuilder
    private var header: some View {
        if let device = model.selectedDevice {
            AndroidDeviceHeader(
                device: device,
                // ONE transaction, matching the way in (``AndroidDeviceList/enter(_:)``).
                onBack: { withAnimation(Slate.Anim.standard) { model.select(nil) } },
                actions: { toolbar },
            )
            .transition(.opacity)
        }
    }

    /// What stands over the picture, as ONE value — the fold is ``AndroidPresentation/stage(...)``,
    /// where the order (loading outranks stalled) is the rule and is spelled once.
    private var reading: AndroidStageReading {
        AndroidPresentation.stage(
            showsLoading: showsLoading,
            hasSelection: model.selection != nil,
            isAwaitingStream: model.isAwaitingStream,
            hasVideo: model.hasVideo,
            deviceIsRunning: model.selectedDevice?.isRunning,
        )
    }

    // MARK: The device

    private var device: some View {
        AndroidScreenView(
            frames: model.frames,
            send: { model.send($0) },
            videoSize: model.streamSize,
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Slate.Metric.space3)
        // Identity by DEVICE: switching devices must build a fresh view rather than feed a second
        // stream's frames into a layer configured for the first one's parameter sets.
        .id(model.selection)
    }

    // MARK: The toolbar

    /// Two trays: navigate it, then act on it. Loose plates in a row read as texture rather than as
    /// verbs, so each job takes a ``SlatePlateGroup`` and the rail becomes two objects instead of
    /// eight.
    ///
    /// The console plate stays OFF the trays on purpose: it LATCHES, and a latched plate is drawn as
    /// a lit key, which reads as lit only against the panel's own tone. Sitting it on a tray would
    /// put a lit key inside a lit tray and cost exactly the signal it exists to carry.
    private var toolbar: some View {
        HStack(spacing: Slate.Metric.space3) {
            SlatePlateGroup {
                ForEach(AndroidPresentation.navigationTray, id: \.action) { plate($0) }
            }
            SlatePlateGroup {
                ForEach(AndroidPresentation.actionTray, id: \.action) { plate($0) }
            }
            plate(AndroidPresentation.consoleVerb)
        }
    }

    /// One verb as a plate. The LATCH is the view's — `scrcpy` has no read side for the backlight and
    /// the drawer's own flag is the model's — and everything else about the control (its glyph, its
    /// sentence, what it does to the device) comes from below.
    private func plate(_ verb: AndroidStageVerb) -> some View {
        let latched = isLatched(verb.action)
        return PlateIconButton(symbol: verb.symbol(latched: latched), active: latched) {
            press(verb)
        }
        .help(verb.help(latched: latched))
    }

    private func isLatched(_ action: AndroidStageAction) -> Bool {
        switch action {
        case .displayPower: isDisplayOff
        case .console: model.isConsoleOpen
        default: false
        }
    }

    /// Flip whichever latch this verb owns FIRST, then run it with the result — the actuator is told
    /// what the device should now do rather than what the button just did
    /// (``AndroidPresentation/run(_:on:isDisplayOff:)``).
    private func press(_ verb: AndroidStageVerb) {
        switch verb.action {
        case .displayPower:
            isDisplayOff.toggle()
        case .console:
            // The drawer's own open/close is a LAYOUT change, so it rides the standard transaction the
            // way every other drill in this panel does.
            withAnimation(Slate.Anim.standard) {
                AndroidPresentation.run(verb.action, on: model)
            }
            return
        default:
            break
        }
        AndroidPresentation.run(verb.action, on: model, isDisplayOff: isDisplayOff)
    }

    // MARK: Output

    /// A fixed band under the device rather than a split the user drags: the device above it is the
    /// thing being driven and must not shrink to a stamp because a console got interesting.
    @ViewBuilder
    private var console: some View {
        if model.isConsoleOpen {
            AndroidConsoleView(model: model)
                .frame(height: Slate.Metric.heightDrawer)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: The stage's other two states

    /// A stage with no picture on it says which of the two reasons that is. Covering the whole stage
    /// rather than captioning it from the header is the point: the ambiguous object IS the empty
    /// rectangle, and an empty rectangle and a dead stream are pixel-identical. It stops at the
    /// header, which keeps the way out reachable while it is up.
    @ViewBuilder
    private var stageState: some View {
        switch reading {
        case .streaming:
            EmptyView()
        case let .loading(caption):
            veil {
                WorkingSpinner()
                self.caption(caption)
            }
        case let .stalled(caption, retryTitle):
            veil {
                self.caption(caption)
                retry(retryTitle)
            }
        }
    }

    /// A stalled mirror is the one failure here that a second attempt genuinely fixes — the jar is
    /// pushed, the server is up, the encoder never started — so the stage offers the retry rather than
    /// making someone go back to the list and pick the same row again.
    private func retry(_ title: String) -> some View {
        Button { model.retry() } label: {
            Text(title)
                .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)
                .contentShape(.rect)
        }
        .buttonStyle(SlatePlateStyle { pressed in
            isRetryHovering && !pressed ? Slate.State.selected : Slate.Surface.raised
        })
        .onHover { isRetryHovering = $0 }
        .animation(Slate.Anim.smallFade, value: isRetryHovering)
    }

    /// The empty stage and its caption are ``DevicePanelChrome``'s — a design decision both panels
    /// make identically, kept in one place so a pass over one file cannot re-tone only one of them.
    private func veil(@ViewBuilder content: () -> some View) -> some View {
        DevicePanelChrome.veil(content: content)
    }

    private func caption(_ text: String) -> some View {
        DevicePanelChrome.caption(text)
    }

    /// Mirror the model's loading state into ``showsLoading``, late on the way up and immediate on the
    /// way down. `.task(id:)` cancels this when the model's state flips, which is what makes the
    /// pending veil for a stream that arrived in time never appear at all. The DELAY is measured and
    /// lives with the other half of the decision (``AndroidPresentation/veilDelay``).
    private func followLoading() async {
        guard let state = await DevicePanelChrome.loadingVeilState(
            isAwaiting: model.isAwaitingStream, after: AndroidPresentation.veilDelay,
        ) else { return }
        showsLoading = state
    }

    // THIS PANEL DRAWS NO BANNER. Every report leaves through the app's notification card; the
    // announcement lives on the surface that outlives both the stage and the list (see
    // ``CodePanelSurfaces``). What stays here is the STATE, which a notification cannot carry: a
    // mirror with no video is drawn on the stage itself, where the ambiguous empty rectangle is.
}
#endif
