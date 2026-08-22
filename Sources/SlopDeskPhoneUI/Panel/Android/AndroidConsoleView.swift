// AndroidConsoleView — `logcat`, under the device, ON THE PHONE.
//
// iOS-ONLY SINCE docs/56 INCREMENT 52b; ``SlopDeskMacUI/MacAndroidConsoleView`` draws the same drawer
// in AppKit. The filter, the three empty sentences, the plain-text form a Copy hands over, the row
// menu and the severity→ink table all descended to ``AndroidPresentation`` — the last one because it
// is a scale, and a scale copied into a second framework is the drift nobody sees until two screens
// sit side by side.
//
// A DRAWER, not a tab, for the reason its simulator twin gives: the reason to read a device's log is
// to see what the thing on screen just did, and a console that replaces the screen breaks exactly
// that loop — tap, watch, read.
//
// THE FILTER IS CLIENT-SIDE and the LEVEL is not, which is the same split as the simulator console
// and for a sharper reason here: `logcat`'s filter spec is fixed at spawn, so a level change is a new
// child process, while a substring filter must NOT reconnect — narrowing the view is the one thing
// that has to keep the history it is narrowing.
//
// THE TAG COLUMN IS THE ANDROID DIFFERENCE. `logcat` carries the WHOLE system, not one process, so a
// quiet app's console is still hundreds of lines a minute of `ActivityManager`, `WindowManager` and
// the rest. The tag is what makes that navigable, so it is drawn as its own run and the filter
// searches it — "hide everything that is not mine" is the first thing anyone does with an Android
// log.

#if os(iOS)
import SFSafeSymbols
import SlopDeskDevicePanels
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

struct AndroidConsoleView: View {
    @Bindable var model: AndroidSidebarModel

    /// Held by the VIEW, not the model: it filters what is drawn and nothing else, it must not survive
    /// a device switch, and putting display state in the model would make a keystroke here an
    /// observable write that redraws the device above.
    @State private var filter = ""
    @State private var isFollowing = true

    var body: some View {
        VStack(spacing: 0) {
            strip
            content
        }
        .background(Slate.Surface.field)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Slate.Line.divider)
                .frame(height: Slate.Metric.hairline)
        }
    }

    // MARK: Controls

    private var strip: some View {
        HStack(spacing: Slate.Metric.space2) {
            Text(AndroidPresentation.consoleTitle)
                .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                .tracking(Slate.Typeface.instrumentTracking)
                .foregroundStyle(Slate.State.header)
                .fixedSize()
            level
            SlateSearchField(
                placeholder: AndroidPresentation.consoleFilterPlaceholder, text: $filter,
            )
            PlateIconButton(symbol: AndroidPresentation.consoleFollowSymbol, active: isFollowing) {
                isFollowing.toggle()
            }
            .help(AndroidPresentation.consoleFollowHelp(isFollowing: isFollowing))
            SlatePlateGroup {
                PlateIconButton(symbol: AndroidPresentation.consoleClearSymbol) { model.clearLog() }
                    .help(AndroidPresentation.consoleClearHelp)
                PlateIconButton(symbol: AndroidPresentation.consoleHideSymbol) {
                    withAnimation(Slate.Anim.standard) { model.toggleConsole() }
                }
                .help(AndroidPresentation.consoleHideHelp)
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightBar)
        .background(Slate.Surface.raised)
    }

    /// A menu rather than a segmented control: the level list does not fit a sidebar's width as segments,
    /// and the value is worth showing at rest.
    private var level: some View {
        Menu {
            ForEach(AndroidLogLevel.allCases) { level in
                Button {
                    model.setLogLevel(level)
                } label: {
                    if level == model.logLevel {
                        Label(level.title, systemSymbol: .checkmark)
                    } else {
                        Text(level.title)
                    }
                }
            }
        } label: {
            Text(model.logLevel.title)
                .font(.system(size: Slate.Typeface.small))
                .foregroundStyle(AndroidInk.secondary.color)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(AndroidPresentation.consoleLevelHelp)
    }

    // MARK: Rows

    /// ⚠️ ``visible`` is read ONCE per pass and threaded down — the Simulator twin's note is this
    /// one's too. It was read three times (the emptiness test, the `animation(value:)` key, the
    /// `ForEach`) and it is a `localizedCaseInsensitiveContains` over every retained line: **0.78 ms**
    /// per derivation on a hit and **1.50 ms** on a miss at `AndroidSidebarModel.logCapacity` = 600
    /// rows, in a scratch `swiftc -O` harness. `logcat` carries the whole system, so the ring sits AT
    /// its cap on any device that is doing anything.
    private var content: some View {
        let shown = visible
        return ZStack {
            if shown.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(AndroidInk.tertiary.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Slate.Metric.space2)
            } else {
                rows(shown)
            }
        }
        .animation(Slate.Anim.smallFade, value: shown.isEmpty)
    }

    private func rows(_ shown: [DeviceLogLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { row($0) }
                    // A hairline anchor after the last row rather than scrolling to the row itself: a
                    // row can be several lines tall, and scrolling to it leaves its own TOP edge at the
                    // bottom of the view — which reads as a console one message behind.
                    Color.clear
                        .frame(height: Slate.Metric.hairline)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, Slate.Metric.space2)
                .padding(.bottom, Slate.Metric.space1)
            }
            .onChange(of: model.logLines.count) { follow(proxy) }
            .onChange(of: filter) { follow(proxy) }
            .onChange(of: isFollowing) { follow(proxy) }
            .onAppear { follow(proxy) }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard isFollowing else { return }
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }

    private func row(_ line: DeviceLogLine) -> some View {
        HStack(alignment: .top, spacing: Slate.Metric.space1) {
            if !line.time.isEmpty {
                Text(line.time)
                    .foregroundStyle(AndroidInk.tertiary.color)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 0) {
                if !line.name.isEmpty {
                    Text(line.name)
                        .foregroundStyle(AndroidPresentation.logInk(line.severity).color)
                }
                Text(line.message)
                    .foregroundStyle(AndroidInk.secondary.color)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        // Monospaced throughout: a log is columnar data, and a proportional face destroys the one
        // alignment that makes a wall of it scannable.
        .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .regular))
        .padding(.vertical, Slate.Metric.hairline)
        .contextMenu { menu(for: line) }
    }

    /// WHICH verbs a log row offers is ``AndroidPresentation/menu(for:)``; the two Copy verbs run here
    /// because what "the console" means is this half's own filtered view, and the filter verb runs
    /// here because the field it writes into is view state by design (see ``filter``).
    private func menu(for line: DeviceLogLine) -> some View {
        ForEach(AndroidPresentation.menu(for: line), id: \.self) { verb in
            Button(verb.title) { run(verb, on: line) }
        }
    }

    private func run(_ verb: AndroidLogVerb, on line: DeviceLogLine) {
        switch verb {
        case .copyLine:
            copy(AndroidPresentation.plain(line))
        case .copyConsole:
            copy(visible.map(AndroidPresentation.plain).joined(separator: "\n"))
        case let .filterByTag(tag):
            filter = tag
        }
    }

    private func copy(_ text: String) {
        ClientPasteboard.write(text)
    }

    // MARK: Deriving

    private var visible: [DeviceLogLine] {
        AndroidPresentation.visible(model.logLines, filter: filter)
    }

    private var emptyMessage: String {
        AndroidPresentation.consoleEmptyMessage(
            hasLines: !model.logLines.isEmpty,
            isLogStarted: model.isLogStarted,
            level: model.logLevel,
            filter: filter,
        )
    }

    private static let bottomAnchor = "android.console.bottom"
}
#endif
