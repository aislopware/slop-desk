// CodeSidebarFontScheme — how the client's own fonts reach the embedded workbench.
//
// The webview's WebContent process cannot see fonts the app registers with `CTFontManager`
// (registration is process-scoped), so the panel has to ship the faces into the page itself. The
// first shape for that was a `data:font/ttf;base64,…` URI per face inside the injected style
// sheet — which meant the dressing user script carried ~4 MB of base64 (3 MB of TTF inflated by a
// third), re-injected and re-parsed on every workbench navigation, per pooled webview.
//
// Now the sheet names three short URLs on a custom scheme and ``CodeSidebarFontSchemeHandler``
// answers them with the bundle's bytes. The script drops to a couple of KB, the fonts are fetched
// as ordinary subresources (memory-mapped from the bundle, never base64), and `immutable` caching
// means a reload does not refetch them.
//
// A CUSTOM scheme, not http: `WKWebViewConfiguration.setURLSchemeHandler` refuses the standard
// schemes outright, and keeping the fonts off the loopback relay is right on the merits — they are
// the CLIENT's resources, nothing the host serves.

import Foundation

/// The scheme, its faces, and the URL shape both ends agree on. Pure — no WebKit, so the iOS
/// slice and the tests both compile it.
enum CodeSidebarFontScheme {
    static let scheme = "slopdesk-font"

    /// The faces the dressing sheet declares. The raw values are the URL slugs.
    enum Face: String, CaseIterable {
        case monoUpright = "mono-upright"
        case monoItalic = "mono-italic"
        case nerdSymbols = "nerd-symbols"
    }

    /// The URL the sheet's `src` names. The `fonts` HOST is load-bearing: a scheme URL with an
    /// empty authority parses as opaque, and the handler would never see a routable path.
    static func url(for face: Face) -> String {
        "\(scheme)://fonts/\(face.rawValue).ttf"
    }

    /// The face a handler request names, or `nil` for anything this app did not mint
    /// (validate-then-drop — the handler answers those with a failure, never with bytes).
    static func face(forRequest url: URL?) -> Face? {
        guard let url, url.scheme == scheme else { return nil }
        let slug = url.lastPathComponent.replacingOccurrences(of: ".ttf", with: "")
        return Face(rawValue: slug)
    }

    /// The bundled file behind a face. `nil` when the resource is missing — the sheet then simply
    /// omits that `@font-face`, exactly as it did when the base64 lookup failed.
    static func bundledURL(for face: Face) -> URL? {
        switch face {
        case .monoUpright: JetBrainsMonoFont.bundledUprightURL
        case .monoItalic: JetBrainsMonoFont.bundledItalicURL
        case .nerdSymbols: NerdSymbolFont.bundledFontURL
        }
    }

    /// The response headers a served face carries.
    ///
    /// On `Access-Control-Allow-Origin`: the workbench document is `http://127.0.0.1:<port>`, so a
    /// font on another scheme is nominally a cross-origin fetch, and CSS font loads are
    /// CORS-anonymous. Measured on this WebKit (2026-08-03, a standalone `WKWebView` probe against
    /// a real http origin): the face loads and `document.fonts.check` passes WITH the header — and
    /// also without it, so WebKit is not enforcing CORS on custom-scheme responses today. The
    /// header stays as the honest answer to the question a future WebKit may start asking; it is
    /// not what makes this work.
    static func responseHeaders(byteCount: Int) -> [String: String] {
        [
            "Content-Type": "font/ttf",
            "Content-Length": String(byteCount),
            "Access-Control-Allow-Origin": "*",
            // The bytes ship inside the app — they cannot change without a relaunch.
            "Cache-Control": "public, max-age=31536000, immutable",
        ]
    }
}
