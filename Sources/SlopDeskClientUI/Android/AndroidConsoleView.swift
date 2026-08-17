// AndroidConsoleView — `logcat`, under the device.
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

#if os(macOS)
import SFSafeSymbols
import SlopDeskDevicePanels
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
            Text("Logcat")
                .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
                .tracking(Slate.Typeface.instrumentTracking)
                .foregroundStyle(Slate.State.header)
                .fixedSize()
            level
            SlateSearchField(placeholder: "Filter", text: $filter)
            PlateIconButton(symbol: .arrowDownToLine, active: isFollowing) {
                isFollowing.toggle()
            }
            .help(isFollowing ? "Following new output" : "Follow new output")
            SlatePlateGroup {
                PlateIconButton(symbol: .trash) { model.clearLog() }
                    .help("Clear Console")
                PlateIconButton(symbol: .xmark) {
                    withAnimation(Slate.Anim.standard) { model.toggleConsole() }
                }
                .help("Hide Console")
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightBar)
        .background(Slate.Surface.raised)
    }

    /// A menu rather than a segmented control: five levels do not fit a sidebar's width as segments,
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
                .foregroundStyle(Slate.Text.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Minimum priority — changing it restarts logcat")
    }

    // MARK: Rows

    private var content: some View {
        ZStack {
            if visible.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Slate.Metric.space2)
            } else {
                rows
            }
        }
        .animation(Slate.Anim.smallFade, value: visible.isEmpty)
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { row($0) }
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
                    .foregroundStyle(Slate.Text.tertiary)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 0) {
                if !line.name.isEmpty {
                    Text(line.name)
                        .foregroundStyle(Self.tint(for: line.severity))
                }
                Text(line.message)
                    .foregroundStyle(Slate.Text.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        // Monospaced throughout: a log is columnar data, and a proportional face destroys the one
        // alignment that makes a wall of it scannable.
        .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .regular))
        .padding(.vertical, Slate.Metric.hairline)
        .contextMenu {
            Button("Copy Line") { copy(Self.plain(line)) }
            Button("Copy Console") { copy(visible.map(Self.plain).joined(separator: "\n")) }
            if !line.name.isEmpty {
                // The one filter action worth a menu item: a tag is what someone actually wants to
                // isolate, and typing it into the field is the step this removes.
                Button("Filter by \(line.name)") { filter = line.name }
            }
        }
    }

    private func copy(_ text: String) {
        ClientPasteboard.write(text)
    }

    // MARK: Deriving

    /// Case-insensitive substring over the whole row — tag included, since "which tag is spamming
    /// this" is the first question anyone asks of a `logcat`.
    private var visible: [DeviceLogLine] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.logLines }
        return model.logLines.filter {
            $0.message.localizedCaseInsensitiveContains(trimmed)
                || $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Three states, three sentences. "Nothing here" over a console that never connected is the
    /// failure this exists to distinguish.
    private var emptyMessage: String {
        if !model.logLines.isEmpty { return "Nothing matches “\(filter)”." }
        return model.isLogStarted
            ? "Waiting for output at \(model.logLevel.title.lowercased()) priority…"
            : "Connecting to logcat…"
    }

    static func plain(_ line: DeviceLogLine) -> String {
        [line.time, line.name, line.message]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The tag's ink. COLOUR ONLY FOR A FAILURE — everything healthy is a grey, and the only
    /// difference between the greys is how far back they sit. A warning is a grey too: `logcat` at
    /// warning level on an ordinary Android device is dozens of lines a minute of framework noise, so
    /// tinting it would spend the alarm colour on the state of nothing being wrong.
    static func tint(for severity: DeviceLogSeverity) -> Color {
        switch severity {
        case .fatal,
             .error: Slate.StatusInk.err
        case .warning,
             .info: Slate.Text.secondary
        // `logcat`'s V and D both land in `plain`, and both should recede. `debug` is the unified
        // log's bucket and `logcat` never answers it — it is here so this switch stays exhaustive
        // over one shared ink scale rather than over an alphabet only Android has.
        case .debug,
             .plain: Slate.Text.tertiary
        }
    }

    private static let bottomAnchor = "android.console.bottom"
}
#endif
