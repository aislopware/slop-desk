// CodeSidebarFontSchemeHandler — the WebKit half of `CodeSidebarFontScheme`. Kept apart from the
// pure half so the scheme's shape (URLs, headers, face table) stays reachable from tests and from
// the iOS slice, while this file — which imports WebKit and is unreachable from any unit test —
// carries only the WKURLSchemeHandler conformance.

#if os(macOS)
import Foundation
import WebKit

/// Answers `slopdesk-font:` requests with the bundled face. Stateless: one instance serves every
/// pooled configuration.
///
/// Validate-then-drop, as everywhere else the app answers something it did not originate: a URL
/// naming no known face, or a face whose bundle resource is missing, fails the load rather than
/// answering with an empty body — an empty `@font-face` source makes WebKit render the fallback
/// silently, which is far harder to notice than a face that simply did not arrive.
package final class CodeSidebarFontSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Where a face's bytes come from. A seam only so the failure path is expressible; production
    /// memory-maps the app bundle (`.mappedIfSafe` — the nerd symbols file alone is ~2.4 MB, and
    /// the scheme handler is called on the main queue).
    private let load: @MainActor (CodeSidebarFontScheme.Face) -> Data?

    package init(
        load: @escaping @MainActor (CodeSidebarFontScheme.Face) -> Data? =
            CodeSidebarFontSchemeHandler.mappedBundleFile,
    ) {
        self.load = load
        super.init()
    }

    package static func mappedBundleFile(_ face: CodeSidebarFontScheme.Face) -> Data? {
        guard let url = CodeSidebarFontScheme.bundledURL(for: face) else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    package func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url
        guard let face = CodeSidebarFontScheme.face(forRequest: url),
              let data = load(face),
              let url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: CodeSidebarFontScheme.responseHeaders(byteCount: data.count),
              )
        else {
            task.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// The page went away mid-load. Nothing to unwind — the response is delivered synchronously in
    /// `start`, so by the time a stop could arrive the task has already finished.
    package func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}
}
#endif
