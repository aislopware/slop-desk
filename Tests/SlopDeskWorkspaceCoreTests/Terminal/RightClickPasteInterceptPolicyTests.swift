import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the pure ``RightClickPasteInterceptPolicy`` — the decision that closes the right-click
/// paste-protection hole. libghostty owns the bare-right-click dispatch, so a `Paste` / `Copy or Paste`
/// action pastes through its OWN narrower gate (only `\n` / bracketed-end). This policy decides when the
/// embedder must INTERCEPT the click and run the broad ``PastePrecheck`` instead.
///
/// Discriminating, not tautological: an implementation that forwarded everything to libghostty (the OLD
/// hole) fails ``testPasteIntercepts`` / ``testCopyOrPasteInterceptsWithoutSelection``; one that stole
/// right-clicks from a mouse-reporting TUI fails ``testCapturedNeverIntercepts``; one that ignored the
/// selection for Copy-or-Paste fails ``testCopyOrPasteForwardsWithSelection``.
final class RightClickPasteInterceptPolicyTests: XCTestCase {
    /// Right-Click Action = Paste, not captured → ALWAYS intercept (regardless of selection).
    func testPasteIntercepts() {
        for hasSelection in [true, false] {
            XCTAssertTrue(
                RightClickPasteInterceptPolicy.interceptsAsPaste(
                    action: .paste, hasSelection: hasSelection, mouseCaptured: false,
                ),
                "Paste must intercept (hasSelection=\(hasSelection))",
            )
        }
    }

    /// Copy-or-Paste with NO selection → pastes → intercept.
    func testCopyOrPasteInterceptsWithoutSelection() {
        XCTAssertTrue(
            RightClickPasteInterceptPolicy.interceptsAsPaste(
                action: .copyOrPaste, hasSelection: false, mouseCaptured: false,
            ),
        )
    }

    /// Copy-or-Paste WITH a selection → copies (no protection needed) → do NOT intercept.
    func testCopyOrPasteForwardsWithSelection() {
        XCTAssertFalse(
            RightClickPasteInterceptPolicy.interceptsAsPaste(
                action: .copyOrPaste, hasSelection: true, mouseCaptured: false,
            ),
        )
    }

    /// A mouse-reporting program owns the click → never intercept, even for a paste action.
    func testCapturedNeverIntercepts() {
        for action in RightClickAction.allCases {
            for hasSelection in [true, false] {
                XCTAssertFalse(
                    RightClickPasteInterceptPolicy.interceptsAsPaste(
                        action: action, hasSelection: hasSelection, mouseCaptured: true,
                    ),
                    "captured mouse must forward (action=\(action) hasSelection=\(hasSelection))",
                )
            }
        }
    }

    /// Context Menu / Copy / Ignore never paste → never intercept (the click is handed to libghostty).
    func testNonPasteActionsNeverIntercept() {
        for action in [RightClickAction.contextMenu, .copy, .ignore] {
            for hasSelection in [true, false] {
                XCTAssertFalse(
                    RightClickPasteInterceptPolicy.interceptsAsPaste(
                        action: action, hasSelection: hasSelection, mouseCaptured: false,
                    ),
                    "\(action) must not intercept (hasSelection=\(hasSelection))",
                )
            }
        }
    }
}
