// AndroidStageView — the whole mirroring surface: what device this is, the device itself, what you
// can do to it, and what it is saying.
//
// THREE BANDS, top to bottom, exactly as the simulator stage has them and for the same reasons: the
// top bar names the thing the other two are about and carries the verbs that act on it; the device is
// the lit content; the console is what the device just said, so it goes below rather than beside and
// the tap-watch-read loop stays one column. Two surfaces, not four bands — housing on `ground`,
// content on `face` (MERIDIAN L5).
//
// NO BEZEL, and it is not an omission. The simulator panel seats its stream inside the real device
// body because `baguette` serves per-model chrome artwork. Nothing equivalent exists for Android: the
// device set is every phone ever made, and drawing a generic rounded rectangle around the frame would
// be a claim about a device's shape that is right for none of them. What the bezel BOUGHT there — the
// side buttons under the pointer where the eye expects them — is bought here by the toolbar, which is
// where those buttons already had to live anyway.
//
// THE TOOLBAR IS THE THREE NAVIGATION KEYS PLUS WHAT HAS NO GESTURE. Back, Home and Recents are the
// device's own navigation and are drawn as one tray, because on a gesture-navigation device they have
// no on-screen target to press and are otherwise unreachable from a mirror. Rotate, capture, the
// clipboard hop and the device's own backlight are host-side or protocol-side settings and take the
// second tray. Everything a finger can already do — pulling the shade down, swiping between apps — is
// deliberately absent: `scrcpy` injects real touch events, so those gestures work on the frame
// itself, and a plate that duplicates a gesture is a plate that can be pressed by mistake.
//
// NO DROP TARGET (yet). The simulator stage installs a dropped `.app` because its server routes files
// by extension. The equivalent here is `adb install`, which is a different verb with a different
// failure mode (a signature mismatch, a downgrade, an ABI the device cannot run) and deserves its own
// reporting rather than being smuggled in as a drop.

#if os(macOS)
import AppKit
import SFSafeSymbols
import SwiftUI

struct AndroidStageView: View {
    @Bindable var model: AndroidSidebarModel

    /// The veil's own state, which is the model's loading state DELAYED — see ``veilDelay``.
    @State private var showsLoading = false
    @State private var isRetryHovering = false
    /// The device's own backlight, as last set from here. Local because `scrcpy` has no read side for
    /// it: this is what the next press toggles, not a claim about the device.
    @State private var isDisplayOff = false

    var body: some View {
        VStack(spacing: 0) {
            headerLayer
            device
                .background(Slate.Surface.face)
                .overlay { stageState }
                .animation(Slate.Anim.smallFade, value: showsLoading)
                .animation(Slate.Anim.smallFade, value: isStalled)
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

    /// The stream is over waiting and there is still no video. Distinct from "loading" by the model's
    /// deadline and from "streaming" by ``AndroidSidebarModel/hasVideo``, so the stage always resolves
    /// into one of three definite things rather than into an indicator with no end.
    private var isStalled: Bool {
        model.selection != nil && !model.isAwaitingStream && !model.hasVideo
    }

    // MARK: The device

    private var device: some View {
        AndroidScreenView(
            frames: model.frames,
            send: { model.send($0) },
            onContentSize: { model.observed(streamSize: $0) },
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
            navigation
            actions
            PlateIconButton(symbol: .listBulletRectangle, active: model.isConsoleOpen) {
                withAnimation(Slate.Anim.standard) { model.toggleConsole() }
            }
            .help(model.isConsoleOpen ? "Hide logcat" : "Show logcat")
        }
    }

    /// Android's three navigation keys, in the platform's own order — Back, Home, Recents, left to
    /// right, which is where a device with on-screen keys draws them.
    private var navigation: some View {
        SlatePlateGroup {
            // `BACK_OR_SCREEN_ON` rather than a bare `KEYCODE_BACK`: on a sleeping device the same
            // press wakes it, which is what the hardware key does and what anyone pressing it means.
            PlateIconButton(symbol: .chevronBackward) {
                model.send(AndroidControlMessage.pressBack())
            }
            .help("Back")
            PlateIconButton(symbol: .circle) { model.press(.home) }
                .help("Home")
            PlateIconButton(symbol: .squareOnSquare) { model.press(.appSwitch) }
                .help("Recent Apps")
        }
    }

    private var actions: some View {
        SlatePlateGroup {
            // ONE rotate, not a pair. `scrcpy`'s `ROTATE_DEVICE` is a toggle between the device's
            // natural orientation and the other one — there is no left and right to offer, and a pair
            // of arrows would be two buttons doing the same thing.
            PlateIconButton(symbol: .rotateRight) { model.rotate() }
                .help("Rotate")
            PlateIconButton(symbol: .cameraViewfinder) {
                Task { await model.copyScreenshot() }
            }
            .help("Copy Screenshot")
            // The clipboard hop, one way. The panel can PUSH the Mac's clipboard to the device and
            // deliberately cannot pull the device's back — a `GET_CLIPBOARD` makes the device write a
            // reply into the byte stream this panel is decoding as video. See ``AndroidControlMessage``.
            PlateIconButton(symbol: .documentOnClipboard) {
                guard let text = AndroidPasteboard.text(), !text.isEmpty else {
                    model.report("The clipboard has no text.")
                    return
                }
                model.setClipboard(text, paste: true)
            }
            .help("Paste the Mac's clipboard into the device")
            // The device's own backlight, which the mirror does not need. A phone on a desk lighting
            // up the room while somebody mirrors it is a real annoyance, and the stream is unaffected.
            PlateIconButton(symbol: isDisplayOff ? .lightbulbSlash : .lightbulb, active: isDisplayOff) {
                isDisplayOff.toggle()
                model.setDisplayPower(on: !isDisplayOff)
            }
            .help(isDisplayOff ? "Turn the device's screen back on" : "Turn the device's screen off")
        }
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
        if showsLoading {
            veil {
                WorkingSpinner()
                caption("Starting the mirror…")
            }
        } else if isStalled {
            veil {
                caption("No video from this device.")
                retry
            }
        }
    }

    /// A stalled mirror is the one failure here that a second attempt genuinely fixes — the jar is
    /// pushed, the server is up, the encoder never started — so the stage offers the retry rather than
    /// making someone go back to the list and pick the same row again.
    private var retry: some View {
        Button { model.retry() } label: {
            Text("Try Again")
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

    /// OPAQUE, on the stage's own tone rather than a dimming scrim. A scrim says "something is on top
    /// of the picture"; there is no picture, and the truthful drawing is the stage itself, empty.
    private func veil(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: Slate.Metric.space2) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Slate.Surface.face)
            .transition(.opacity)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Slate.Typeface.footnote))
            .foregroundStyle(Slate.Text.secondary)
    }

    /// How long the model may be loading before the veil admits it.
    ///
    /// 600 ms rather than the simulator stage's 400, and measured: a warm emulator's first keyframe
    /// arrives 0.83 s after the request (2026-08-04), because the host has to push the server jar,
    /// start `app_process` and wait for the device's encoder. So the veil DOES appear on an ordinary
    /// selection here — unlike the simulator's 0.09 s case, where any delay at all would have made it
    /// a flash. What the delay still buys is the second selection: a device opened, left and reopened
    /// while the panel is warm comes back faster than this, and flashing grey over it would be the
    /// failure state drawn onto the ordinary case.
    private static let veilDelay: Duration = .milliseconds(600)

    /// Mirror the model's loading state into ``showsLoading``, late on the way up and immediate on the
    /// way down. `.task(id:)` cancels this when the model's state flips, which is what makes the
    /// pending veil for a stream that arrived in time never appear at all.
    private func followLoading() async {
        guard model.isAwaitingStream else {
            showsLoading = false
            return
        }
        try? await Task.sleep(for: Self.veilDelay)
        guard !Task.isCancelled else { return }
        showsLoading = true
    }

    // THIS PANEL DRAWS NO BANNER. Every report leaves through the app's notification card; the
    // announcement lives on the surface that outlives both the stage and the list (see
    // ``CodeSidebarColumn``). What stays here is the STATE, which a notification cannot carry: a
    // mirror with no video is drawn on the stage itself, where the ambiguous empty rectangle is.
}
#endif
