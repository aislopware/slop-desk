import Foundation

// L0: extracted from the deleted SwiftUI `PaneLeafView.swift`. `RemoteGUIDisplay` is the PURE
// (SwiftUI- and store-free) display decision for a remote-GUI pane — live vs entry-form vs
// cap-gated — unit-tested directly (LiveVideoCapTests). The rebuilt pane leaf (L6) reads it.
public enum RemoteGUIDisplay: Equatable {
    /// The live ``RemoteWindowPanel`` (admitted to a cap slot — its decode stack may run).
    case live
    /// The ``RemoteWindowPanel`` entry FORM: either the model is not yet configured (no host/port — the
    /// user must dial it in), OR it just became configured while a cap slot IS free (so admission is
    /// about to be auto-attempted and flip the pane to `.live` — the form must NOT vanish before then).
    /// Holds NO decode stack (`model.active == nil`).
    case entryForm
    /// The cap-saturated placeholder: the model IS configured AND no slot is free, so admission was
    /// refused specifically because ``WorkspaceStore/liveVideoCap`` is saturated (BUG-A — distinct from
    /// the unconfigured / free-slot `.entryForm`).
    case gated

    /// The PURE display decision (BUG-A + F1) — free of any SwiftUI / store state so it is unit-tested
    /// directly:
    /// - `admitted` ⇒ `.live`;
    /// - else NOT configured ⇒ `.entryForm` (let the user dial in — never gate an unconfigured pane);
    /// - else configured AND a slot IS free ⇒ `.entryForm` (the form stays until the reactive retry
    ///   admits the now-configured pane and flips `admitted` true — F1: the form must not disappear
    ///   the instant the endpoint becomes valid);
    /// - else (configured AND no free slot) ⇒ `.gated` (admission was genuinely refused by the cap).
    public static func resolve(admitted: Bool, configured: Bool, hasFreeSlot: Bool) -> Self {
        if admitted { return .live }
        guard configured else { return .entryForm }
        return hasFreeSlot ? .entryForm : .gated
    }
}
