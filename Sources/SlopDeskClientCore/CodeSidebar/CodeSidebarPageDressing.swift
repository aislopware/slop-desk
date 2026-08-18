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
//     `MacPanelTabPlate` vocabulary), touching GEOMETRY only — every colour stays the theme's.
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
//   • The webview CANVAS (a separate, document-start, ALL-frames script). VS Code webview
//     content documents (markdown preview, extension pages) are transparent at every layer by
//     design — the desktop app composites them over the editor — and they scroll at FRAME level,
//     so WebKit fills the slivers a scroll exposes before paint catches up with the frame's
//     canvas colour: transparent resolves to WHITE. None of the app's other measures reach a
//     subframe (`underPageBackgroundColor` covers main-frame overscroll only, the KVC
//     `drawsBackground` only the base canvas, the dressing sheet is main-frame-only). The script
//     keys the root canvas to the workbench's own theme var, so it re-resolves on theme flips
//     and stays transparent in any frame without VS Code vars.
//
// Everything here is a PURE string builder (unit-pinned headlessly); the pool wires the products
// into `WKUserContentController` — the only WebKit-touching seam, unreachable from unit tests.

import Foundation

package enum CodeSidebarPageDressing {
    /// The CSS family the nerd-font @font-face declares — the name the seeded `editor.fontFamily`
    /// (`slopdesk-codeseed`'s `resources/settings.json`, host side) lists as the private-use
    /// fallback.
    package static let nerdFontFamilyName = "Symbols Nerd Font"

    /// The CSS family the JetBrains Mono @font-faces declare — the seeded `editor.fontFamily`'s
    /// PRIMARY. Must match the host-side seed string.
    package static let monoFontFamilyName = "JetBrains Mono"

    /// The DOM id of the injected style tag — the script's own re-injection guard keys on it.
    package static let styleElementID = "slopdesk-dressing"

    /// The `WKScriptMessageHandler` name the clipboard bridge posts copied text to.
    package static let clipboardHandlerName = "slopdeskClipboard"

    /// The DOM id of the webview-canvas style tag — the canvas script's re-injection guard.
    package static let canvasStyleElementID = "slopdesk-webview-canvas"

    /// The DOM id of the meta tag code-server embeds the workbench boot configuration in — the
    /// element the recommendation-tips graft rewrites.
    package static let workbenchConfigurationMetaID = "vscode-workbench-web-configuration"

    /// The slopcat mark (docs/brand/logo-slopcat.svg) with the brand file's `currentColor`
    /// resolved to the theme's tertiary ink and the stock letterpress's `opacity=".3"` baked onto
    /// the root — a standalone SVG document in a data URI resolves `currentColor` to black, so
    /// the colour must be literal here.
    package static let slopcatLetterpressSVG = """
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
    /// the Slate ladder verbatim: the tab plate 10 (`islandRadiusCompact`), control 6
    /// (`radiusControl`), card 8 (`radiusCard`), small 4 (`radiusSmall`); the 4px tab inset rides
    /// the 4pt grid (`space1`).
    /// ⚠️ The tab plate reads `islandRadiusCompact`, NOT `radiusTab` (user-directed 2026-08-09 —
    /// 6 read as too tight for a plate this size). It is the same chip the app cuts for a selected
    /// sidebar row, so it takes the same corner; list ROWS stay on 6, because 10 on a 22px row is
    /// close enough to a capsule to lose the rectangle the tree reads by.
    ///
    ///   • TABS are cut like BROWSER TABS (user-directed 2026-08-09, replacing the free-floating
    ///     plate): inset 4px off the strip's top and left but flush with its BOTTOM, and rounded on
    ///     the top two corners only, so the open tab opens into the canvas underneath it. Nothing
    ///     here says WHICH tab is open by weight: the open tab is outlined on three sides and open
    ///     on the fourth, a notch cut into the canvas. It is the ONLY line this sheet draws, and it
    ///     sets no colour — it reads `var(--vscode-editorGroup-border)`, which the host seed fills.
    ///     The per-tab 1px dividers are dropped.
    ///     The shrunk height comes from re-scoping `--editor-group-tab-height` on the tab (see the
    ///     first CSS comment), so the stock label/icon metrics keyed on that var track it for
    ///     free; the active-tab underline containers (`.tab-border-top/bottom-container`, absolute
    ///     at the plate's edges) go entirely — a Slate plate carries selection by its background
    ///     fill, never an underline. The label's fade-out overlay goes too (it is square-cornered
    ///     and opaque, so it stood proud of the plate's corner); the label ellipsizes instead.
    ///   • Lists/trees (explorer rows, palette rows): the selection/hover fill rounds to 6.
    ///   • Scrollbar sliders round to 5 (half their 10px width — a capsule, not a bar).
    ///   • Inputs step from the stock 4 up to the control rung 6; menus/hovers/find ride the card
    ///     rung 8 (the widgets the workbench ALREADY tokenized — quick input, suggest — sit on
    ///     their own vars and are left alone).
    package static let slateSofteningCSS = """
    /* The plate height is made by RE-SCOPING the workbench's own `--editor-group-tab-height` on
       the tab, not by overriding stock rules one at a time: every stock rule keyed on the var —
       the tab's height, the label's line-height, and both tab-icon forms' heights
       (`.monaco-icon-label::before` for font glyphs, `.monaco-icon-label-iconpath` for SVG
       icons, each pinned to the FULL var by the stock sheet; a per-rule shrink here once left
       the SVG form centering on the 35px box, 4px below the label's line) — derives the shrunk
       value by itself. The strip and everything outside `.tab` still see the full var. The
       derived value must be CAPTURED on an ancestor first: `--x: calc(var(--x) - 4px)` on the
       tab itself is a cyclic custom-property reference, which invalidates the property. */
    .monaco-workbench .part.editor > .content .editor-group-container > .title {
        --slate-tab-plate: calc(var(--editor-group-tab-height) - 4px);
    }
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab {
        --editor-group-tab-height: var(--slate-tab-plate);
        margin: 4px 0 0 4px;
        border-radius: 10px 10px 0 0;
        border-right: none !important;
        border-left: none !important;
    }
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab:last-child {
        margin-right: 4px;
    }
    /* The strip's baseline and the notch in it. The line runs along the FOOT of the tab row and of
       the action icons beside it, painted as a background-image so the tabs — which are opaque and
       flush with that foot — sit on top of it; a closed tab then redraws it across its own foot,
       and the open one turns it up and over its top corners instead. The break under the open tab
       is what says "this one opens into the canvas". Colour comes from the workbench's own
       `editorGroup.border` var (the host seed sets it): this sheet stays free of colour literals,
       which is what keeps it from drifting when the theme moves.
       ⚠️ The doubled seam reported here on 2026-08-09 was NOT this line. It was the client's own
       rule under the panel tab row, a few pixels above it (`CodePanelSurfaces`); that one is the
       one that went. */
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container,
    .monaco-workbench .part.editor > .content .editor-group-container > .title .editor-actions {
        background-image: linear-gradient(to top, var(--vscode-editorGroup-border) 1px, transparent 1px);
        background-repeat: no-repeat;
        background-position: bottom;
    }
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab {
        box-shadow: inset 0 -1px 0 0 var(--vscode-editorGroup-border);
    }
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab.active {
        box-shadow:
            inset 1px 0 0 0 var(--vscode-editorGroup-border),
            inset -1px 0 0 0 var(--vscode-editorGroup-border),
            inset 0 1px 0 0 var(--vscode-editorGroup-border);
    }
    /* ⚠️⚠️ THE PANEL'S LEADING EDGE CARRIES NO VERTICAL LINE — settled, in any hand, after three
       rounds on 2026-08-09 (all three user-rejected):
         1. a FULL-HEIGHT rail on the parts, from this sheet — clutter beside the tab outline;
         2. a native chrome rule drawn by the client column (`Slate.Line.panelEdge`) — the wrong
            hand: a second mark in chrome ink beside the workbench's own baseline;
         3. the workbench's own line, `inset 1px 0 0 0 var(--vscode-editorGroup-border)` on the
            EDITOR CONTAINER — geometrically exactly what was asked for (measured live: the
            container's box starts at the title's foot, y=65 under a 35px strip at y=30, and ends
            at the status bar, so it ran from the open tab's foot down and never up beside the
            tabs) and still not wanted. The panel stands on the ground with nothing marking where
            it begins, which is the same way every other column stands on it.
       Do not propose a fourth. Two measurements are worth keeping if this is ever reopened: an
       inset `box-shadow` on a PART renders NOTHING (children carry their own opaque background and
       paint over the parent's shadow — every sampled pixel down the left edge and the
       editor/sidebar seam came back ground cream), whereas the same shadow on `.editor-container`
       DOES show through Monaco at every sampled row. So the container is the mount that works, and
       an overlay pseudo-element is only needed on the parts. */
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab > .tab-border-top-container,
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container > .tab > .tab-border-bottom-container {
        display: none !important;
    }
    /* The label's fade-out overlay goes entirely, and the label truncates with a real ellipsis
       instead. The overlay is `right: 0; top: 1px; bottom: 1px` with SQUARE corners, and the
       workbench fills it at runtime with `linear-gradient(to left, flatten(tab background),
       transparent)` — an OPAQUE approximation. Against a translucent plate that colour never
       matches, and having no radius of its own it kept standing straight where the plate's corner
       curved away, leaving a 1px square ear at the top-right and bottom-right. Stock `sizing-fit`
       never carried the class; pinning tabs to a fixed width is what turned it on. This is the
       same pair of rules the workbench's own modern-UI mode applies. */
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container
        > .tab.sizing-fixed > .tab-label > .monaco-icon-label-container::after,
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container
        > .tab.sizing-shrink > .tab-label > .monaco-icon-label-container::after {
        display: none !important;
    }
    .monaco-workbench .part.editor > .content .editor-group-container > .title .tabs-container
        > .tab.sizing-fixed > .tab-label > .monaco-icon-label-container {
        flex: 1 !important;
        min-width: 0;
        text-overflow: ellipsis !important;
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

    /// The injected sheet. Each font URL is a `slopdesk-font:` address the pool's scheme handler
    /// answers (``CodeSidebarFontScheme``); `nil` means the bundle has no such resource, and the
    /// sheet then simply omits that face — the softening and the letterpress are independent jobs
    /// and still ship.
    package static func styleSheet(
        nerdFontURL: String?,
        monoUprightURL: String? = nil,
        monoItalicURL: String? = nil,
    ) -> String {
        var sheet = ""
        if let monoUprightURL {
            sheet += fontFace(
                family: monoFontFamilyName, source: monoUprightURL,
                descriptors: "font-style: normal;\n    font-weight: 100 800;",
            )
        }
        if let monoItalicURL {
            sheet += fontFace(
                family: monoFontFamilyName, source: monoItalicURL,
                descriptors: "font-style: italic;\n    font-weight: 100 800;",
            )
        }
        if let nerdFontURL {
            sheet += fontFace(family: nerdFontFamilyName, source: nerdFontURL, descriptors: nil)
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
    private static func fontFace(family: String, source: String, descriptors: String?) -> String {
        """
        @font-face {
            font-family: "\(family)";
            src: url("\(source)") format("truetype");
            \(descriptors.map { "\($0)\n    " } ?? "")font-display: block;
        }

        """
    }

    /// The `WKUserScript` source: append the sheet once per document (`atDocumentEnd`, so `head`
    /// exists; the id guard makes a re-run — e.g. a soft SPA navigation — a no-op).
    package static func userScript(styleSheet: String) -> String {
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
    package static func recommendationTipsScript(tipsJSON: String = CodeSidebarRecommendationTips.json) -> String {
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
    /// Re-check `document.hasFocus()` (the engine's truth — it never went true) and dispatch the
    /// missing blur: across the boot window on a timer, and then on every `focusin` for the rest of
    /// the page's life. The boot timers alone were not enough — the workbench re-focuses its editor
    /// long after boot (a remount, a layout change, a file opening), and each of those pulls put the
    /// caret back beside the terminal's with the timers long expired (user-reported 2026-08-10). The
    /// listener runs the check a beat late so a click that legitimately hands the panel the keyboard
    /// has settled its native focus first, and it costs nothing when the page really is focused.
    /// Synthetic EVENTS only — never `blur()` itself, which
    /// would clear `document.activeElement` and break the real focus hand-off (WebKit re-fires
    /// `focus` on the preserved element when the view actually takes the keyboard, and that is
    /// what puts the caret back).
    package static func focusTruthScript() -> String {
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
            window.\(focusTruthSyncName) = sync;
            document.addEventListener("focusin", function () { setTimeout(sync, 60); }, true);
            [1500, 4000, 9000, 20000].forEach(function (ms) { setTimeout(sync, ms); });
        })();
        """
    }

    /// The page hook ``focusTruthScript()`` publishes, so the NATIVE side can replay the blur at the
    /// moments the page cannot see: a resign, and a remount whose keyboard stays with the terminal
    /// (WebKit delivers no blur to a view that lost first responder by being unparented). See
    /// ``CodeSidebarWKWebView/syncFocusTruth()``.
    package static let focusTruthSyncName = "__slopdeskSyncFocusTruth"

    /// ``focusTruthSyncName`` as a call that is inert on a page which has not run the script yet.
    package static let focusTruthSyncCall = "window.\(focusTruthSyncName) && window.\(focusTruthSyncName)();"

    /// The webview-canvas `WKUserScript` source (document START — the first paint must already
    /// have the colour — and ALL frames: the markdown preview lives two iframes deep). Gives
    /// every document an opaque root canvas in the workbench's own editor colour, so a
    /// frame-level scroll exposes theme-coloured slivers instead of WebKit's white.
    ///
    /// The rule is UNLAYERED on purpose: the webview host's `_defaultStyles` sets
    /// `body { background-color: transparent }` inside `@layer vscode-default`, and any
    /// unlayered rule outranks a layered one. The var reference stays live — the host posts the
    /// theme AFTER document load (and re-posts on every theme flip), and the computed canvas
    /// follows; a frame without VS Code vars falls back to transparent, changing nothing there.
    package static func webviewCanvasScript() -> String {
        """
        (function () {
            if (document.getElementById("\(canvasStyleElementID)")) { return; }
            var root = document.head || document.documentElement;
            if (!root) { return; }
            var style = document.createElement("style");
            style.id = "\(canvasStyleElementID)";
            style.textContent = "html { background-color: var(--vscode-editor-background, transparent); }";
            root.appendChild(style);
        })();
        """
    }

    /// The clipboard-bridge `WKUserScript` source (document START, so the wrap is in place before
    /// the workbench captures the API). Wraps `navigator.clipboard.writeText` / `.write` to ALSO
    /// post the plain text to the native `clipboardHandlerName` handler; the original call still
    /// runs as best effort with its rejection swallowed (the native write already succeeded — a
    /// surfaced rejection would make VS Code toast a copy error that is not true here).
    package static func clipboardBridgeScript() -> String {
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
    package static func javaScriptStringLiteral(_ string: String) -> String {
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
