import Foundation
import SlopDeskProtocol

/// The FUSED host-side output sniffer: ONE pass over the outbound PTY byte stream replacing
/// the back-to-back pair ``HostTitleBellSniffer`` + ``HostCommandStatusSniffer``. It emits
/// inline host→client CONTROL messages:
///
/// - ``WireMessage/title(_:)`` — OSC 0 / OSC 2 (`ESC ] 0;… <terminator>` / `ESC ] 2;…`).
/// - ``WireMessage/bell`` — a standalone ground-state `BEL` (never an OSC/string terminator).
/// - ``WireMessage/commandStatus(_:)`` — OSC 133 `C` (running) / `D[;exit]` (idle, with the
///   host-measured C→D duration in milliseconds via the injectable ``clock``).
/// - ``WireMessage/cwd(_:)`` — OSC 7 `file://host/path`, the shell's current working directory.
///
/// ## Provenance (exact-parity port)
/// Both old sniffers shared an IDENTICAL 8-state transition table; the title sniffer was the
/// strict superset (it also emits `.bell` in ground). ``step(_:into:)`` is that table VERBATIM.
/// The only fusion point is ``finishOSC(into:)``, dispatching on the Ps prefix: `0`/`2` → title
/// (incl. `lastTitle` dedup), `133` → the command sniffer's C/D logic, guarded by an
/// EXACT-PARITY 256-byte cap (``cmdOscCap``) so payloads of 257..4096 bytes stay ignored
/// exactly as the old command sniffer (buffer cap 256) ignored them.
///
/// Cross-type messages are emitted in BYTE order (the old pair emitted all title/bell before
/// all command messages per chunk); per-type subsequences are byte-identical to the old pair.
///
/// ## Non-destructive + streaming-safe (unchanged invariants)
/// ``observe(_:)`` only OBSERVES — the caller forwards the original bytes UNCHANGED. The
/// machine is a true byte-at-a-time state machine: state persists across chunks, so any
/// split (mid-ESC, mid-OSC, mid-terminator) yields identical messages to the whole stream.
/// The OSC payload buffer is capped (``oscCap``); over-cap / string-sequence bodies are
/// swallowed without buffering, so a hostile stream can never wedge the sniffer or make it
/// buffer unboundedly. Stray-ESC re-entry and DCS/SOS/PM/APC swallowing are carried over
/// verbatim (see the old sniffers' doc comments for the full rationale of each).
///
/// ## Fast path (hot read-loop thread)
/// In the three "skim" states — `.ground`, `.oscDiscard`, `.stringConsume` — the ONLY bytes
/// that matter are `ESC` (0x1B) and `BEL` (0x07); every other byte is a no-op (verified
/// against ``step(_:into:)``: ground ignores content, discard/string swallow it; in THIS
/// grammar `BEL` DOES terminate `.stringConsume` too). ``observe(_:)`` therefore `memchr`s
/// for the next interesting byte and routes ONLY that byte through ``step(_:into:)`` — it
/// decides WHICH bytes reach `step()`, never replaces a transition. Other states step per-byte.
///
/// `@unchecked Sendable`: the mutable parser/timing state is guarded by ``lock``. In
/// practice ``observe(_:)`` is only ever called from the single serial `PTYReadLoop` queue
/// (the `onChunk` sink), so calls are already serialized; the lock makes the type safe to
/// capture in the `@Sendable` `onChunk` closure regardless.
public final class HostOutputSniffer: @unchecked Sendable {
    /// - Parameter clock: the wall-clock source for the OSC 133 C→D duration. Injectable so
    ///   a test advances it deterministically; defaults to `Date.init` in production.
    @preconcurrency
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        localHostnames: Set<String> = HostOutputSniffer.defaultLocalHostnames(),
    ) {
        self.clock = clock
        self.localHostnames = localHostnames
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> Date

    /// Lower-cased host identities an OSC 7 `file://<authority>/…` may carry for its path to count as
    /// a LOCAL cwd. Empty authority and `localhost` are always local; the host's own hostname(s) are
    /// added at init. A FOREIGN authority (a shell ssh'd into another box) is DROPPED so it can't
    /// poison cwd inheritance — the same check iTerm2 / Terminal.app / ghostty perform. See
    /// ``osc7Path(from:localHostnames:)``.
    private let localHostnames: Set<String>

    /// The default local identities: `localhost`, the empty authority, and this host machine's own
    /// hostname (both the full form, e.g. `mac-studio.local`, and the leading label, `mac-studio`).
    public static func defaultLocalHostnames() -> Set<String> {
        var names: Set = ["", "localhost"]
        let full = ProcessInfo.processInfo.hostName.lowercased()
        if !full.isEmpty {
            names.insert(full)
            if let first = full.split(separator: ".").first { names.insert(String(first)) }
        }
        return names
    }

    /// When the foreground command started (set on `133;C`, cleared on `133;D`); `nil` idle.
    private var runningSince: Date?

    /// `true` once an idle signal has been emitted for the current prompt cycle (set by `133;D` and the
    /// `133;B` startup-prompt path, reset by `133;C`). Stops `133;B` from emitting a redundant second
    /// `.idle` after `133;D` already advertised the exit code, while still surfacing `133;B` at first
    /// launch (before any command has run, so no `133;D` fired).
    private var idleSentSinceLastC = false

    // MARK: Parser state (verbatim from HostTitleBellSniffer)

    private enum State {
        /// Outside any escape sequence (opaque content). A `BEL` here is a real bell.
        case ground
        /// Saw `ESC` (`0x1B`); waiting for the next byte to classify (`]` → OSC, etc.).
        case escape
        /// Inside an OSC sequence (`ESC ]`). Collecting payload until `BEL` or `ST`.
        case osc
        /// Inside an OSC and the previous byte was `ESC` — waiting to see if it is the
        /// `\` that completes an `ST` terminator (`ESC \`), or a new sequence start.
        case oscEscape
        /// An over-cap OSC is being DISCARDED: still INSIDE the OSC (so its terminator must
        /// be consumed here, not re-parsed as ground), but no longer buffering. Bounded O(n).
        case oscDiscard
        /// Inside a discarded OSC and the previous byte was `ESC` (possible `ST`).
        case oscDiscardEscape
        /// Inside a DCS/SOS/PM/APC string sequence (R9 #4): swallow the body to its ST/BEL terminator,
        /// emitting NOTHING. UNLIKE an OSC, an embedded ESC that is NOT `\` is part of the opaque string
        /// (it does NOT start a new sequence), so this never re-classifies — that is the whole point.
        case stringConsume
        /// Inside a string sequence and the previous byte was `ESC` (possible `ST` = `ESC \`).
        case stringConsumeEscape
    }

    private var state: State = .ground

    /// Accumulated OSC payload bytes (without the leading `ESC ]` or the terminator),
    /// e.g. `0;my title` or `133;D;0`. Bounded by ``oscCap``.
    private var oscBuffer: [UInt8] = []

    /// The last title we emitted, for trivial coalescing (don't spam identical titles).
    private var lastTitle: String?

    /// IN-FLIGHT kitty (OSC 99) notifications keyed by their `i=<id>` group (or `""` when the chunk
    /// omits `i`), accumulated across `d=0` continuation chunks and FINALIZED + emitted at the `d=1`
    /// (default) chunk. Bounded by ``kittyAssemblyMax`` entries / ``kittyAssemblyCap`` chars; an OSC-99
    /// sequence mutates this only at completion (``finishOSC``), exactly like ``lastTitle`` — so the
    /// chunk-invariance oracle (byte-split == whole) still holds.
    private var kittyAssembly: [String: (title: String, body: String)] = [:]

    /// Hard cap on the buffered OSC payload (the TITLE sniffer's cap — the larger of the two).
    /// A real title is tiny; anything longer is abandoned + resynced. Generous enough for long
    /// window titles / paths, small enough to bound a hostile unterminated OSC.
    private static let oscCap = 4096

    /// EXACT-PARITY guard for the 133 path: the old ``HostCommandStatusSniffer`` capped ITS
    /// buffer at 256, so a `133;…` payload of 257..4096 bytes never reached its finishOSC.
    /// The fused machine buffers up to 4096 (the title cap), so ``finishOSC(into:)`` must
    /// re-impose 256 on the 133 branch to keep those payloads ignored byte-for-byte.
    private static let cmdOscCap = 256

    /// Payload cap for the OSC 9 / OSC 777 / OSC 99 notification path: a real notification line is
    /// short; a multi-kilobyte one is not worth surfacing as a desktop alert (and bounds a hostile
    /// stream). Applied per OSC sequence (each chunk), before any parse.
    private static let notifyOscCap = 1024

    /// Bounded number of IN-FLIGHT kitty (OSC 99) notifications being assembled across `d=0`
    /// continuation chunks, keyed by their `i=<id>` group. A hostile stream that opens many distinct
    /// ids with `d=0` can never grow ``kittyAssembly`` past this — a brand-new id over the cap is
    /// DROPPED (validate-then-drop), not buffered.
    private static let kittyAssemblyMax = 8

    /// Bounded TOTAL assembled (title + body) character length for a single in-flight kitty
    /// notification; a `d=0` stream that keeps appending is abandoned once it exceeds this. Each
    /// chunk is already ≤ ``notifyOscCap``; this additionally bounds the cross-chunk accumulation.
    private static let kittyAssemblyCap = 4096

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let rightBracket: UInt8 = 0x5D // ']'
    private static let backslash: UInt8 = 0x5C // '\'
    private static let semicolon: UInt8 = 0x3B // ';'
    // String-sequence introducers (R9 #4): DCS `ESC P`, SOS `ESC X`, PM `ESC ^`, APC `ESC _`. A real
    // terminal swallows their body to the ST/BEL terminator without ringing a bell or changing the title.
    private static let dcs: UInt8 = 0x50 // 'P'
    private static let sos: UInt8 = 0x58 // 'X'
    private static let pm: UInt8 = 0x5E // '^'
    private static let apc: UInt8 = 0x5F // '_'

    // MARK: Observe

    /// Observes a chunk of the OUTBOUND byte stream and returns the CONTROL messages
    /// (`.title` / `.bell` / `.commandStatus`) detected in it, in byte order. **Does not
    /// modify or consume the bytes** — the caller forwards the original chunk unchanged.
    @discardableResult
    public func observe(_ bytes: Data) -> [WireMessage] {
        lock.lock()
        defer { lock.unlock() }
        var messages: [WireMessage] = []
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var i = 0
            while i < count {
                switch state {
                case .ground:
                    // FAST PATH: in ground, only ESC (state change) and BEL (.bell) matter.
                    // Find the next ESC in the remainder…
                    let escPointer = memchr(base + i, Int32(Self.esc), count - i)
                    let escOffset = escPointer.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                    // …then scan for BELs ONLY in the prefix BEFORE that ESC. CRITICAL bound: an
                    // UNBOUNDED BEL memchr over the whole remainder, re-run on every ground re-entry,
                    // degrades to O(n^2) on escape-dense streams (MEASURED at 29 MiB/s — SLOWER than
                    // the per-byte loop it replaces). Bounding to [i, escOffset) keeps total scanned
                    // bytes <= 2x the input (each byte seen by at most one ESC scan + one BEL scan).
                    var j = i
                    while j < escOffset {
                        guard let belPointer = memchr(base + j, Int32(Self.bel), escOffset - j) else { break }
                        let belOffset = base.distance(to: UnsafeRawPointer(belPointer))
                        step(Self.bel, into: &messages) // ground BEL → .bell (state stays ground)
                        j = belOffset + 1
                    }
                    if escOffset < count {
                        step(Self.esc, into: &messages) // ground ESC → .escape
                        i = escOffset + 1
                    } else {
                        i = count
                    }

                case .oscDiscard,
                     .stringConsume:
                    // FAST PATH: in both skim states the ONLY interesting bytes are ESC and
                    // BEL — every other byte is swallowed with no transition. (Verified
                    // against step(): BEL DOES terminate `.stringConsume` in this grammar,
                    // same as `.oscDiscard` — both drop to ground on BEL.) Route only the
                    // FIRST interesting byte through step(); never substitute a transition.
                    let escPointer = memchr(base + i, Int32(Self.esc), count - i)
                    let escOffset = escPointer.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                    // BEL scan bounded to the prefix BEFORE the ESC — same O(n^2) guard
                    // (and 29 MiB/s measurement) as the ground fast path above.
                    if let belPointer = memchr(base + i, Int32(Self.bel), escOffset - i) {
                        let belOffset = base.distance(to: UnsafeRawPointer(belPointer))
                        step(Self.bel, into: &messages) // terminator → ground
                        i = belOffset + 1
                    } else if escOffset < count {
                        step(Self.esc, into: &messages) // → .oscDiscardEscape / .stringConsumeEscape
                        i = escOffset + 1
                    } else {
                        i = count
                    }

                case .escape,
                     .osc,
                     .oscEscape,
                     .oscDiscardEscape,
                     .stringConsumeEscape:
                    // Buffering / classification states: every byte matters — step per-byte.
                    step(base.load(fromByteOffset: i, as: UInt8.self), into: &messages)
                    i += 1
                }
            }
        }
        return messages
    }

    /// Convenience overload for raw byte arrays (used by tests).
    @discardableResult
    public func observe(_ bytes: [UInt8]) -> [WireMessage] {
        observe(Data(bytes))
    }

    // MARK: State machine (verbatim from HostTitleBellSniffer — the strict superset)

    private func step(_ byte: UInt8, into messages: inout [WireMessage]) {
        switch state {
        case .ground:
            switch byte {
            case Self.esc:
                state = .escape
            case Self.bel:
                // A BEL in ground state is a real terminal bell (NOT an OSC terminator).
                messages.append(.bell)
            default:
                break // opaque content byte — ignore.
            }

        case .escape:
            switch byte {
            case Self.rightBracket:
                state = .osc
                oscBuffer.removeAll(keepingCapacity: true)
            case Self.dcs,
                 Self.sos,
                 Self.pm,
                 Self.apc:
                // R9 #4 (security): DCS/SOS/PM/APC introduce a STRING sequence whose body a conformant
                // terminal swallows to its ST/BEL terminator WITHOUT ringing a bell or changing the title.
                // Consume the whole string + terminator, emitting NOTHING — else a malicious remote program
                // could embed a BEL (phantom bell), an `ESC]2;…` (title spoof), or an `ESC]133;C/D`
                // (phantom command status) inside the string body and we'd fabricate control events.
                state = .stringConsume
            case Self.esc:
                // `ESC ESC` — stay in escape, waiting to classify the second ESC.
                state = .escape
            default:
                // Some other escape (CSI `ESC[`, a 2-byte / nF escape like `ESC c`) — not an OSC,
                // untracked, return to ground. A BEL here (`ESC BEL`) is neither a sequence we care
                // about nor a standalone bell — treating it as ground content is fine.
                state = .ground
            }

        case .osc:
            switch byte {
            case Self.bel:
                // BEL terminates the OSC string — emit a title / command status if it is an
                // OSC 0/2/133, and CRUCIALLY do NOT emit a .bell (this BEL is a terminator).
                finishOSC(into: &messages)
                state = .ground
            case Self.esc:
                // Possible start of an `ST` terminator (`ESC \`).
                state = .oscEscape
            default:
                oscBuffer.append(byte)
                if oscBuffer.count > Self.oscCap {
                    // Overlong — abandon WITHOUT emitting. Do NOT drop to `.ground`: we are still
                    // INSIDE the OSC, so its terminator (BEL / ST) hasn't arrived; dropping to ground
                    // would re-parse that terminator BEL as a spurious `.bell` (and misread following
                    // bytes). Switch to `.oscDiscard` to swallow the rest — terminator included —
                    // byte-at-a-time (bounded, no buffering).
                    oscBuffer.removeAll(keepingCapacity: true)
                    state = .oscDiscard
                }
            }

        case .oscDiscard:
            // Discarding an over-cap OSC: consume bytes until its genuine terminator so the
            // terminator can never leak into ground parsing. No buffering → still O(n)/bounded.
            switch byte {
            case Self.bel:
                state = .ground
            case Self.esc:
                state = .oscDiscardEscape
            default:
                break // discarded payload byte
            }

        case .oscDiscardEscape:
            if byte == Self.backslash {
                state = .ground // `ESC \` = ST terminator of the discarded OSC.
            } else {
                // The `ESC` was not an ST terminator — it may introduce a NEW sequence. Re-enter
                // `.escape` and re-classify this byte (mirror the `.oscEscape` stray-ESC fix;
                // there is no payload to finish since the OSC was discarded).
                state = .escape
                step(byte, into: &messages)
            }

        case .stringConsume:
            // R9 #4: swallow a DCS/SOS/PM/APC string body, emitting nothing. The ONLY terminators are
            // ST (`ESC \`) and BEL. CRUCIALLY, unlike the OSC-discard path, an embedded ESC that is not
            // `\` stays INSIDE the string (it does NOT introduce a new sequence), so an `ESC]2;…` or
            // `ESC]133;…` in the body can never spoof a title / command status and an embedded BEL
            // never rings.
            switch byte {
            case Self.bel:
                state = .ground
            case Self.esc:
                state = .stringConsumeEscape
            default:
                break // opaque string-body byte — swallow.
            }

        case .stringConsumeEscape:
            switch byte {
            case Self.backslash:
                state = .ground // `ESC \` = ST terminator.
            case Self.esc:
                state = .stringConsumeEscape // another ESC — could still begin ST; keep waiting.
            default:
                state = .stringConsume // a lone ESC inside the body — swallow it + keep consuming.
            }

        case .oscEscape:
            if byte == Self.backslash {
                // `ESC \` = ST: the OSC is complete.
                finishOSC(into: &messages)
                state = .ground
            } else {
                // The `ESC` was not an ST terminator. Treat the OSC as terminated by the stray ESC,
                // but that consumed ESC may itself introduce a NEW sequence — re-enter `.escape` (NOT
                // `.ground`) and re-classify this byte as its introducer. Dropping to ground would
                // orphan the ESC and let a following sequence's `]` be read as plain content, losing
                // the whole sequence (the prior stray-ESC bug — see the old sniffers).
                finishOSC(into: &messages)
                state = .escape
                step(byte, into: &messages)
            }
        }
    }

    // MARK: OSC handling — fused dispatch: title (0/2) + command status (133) + notifications (9/777/99)

    private func finishOSC(into messages: inout [WireMessage]) {
        defer { oscBuffer.removeAll(keepingCapacity: true) }
        // Split the Ps prefix at the FIRST ';' — the payload after it may itself contain ';'
        // (a title keeps them; the 133 path re-splits the FULL payload below, exactly like
        // the old command sniffer).
        guard let sep = oscBuffer.firstIndex(of: Self.semicolon) else { return }
        let psBytes = oscBuffer[oscBuffer.startIndex..<sep]
        let ps = String(bytes: psBytes, encoding: .utf8) ?? ""

        switch ps {
        case "0",
             "2":
            // Title path — verbatim from HostTitleBellSniffer. We surface a title for OSC 0
            // (icon name + window title) and OSC 2 (window title only). OSC 1 is
            // icon-name-ONLY and is deliberately ignored — it never sets the window title.
            let titleBytes = oscBuffer[oscBuffer.index(after: sep)...]
            let title = String(bytes: titleBytes, encoding: .utf8) ?? ""
            // zsh/p10k/starship emit an empty-body OSC 0/2 during prompt redraw BEFORE
            // setting the real title. Wiring that empty title clears the client's shown
            // title across the command boundary. Drop it silently — the client keeps the
            // last real title until a non-empty one arrives.
            guard !title.isEmpty else { return }
            // Trivial dedup: don't spam an identical title back-to-back.
            if title == lastTitle { return }
            lastTitle = title
            messages.append(.title(title))

        case "133":
            // EXACT-PARITY guard: the old command sniffer's 256-byte buffer cap means a
            // `133;…` payload of 257..4096 bytes was discarded before ever reaching its
            // finishOSC — reproduce that here so those payloads stay ignored.
            guard oscBuffer.count <= Self.cmdOscCap else { return }
            // C/D logic — verbatim from HostCommandStatusSniffer: full split on ';' with
            // empty fields KEPT. Expected: "133;A" | "133;B" | "133;C" | "133;D" |
            // "133;D;<exit>" (+ extra ;k=v).
            let payload = String(bytes: oscBuffer, encoding: .utf8) ?? ""
            let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count >= 2, fields[0] == "133" else { return }

            switch fields[1] {
            case "C":
                // A command began executing — mark RUNNING, reset the idle-sent flag, and start the clock.
                idleSentSinceLastC = false
                runningSince = clock()
                messages.append(.commandStatus(.running))
            case "D":
                // A command finished. Ignore a `D` with no matching `C` (the first-prompt
                // phantom `D;0`) — never emit a 0-duration `.idle` for a command that never ran.
                guard let started = runningSince else { return }
                runningSince = nil
                idleSentSinceLastC = true
                let exit = Self.parseExit(fields)
                let durationMS = Self.durationMS(from: started, to: clock())
                messages.append(.commandStatus(.idle(exitCode: exit, durationMS: durationMS)))
            case "B":
                // Prompt-ready mark: the shell finished rendering its prompt and the line editor accepts
                // input. When no idle signal has fired since the last command (i.e. first launch, before
                // any command ran), emit `.idle` so the client knows the shell is at a prompt. After a
                // `D` the client already has it — suppress the redundant B to keep D's exit-code/duration.
                if runningSince == nil, !idleSentSinceLastC {
                    idleSentSinceLastC = true
                    messages.append(.commandStatus(.idle(exitCode: nil, durationMS: 0)))
                }
            default:
                break // A / unknown 133 subcommand — not surfaced.
            }

        case "7":
            // OSC 7 — current working directory (`ESC ] 7 ; file://<host>/<absolute-path> ST/BEL`).
            // This is shell-controlled metadata, like title, but unlike title it feeds cwd inheritance:
            // split/new-tab can use the fresh cwd immediately instead of waiting for the command-complete
            // metadata RPC. The payload is already bounded by oscCap; malformed/non-file/relative values
            // are silently dropped.
            let bodyBytes = oscBuffer[oscBuffer.index(after: sep)...]
            guard let body = String(bytes: bodyBytes, encoding: .utf8),
                  let cwd = Self.osc7Path(from: body, localHostnames: localHostnames)
            else { return }
            messages.append(.cwd(cwd))

        case "9":
            // OSC 9 — iTerm2/ConEmu "post a notification" (`ESC ] 9 ; <body> ST`). The whole
            // remainder after `9;` is the notification body; no explicit title (the client falls
            // back to the pane title). A bounded payload like the 133 path (a notification body is
            // small; a giant one is not worth fabricating an alert for).
            guard oscBuffer.count <= Self.notifyOscCap else { return }
            let bodyBytes = oscBuffer[oscBuffer.index(after: sep)...]
            let body = String(bytes: bodyBytes, encoding: .utf8) ?? ""
            guard !body.isEmpty else { return }
            // OSC 9 is overloaded: iTerm2/ConEmu use `ESC]9;4;<state>;<pct>` for the taskbar PROGRESS-BAR
            // protocol (emitted continuously by winget, long builds, etc.), NOT a desktop notification;
            // surfacing those as alerts with body "4;1;50" floods the user with raw output. So `9;4` is
            // parsed into a `.progress` CONTROL message (E14/K1), never a `.notification`, while the
            // free-text iTerm2 form (`ESC]9;<message>`) stays a notification — BYTE-IDENTICAL to before
            // (only the previously-DROPPED `9;4` subtype now emits progress).
            if body == "4" || body.hasPrefix("4;") {
                if let (state, percent) = ProgressOSCParser.parse(body) {
                    messages.append(.progress(state: state.rawValue, percent: percent))
                }
                return // a 9;4 is progress (or malformed → dropped), never a notification
            }
            messages.append(.notification(title: "", body: body))

        case "777":
            // OSC 777 — urxvt/ConEmu `ESC ] 777 ; notify ; <title> ; <body> ST`. Only the `notify`
            // subcommand is a desktop notification; other 777 subcommands are ignored.
            guard oscBuffer.count <= Self.notifyOscCap else { return }
            let payload = String(bytes: oscBuffer, encoding: .utf8) ?? ""
            let fields = payload.split(separator: ";", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[1] == "notify" else { return }
            let title = String(fields[2])
            let body = fields.count >= 4 ? String(fields[3]) : ""
            guard !title.isEmpty || !body.isEmpty else { return }
            messages.append(.notification(title: title, body: body))

        case "99":
            // OSC 99 — the kitty desktop-notification protocol (`ESC ] 99 ; <metadata> ; <payload> ST`).
            // A BOUNDED validate-then-drop parse of the title/body + base64 (`e=1`) + single
            // replace-by-id (`i=<id>`) / chunked-continuation (`d=0`) SUBSET, mapped onto the EXISTING
            // ``WireMessage/notification(title:body:)`` (type 25) — NO new wire. The broader kitty
            // surface (urgency `u`, capability query `p=?`, buttons, icons, multi-datagram reassembly)
            // is a documented CEILING (see docs/DECISIONS.md): such chunks are DROPPED, never answered
            // (no dead capability-query path). Same per-chunk ``notifyOscCap`` bound as OSC 9 / 777.
            guard oscBuffer.count <= Self.notifyOscCap else { return }
            let remainderBytes = oscBuffer[oscBuffer.index(after: sep)...]
            guard let remainder = String(bytes: remainderBytes, encoding: .utf8) else { return }
            finishKittyNotification(remainder, into: &messages)

        default:
            // Any other Ps (OSC 1 icon, OSC 8 hyperlink, OSC 52 clipboard, OSC 4 palette …)
            // is neither a title, a command mark, nor a notification — skip.
            return
        }
    }

    static func osc7Path(from body: String, localHostnames: Set<String>) -> String? {
        guard body.hasPrefix("file://") else { return nil }
        let afterScheme = body.dropFirst("file://".count)
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        // Honor the authority: a FOREIGN hostname (a shell ssh'd into another box) must not be treated
        // as a local cwd — dropping it stops an ssh-inside-pane from poisoning cwd inheritance (the
        // next split would `chdir` into a host-nonexistent / wrong path). Percent-decode + lowercase
        // the authority; accept only a local identity (empty / localhost / this host's hostname).
        let authority = String(afterScheme[afterScheme.startIndex..<slash])
        let host = (authority.removingPercentEncoding ?? authority).lowercased()
        // An empty authority (`file:///…`) and `localhost` are ALWAYS local (machine-independent); any
        // other authority must match an injected local hostname or it is a foreign shell → drop.
        guard host.isEmpty || host == "localhost" || localHostnames.contains(host) else { return nil }
        let encodedPath = String(afterScheme[slash...])
        guard !encodedPath.isEmpty,
              encodedPath.hasPrefix("/"),
              let decoded = encodedPath.removingPercentEncoding,
              !decoded.isEmpty,
              decoded.hasPrefix("/")
        else { return nil }
        return decoded
    }

    // MARK: OSC 99 (kitty notification protocol) — bounded validate-then-drop → .notification

    /// One parsed kitty (OSC 99) chunk after the `99;` Ps was stripped: the `i=` group id, whether
    /// this is the FINAL chunk (`d != "0"`, default `1`), which field the payload sets (`p=body` →
    /// body, else title — kitty's default `p` is `title`), and the DECODED payload text.
    ///
    /// Returns `nil` (DROP) on ANY malformed / unsupported shape: a missing metadata/payload `;`,
    /// an unknown encoding `e` (only `0`/`1`), an unsupported payload type `p` (anything other than
    /// `title`/`body` — incl. the capability query `p=?`, `buttons`, `icon`, …), bad base64, or
    /// non-UTF-8 decoded bytes. Pure: the only allocation is the split + the decoded string.
    private struct KittyChunk {
        let id: String
        let done: Bool
        let isBody: Bool
        let text: String
    }

    /// Parses `<metadata>;<payload>` (the OSC-99 body after the leading `99;`). See ``KittyChunk``.
    private static func parseKittyChunk(_ remainder: String) -> KittyChunk? {
        // kitty REQUIRES `99;<metadata>;<payload>`; after stripping `99;` the remainder must still
        // carry the metadata/payload `;`. A single-`;` form (`ESC]99;text`) is malformed → drop.
        guard let metaEnd = remainder.firstIndex(of: ";") else { return nil }
        let metadata = remainder[remainder.startIndex..<metaEnd]
        let payload = remainder[remainder.index(after: metaEnd)...]

        // Read ONLY the supported metadata keys (`:`-separated `key=value`); every other key
        // (urgency `u`, actions `a`, when `o`, close `c`, …) is ignored — the documented ceiling.
        var id = ""
        var done = true // d default 1 (this is the final/only chunk)
        var encoding = "" // e default 0 (plain UTF-8)
        var payloadType = "title" // p default (kitty: an unmarked payload is the title)
        for token in metadata.split(separator: ":", omittingEmptySubsequences: true) {
            guard let eq = token.firstIndex(of: "=") else { continue } // lenient: skip a keyless token
            let key = String(token[token.startIndex..<eq])
            let value = String(token[token.index(after: eq)...])
            switch key {
            case "i": id = value
            case "d": done = value != "0"
            case "e": encoding = value
            case "p": payloadType = value
            default: break // unsupported metadata key — ceiling, ignore
            }
        }
        // Validate-then-drop the discriminants we DO act on (never trust an unknown one).
        guard encoding.isEmpty || encoding == "0" || encoding == "1" else { return nil }
        guard payloadType == "title" || payloadType == "body" else { return nil }

        let text: String
        if encoding == "1" {
            // base64 (`e=1`): decode, then UTF-8; a malformed payload is dropped, never trusted.
            guard let data = Data(base64Encoded: String(payload)),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            text = decoded
        } else {
            text = String(payload)
        }
        return KittyChunk(id: id, done: done, isBody: payloadType == "body", text: text)
    }

    /// Assembles a kitty (OSC 99) chunk across `d=0` continuations (keyed by `i=`), finalizing at the
    /// `d=1` chunk into the EXISTING ``WireMessage/notification(title:body:)``. Bounded by
    /// ``kittyAssemblyMax`` in-flight ids + ``kittyAssemblyCap`` accumulated chars.
    private func finishKittyNotification(_ remainder: String, into messages: inout [WireMessage]) {
        guard let chunk = Self.parseKittyChunk(remainder) else { return }

        // Bound the in-flight id count BEFORE creating a new slot (drop a brand-new id over the cap).
        let existing = kittyAssembly[chunk.id]
        if existing == nil, kittyAssembly.count >= Self.kittyAssemblyMax { return }
        var note = existing ?? (title: "", body: "")

        if chunk.isBody { note.body += chunk.text } else { note.title += chunk.text }
        // Bound the cross-chunk accumulation: a hostile `d=0` stream that keeps appending is abandoned.
        guard note.title.count + note.body.count <= Self.kittyAssemblyCap else {
            kittyAssembly[chunk.id] = nil
            return
        }
        guard chunk.done else {
            kittyAssembly[chunk.id] = note // d=0 → keep waiting for the final chunk
            return
        }
        kittyAssembly[chunk.id] = nil // finalize: clear the in-flight slot

        // Map onto .notification (type 25): fold a TITLE-only kitty notification into the body (so the
        // macOS banner shows it as primary text, consistent with the OSC-9 empty-title + the client's
        // pane-title fallback); keep both fields when a `p=body` chunk supplied a distinct body.
        let title = note.body.isEmpty ? "" : note.title
        let body = note.body.isEmpty ? note.title : note.body
        guard !title.isEmpty || !body.isEmpty else { return } // empty title+body → drop
        messages.append(.notification(title: title, body: body))
    }

    /// Parses the optional exit code from a `133;D[;<exit>[;k=v…]]` field list (field[2],
    /// tolerating a trailing `=value`), clamped to `Int32`. Returns `nil` when absent/unparsable.
    private static func parseExit(_ fields: [Substring]) -> Int32? {
        guard fields.count >= 3 else { return nil }
        let raw = fields[2].split(separator: "=").first.map(String.init) ?? String(fields[2])
        guard let value = Int(raw) else { return nil }
        return Int32(truncatingIfNeeded: value)
    }

    /// The non-negative C→D wall-clock duration in milliseconds (clamped at 0; a non-monotonic
    /// clock or a same-instant C/D can never produce a negative).
    private static func durationMS(from start: Date, to end: Date) -> UInt32 {
        let seconds = end.timeIntervalSince(start)
        let ms = (seconds * 1000).rounded()
        guard ms > 0 else { return 0 }
        return ms >= Double(UInt32.max) ? UInt32.max : UInt32(ms)
    }
}
