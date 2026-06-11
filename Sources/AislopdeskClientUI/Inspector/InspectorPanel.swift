#if canImport(SwiftUI)
import SwiftUI
import AislopdeskInspector

/// The read-only structured inspector panel: composes the SwiftUI views already built in
/// `AislopdeskInspector` (`InspectorPane` → tool-card timeline / subagent tree / todos /
/// thinking-placeholder) and drives them from an `InspectorViewModel` fed by an
/// ``AislopdeskInspector/InspectorClient``'s event stream (NWConnection #2).
///
/// Read-only by construction (doc 16): the panel only *consumes* events; it never produces
/// any signal that reaches the agent. The terminal byte pipeline (PATH 1) is entirely
/// separate — this panel rides the inspector's second channel.
public struct InspectorPanel: View {
    @State private var model: InspectorViewModel
    private let client: InspectorClient?

    /// - Parameters:
    ///   - model: the `@MainActor @Observable` projection store (one source of truth).
    ///   - client: the inspector second-channel client; when present, the panel subscribes
    ///     on appear and folds its event stream into `model`. `nil` for previews / tests that
    ///     drive `model` directly.
    public init(model: InspectorViewModel, client: InspectorClient? = nil) {
        _model = State(initialValue: model)
        self.client = client
    }

    public var body: some View {
        InspectorPane(model: model)
            .task {
                guard let client else { return }
                // Full replay then live (read-only subscribe control — the only thing the
                // client is allowed to send).
                try? await client.subscribe(fromSeq: 0)
                await model.consume(client.events())
            }
    }
}
#endif
