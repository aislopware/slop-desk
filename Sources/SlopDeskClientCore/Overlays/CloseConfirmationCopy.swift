// CloseConfirmationCopy — the near-side FACE of `slopdesk_workspace::close_confirm`.
//
// The confirmation itself is the platform's own modal on both platforms — an `NSAlert` sheet on the Mac
// (``SlopDeskMacUI/MacCloseConfirmation``), and a `UIAlertController` on the phone once the UIKit shell
// mounts one — the SwiftUI `.alert` that used to sit on `OverlayHostView` has no successor yet — and
// there is nothing to port about either. What there IS to keep in one place is the WORDING, because it
// is not a constant: it depends on which of the two parks is armed, on whether a configured policy
// actually gated the park (a park raised purely for the project-loss warning must not claim "a process
// is still running" over an idle shell), and on whether the close takes a project's last pane with it.
// Both can apply at once. Three branches and a join is exactly the amount of logic that drifts when two
// halves each carry it, so neither does — and now neither LANGUAGE does either.
//
// ``request(store:)`` stays on this side: reading a live park off the store is a walk over `@MainActor`
// state the store owns, not a rule about what a human is told.
//
// Both sentences ride in ONE delivery because an alert is raised with both or not at all, and two doors
// would give a caller a way to pair a headline about a pane with a body about a tab.

import CSlopDeskFFI
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

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
    public static func title(_ request: Request) -> String { copy(request)[0] }

    /// The alert's body: the policy line when a policy gated the park, the project-loss line when the
    /// close takes a project's last pane, or both. A park that matches NEITHER gate (both are resolved
    /// live, so either can decay while the dialog is up) still prints the policy line rather than an
    /// empty body.
    public static func message(_ request: Request) -> String { copy(request)[1] }

    /// Both sentences, in one crossing.
    private static func copy(_ request: Request) -> [String] {
        var arena = WsStrings()
        let paneTitle = arena.span(request.paneTitle)
        let projectName = arena.span(request.projectName)
        let blob = arena.bytes.withUnsafeBufferPointer { lent in
            wsAnswerBytes { out, cap in
                Int(slopdesk_ws_close_confirm_copy(
                    request.scope.closeCode,
                    request.policyGated,
                    (request.policy ?? .process).closeCode,
                    paneTitle,
                    projectName,
                    lent.baseAddress,
                    lent.count,
                    out,
                    cap,
                ))
            }
        }
        return wsRuns(blob, count: 2)
    }
}

private extension CloseScope {
    /// A window closes like a tab as far as the wording goes — the sentence names the thing the reader
    /// pressed × on, and nobody presses × on a window expecting to be told about a pane.
    var closeCode: UInt8 {
        switch self {
        case .pane: 0
        case .tab,
             .window: 1
        }
    }
}

private extension CloseConfirmationPolicy {
    var closeCode: UInt8 {
        switch self {
        case .process: 0
        case .always: 1
        case .multipleTabs: 2
        }
    }
}
