// InspectorColumn — the right inspector (REBUILD-V2, L1). Placeholder only: the real agent-status /
// branch / host / ping / tokens / exit-code inspector lands in L4. SYSTEM material background.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct InspectorColumn: View {
    let store: WorkspaceStore

    var body: some View {
        Text("Inspector — L4")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
    }
}
#endif
