// CwdPill — the cwd context row (REBUILD-V2, L2). A simple native folder label bound to the pane's
// last-known cwd; hidden when no cwd is known. NO fancy pill, NO design-system — SYSTEM colours/fonts.
// (Truncation logic stays in the kept-pure `PaneMath.truncatedCwd`.)

#if canImport(SwiftUI)
import SwiftUI

struct CwdPill: View {
    /// The working-directory path to display (already the pane's last-known cwd). `nil`/empty ⇒ hidden.
    let cwd: String?

    /// Truncate from the beginning so the leaf directory stays visible (`PaneMath.truncatedCwd`).
    private var displayPath: String {
        guard let cwd, !cwd.isEmpty else { return "" }
        return PaneMath.truncatedCwd(cwd)
    }

    var body: some View {
        if let cwd, !cwd.isEmpty {
            Label(displayPath, systemImage: "folder")
                .font(.system(size: Otty.Typeface.small + 1))
                .foregroundStyle(Otty.Text.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(cwd)
        }
    }
}
#endif
