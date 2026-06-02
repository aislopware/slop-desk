#if canImport(SwiftUI)
import SwiftUI
import RworkInspector

/// The root client view: a split layout of the terminal screen + a toggleable inspector
/// panel, with the connection chrome on top and the input bar at the bottom.
///
/// Platform chrome differs (`#if os(macOS)` / `#if os(iOS)`):
/// - **macOS**: a side-by-side `HSplitView`-style layout (terminal left, inspector right) —
///   doc 16 "desktop = split-view".
/// - **iOS**: the inspector is a bottom sheet / overlay toggled from the toolbar — doc 16
///   "iOS = tab/bottom-sheet".
public struct ClientRootView: View {
    @State private var connection: ConnectionViewModel
    @State private var input: InputBarModel
    private let inspectorModel: InspectorViewModel
    private let inspectorClient: InspectorClient?

    @State private var showInspector = false

    public init(
        connection: ConnectionViewModel,
        input: InputBarModel = InputBarModel(),
        inspectorModel: InspectorViewModel = InspectorViewModel(),
        inspectorClient: InspectorClient? = nil
    ) {
        _connection = State(initialValue: connection)
        _input = State(initialValue: input)
        self.inspectorModel = inspectorModel
        self.inspectorClient = inspectorClient
    }

    public var body: some View {
        VStack(spacing: 0) {
            ConnectionView(model: connection)
            Divider()
            content
            Divider()
            InputBarView(model: input, client: connection.activeClient)
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 480)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        // Desktop: terminal + inspector side-by-side (doc 16 split-view).
        HStack(spacing: 0) {
            terminal
            if showInspector {
                Divider()
                inspector
                    .frame(minWidth: 280, maxWidth: 420)
            }
        }
        .toolbar { inspectorToggle }
        #else
        // iOS: terminal full-bleed, inspector as a bottom sheet (doc 16 tab/bottom-sheet).
        terminal
            .toolbar { inspectorToggle }
            .sheet(isPresented: $showInspector) {
                inspector
                    .presentationDetents([.medium, .large])
            }
        #endif
    }

    private var terminal: some View {
        TerminalScreenView(model: connection.terminalModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspector: some View {
        InspectorPanel(model: inspectorModel, client: inspectorClient)
    }

    private var inspectorToggle: some ToolbarContent {
        ToolbarItem {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: showInspector ? "sidebar.right" : "sidebar.squares.right")
            }
        }
    }
}
#endif
