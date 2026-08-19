import AppKit

/// `SLOPDESK_FOCUS_DEBUG=1` — logs every `NSWindow.makeFirstResponder(_:)` (caller stack, target,
/// outcome, and the responder that actually ended up first) to stderr. Inert without the flag.
///
/// The keyboard-focus saga (terminal ⇄ embedded workbench ⇄ overlays) keeps producing "who moved
/// the keyboard?" questions that no state flag can answer after the fact: the mover is AppKit,
/// WebKit, or SwiftUI internals, and the interesting event is over by the time anything
/// observable has changed. This is the tap that answers them at the moment it happens.
@MainActor
enum FocusDebugProbe {
    private static var installed = false

    static func installIfRequested(
        env: [String: String] = ProcessInfo.processInfo.environment,
    ) {
        guard env["SLOPDESK_FOCUS_DEBUG"] == "1", !installed else { return }
        installed = true
        let selector = #selector(NSWindow.makeFirstResponder(_:))
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        typealias MakeFirstResponderFn = @convention(c) (NSWindow, Selector, NSResponder?) -> Bool
        let originalIMP = method_getImplementation(method)
        let original = unsafeBitCast(originalIMP, to: MakeFirstResponderFn.self)
        let block: @convention(block) (NSWindow, NSResponder?) -> Bool = { window, responder in
            let outcome = original(window, selector, responder)
            let target = responder.map { String(describing: type(of: $0)) } ?? "nil"
            let landed = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let stack = Thread.callStackSymbols.dropFirst().prefix(10).joined(separator: "\n    ")
            FileHandle.standardError.write(Data(
                "[focus] makeFirstResponder(\(target)) -> \(outcome), now: \(landed)\n    \(stack)\n"
                    .utf8,
            ))
            return outcome
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
