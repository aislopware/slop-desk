#if os(macOS)
import ApplicationServices
import Foundation

/// Reads the frontmost target's LIVE canGoBack/canGoForward via the Accessibility API, for the
/// `SwipeNavStatusMessage.navFlags` push (doc 20 §9.6): the swipe-nav chip must not promise a
/// navigation the browser cannot perform (Back/Forward greyed out ⇒ ⌘[/⌘] is a no-op).
///
/// Two probe-verified strategies (see DECISIONS, history gate):
/// - **Toolbar pair, preferred**: buttons with `AXIdentifier` `BackButton`/`ForwardButton`
///   (Safari family). This is what the user SEES grey out, so it cannot be stale — Safari's
///   autoenabled MENUS validate lazily and keep reporting a background navigation's old state,
///   which is exactly the dangerous direction (chip hidden while navigation would work).
/// - **Menu key-equivalent pair**: the menu items whose key equivalent is ⌘[ / ⌘] (cmd-only
///   modifiers). Locale-independent and semantically exact — it asks "would the chord we send
///   do anything". Chromium's CommandUpdater keeps these live without any menu opening.
///
/// Any failure — no AX trust, no pair found, element invalidated, timeout — returns nil and
/// the push ships `historyKnown=false`: the client FAILS OPEN to the pre-gate behavior.
///
/// The full scan costs 25–180 ms of blocking AX IPC (cold Chrome); a cached `AXEnabled`
/// re-read costs ~0.05 ms. So the two elements are cached per pid and re-scanned only when
/// the pid changes, a read errors, or — toolbar pairs, whose state is per-WINDOW — the app's
/// focused window is no longer the one the pair was scanned from (see `Pair.window`). EVERY
/// call blocks on out-of-process IPC (0.1 s messaging timeout) — call off the main actor
/// only, and never from unit tests (hang-safety: this is process-external state, same rule
/// as SCStream/VT).
public final class HostNavHistory: @unchecked Sendable {
    private struct Pair {
        var pid: pid_t
        var back: AXUIElement
        var forward: AXUIElement
        /// The window the TOOLBAR pair was scanned from — Back/Forward is per-WINDOW state
        /// there, and a pair from window A keeps reading successfully (live, no AX error)
        /// after focus moves to window B of the same app, silently serving A's history as
        /// B's forever (review-caught). Every read re-checks the app's current focused
        /// window against this and rescans on mismatch. nil = menu strategy, which is
        /// app-global and focus-following by construction (Chromium's CommandUpdater
        /// retargets the ⌘[/⌘] items to the active window).
        var window: AXUIElement?
    }

    private let lock = NSLock()
    private var cached: Pair?
    /// One failed scan per pid per beat would hammer a pair-less app (e.g. a browser with no
    /// windows) with 25 ms+ walks every 250 ms tick — remember the last pid that scanned empty
    /// and let the ~2 s heartbeat (`rescanUnknown`) retry it instead.
    private var emptyScanPID: pid_t?

    public init() {}

    /// The current Back/Forward availability for `pid`, or nil when unknown (fail open).
    /// `rescanUnknown` lets the slow heartbeat retry a pid whose last scan found no pair
    /// (app was mid-launch, window not up yet) while the fast change-poll skips it.
    public func read(pid: pid_t, rescanUnknown: Bool) -> NavHistoryFlags? {
        lock.lock()
        let pair = cached?.pid == pid ? cached : nil
        let knownEmpty = emptyScanPID == pid
        lock.unlock()
        if let pair {
            if pairIsCurrent(pair), let flags = readEnabled(pair) { return flags }
            // Focus moved to another window (toolbar pairs are per-window) or the element
            // went stale (window closed, app relaunched its UI) — drop + rescan once.
            store(pair: nil, emptyPID: nil)
            return scanAndRead(pid: pid)
        }
        if knownEmpty, !rescanUnknown { return nil }
        return scanAndRead(pid: pid)
    }

    /// A menu pair is always current (see `Pair.window`); a toolbar pair only while its
    /// window is STILL the one that would receive the chord. `CFEqual` compares AXUIElements
    /// by (pid, accessibility object), so the same window re-fetched compares equal. A failed
    /// focused-window read fails the check — the rescan then lands on whatever is true now,
    /// or collapses to UNKNOWN.
    private func pairIsCurrent(_ pair: Pair) -> Bool {
        guard let window = pair.window else { return true }
        let appEl = AXUIElementCreateApplication(pair.pid)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        guard let focused = focusedOrFirstWindow(appEl: appEl) else { return false }
        return CFEqual(window, focused)
    }

    /// The window the ⌘[/⌘] chord would land in: the app's focused window, else its first
    /// (mirrors the scan so the currency check compares like with like).
    private func focusedOrFirstWindow(appEl: AXUIElement) -> AXUIElement? {
        axElement(attr(appEl, kAXFocusedWindowAttribute))
            ?? (attr(appEl, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    private func store(pair: Pair?, emptyPID: pid_t?) {
        lock.lock()
        cached = pair
        emptyScanPID = emptyPID
        lock.unlock()
    }

    private func scanAndRead(pid: pid_t) -> NavHistoryFlags? {
        let appEl = AXUIElementCreateApplication(pid)
        // Cap each blocking AX IPC so a hung target fails fast instead of the ~6 s framework
        // default — a missed read just means one UNKNOWN (fail-open) push.
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        guard let pair = findToolbarPair(appEl: appEl, pid: pid) ?? findMenuPair(appEl: appEl, pid: pid)
        else {
            store(pair: nil, emptyPID: pid)
            return nil
        }
        store(pair: pair, emptyPID: nil)
        return readEnabled(pair)
    }

    /// Both directions must read cleanly or the whole result is UNKNOWN — half a truth could
    /// dark the wrong edge.
    private func readEnabled(_ pair: Pair) -> NavHistoryFlags? {
        guard let back = enabled(pair.back), let forward = enabled(pair.forward) else { return nil }
        return NavHistoryFlags(canGoBack: back, canGoForward: forward)
    }

    private func enabled(_ el: AXUIElement) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? Bool
    }

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success else { return nil }
        return ref
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// `as?` on a CF type is compile-time-only (always "succeeds") — gate on the actual type id.
    private func axElement(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (ref as! AXUIElement)
    }

    // MARK: Toolbar strategy

    /// The stable identifiers Safari (and WebKit-family shells) put on the visible history
    /// buttons — matched exactly, never by localized description.
    private static let backIdentifiers: Set<String> = ["BackButton"]
    private static let forwardIdentifiers: Set<String> = ["ForwardButton"]

    private func findToolbarPair(appEl: AXUIElement, pid: pid_t) -> Pair? {
        guard let win = focusedOrFirstWindow(appEl: appEl) else { return nil }
        var back: AXUIElement?
        var forward: AXUIElement?
        // Bounded walk: the chrome (toolbars) sits shallow (probed d4 Safari / d7 Chrome);
        // AXWebArea is the page's own huge subtree and can never contain the app's buttons.
        var budget = 800
        func walk(_ el: AXUIElement, depth: Int) {
            if depth > 8 || budget <= 0 || (back != nil && forward != nil) { return }
            budget -= 1
            let role = attr(el, kAXRoleAttribute) as? String
            if role == "AXWebArea" { return }
            if role == kAXButtonRole as String, let ident = attr(el, "AXIdentifier") as? String {
                if Self.backIdentifiers.contains(ident) { back = el }
                if Self.forwardIdentifiers.contains(ident) { forward = el }
            }
            for child in children(el) { walk(child, depth: depth + 1) }
        }
        walk(win, depth: 0)
        guard let back, let forward else { return nil }
        return Pair(pid: pid, back: back, forward: forward, window: win)
    }

    // MARK: Menu strategy

    /// `kAXMenuItemCmdModifiersAttribute` value for a bare-⌘ key equivalent.
    private static let cmdOnlyModifiers = 0

    private func findMenuPair(appEl: AXUIElement, pid: pid_t) -> Pair? {
        guard let bar = axElement(attr(appEl, kAXMenuBarAttribute)) else { return nil }
        var back: AXUIElement?
        var forward: AXUIElement?
        for topItem in children(bar) {
            for menu in children(topItem) {
                // Depth 1 = the menu's items; one submenu level for apps that nest history.
                func scan(_ items: [AXUIElement], depth: Int) {
                    for item in items {
                        if back != nil, forward != nil { return }
                        if let cmd = attr(item, kAXMenuItemCmdCharAttribute) as? String,
                           cmd == "[" || cmd == "]",
                           (attr(item, kAXMenuItemCmdModifiersAttribute) as? Int) == Self.cmdOnlyModifiers
                        {
                            if cmd == "[", back == nil { back = item }
                            if cmd == "]", forward == nil { forward = item }
                        }
                        if depth < 1 {
                            for sub in children(item) { scan(children(sub), depth: depth + 1) }
                        }
                    }
                }
                scan(children(menu), depth: 0)
            }
        }
        guard let back, let forward else { return nil }
        return Pair(pid: pid, back: back, forward: forward, window: nil)
    }
}
#endif
