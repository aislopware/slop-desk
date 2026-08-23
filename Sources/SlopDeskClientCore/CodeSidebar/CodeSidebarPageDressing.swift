// CodeSidebarPageDressing — the marshaller for the strings injected into the embedded workbench.
//
// The RULE is `rust/slopdesk-codepanel`: what the stylesheet says, what each of the four scripts
// does, why the letterpress ink is literal, and what the recommendation catalogue holds. All of it
// was 1,354 lines of Swift that imported Foundation and nothing else — pure string building, unit-
// pinned headlessly because there was nothing in it to touch a view. It crossed under docs/55.
//
// What is left here is the crossing and nothing else: a `(out, cap)` retry per text, three lent
// font URLs, and one process-lifetime cache for the sheet. The WebKit seam — installing a
// `WKUserScript`, answering the `slopdesk-font:` scheme, writing `NSPasteboard` — stays in
// `CodeSidebarWebViewPool`, because it IS the framework and was never the part under test.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

package enum CodeSidebarPageDressing {
    /// One of the panel's fixed texts, by its `SLOPDESK_CODE_PANEL_*` code.
    ///
    /// A code the linked artifact does not know answers nothing, and `wsDelivered` turns that into
    /// `nil` — the caller then installs no script rather than dressing a page with a fragment. The
    /// capacity is a first guess; the door reports a larger need and the retry pays for it once.
    private static func text(_ kind: Int32) -> String? {
        wsDelivered(capacity: 4096) { out, cap in
            slopdesk_code_panel_text(UInt8(truncatingIfNeeded: kind), out, cap)
        }
    }

    /// The DOM id of the injected style tag.
    package static let styleElementID = text(SLOPDESK_CODE_PANEL_STYLE_ELEMENT_ID) ?? ""

    /// The `WKScriptMessageHandler` name the clipboard bridge posts copied text to.
    package static let clipboardHandlerName = text(SLOPDESK_CODE_PANEL_CLIPBOARD_HANDLER) ?? ""

    /// The page hook ``focusTruthScript()`` publishes, as a call that is inert on a page which has
    /// not run the script yet. The NATIVE side replays the blur at the moments the page cannot see:
    /// a resign, and a remount whose keyboard stays with the terminal. See
    /// ``CodeSidebarWKWebView/syncFocusTruth()``.
    package static let focusTruthSyncCall = text(SLOPDESK_CODE_PANEL_FOCUS_SYNC_CALL) ?? ""

    /// The dressing user script for a webview whose bundle resolved these faces — the stylesheet
    /// and its injection wrapper, composed in one crossing.
    ///
    /// A `nil` URL is a face the bundle has no resource for; the sheet omits it rather than naming
    /// one the scheme handler would 404.
    package static func dressingScript(
        nerdFontURL: String?,
        monoUprightURL: String? = nil,
        monoItalicURL: String? = nil,
    ) -> String? {
        withOptionalText(nerdFontURL) { nerd, nerdLen, _ in
            withOptionalText(monoUprightURL) { upright, uprightLen, _ in
                withOptionalText(monoItalicURL) { italic, italicLen, _ in
                    wsDelivered(capacity: 16384) { out, cap in
                        slopdesk_code_panel_dressing_script(
                            nerd, nerdLen, upright, uprightLen, italic, italicLen, out, cap,
                        )
                    }
                }
            }
        }
    }

    /// The recommendation-tips graft (document START, main frame only).
    package static func recommendationTipsScript() -> String? {
        text(SLOPDESK_CODE_PANEL_TIPS_SCRIPT)
    }

    /// The focus-truth corrector (document START, main frame).
    package static func focusTruthScript() -> String? {
        text(SLOPDESK_CODE_PANEL_FOCUS_TRUTH_SCRIPT)
    }

    /// The webview canvas (document START, ALL frames).
    package static func webviewCanvasScript() -> String? {
        text(SLOPDESK_CODE_PANEL_CANVAS_SCRIPT)
    }

    /// The clipboard bridge (document START, ALL frames).
    package static func clipboardBridgeScript() -> String? {
        text(SLOPDESK_CODE_PANEL_CLIPBOARD_SCRIPT)
    }
}
