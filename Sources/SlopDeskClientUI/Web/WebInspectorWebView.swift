// WebInspectorWebView — the Web surface's web view: Chrome's OWN DevTools frontend, loaded from the
// host's browser through the client's loopback relay.
//
// Nothing of DevTools is vendored here. The browser serves the whole frontend from its debugging
// port, so what the panel renders is always the build that matches the protocol behind it — the
// reason this route was taken over WebKit's own inspector, which an embedding app has no supported
// way to open (and whose private path is macOS-only, while a SlopDesk client must also run on iPad).
//
// ONE pooled web view, not one per target. Switching tabs re-points the SAME instance: minting a new
// one per page would pay the frontend's boot every time, and the pooled instance is also what
// survives the panel being collapsed or another tab being selected.
//
// HANG-SAFETY: nothing in the unit-test dependency closure may construct a WKWebView — the pool is
// `macOS`-gated and reached only from the mounted surface. The pure parts (URL building, address
// normalisation) live in `WebSidebarModel`.

#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// The frontend's first-paint veil, the same device the workbench uses: WebKit paints its default
/// white between the provisional commit and the page's first paint, and DevTools takes long enough
/// to boot that the flash is plainly visible against the dark panel.
@MainActor
@Observable
final class WebInspectorLoadState {
    private(set) var veiled = true
    func navigationStarted() { veiled = true }
    func navigationSettled() { veiled = false }
}

/// The retained `WKNavigationDelegate` driving the veil (`navigationDelegate` is weak). Failures
/// settle too — a dead endpoint must surface WebKit's error page, never an eternal spinner.
@MainActor
private final class WebInspectorNavigationObserver: NSObject, WKNavigationDelegate {
    let state: WebInspectorLoadState

    init(state: WebInspectorLoadState) {
        self.state = state
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation?) {
        state.navigationStarted()
    }

    func webView(_: WKWebView, didFinish _: WKNavigation?) {
        state.navigationSettled()
    }

    func webView(_: WKWebView, didFail _: WKNavigation?, withError _: Error) {
        state.navigationSettled()
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError _: Error) {
        state.navigationSettled()
    }
}

/// The single pooled frontend web view. `@MainActor` (WKWebView is main-thread only).
@MainActor
final class WebInspectorWebViewPool {
    static let shared = WebInspectorWebViewPool()

    let loadState = WebInspectorLoadState()
    private var webView: WKWebView?
    private var navigationObserver: WebInspectorNavigationObserver?

    /// The web view, pointed at `url`. Re-loads only when the address actually moved — a re-render
    /// with the same target must not restart the frontend and throw away the user's open panel,
    /// their breakpoints and their console history.
    func webView(url: URL) -> WKWebView {
        if let existing = webView {
            if existing.url != url { existing.load(URLRequest(url: url)) }
            return existing
        }
        let configuration = WKWebViewConfiguration()
        // DevTools' own audio/video previews (a page's media in the network panel) must not stall
        // behind a user-gesture gate the panel can never satisfy.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.themeSeedSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.hoverCursorSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        ))
        let created = WKWebView(frame: .zero, configuration: configuration)
        // Right-click → Inspect Element on the FRONTEND itself — the only window into a DevTools
        // build that misbehaves, exactly as the workbench keeps one.
        created.isInspectable = true
        created.underPageBackgroundColor = NSColor(webSlateBackdropHex: Slate.theme.terminalBackgroundHex)
        // WebKit's base canvas is white until first paint; there is no public API for it, and the
        // long-standing KVC key lets the dark panel show through instead.
        created.setValue(false, forKey: "drawsBackground")
        let observer = WebInspectorNavigationObserver(state: loadState)
        navigationObserver = observer
        created.navigationDelegate = observer
        created.load(URLRequest(url: url))
        webView = created
        return created
    }

    /// Reload the frontend (the strip's reload plate). The PAGE is untouched — reloading what the
    /// user is inspecting is a different verb, and one they can reach from inside DevTools.
    func reload() {
        webView?.reload()
    }

    /// The screencast column's size, measured out of the frontend's own layout.
    ///
    /// It is asked of the frontend rather than computed from the panel's geometry because the split
    /// between the page and DevTools' panels is DevTools' to decide — it has a minimum of its own,
    /// it remembers where the user dragged the divider, and both move without the panel resizing.
    /// The answer feeds ``WebViewportFit``.
    ///
    /// `nil` while the frontend is still booting, which is not an error: the fit loop asks again.
    func screencastColumn() async -> CGSize? {
        guard let webView else { return nil }
        let value = try? await webView.evaluateJavaScript(Self.columnMeasureSource)
        guard let box = value as? [String: Any],
              let width = box["w"] as? Double, let height = box["h"] as? Double,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// `.screencast` is the whole left-hand column: DevTools' navigation bar, the device frame it
    /// draws, and the page inside them.
    private static let columnMeasureSource = """
    (function () {
      var element = document.querySelector('.screencast');
      if (!element) { return null; }
      var box = element.getBoundingClientRect();
      return { w: box.width, h: box.height };
    })();
    """

    /// Seeds DevTools' dark theme on the FIRST load only.
    ///
    /// DevTools keeps its settings in the frontend origin's `localStorage`, and the client's relay
    /// gives that origin a stable port — so this survives both a browser respawn and an app
    /// relaunch, and the user's own later choice of theme is never overwritten (the guard is what
    /// makes it a seed rather than a policy). The value is JSON, quotes included: DevTools parses
    /// what it reads back.
    ///
    /// ⚠️ The key is `ui-theme`, KEBAB-case. DevTools renamed its setting keys, and the old
    /// `uiTheme` is still accepted into storage while being read by nobody — so seeding it looks
    /// like it worked (the key is there afterwards) and the frontend still comes up light.
    /// Measured against Chrome 150: `ui-theme` puts `theme-with-dark-background` on the root
    /// element, `uiTheme` does nothing (`docs/49`).
    nonisolated static let themeSeedSource = """
    (function () {
      try {
        if (!window.localStorage.getItem('ui-theme')) {
          window.localStorage.setItem('ui-theme', '"dark"');
        }
      } catch (e) {}
    })();
    """

    /// Gives the screencast the cursor the PAGE would be showing.
    ///
    /// DevTools' screencast never does this itself — measured against its module on Chrome 151, the
    /// only `cursor` in it is a static rule for touch mode. So a link, a text run and a resize handle
    /// all look identical under an arrow, which is the one thing that tells you a remote page is
    /// remote.
    ///
    /// It rides the frontend's OWN protocol socket rather than opening one. `window.WebSocket` is
    /// wrapped at document start (before the frontend's modules run, which is what makes the wrap
    /// possible at all), the page-target connection is kept, and commands go out on it with ids far
    /// above anything the frontend mints. Replies to those ids are swallowed before the frontend's
    /// own listener sees them — an id it did not mint is a protocol error to it. The gain is that
    /// there is no second session to keep alive, no second target to follow when the panel switches
    /// pages, and no extra hop through the two relays.
    ///
    /// The PAGE reports what it is under, not the frontend: a script installed in the page records
    /// the element of each `mousemove` — the very events DevTools is already dispatching — and the
    /// frontend reads its computed cursor while the pointer is over the canvas. That way nothing
    /// here has to reproduce the screencast's coordinate mapping, which is DevTools' own and moves
    /// with its zoom and device frame.
    ///
    /// A custom `url(…)` cursor is reduced to the keyword it falls back to: the image belongs to the
    /// page's origin and would be resolved against the frontend's, which loads nothing.
    nonisolated static let hoverCursorSource = """
    (function () {
      var FLOOR = 900000;
      var Native = window.WebSocket;
      var live = null;
      var waiting = {};
      var nextID = FLOOR;

      function Wrapped(url, protocols) {
        var socket = protocols === undefined ? new Native(url) : new Native(url, protocols);
        if (String(url).indexOf('/devtools/page/') !== -1) {
          live = socket;
          socket.addEventListener('message', function (event) {
            var message;
            try { message = JSON.parse(event.data); } catch (e) { return; }
            if (!message || typeof message.id !== 'number' || message.id < FLOOR) { return; }
            event.stopImmediatePropagation();
            var resolve = waiting[message.id];
            if (resolve) { delete waiting[message.id]; resolve(message.result); }
          });
          socket.addEventListener('open', arm);
        }
        return socket;
      }
      Wrapped.prototype = Native.prototype;
      Wrapped.CONNECTING = 0;
      Wrapped.OPEN = 1;
      Wrapped.CLOSING = 2;
      Wrapped.CLOSED = 3;
      window.WebSocket = Wrapped;

      function call(method, params) {
        return new Promise(function (resolve) {
          if (!live || live.readyState !== 1) { resolve(null); return; }
          var id = ++nextID;
          waiting[id] = resolve;
          live.send(JSON.stringify({ id: id, method: method, params: params || {} }));
          setTimeout(function () {
            if (waiting[id]) { delete waiting[id]; resolve(null); }
          }, 4000);
        });
      }

      var RECORDER = "(function () {"
        + " var key = Symbol.for('slopdesk.hover');"
        + " if (window[key]) { return; }"
        + " var slot = { target: null };"
        + " window[key] = slot;"
        + " addEventListener('mousemove', function (e) { slot.target = e.target; }, true);"
        + " })()";
      var READER = "(function () {"
        + " var slot = window[Symbol.for('slopdesk.hover')];"
        + " var target = slot && slot.target;"
        + " if (!target || !target.isConnected) { return ''; }"
        + " return getComputedStyle(target).cursor;"
        + " })()";

      function arm() {
        call('Runtime.evaluate', { expression: RECORDER });
        call('Page.addScriptToEvaluateOnNewDocument', { source: RECORDER });
      }

      var canvas = null;
      var shown = '';
      var timer = null;

      function keyword(value) {
        if (!value) { return 'default'; }
        if (value.indexOf('url(') !== -1 || value.indexOf('image-set(') !== -1) {
          var parts = value.split(',');
          value = parts[parts.length - 1].trim();
        }
        return /^[a-z-]+$/.test(value) ? value : 'default';
      }

      function poll() {
        if (!canvas) { return; }
        call('Runtime.evaluate', { expression: READER, returnByValue: true }).then(function (answer) {
          var value = answer && answer.result ? answer.result.value : '';
          var safe = keyword(value);
          if (canvas && safe !== shown) { shown = safe; canvas.style.cursor = safe; }
          if (canvas) { timer = setTimeout(poll, 90); }
        });
      }

      document.addEventListener('mousemove', function (event) {
        var target = event.target;
        var found = target && target.closest ? target.closest('.screencast canvas') : null;
        if (found === canvas) { return; }
        if (canvas) { canvas.style.cursor = ''; }
        canvas = found;
        shown = '';
        if (timer) { clearTimeout(timer); timer = null; }
        if (canvas) { poll(); }
      }, true);
    })();
    """
}

/// Mounts the pooled frontend inside a container view — a container (not the web view itself)
/// because the pooled `NSView` must survive this representable's teardown, exactly as the
/// workbench's does.
struct WebInspectorWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        let webView = WebInspectorWebViewPool.shared.webView(url: url)
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

private extension NSColor {
    /// Concrete sRGB colour from the theme's 6-hex backdrop string — appearance-stable, for the
    /// reason the workbench's twin records (the SwiftUI-Color→NSColor bridge resolves through the
    /// effective appearance and can read wrong on light themes).
    convenience init(webSlateBackdropHex hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1,
        )
    }
}
#endif
