#!/usr/bin/env swift
// capture-mouse-probe.swift — Isolation diagnostic for the THREE-FINGER-DRAG
// drag-select ("bôi đen") bug in Rwork's remote-mouse path.
//
// WHY: over Rwork a single click lands correctly (right coordinates), but a
// THREE-FINGER drag-select does nothing. The whole drag path depends on the CLIENT
// forwarding a clean  mouseDown → mouseDragged…N → mouseUp : the host turns the
// in-between moves into `.leftMouseDragged` ONLY while it believes a button is held
// (`heldButton`, set when the client's mouseDown is injected). So the first question
// to answer — with ZERO network / host / NetBird — is what NSEvent stream a
// three-finger drag actually produces on THIS Mac's trackpad. This probe captures it.
//
// HOW TO RUN (on the CLIENT = macbook-pro, from a REAL GUI login session, in Terminal):
//   swift scripts/capture-mouse-probe.swift
// A small window appears and grabs focus. With it focused, do these IN ORDER — each
// event prints a line to the terminal as you go:
//   1. ONE single click on the window        (baseline: expect mouseDown[count=1] → mouseUp)
//   2. (if you can) press-hold-MOVE-release with ONE finger  (a true one-finger click-drag)
//   3. your THREE-FINGER drag-select gesture across the window  (the failing case)
//   4. a RIGHT click                          (baseline for right button)
// Then press Cmd-Q to quit. Paste me everything the terminal printed.
//
// HOW I READ IT:
//   • 3-finger drag prints  mouseDown → mouseDragged×N → mouseUp   ⇒ client is FINE;
//     the bug is the host-side heldButton race in RworkVideoHostSession.inject — fix host.
//   • 3-finger drag prints  mouseDragged / mouseMoved with NO preceding mouseDown
//     (or never a mouseUp)  ⇒ the client must synthesise the down / send drag explicitly.
//   • clickCount==0 on the down is itself a useful tell (host does max(1,count) already).
//
// If NOTHING prints when you interact: System Settings ▸ Privacy & Security ▸
// Accessibility / Input Monitoring is NOT needed (this is the app's own window), but the
// window must be FOCUSED — click its title bar once.

import AppKit

final class ProbeView: NSView {
    private var t0: TimeInterval = 0
    override var acceptsFirstResponder: Bool { true }

    private func log(_ kind: String, _ e: NSEvent) {
        if t0 == 0 { t0 = e.timestamp }
        let dt = Int((e.timestamp - t0) * 1000)
        let p = convert(e.locationInWindow, from: nil)
        // Y flipped to top-left origin to match how Rwork forwards points.
        let y = Int((bounds.height - p.y).rounded())
        let padded = kind.padding(toLength: 18, withPad: " ", startingAt: 0)
        let line = "+\(String(format: "%5d", dt))ms  \(padded) btn=\(e.buttonNumber) count=\(e.clickCount)  (\(Int(p.x.rounded())),\(y))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    override func mouseDown(with e: NSEvent)         { log("mouseDown", e) }
    override func mouseDragged(with e: NSEvent)      { log("mouseDragged", e) }
    override func mouseUp(with e: NSEvent)           { log("mouseUp", e) }
    override func mouseMoved(with e: NSEvent)        { log("mouseMoved", e) }
    override func rightMouseDown(with e: NSEvent)    { log("rightMouseDown", e) }
    override func rightMouseDragged(with e: NSEvent) { log("rightMouseDragged", e) }
    override func rightMouseUp(with e: NSEvent)      { log("rightMouseUp", e) }
    override func otherMouseDown(with e: NSEvent)    { log("otherMouseDown", e) }
    override func otherMouseDragged(with e: NSEvent) { log("otherMouseDragged", e) }
    override func otherMouseUp(with e: NSEvent)      { log("otherMouseUp", e) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        dirtyRect.fill()
        let s = "Drag-select here.\n1) single click  2) 1-finger drag  3) THREE-finger drag  4) right-click\nThen ⌘Q. Watch the terminal."
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        s.draw(in: bounds.insetBy(dx: 16, dy: 16), withAttributes: attrs)
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

let win = NSWindow(
    contentRect: NSRect(x: 240, y: 240, width: 560, height: 380),
    styleMask: [.titled, .closable, .miniaturizable],
    backing: .buffered, defer: false)
win.title = "Rwork mouse probe — click, 1-finger drag, 3-finger drag, then ⌘Q"
win.acceptsMouseMovedEvents = true
let view = ProbeView(frame: win.contentView!.bounds)
view.autoresizingMask = [.width, .height]
win.contentView!.addSubview(view)
win.makeFirstResponder(view)
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

FileHandle.standardError.write(Data("capture-mouse-probe: window is up — focus it, do the gestures, ⌘Q to quit.\n".utf8))
app.run()
