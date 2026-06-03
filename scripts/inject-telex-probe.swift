#!/usr/bin/env swift
// inject-telex-probe.swift — Isolation diagnostic for the xkey (xmannv/xkey) Telex
// composition bug in Rwork's remote-keyboard path.
//
// WHY: Rwork forwards layout-level KEYCODES to the host and posts them as synthetic
// CGEvents, expecting the host's xkey IME to compose Vietnamese Telex server-side
// (the "scancode mode" Parsec/VNC/Screen-Sharing use). On hardware a single double
// ("dd"->"đ") composes but a full word miscomposes (e.g. injecting "ddaa" yields
// "daâ", not "đâ"). xkey's source shows it re-injects corrections (backspace + composed
// char) ASYNCHRONOUSLY and keys all process/skip decisions off kCGEventSourceUserData
// (sentinels 0x584B4559 / 0x584B4849), NOT off the source state. So this probe bisects
// the two remaining variables — INTER-KEY TIMING and TAP/SOURCE — with zero network.
//
// HOW TO RUN (on the HOST = macstudio, from a REAL GUI session, NOT over ssh):
//   1. Open a BLANK TextEdit document (leave it; the probe brings it frontmost itself).
//   2. Turn xkey ON, Telex mode. Verify by hand that typing "dd" -> "đ" works.
//   3. swift scripts/inject-telex-probe.swift sweep
//      It injects "ddaa" (expect "đâ") once per variant, each on its OWN LINE, so the
//      TextEdit document ends up with one line per variant in the order printed to stderr.
//   4. Paste back the TextEdit contents (the N lines). I map line -> variant.
//
// Single-variant form (for follow-up):  swift scripts/inject-telex-probe.swift <variant> [delayMs]
//   variants: rwork | nouser | private | session | postpid   (see makeVariants)
//
// If NOTHING types: System Settings > Privacy & Security > Accessibility -> enable Terminal.

import Foundation
import CoreGraphics
import AppKit

// US-QWERTY virtual keycodes (kVK_ANSI_*).
let KC: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    " ": 49,
]
let KC_RETURN: CGKeyCode = 36

// xkey's self-event sentinels — we must NEVER post these as userData (xkey would skip).
let XKEY_MARKER: Int64 = 0x584B4559   // "XKEY"
let XKEY_HID_SEEN: Int64 = 0x584B4849 // "XKHI"

enum PostMode { case hid, session, pid }

struct Variant {
    let name: String
    let stateID: CGEventSourceStateID?   // nil => CGEvent source = nil
    let setUserData: Bool                 // stamp a nonzero (non-sentinel) tag like Rwork does
    let post: PostMode
    let delayMs: UInt32
}

// The bisection matrix. Each injects "ddaa" expecting "đâ".
func makeVariants() -> [Variant] {
    [
        // current production path, at three paces (timing bisect):
        Variant(name: "rwork@12  (hid + userData, .hidSystemState)",  stateID: .hidSystemState, setUserData: true,  post: .hid,     delayMs: 12),
        Variant(name: "rwork@60",                                      stateID: .hidSystemState, setUserData: true,  post: .hid,     delayMs: 60),
        Variant(name: "rwork@150",                                     stateID: .hidSystemState, setUserData: true,  post: .hid,     delayMs: 150),
        // tap/source bisect at a settled pace (60ms):
        Variant(name: "session@60 (post .cgSessionEventTap)",          stateID: .hidSystemState, setUserData: true,  post: .session, delayMs: 60),
        Variant(name: "private@60 (.privateState source, no userData)",stateID: .privateState,   setUserData: false, post: .hid,     delayMs: 60),
        Variant(name: "nouser@60  (no userData stamp)",                stateID: .hidSystemState, setUserData: false, post: .hid,     delayMs: 60),
    ]
}

let frontPidAtLaunch = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

func makeSource(_ stateID: CGEventSourceStateID?) -> CGEventSource? {
    guard let stateID else { return nil }
    let s = CGEventSource(stateID: stateID)
    s?.localEventsSuppressionInterval = 0
    return s
}

func injectKey(_ code: CGKeyCode, _ v: Variant, source: CGEventSource?, frontPid: pid_t) {
    for down in [true, false] {
        guard let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
        ev.flags = []                       // plain lowercase letter: no modifiers
        if v.setUserData {
            ev.setIntegerValueField(.eventSourceUserData, value: 0x52574B31) // "RWK1" — nonzero, NOT an xkey sentinel
        }
        switch v.post {
        case .hid:     ev.post(tap: .cghidEventTap)
        case .session: ev.post(tap: .cgSessionEventTap)
        case .pid:     if frontPid != 0 { ev.postToPid(frontPid) } else { ev.post(tap: .cghidEventTap) }
        }
        usleep(v.delayMs * 1000)
    }
}

func runVariant(_ v: Variant, word: [Character], appendReturn: Bool) {
    let source = makeSource(v.stateID)
    let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? frontPidAtLaunch
    for ch in word {
        if let code = KC[ch] { injectKey(code, v, source: source, frontPid: frontPid) }
    }
    if appendReturn { injectKey(KC_RETURN, v, source: source, frontPid: frontPid) }
}

func activateTextEdit() -> Bool {
    guard let te = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) else {
        FileHandle.standardError.write(Data("⚠️  TextEdit is not running — open a blank TextEdit document first.\n".utf8))
        return false
    }
    te.activate(options: [.activateAllWindows])
    return true
}

// ---- main ----
let args = CommandLine.arguments
let word: [Character] = ["d", "d", "a", "a"]   // expect "đâ"

let ok = activateTextEdit()
usleep(1_500_000)
let nowFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
FileHandle.standardError.write(Data("inject-telex-probe: frontmost=\(nowFront) (TextEdit focused=\(ok))\n".utf8))

if args.count > 1 && args[1] == "word" {
    // Type an arbitrary Telex phrase using the FIXED production pattern (no userData,
    // .hidSystemState, HID tap, 60ms) — mirrors exactly what the patched host now does.
    // Usage: swift scripts/inject-telex-probe.swift word "tieesng vieejt"  -> expect "tiếng việt"
    let telex = args.count > 2 ? args[2] : "tieesng vieejt"
    let v = Variant(name: "fixed", stateID: .hidSystemState, setUserData: false, post: .hid, delayMs: 60)
    FileHandle.standardError.write(Data("WORD (fixed pattern) — typing telex \"\(telex)\" into TextEdit\n".utf8))
    runVariant(v, word: Array(telex.lowercased()), appendReturn: false)
    FileHandle.standardError.write(Data("done — check TextEdit for the composed Vietnamese.\n".utf8))
} else if args.count > 1 && args[1] == "sweep" {
    let variants = makeVariants()
    FileHandle.standardError.write(Data("SWEEP — injecting \"ddaa\" (expect \"đâ\") once per variant, one TextEdit line each:\n".utf8))
    for (i, v) in variants.enumerated() {
        FileHandle.standardError.write(Data("  line \(i + 1): \(v.name)\n".utf8))
    }
    FileHandle.standardError.write(Data("Starting in 1s…\n".utf8))
    usleep(1_000_000)
    for (i, v) in variants.enumerated() {
        runVariant(v, word: word, appendReturn: i < variants.count - 1) // Return between lines, not after last
        usleep(300_000) // let xkey's async correction settle before the next variant
    }
    FileHandle.standardError.write(Data("done — read the \(variants.count) lines in TextEdit, map to the list above.\n".utf8))
} else {
    let name = args.count > 1 ? args[1] : "rwork"
    let delay = args.count > 2 ? (UInt32(args[2]) ?? 12) : 12
    let stateID: CGEventSourceStateID? = (name == "private") ? .privateState : (name == "nilsrc" ? nil : .hidSystemState)
    let post: PostMode = (name == "session") ? .session : (name == "postpid" ? .pid : .hid)
    let setUD = !(name == "nouser" || name == "private" || name == "nilsrc")
    let v = Variant(name: name, stateID: stateID, setUserData: setUD, post: post, delayMs: delay)
    FileHandle.standardError.write(Data("single variant=\(name) delayMs=\(delay) — injecting \"ddaa\", expect \"đâ\"\n".utf8))
    runVariant(v, word: word, appendReturn: false)
    FileHandle.standardError.write(Data("done — check TextEdit.\n".utf8))
}
