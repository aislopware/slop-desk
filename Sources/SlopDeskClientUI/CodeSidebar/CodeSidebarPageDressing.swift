// CodeSidebarPageDressing — the client-side finishing coat injected into the embedded workbench
// (a WKUserScript that appends ONE <style> tag). Two jobs the host-side settings seed cannot do:
//
//   • The bundled Symbols Nerd Font as a CSS face. The seeded `editor.fontFamily` falls back to
//     "Symbols Nerd Font" for the private-use glyphs SF Mono lacks (agent marks, powerline
//     segments) — but the webview's WebContent process cannot see fonts the app registers with
//     `CTFontManager` (registration is process-scoped), so the face rides in as an @font-face
//     data URI built from the same TTF the terminal chrome bundles.
//   • The empty-editor letterpress. code-server's stock watermark is ITS logo; the panel is
//     SlopDesk's surface, so the slopcat (docs/brand/logo-slopcat.svg, recoloured to the theme's
//     tertiary ink at the stock watermark's subtlety) replaces it via a background-image override.
//
// Everything here is a PURE string builder (unit-pinned headlessly); the pool wires the product
// into `WKUserContentController` — the only WebKit-touching seam, unreachable from unit tests.

import Foundation

enum CodeSidebarPageDressing {
    /// The CSS family the @font-face declares — the name the seeded `editor.fontFamily`
    /// (`CodeServerManager.seededUserSettings`, host side) references in its fallback stack.
    static let nerdFontFamilyName = "Symbols Nerd Font"

    /// The DOM id of the injected style tag — the script's own re-injection guard keys on it.
    static let styleElementID = "slopdesk-dressing"

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

    /// The injected sheet. `nerdFontBase64` nil (bundle lookup failed) still dresses the
    /// letterpress — the two jobs are independent.
    static func styleSheet(nerdFontBase64: String?) -> String {
        var sheet = ""
        if let nerdFontBase64 {
            sheet += """
            @font-face {
                font-family: "\(nerdFontFamilyName)";
                src: url("data:font/ttf;base64,\(nerdFontBase64)") format("truetype");
                font-display: block;
            }

            """
        }
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
