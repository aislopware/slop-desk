// SimulatorConsoleView — the device's unified log, under the device.
//
// A DRAWER, not a tab. The reason to read a simulator's log is to see what the thing on screen just
// did, and a console that replaces the screen breaks exactly that loop: tap, watch, read. It takes a
// fixed share of the column so the device above it stays big enough to drive.
//
// THE FILTER IS CLIENT-SIDE and deliberately so. The server takes a `--level` at subscribe time and
// nothing else, so a level change means a reconnect (the model does that); a substring filter must
// NOT, because narrowing the view is the one thing that has to keep the history it is narrowing.
//
// FOLLOW IS A LATCH, not an inferred scroll position. The usual shape — stick to the bottom until
// the reader scrolls away — needs the scroll offset, and on this deployment target SwiftUI does not
// report it: `onScrollGeometryChange` is macOS 15, and the preference/`GeometryReader` substitute is
// a second opinion about layout that goes wrong in exactly the burst conditions a console is for.
// An explicit latch is what Console.app and Xcode both offer, it is legible at rest, and it cannot
// disagree with reality.

#if os(macOS)
import AppKit
import SFSafeSymbols
import SwiftUI

struct SimulatorConsoleView: View {
    @Bindable var model: SimulatorSidebarModel

    /// Held by the VIEW, not the model: it filters what is drawn and nothing else, it must not
    /// survive a device switch, and putting display state in the model would make a keystroke here
    /// an observable write that redraws the device above.
    @State private var filter = ""
    @State private var isFollowing = true

    var body: some View {
        VStack(spacing: 0) {
            strip
            content
        }
        .background(Slate.Surface.face)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Slate.Line.divider)
                .frame(height: Slate.Metric.hairline)
        }
    }

    // MARK: Controls

    /// The drawer's own head, one rung ABOVE the rows it sits on. A drawer sharing its body's tone
    /// with the surface above it has no top edge of its own, so the rows read as a continuation of
    /// the stage rather than as a second thing that opened. Clear and Hide ride one tray — both
    /// destroy what is on screen (one the history, one the drawer), which is the pairing worth
    /// making at a glance; Follow stays loose beside them because it LATCHES, and a lit key only
    /// reads as lit against the panel's own tone.
    private var strip: some View {
        HStack(spacing: Slate.Metric.space2) {
            Text("Console")
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
                PlateIconButton(symbol: .xmark) { model.toggleConsole() }
                    .help("Hide Console")
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.heightBar)
        .background(Slate.Surface.raised)
    }

    /// A menu rather than a segmented control: five levels do not fit a sidebar's width as segments,
    /// and the value is worth showing at rest — which a menu label does and a segmented picker only
    /// does by highlighting one of five things too small to read.
    private var level: some View {
        Menu {
            ForEach(SimulatorLogLevel.allCases) { level in
                Button {
                    model.setLogLevel(level)
                } label: {
                    // The check is the menu's own affordance for a chosen row; drawing the state any
                    // other way would give one control two vocabularies.
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
        .help("Minimum log level — changing it re-subscribes")
    }

    // MARK: Rows

    @ViewBuilder
    private var content: some View {
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

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { row($0) }
                    // A hairline anchor after the last row rather than scrolling to the row itself:
                    // a row can be several lines tall, and scrolling to it leaves its own TOP edge at
                    // the bottom of the view — which reads as a console one message behind.
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

    private func row(_ line: SimulatorLogLine) -> some View {
        HStack(alignment: .top, spacing: Slate.Metric.space1) {
            if !line.time.isEmpty {
                Text(line.time)
                    .foregroundStyle(Slate.Text.tertiary)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 0) {
                if !line.process.isEmpty {
                    Text(line.process)
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
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Deriving

    /// Case-insensitive substring over the whole row — process included, since "which process is
    /// spamming this" is as common a question as "where is my message".
    private var visible: [SimulatorLogLine] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.logLines }
        return model.logLines.filter {
            $0.message.localizedCaseInsensitiveContains(trimmed)
                || $0.process.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Three states, three sentences. "Nothing here" over a console that never connected is the
    /// failure this exists to distinguish.
    private var emptyMessage: String {
        if !model.logLines.isEmpty { return "Nothing matches “\(filter)”." }
        return model.isLogStarted
            ? "Waiting for output at \(model.logLevel.title.lowercased()) level…"
            : "Connecting to the device log…"
    }

    static func plain(_ line: SimulatorLogLine) -> String {
        [line.time, line.process, line.message]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The process name's ink. COLOUR ONLY FOR A FAULT — everything healthy is a grey, and the only
    /// difference between the greys is how far back they sit.
    ///
    /// Info used to be green (user-directed 2026-08-04). Info is the ordinary case: a busy device
    /// emits hundreds of info lines a second, so the rule spent the console's one alarm colour on the
    /// state of nothing being wrong, and a wall half-green made the handful of red lines it exists to
    /// surface no easier to find. Debug still recedes, because a debug line IS lower-value than the
    /// default and luminance is the channel for that.
    static func tint(for severity: SimulatorLogLine.Severity) -> Color {
        switch severity {
        case .fault,
             .error: Slate.Status.err
        case .debug: Slate.Text.tertiary
        case .info,
             .plain: Slate.Text.secondary
        }
    }

    private static let bottomAnchor = "console.bottom"
}
#endif
