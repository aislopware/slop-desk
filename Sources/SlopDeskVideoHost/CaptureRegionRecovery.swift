// C6 BUG B (2026-07-03): the PURE decision ladder for a failed DIALOG-EXPAND capture rebuild.
// `applyCaptureRegion` stops the OLD capturer before starting the new region-override capturer; if
// that start throws, the session used to be left `.streaming` with capturer/encoder nil — a silent
// forever-freeze with no recovery path (contrast `applyResize`'s rollBackWindow +
// restartOldSizeCapture). The ladder: try the union → degrade to a plain window-frame capturer →
// as the last resort send `.bye` + stop (a visible disconnect the client's reconnect UI handles
// beats a silent freeze). The SCK/VT side effects stay in the actor
// (`SlopDeskVideoHostSession/recoverPlainWindowCapture`); this pure rung selection is headlessly
// unit-tested.

/// Decides the recovery rung after a capture-region rebuild's `start()` threw.
public enum CaptureRegionFailureRecovery {
    /// What the actor must do next.
    public enum Action: Equatable, Sendable {
        /// A bye/stop teardown or a NEWER owner raced the rebuild — do nothing (rebuilding or
        /// disconnecting from here would double-tear, or orphan the newer owner's live SCStream).
        case abandon
        /// Rebuild a PLAIN window-frame capturer (drop the union region): the stream degrades to
        /// the un-expanded window instead of freezing.
        case rebuildPlainWindow
        /// The plain-window fallback ALSO failed — send `.bye` + stop the session so the client
        /// shows its disconnect/reconnect UI instead of a frozen frame.
        case disconnect
    }

    /// The rung for one failure. `superseded` = the failed refs are no longer the installed ones
    /// (a newer resize/region owner installed its own capturer/encoder across a suspension point);
    /// `isFallbackRebuild` = the failure was the plain-window fallback itself (the last rung).
    public static func action(
        mediaFlowing: Bool,
        superseded: Bool,
        isFallbackRebuild: Bool,
    ) -> Action {
        guard mediaFlowing, !superseded else { return .abandon }
        return isFallbackRebuild ? .disconnect : .rebuildPlainWindow
    }
}
