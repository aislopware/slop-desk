// CloseConfirmationCopy — what the pane/tab close confirmation SAYS, resolved once for both halves.
//
// The confirmation itself is the platform's own modal on both platforms — an `NSAlert` sheet on the Mac
// (``SlopDeskMacUI/MacCloseConfirmation``), a SwiftUI `.alert` on the phone (``OverlayHostView``) — and
// there is nothing to port about either. What there IS to keep in one place is the WORDING, because it
// is not a constant: it depends on which of the two parks is armed, on whether a configured policy
// actually gated the park (a park raised purely for the project-loss warning must not claim "a process
// is still running" over an idle shell), and on whether the close takes a project's last pane with it.
// Both can apply at once. Three branches and a join is exactly the amount of logic that drifts when two
// halves each carry it, so neither does: they read the park off the store through ``request(store:)``
// and print ``title(_:)`` and ``message(_:)``.
//
// It lives HERE rather than in the domain because it is a PRESENTATION of the domain (docs/56 §2): the
// store owns whether a close is parked and why; what a human is told about it is what a UI asks the
// store for.

import SlopDeskWorkspaceCore

/// The close confirmation's wording — PURE, so the copy is pinnable without instantiating a dialog.
public enum CloseConfirmationCopy {
    /// Everything the confirmation needs to know about a parked close, read off the store in one pass.
    ///
    /// The two parks are mutually exclusive, so `paneTitle` is what tells them apart: a pane close names
    /// the leaf it would take, a tab close has no leaf to name.
    public struct Request: Equatable, Sendable {
        /// Which unit the parked close is about.
        public let scope: CloseScope
        /// The parked PANE's title, or `nil` for a parked tab close. Empty is its own case — a pane with
        /// no title is named generically rather than with a pair of empty quotes.
        public let paneTitle: String?
        /// Whether a configured policy ACTUALLY gated this park. `false` when the park exists only for
        /// the project-loss warning below.
        public let policyGated: Bool
        /// The policy that gated it, when one did.
        public let policy: CloseConfirmationPolicy?
        /// The By-Project section that dies with the close, when the close takes its last pane.
        public let projectName: String?

        public init(
            scope: CloseScope,
            paneTitle: String?,
            policyGated: Bool,
            policy: CloseConfirmationPolicy?,
            projectName: String?,
        ) {
            self.scope = scope
            self.paneTitle = paneTitle
            self.policyGated = policyGated
            self.policy = policy
            self.projectName = projectName
        }
    }

    /// Reads the live park off `store`, or `nil` when nothing is parked.
    ///
    /// Every field is resolved LIVE rather than captured when the park was armed, which is the store's
    /// own choice (see ``WorkspaceStore/pendingCloseProjectName``) and the reason this is a function of
    /// the store rather than a value the store hands out: a pane opened or closed while the dialog is up
    /// keeps the answer honest.
    @preconcurrency
    @MainActor
    public static func request(store: WorkspaceStore) -> Request? {
        if let spec = store.pendingCloseSpec {
            return Request(
                scope: .pane,
                paneTitle: spec.title,
                policyGated: store.pendingClosePolicyGated,
                policy: store.pendingCloseReasonPolicy,
                projectName: store.pendingCloseProjectName,
            )
        }
        guard store.pendingTabCloseID != nil else { return nil }
        return Request(
            scope: .tab,
            paneTitle: nil,
            policyGated: store.pendingClosePolicyGated,
            policy: store.pendingCloseReasonPolicy,
            projectName: store.pendingCloseProjectName,
        )
    }

    /// The alert's headline: the pane's own title when a pane close is parked, else the tab copy.
    public static func title(_ request: Request) -> String {
        guard let name = request.paneTitle else { return "Close this tab?" }
        return name.isEmpty ? "Close this pane?" : "Close “\(name)”?"
    }

    /// The alert's body: the policy line when a policy gated the park, the project-loss line when the
    /// close takes a project's last pane, or both. A park that matches NEITHER gate (both are resolved
    /// live, so either can decay while the dialog is up) still prints the policy line rather than an
    /// empty body.
    public static func message(_ request: Request) -> String {
        var lines: [String] = []
        if request.policyGated {
            lines.append(reason(for: request.policy ?? .process, scope: request.scope))
        }
        if let project = request.projectName {
            lines.append(projectCloseReason(project: project, scope: request.scope))
        }
        if lines.isEmpty {
            lines.append(reason(for: request.policy ?? .process, scope: request.scope))
        }
        return lines.joined(separator: "\n\n")
    }

    /// The close-confirmation subtitle for a given resolved policy + close scope. The wording stays soft:
    /// a running process names the consequence; `always` asks plainly (scoped to "pane" vs "tab");
    /// `multiple_tabs` warns that the window holds several tabs.
    public static func reason(for policy: CloseConfirmationPolicy, scope: CloseScope = .tab) -> String {
        switch policy {
        case .process:
            "A process is still running. Closing it will stop the command."
        case .always:
            switch scope {
            case .pane: "Are you sure you want to close this pane?"
            case .tab,
                 .window: "Are you sure you want to close this tab?"
            }
        case .multipleTabs:
            "This window has multiple tabs."
        }
    }

    /// The project-loss warning line: the parked close takes `project`'s LAST pane / tab with it, so the
    /// whole By-Project section disappears. Appended to (or standing in for) the policy reason above.
    public static func projectCloseReason(project: String, scope: CloseScope) -> String {
        switch scope {
        case .pane:
            "This is the last pane of “\(project)”. Closing it will close the project."
        case .tab,
             .window:
            "This is the last tab of “\(project)”. Closing it will close the project."
        }
    }
}
