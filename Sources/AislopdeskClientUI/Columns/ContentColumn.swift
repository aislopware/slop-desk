// ContentColumn — the centre content area (REBUILD-V2, L1). Placeholder only: the real identity-keyed
// pane grid (terminal / claude / remote splits, no-teardown for libghostty) lands in L2. SYSTEM colours.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct ContentColumn: View {
    let store: WorkspaceStore
    let connection: AppConnection

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Content area — panes land in L2")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
            .background(Color(.windowBackgroundColor))
        #else
            .background(Color(.systemBackground))
        #endif
    }
}
#endif
