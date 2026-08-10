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
        // The ground — the drawer is part of the sunken panel, not a lit surface inside it (ONE
        // ISLAND, law 1). Its top edge is the hairline below, which is the whole reason the rule is
        // drawn here rather than left to a tone change (and was already true when this was `face`:
        // the drawer opens over the stage, so it needs an edge of its own either way).
        .background(Slate.Surface.field)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Slate.Line.divider)
                .frame(height: Slate.Metric.hairline)
        }
    }

    // MARK: Controls

    /// The drawer's own head, one rung ABOVE the rows it sits on — `raised`, a translucent tint over
    /// the panel's cream rather than a tone borrowed from elsewhere. It is what separates the head
    /// from the log under it once both stand on the same ground. Clear and Hide ride one tray — both
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
                // Closes through the same transaction the toolbar plate opens with, so the drawer
                // leaves the way it arrived rather than vanishing from under the pointer.
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

    /// The waiting sentence and the log cross-fade rather than replace each other: the first line to
    /// arrive after a subscribe swaps a centred sentence for a wall of mono text, and cut hard it
    /// reads as the drawer being rebuilt. Keyed on emptiness alone — the rows themselves must never
    /// animate, a console at full tilt appends dozens of lines a second.
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
             .error: Slate.StatusInk.err
        case .debug: Slate.Text.tertiary
        case .info,
             .plain: Slate.Text.secondary
        }
    }

    private static let bottomAnchor = "console.bottom"
}
#endif
