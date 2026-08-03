// CodeSidebarPageDressing — the client-side finishing coat injected into the embedded workbench
// (a WKUserScript that appends ONE <style> tag, plus the clipboard bridge script). The jobs the
// host-side settings seed cannot do:
//
//   • The terminal's own mono as CSS faces. The seeded `editor.fontFamily` leads with
//     "JetBrains Mono" — the face libghostty embeds and actually renders (the preference's
//     "SF Mono" resolves on neither machine) — but the webview's WebContent process cannot see
//     fonts the app registers with `CTFontManager` (registration is process-scoped), so the
//     bundled variable TTFs (upright + italic) ride in as @font-face data URIs, with the Symbols
//     Nerd Font behind them for the private-use glyphs (agent marks, powerline segments).
//   • The SLATE SOFTENING. The workbench's own corner-radius tokens (small 4 / medium 6 /
//     large 8) already sit exactly on Slate's ladder (`radiusSmall`/`radiusControl`/`radiusCard`)
//     — but the surfaces the user actually lives on never adopted them: editor TABS are square
//     full-bleed rectangles, list selections and scrollbar sliders are hard rectangles. The sheet
//     re-cuts exactly those in the app's geometry (tabs = floating rounded plates, the
//     `PanelTabPlate` vocabulary), touching GEOMETRY only — every colour stays the theme's.
//   • The empty-editor letterpress. code-server's stock watermark is ITS logo; the panel is
//     SlopDesk's surface, so the slopcat (docs/brand/logo-slopcat.svg, recoloured to the theme's
//     tertiary ink at the stock watermark's subtlety) replaces it via a background-image override.
//   • The RECOMMENDATION-TIPS graft (a separate, document-start script). code-server's web
//     client server hand-builds the `productConfiguration` embedded in the workbench HTML and
//     forwards only the extensions gallery — never any recommendation-tips key — so the
//     Extensions view's RECOMMENDED section is permanently empty. The graft rewrites the boot
//     configuration meta tag (filling ONLY keys the server did not send, so a future code-server
//     that ships its own tips wins) with `CodeSidebarRecommendationTips.json` before the
//     workbench script reads it.
//   • The clipboard BRIDGE (a separate, document-start script). WebKit's async clipboard API
//     silently drops the workbench's copy: `navigator.clipboard.writeText` needs a transient user
//     activation that VS Code's async copy path has often already spent, so ⌘C in the editor
//     never reached NSPasteboard. The bridge wraps `writeText`/`write` to ALSO post the plain
//     text to the native handler (`clipboardHandlerName` — the pool writes NSPasteboard), keeping
//     the original call as best effort. Copy works deterministically; paste already worked.
//
// Everything here is a PURE string builder (unit-pinned headlessly); the pool wires the products
// into `WKUserContentController` — the only WebKit-touching seam, unreachable from unit tests.

import Foundation

enum CodeSidebarPageDressing {
    /// The CSS family the nerd-font @font-face declares — the name the seeded `editor.fontFamily`
    /// (`CodeServerManager.seededUserSettings`, host side) lists as the private-use fallback.
    static let nerdFontFamilyName = "Symbols Nerd Font"

    /// The CSS family the JetBrains Mono @font-faces declare — the seeded `editor.fontFamily`'s
    /// PRIMARY. Must match the host-side seed string.
    static let monoFontFamilyName = "JetBrains Mono"

    /// The DOM id of the injected style tag — the script's own re-injection guard keys on it.
    static let styleElementID = "slopdesk-dressing"

    /// The `WKScriptMessageHandler` name the clipboard bridge posts copied text to.
    static let clipboardHandlerName = "slopdeskClipboard"

    /// The DOM id of the meta tag code-server embeds the workbench boot configuration in — the
    /// element the recommendation-tips graft rewrites.
    static let workbenchConfigurationMetaID = "vscode-workbench-web-configuration"

    /// The slopcat mark (docs/brand/logo-slopcat.svg) with the brand file's `currentColor`
    /// resolved to the theme's tertiary ink and the stock letterpress's `opacity=".3"` baked onto
    /// the root — a standalone SVG document in a data URI resolves `currentColor` to black, so
    /// the colour must be literal here.
    static let slopcatLetterpressSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256" opacity=".3">
      <defs>
        <mask id="slopcat-cut">
          <rect width="256" height="256" fill="#000"/>
          <path d="M 74 76 L 81 46 Q 98 54 112 70 Z" fill="#fff" stroke="#fff" stroke-width="10" stroke-linejoin="round"/>
          <path d="M 182 76 L 175 46 Q 158 54 144 70 Z" fill="#fff" stroke="#fff" stroke-width="10" stroke-linejoin="round"/>
          <rect x="56" y="68" width="144" height="120" rx="30" fill="#fff"/>
          <path d="M 90 111 L 114 128 L 90 145" fill="none" stroke="#000" stroke-width="13" stroke-linecap="round" stroke-linejoin="round"/>
          <rect x="140" y="134" width="34" height="11" rx="5.5" fill="#000"/>
        </mask>
      </defs>
      <rect width="256" height="256" fill="#727072" mask="url(#slopcat-cut)"/>
    </svg>
    """

    /// The Slate softening rules — geometry only (radius, insets), colours untouched. Values are
    /// the Slate ladder verbatim: tab/control 6 (`radiusTab`/`radiusControl`), card 8
    /// (`radiusCard`), small 4 (`radiusSmall`); the 4px tab inset rides the 4pt grid (`space1`).
    ///
    ///   • TABS become floating rounded plates: inset 4px off the strip's top/bottom/left, the
    ///     per-tab 1px dividers dropped (the strip background now separates them). The active tab's
    ///     background fill reads as a plate — exactly the app's `PanelTabPlate` at rest/selected.
    ///     The shrunk height comes from re-scoping `--editor-group-tab-height` on the tab (see the
    ///     first CSS comment), so the stock label/icon metrics keyed on that var track it for
    ///     free; the active-tab underline containers (`.tab-border-top/bottom-container`, absolute
    ///     at the plate's edges) go entirely — a Slate plate carries selection by its background
    ///     fill, never an underline.
    ///   • Lists/trees (explorer rows, palette rows): the selection/hover fill rounds to 6.
    ///   • Scrollbar sliders round to 5 (half their 10px width — a capsule, not a bar).
    ///   • Inputs step from the stock 4 up to the control rung 6; menus/hovers/find ride the card
    ///     rung 8 (the widgets the workbench ALREADY tokenized — quick input, suggest — sit on
    ///     their own vars and are left alone).
    static let slateSofteningCSS = """
    /* The plate height is made by RE-SCOPING the workbench's own `--editor-group-tab-height` on
       the tab, not by overriding stock rules one at a time: every stock rule keyed on the var —
       the tab's height, the label's line-height, and both tab-icon forms' heights
       (`.monaco-icon-label::before` for font glyphs, `.monaco-icon-label-iconpath` for SVG
       icons, each pinned to the FULL var by the stock sheet; a per-rule shrink here once left
       the SVG form centering on the 35px box, 4px below the label's line) — derives the shrunk
       value by itself. The strip and everything outside `.tab` still see the full var. The
       derived value must be CAPTURED on an ancestor first: `--x: calc(var(--x) - 8px)` on the
       tab itself is a cyclic custom-property reference, which invalidates the property. */
    .monaco-workbench .part.editor > .content .editor-group-container > .title {
        --slate-tab-plate: calc(var(--editor-group-tab-height) - 8px);
    }
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab {
        --editor-group-tab-height: var(--slate-tab-plate);
        margin: 4px 0 4px 4px;
        border-radius: 6px;
        border-right: none !important;
        border-left: none !important;
    }
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab:last-child {
        margin-right: 4px;
    }
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab > .tab-border-top-container,
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab > .tab-border-bottom-container {
        display: none !important;
    }
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab > .tab-fade-hide:after {
        border-radius: 6px;
    }
    .monaco-workbench .monaco-list-row {
        border-radius: 6px;
    }
    .monaco-workbench .monaco-scrollable-element > .scrollbar > .slider {
        border-radius: 5px;
    }
    .monaco-workbench .monaco-inputbox {
        border-radius: 6px;
    }
    .monaco-workbench .monaco-select-box {
        border-radius: 6px !important;
    }
    .monaco-workbench .monaco-button {
        border-radius: 6px;
    }
    .monaco-editor .find-widget {
        border-radius: 8px;
    }
    .monaco-hover {
        border-radius: 8px;
    }
    .context-view .monaco-menu {
        border-radius: 8px;
    }
    .monaco-workbench > .notifications-toasts .notification-toast-container > .notification-toast {
        border-radius: 8px;
        overflow: hidden;
    }
    """

    /// The injected sheet. Any nil font payload (bundle lookup failed) still ships the remaining
    /// faces, the softening and the letterpress — the jobs are independent.
    static func styleSheet(
        nerdFontBase64: String?,
        monoUprightBase64: String? = nil,
        monoItalicBase64: String? = nil,
    ) -> String {
        var sheet = ""
        if let monoUprightBase64 {
            sheet += fontFace(
                family: monoFontFamilyName, base64: monoUprightBase64,
                descriptors: "font-style: normal;\n    font-weight: 100 800;",
            )
        }
        if let monoItalicBase64 {
            sheet += fontFace(
                family: monoFontFamilyName, base64: monoItalicBase64,
                descriptors: "font-style: italic;\n    font-weight: 100 800;",
            )
        }
        if let nerdFontBase64 {
            sheet += fontFace(family: nerdFontFamilyName, base64: nerdFontBase64, descriptors: nil)
        }
        sheet += slateSofteningCSS
        let svgBase64 = Data(slopcatLetterpressSVG.utf8).base64EncodedString()
        // Matches the stock rule's specificity class-for-class (`.monaco-workbench.vs-dark …`)
        // via !important — the override must win for every theme class the workbench applies.
        sheet += """

        .monaco-workbench .editor-group-watermark .letterpress {
            background-image: url("data:image/svg+xml;base64,\(svgBase64)") !important;
        }
        """
        return sheet
    }

    /// One @font-face block. `descriptors` carries the style/weight lines for the variable faces
    /// (nil for the single-face nerd font).
    private static func fontFace(family: String, base64: String, descriptors: String?) -> String {
        """
        @font-face {
            font-family: "\(family)";
            src: url("data:font/ttf;base64,\(base64)") format("truetype");
            \(descriptors.map { "\($0)\n    " } ?? "")font-display: block;
        }

        """
    }

    /// The `WKUserScript` source: append the sheet once per document (`atDocumentEnd`, so `head`
    /// exists; the id guard makes a re-run — e.g. a soft SPA navigation — a no-op).
    static func userScript(styleSheet: String) -> String {
        """
        (function () {
            if (document.getElementById("\(styleElementID)")) { return; }
            var style = document.createElement("style");
            style.id = "\(styleElementID)";
            style.textContent = \(javaScriptStringLiteral(styleSheet));
            (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    /// The recommendation-tips `WKUserScript` source (document START, main frame only). Grafts
    /// ``CodeSidebarRecommendationTips/json`` into the `data-settings` boot configuration on the
    /// ``workbenchConfigurationMetaID`` meta tag, filling ONLY the keys the server did not send.
    ///
    /// TIMING: at document start the document is still empty, so the graft arms a
    /// `MutationObserver` and rewrites the attribute the moment the meta node is parsed in. The
    /// observer's microtask runs before the workbench's external boot script can execute (the
    /// parser must fetch it first), so the workbench only ever reads the grafted configuration.
    /// A malformed attribute leaves the page untouched — recommendations degrade to the stock
    /// empty section, never a broken workbench.
    static func recommendationTipsScript(tipsJSON: String = CodeSidebarRecommendationTips.json) -> String {
        """
        (function () {
            if (window.__slopdeskRecommendationTips) { return; }
            window.__slopdeskRecommendationTips = true;
            var tips = JSON.parse(\(javaScriptStringLiteral(tipsJSON)));
            function graft() {
                var meta = document.getElementById("\(workbenchConfigurationMetaID)");
                if (!meta) { return false; }
                try {
                    var settings = JSON.parse(meta.getAttribute("data-settings"));
                    var product = settings.productConfiguration || (settings.productConfiguration = {});
                    var changed = false;
                    for (var key in tips) {
                        if (!(key in product)) { product[key] = tips[key]; changed = true; }
                    }
                    if (changed) { meta.setAttribute("data-settings", JSON.stringify(settings)); }
                } catch (e) {}
                return true;
            }
            if (graft()) { return; }
            var observer = new MutationObserver(function () {
                if (graft()) { observer.disconnect(); }
            });
            observer.observe(document.documentElement || document, { childList: true, subtree: true });
        })();
        """
    }

    /// The focus-truth corrector `WKUserScript` source (document START, main frame). The
    /// workbench autofocuses its restored editor during boot and carries on believing the window
    /// is focused — but the native side refuses that focus (the webview takes the keyboard only
    /// from a click), and a page that was NEVER natively focused never receives a blur to learn
    /// otherwise: the restored editor's caret blinks alongside the focused terminal's cursor.
    /// Re-check `document.hasFocus()` (the engine's truth — it never went true) across the boot
    /// window and dispatch the missing blur. Synthetic EVENTS only — never `blur()` itself, which
    /// would clear `document.activeElement` and break the real focus hand-off (WebKit re-fires
    /// `focus` on the preserved element when the view actually takes the keyboard, and that is
    /// what puts the caret back).
    static func focusTruthScript() -> String {
        """
        (function () {
            if (window.__slopdeskFocusTruth) { return; }
            window.__slopdeskFocusTruth = true;
            function sync() {
                if (document.hasFocus()) { return; }
                var el = document.activeElement;
                if (el && el !== document.body) { el.dispatchEvent(new FocusEvent("blur")); }
                window.dispatchEvent(new FocusEvent("blur"));
            }
            [1500, 4000, 9000, 20000].forEach(function (ms) { setTimeout(sync, ms); });
        })();
        """
    }

    /// The clipboard-bridge `WKUserScript` source (document START, so the wrap is in place before
    /// the workbench captures the API). Wraps `navigator.clipboard.writeText` / `.write` to ALSO
    /// post the plain text to the native `clipboardHandlerName` handler; the original call still
    /// runs as best effort with its rejection swallowed (the native write already succeeded — a
    /// surfaced rejection would make VS Code toast a copy error that is not true here).
    static func clipboardBridgeScript() -> String {
        """
        (function () {
            if (window.__slopdeskClipboardBridged) { return; }
            window.__slopdeskClipboardBridged = true;
            function post(text) {
                try { window.webkit.messageHandlers.\(clipboardHandlerName).postMessage(String(text)); } catch (e) {}
            }
            var clipboard = navigator.clipboard;
            if (!clipboard) { return; }
            var writeText = clipboard.writeText && clipboard.writeText.bind(clipboard);
            clipboard.writeText = function (text) {
                post(text);
                if (writeText) { return writeText(text).catch(function () {}); }
                return Promise.resolve();
            };
            var write = clipboard.write && clipboard.write.bind(clipboard);
            clipboard.write = function (items) {
                try {
                    Array.prototype.forEach.call(items || [], function (item) {
                        if (item && item.types && item.types.indexOf("text/plain") >= 0) {
                            item.getType("text/plain")
                                .then(function (blob) { return blob.text(); })
                                .then(post)
                                .catch(function () {});
                        }
                    });
                } catch (e) {}
                if (write) { return write(items).catch(function () {}); }
                return Promise.resolve();
            };
        })();
        """
    }

    /// `string` as a double-quoted JavaScript string literal. Hand-rolled (not `JSONEncoder`) for
    /// the two JS-specific hazards JSON does not cover: U+2028/U+2029 are legal inside JSON
    /// strings but terminate a pre-ES2019 JS line, and a top-level-fragment encode is a Foundation
    /// version lottery. Pure — pinned.
    static func javaScriptStringLiteral(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
