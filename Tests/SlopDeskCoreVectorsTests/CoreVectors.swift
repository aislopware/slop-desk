import CoreGraphics // CGRect/CGPoint/CGSize for the host geometry deciders
import Foundation
import SlopDeskProtocol // WorkspaceIntent (the workspace document ladder)
import SlopDeskVideoClient // TrendlineEstimator, OwdLateDetector, PacerDepthPolicy
import SlopDeskVideoProtocol

// LoopbackWorkspaceDocument + WorkspaceMirrorBox — the SWIFT half of the versioning ladder
// `workspaceDocumentVersioning` pins against `rust/slopdesk-hostserver`'s. Headless: the target
// holds no view framework, so naming it here does not drag the client UI into the generator.
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel // WorkspaceStateCodec (the host workspace document, docs/45)

// CoreVectors — mints a deterministic JSON corpus of golden vectors through the REAL
// `SlopDeskVideoProtocol` faces, using ONLY the public API.
//
// It is no longer a PARITY dumper: there is one implementation, in Rust, and these faces are its
// marshallers. What the corpus pins now is the pair the one-implementation rule cannot check by
// itself — the ABI and the marshalling. A field reordered in a `#[repr(C)]` record, a length
// spelled in the wrong unit, an endianness flipped on the way out: each still produces a Rust
// suite that passes and bytes on the wire that a peer of an older build cannot read. The frozen
// corpus catches exactly that class, and `slopdesk-gate golden` diffs against it rather than
// regenerating it.
//
// It lives under `Tests/` and NOT as an executable target, because the standing rule leaves Swift
// no binaries. The value that kept it Swift is untouched by the move: what it pins is how SWIFT
// marshals, so minting it from Rust would diff Rust against Rust and pin nothing.
//
// Determinism: floats that feed bytes use exactly-representable values; pure-numeric
// outputs (coordinate math, YCbCr, loss thresholds) are emitted as IEEE bit patterns so
// JSON float formatting can never blur the comparison. Re-running this dumper produces a
// byte-identical file (sorted keys), so the committed corpus stays clean in git.

/// The emitted half of `golden/golden_vectors.json`, minted fresh.
enum CoreVectors {
    // swiftlint:disable function_body_length

    /// Every vector this side can still mint, keyed exactly as the corpus keys them.
    ///
    /// The whole body is one function on purpose: the corpus is a SEQUENCE of independent records,
    /// and splitting it into per-group methods would buy nothing but a place for a group to be
    /// forgotten. `slopdesk-gate golden` pins the key set from Rust, so a dropped `root[…]` is a
    /// gate failure naming the key rather than a quieter corpus.
    ///
    /// `@MainActor` because `LoopbackWorkspaceDocument` is: the versioning ladder runs the REAL
    /// class, which is the only way that key can catch this side drifting. As top-level code the
    /// isolation was implicit; as a method it is written down.
    @MainActor
    static func mint() -> [String: Any] {
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        func hex(_ bytes: [UInt8]) -> String { hex(Data(bytes)) }

        var root: [String: Any] = [:]

        // MARK: FrameFragment.encode

        func fragmentRecord(
            streamSeq: UInt32,
            frameID: UInt32,
            fragIndex: UInt16,
            fragCount: UInt16,
            flags: UInt8,
            hostTs: UInt32,
            payload: [UInt8],
        ) -> [String: Any] {
            let header = FrameFragmentHeader(
                streamSeq: streamSeq,
                frameID: frameID,
                fragIndex: fragIndex,
                fragCount: fragCount,
                flags: .init(rawValue: flags),
                payloadLength: UInt16(payload.count),
                hostSendTsMillis: hostTs,
            )
            let frag = FrameFragment(header: header, payload: Data(payload))
            return [
                "streamSeq": streamSeq,
                "frameID": frameID,
                "fragIndex": fragIndex,
                "fragCount": fragCount,
                "flags": flags,
                "hostTs": hostTs,
                "payloadHex": hex(payload),
                "hex": hex(frag.encode()),
            ]
        }

        root["fragmentEncode"] = [
            fragmentRecord(
                streamSeq: 0x0102_0304,
                frameID: 0x0506_0708,
                fragIndex: 0x090A,
                fragCount: 0x0B0C,
                flags: 0b0000_0101,
                hostTs: 0x0D0E_0F10,
                payload: [0xAA, 0xBB, 0xCC],
            ),
            fragmentRecord(streamSeq: 0, frameID: 0, fragIndex: 0, fragCount: 1, flags: 0, hostTs: 0, payload: []),
            fragmentRecord(
                streamSeq: 0xFFFF_FFFF,
                frameID: 7,
                fragIndex: 2,
                fragCount: 9,
                flags: 0b1101_1010,
                hostTs: 1234,
                payload: Array(0..<UInt8(200)).map(\.self),
            ),
        ]

        // MARK: XORParityFEC.parity + recover

        func fecParityRecord(data: [[UInt8]], groupSize: Int) -> [String: Any] {
            let fec = XORParityFEC(groupSize: 5)
            let parity = fec.parity(forDataFragments: data.map { Data($0) }, groupSize: groupSize)
            return ["dataHex": data.map { hex($0) }, "groupSize": groupSize, "parityHex": parity.map { hex($0) }]
        }

        root["fecParity"] = [
            fecParityRecord(data: [[1, 2], [3], [4, 5, 6], [7], [8, 9]], groupSize: 5),
            fecParityRecord(data: (0..<12).map { [UInt8($0), UInt8($0) &+ 1, UInt8($0) &+ 2] }, groupSize: 5),
            fecParityRecord(data: [[10], [20], [30], [40], [50]], groupSize: 2),
            fecParityRecord(data: [[0xAB, 0xCD, 0xEF]], groupSize: 1),
        ]

        func fecRecoverRecord(data: [[UInt8]?], parity: [[UInt8]?], groupSize: Int) -> [String: Any] {
            let fec = XORParityFEC(groupSize: 5)
            let recovered = fec.recover(
                dataFragments: data.map { (bytes: [UInt8]?) in bytes.map { Data($0) } },
                parityFragments: parity.map { (bytes: [UInt8]?) in bytes.map { Data($0) } },
                groupSize: groupSize,
            )
            func opt(_ b: [UInt8]?) -> Any { b.map { hex($0) } ?? NSNull() }
            func optD(_ d: Data?) -> Any { d.map { hex($0) } ?? NSNull() }
            return [
                "dataHex": data.map(opt),
                "parityHex": parity.map(opt),
                "groupSize": groupSize,
                "recoveredHex": recovered.map(optD),
            ]
        }

        let g5parity = XORParityFEC(groupSize: 5).parity(
            forDataFragments:
            [[1, 2], [3], [4, 5, 6], [7], [8, 9]].map { Data($0) },
            groupSize: 5,
        ).map { Array($0) }
        root["fecRecover"] = [
            // lose the middle data fragment; group parity recovers it.
            fecRecoverRecord(data: [[1, 2], [3], nil, [7], [8, 9]], parity: [g5parity[0]], groupSize: 5),
            // two holes in one group → both stay nil (unrecoverable).
            fecRecoverRecord(data: [nil, nil, [4, 5, 6], [7], [8, 9]], parity: [g5parity[0]], groupSize: 5),
            // hole but parity also lost → stays nil.
            fecRecoverRecord(data: [[1, 2], nil, [4, 5, 6], [7], [8, 9]], parity: [nil], groupSize: 5),
        ]

        // MARK: CursorUpdate / CursorShapeMessage

        func cursorUpdateRecord(
            shapeID: UInt16,
            visible: Bool,
            x: Double,
            y: Double,
            hx: Double,
            hy: Double,
        ) -> [String: Any] {
            let u = CursorUpdate(
                position: VideoPoint(x: x, y: y),
                shapeID: shapeID,
                hotspot: VideoPoint(x: hx, y: hy),
                visible: visible,
            )
            return ["shapeID": shapeID, "visible": visible, "x": x, "y": y, "hx": hx, "hy": hy, "hex": hex(u.encode())]
        }

        root["cursorUpdate"] = [
            cursorUpdateRecord(shapeID: 0xBEEF, visible: false, x: 12.5, y: -3.25, hx: 1.0, hy: 2.0),
            cursorUpdateRecord(shapeID: 0, visible: true, x: 0.0, y: 0.0, hx: 0.0, hy: 0.0),
        ]
        func cursorShapeRecord(
            shapeID: UInt16,
            w: Double,
            h: Double,
            hx: Double,
            hy: Double,
            bitmap: [UInt8],
        ) -> [String: Any] {
            let s = CursorShapeMessage(
                shapeID: shapeID,
                size: VideoSize(width: w, height: h),
                hotspot: VideoPoint(x: hx, y: hy),
                bitmap: Data(bitmap),
            )
            return [
                "shapeID": shapeID,
                "w": w,
                "h": h,
                "hx": hx,
                "hy": hy,
                "bitmapHex": hex(bitmap),
                "hex": hex(s.encode()),
            ]
        }

        root["cursorShape"] = [
            cursorShapeRecord(
                shapeID: 7,
                w: 32.0,
                h: 32.0,
                hx: 4.0,
                hy: 4.0,
                bitmap: [0x89, 0x50, 0x4E, 0x47, 1, 2, 3],
            ),
            cursorShapeRecord(shapeID: 1, w: 16.0, h: 16.0, hx: 0.0, hy: 0.0, bitmap: []),
        ]

        func swipeNavStatusRecord(
            eligible: Bool, slowTier: Bool, fireTravel: UInt16,
            canGoBack: Bool, canGoForward: Bool, historyKnown: Bool,
        ) -> [String: Any] {
            let s = SwipeNavStatusMessage(
                eligible: eligible, slowTier: slowTier, fireTravel: fireTravel,
                canGoBack: canGoBack, canGoForward: canGoForward, historyKnown: historyKnown,
            )
            return [
                "eligible": eligible, "slowTier": slowTier, "fireTravel": fireTravel,
                "canGoBack": canGoBack, "canGoForward": canGoForward, "historyKnown": historyKnown,
                "hex": hex(s.encode()),
            ]
        }

        root["swipeNavStatus"] = [
            swipeNavStatusRecord(
                eligible: true, slowTier: true, fireTravel: 80,
                canGoBack: false, canGoForward: false, historyKnown: false,
            ),
            swipeNavStatusRecord(
                eligible: false, slowTier: false, fireTravel: 500,
                canGoBack: false, canGoForward: false, historyKnown: false,
            ),
            swipeNavStatusRecord(
                eligible: true, slowTier: true, fireTravel: 80,
                canGoBack: true, canGoForward: false, historyKnown: true,
            ),
        ]

        // MARK: WindowGeometryMessage

        func wg(_ name: String, _ msg: WindowGeometryMessage, _ extra: [String: Any]) -> [String: Any] {
            var r: [String: Any] = ["variant": name, "hex": hex(msg.encode())]
            r.merge(extra) { a, _ in a }
            return r
        }

        root["windowGeometry"] = [
            wg("move", .move(VideoPoint(x: 10.0, y: 20.0)), ["x": 10.0, "y": 20.0]),
            wg("resize", .resize(VideoSize(width: 640.0, height: 480.0)), ["w": 640.0, "h": 480.0]),
            wg(
                "bounds",
                .bounds(VideoRect(x: 1.0, y: 2.0, width: 3.0, height: 4.0)),
                ["x": 1.0, "y": 2.0, "w": 3.0, "h": 4.0],
            ),
            wg("title", .title("héllo · 窗口"), ["title": "héllo · 窗口"]),
        ]

        // MARK: InputEvent

        func ie(_ name: String, _ msg: InputEvent, _ extra: [String: Any]) -> [String: Any] {
            var r: [String: Any] = ["variant": name, "hex": hex(msg.encode())]
            r.merge(extra) { a, _ in a }
            return r
        }

        let mods: UInt8 = InputModifiers([.shift, .command]).rawValue
        root["inputEvent"] = [
            ie(
                "mouseMove",
                .mouseMove(normalized: VideoPoint(x: 0.25, y: 0.75), tag: 42),
                ["nx": 0.25, "ny": 0.75, "tag": 42],
            ),
            ie(
                "mouseDown",
                .mouseDown(
                    button: .right,
                    normalized: VideoPoint(x: 0.1, y: 0.2),
                    clickCount: 2,
                    modifiers: .init(rawValue: mods),
                    tag: 7,
                ),
                ["button": 1, "nx": 0.1, "ny": 0.2, "clickCount": 2, "mods": mods, "tag": 7],
            ),
            ie(
                "mouseUp",
                .mouseUp(
                    button: .left,
                    normalized: VideoPoint(x: 0.3, y: 0.4),
                    clickCount: 1,
                    modifiers: .init(rawValue: 0),
                    tag: 8,
                ),
                ["button": 0, "nx": 0.3, "ny": 0.4, "clickCount": 1, "mods": 0, "tag": 8],
            ),
            ie(
                "mouseDrag",
                .mouseDrag(
                    button: .other,
                    normalized: VideoPoint(x: 0.5, y: 0.6),
                    clickCount: 1,
                    modifiers: .init(rawValue: InputModifiers.control.rawValue),
                    tag: 9,
                ),
                ["button": 2, "nx": 0.5, "ny": 0.6, "clickCount": 1, "mods": InputModifiers.control.rawValue, "tag": 9],
            ),
            ie(
                "scroll",
                .scroll(
                    dx: -3.5,
                    dy: 12.0,
                    normalized: VideoPoint(x: 0.0, y: 1.0),
                    scrollPhase: 2,
                    momentumPhase: 0,
                    continuous: true,
                    modifiers: .init(rawValue: InputModifiers.command.rawValue),
                    tag: 10,
                ),
                [
                    "dx": -3.5,
                    "dy": 12.0,
                    "nx": 0.0,
                    "ny": 1.0,
                    "scrollPhase": 2,
                    "momentumPhase": 0,
                    "continuous": true,
                    "mods": InputModifiers.command.rawValue,
                    "tag": 10,
                ],
            ),
            ie(
                "scroll",
                .scroll(
                    dx: 0.0,
                    dy: 4.25,
                    normalized: VideoPoint(x: 0.0, y: 1.0),
                    scrollPhase: 0,
                    momentumPhase: 2,
                    continuous: true,
                    tag: 10,
                ),
                [
                    "dx": 0.0,
                    "dy": 4.25,
                    "nx": 0.0,
                    "ny": 1.0,
                    "scrollPhase": 0,
                    "momentumPhase": 2,
                    "continuous": true,
                    "mods": 0,
                    "tag": 10,
                ],
            ),
            ie(
                "key",
                .key(
                    keyCode: 0x35,
                    down: true,
                    isRepeat: true,
                    modifiers: .init(rawValue: InputModifiers.option.rawValue),
                    tag: 11,
                ),
                ["keyCode": 0x35, "down": true, "repeat": true, "mods": InputModifiers.option.rawValue, "tag": 11],
            ),
            ie("text", .text("gõ được 文字", tag: 12), ["text": "gõ được 文字", "tag": 12]),
        ]

        // MARK: VideoControlMessage

        func vc(_ name: String, _ msg: VideoControlMessage, _ extra: [String: Any]) -> [String: Any] {
            var r: [String: Any] = ["variant": name, "hex": hex(msg.encode())]
            r.merge(extra) { a, _ in a }
            return r
        }

        root["videoControl"] = [
            vc(
                "hello",
                .hello(
                    protocolVersion: 7,
                    requestedWindowID: 0xDEAD_BEEF,
                    viewport: VideoSize(width: 1280.0, height: 800.0),
                ),
                ["version": 7, "windowID": 0xDEAD_BEEF, "vw": 1280.0, "vh": 800.0],
            ),
            vc(
                "helloAck",
                .helloAck(
                    accepted: true,
                    streamID: 42,
                    captureWidth: 1920,
                    captureHeight: 1080,
                    windowBoundsCG: VideoRect(x: 0.0, y: 25.0, width: 800.0, height: 600.0),
                    fullRange: true,
                ),
                [
                    "accepted": true,
                    "streamID": 42,
                    "cw": 1920,
                    "ch": 1080,
                    "bx": 0.0,
                    "by": 25.0,
                    "bw": 800.0,
                    "bh": 600.0,
                    "fullRange": true,
                ],
            ),
            vc("bye", .bye, [:]),
            vc(
                "resizeRequest",
                .resizeRequest(desired: VideoSize(width: 640.5, height: 480.25), epoch: 3),
                ["w": 640.5, "h": 480.25, "epoch": 3],
            ),
            vc(
                "resizeAck",
                .resizeAck(captureWidth: 640, captureHeight: 480, epoch: 3),
                ["cw": 640, "ch": 480, "epoch": 3],
            ),
            vc("keepalive", .keepalive, [:]),
            vc("listWindows", .listWindows, [:]),
            vc("windowList", .windowList([
                WindowSummary(windowID: 1, appName: "Google Chrome", title: "Tab — Title", width: 1200, height: 800),
                WindowSummary(windowID: 2, appName: "Terminal", title: "", width: 80, height: 24),
            ]), ["windows": [
                ["windowID": 1, "appName": "Google Chrome", "title": "Tab — Title", "width": 1200, "height": 800],
                ["windowID": 2, "appName": "Terminal", "title": "", "width": 80, "height": 24],
            ]]),
            vc("focusWindow", .focusWindow, [:]),
            vc("streamCadence", .streamCadence(fps: 60), ["fps": 60]),
            vc(
                "scrollOffset",
                .scrollOffset(dx: -5, dy: 42, bandTop: 1000, bandBottom: 9000),
                ["dx": -5, "dy": 42, "bandTop": 1000, "bandBottom": 9000],
            ),
            vc("contentMask", .contentMask([
                MaskRect(x: 0, y: 0, width: 2880, height: 1800),
                MaskRect(x: 96, y: 1406, width: 538, height: 172),
            ]), ["rects": [
                ["x": 0, "y": 0, "w": 2880, "h": 1800],
                ["x": 96, "y": 1406, "w": 538, "h": 172],
            ]]),
            vc(
                "displayMax",
                .displayMax(width: 1920, height: 1080),
                ["maxWidth": 1920, "maxHeight": 1080],
            ),
            vc("listSystemDialogs", .listSystemDialogs, [:]),
            vc("systemDialogList", .systemDialogList([
                SystemDialogSummary(
                    windowID: 9,
                    owner: "SecurityAgent",
                    title: "",
                    width: 400,
                    height: 200,
                    isSecure: true,
                ),
            ]), ["dialogs": [
                ["windowID": 9, "owner": "SecurityAgent", "title": "", "width": 400, "height": 200, "isSecure": true],
            ]]),
            vc(
                "windowFeedSubscribe",
                .windowFeedSubscribe(knownGeneration: 0xDEAD_BEEF),
                ["knownGeneration": 0xDEAD_BEEF],
            ),
            vc("windowFeedSnapshot", .windowFeedSnapshot(
                generation: 7,
                chunkIndex: 1,
                chunkCount: 3,
                records: [
                    HostWindowRecord(
                        windowID: 42, widthPt: 1512, heightPt: 982,
                        flags: [.onScreen, .frontmostApp, .focusedWindow], displayIndex: 0,
                        bundleID: "com.mitchellh.ghostty", appName: "Ghostty", title: "~/work — zsh",
                    ),
                    HostWindowRecord(
                        windowID: 43, widthPt: 800, heightPt: 600,
                        flags: [.minimized, .appHidden], displayIndex: 1,
                        bundleID: "", appName: "Tool", title: "",
                    ),
                ],
            ), [
                "generation": 7,
                "chunkIndex": 1,
                "chunkCount": 3,
                "records": [
                    [
                        "windowID": 42, "width": 1512, "height": 982, "flags": 0b0001_1001, "display": 0,
                        "bundleID": "com.mitchellh.ghostty", "appName": "Ghostty", "title": "~/work — zsh",
                    ],
                    [
                        "windowID": 43, "width": 800, "height": 600, "flags": 0b0000_0110, "display": 1,
                        "bundleID": "", "appName": "Tool", "title": "",
                    ],
                ],
            ]),
            vc("windowFeedCurrent", .windowFeedCurrent(generation: 7), ["generation": 7]),
            vc(
                "appIconRequest",
                .appIconRequest(sizePx: 64, bundleID: "com.mitchellh.ghostty"),
                ["sizePx": 64, "bundleID": "com.mitchellh.ghostty"],
            ),
            vc("blobChunk", .blobChunk(
                blobKind: 0, blobID: 0xDEAD_BEEF_CAFE_F00D, metaA: 64, metaB: 0,
                chunkIndex: 1, chunkCount: 3, bytes: Data([0x89, 0x50, 0x4E, 0x47]),
            ), [
                "blobKind": 0, "blobID": String(0xDEAD_BEEF_CAFE_F00D as UInt64), "metaA": 64, "metaB": 0,
                "chunkIndex": 1, "chunkCount": 3, "bytesHex": "89504e47",
            ]),
            vc(
                "windowPreviewRequest",
                .windowPreviewRequest(windowID: 42, maxWidthPx: 640),
                ["windowID": 42, "maxWidthPx": 640],
            ),
            vc("listDisplays", .listDisplays, [:]),
            vc("displayList", .displayList([
                DisplaySummary(displayID: 1, width: 2560, height: 1440, isMain: true),
                DisplaySummary(displayID: 0x04FD_0002, width: 1920, height: 1080, isMain: false),
            ]), ["displays": [
                ["displayID": 1, "width": 2560, "height": 1440, "isMain": true],
                ["displayID": 0x04FD_0002, "width": 1920, "height": 1080, "isMain": false],
            ]]),
            vc(
                "helloDisplay",
                .helloDisplay(
                    protocolVersion: 7,
                    requestedDisplayID: 1,
                    viewport: VideoSize(width: 1280.0, height: 800.0),
                ),
                ["version": 7, "displayID": 1, "vw": 1280.0, "vh": 800.0],
            ),
            vc(
                "streamSettings",
                .streamSettings(fpsCap: 24, bitrateCeilingBps: 8_000_000),
                ["fpsCap": 24, "bitrateCeilingBps": 8_000_000],
            ),
            vc("audioControlOn", .audioControl(enabled: true), ["enabled": true]),
            vc("audioControlOff", .audioControl(enabled: false), ["enabled": false]),
            vc(
                "hostStats",
                .hostStats(rttTenthsMillis: 123, encodeTenthsMillis: 45),
                ["rttTenthsMillis": 123, "encodeTenthsMillis": 45],
            ),
            vc("privacyModeOn", .privacyMode(enabled: true), ["enabled": true]),
            vc("privacyModeOff", .privacyMode(enabled: false), ["enabled": false]),
        ]

        // MARK: AudioChannelMessage

        func aw(_ name: String, _ msg: AudioChannelMessage, _ extra: [String: Any]) -> [String: Any] {
            var r: [String: Any] = ["variant": name, "hex": hex(msg.encode())]
            r.merge(extra) { a, _ in a }
            return r
        }

        root["audioWire"] = [
            aw(
                "configAacEld",
                .config(
                    seq: 1,
                    hostSendTsMillis: 250,
                    config: AudioStreamConfig(
                        format: .aacEld,
                        sampleRate: 48000,
                        channels: 2,
                        cookie: Data([0xDE, 0xAD]),
                    ),
                ),
                ["seq": 1, "hostTs": 250, "format": 1, "sampleRate": 48000, "channels": 2, "cookieHex": "dead"],
            ),
            aw(
                "frame",
                .frame(seq: 2, hostSendTsMillis: 251, payload: Data([0x01, 0x02, 0x03, 0x04])),
                ["seq": 2, "hostTs": 251, "payloadHex": "01020304"],
            ),
            aw(
                "frameExtremes",
                .frame(seq: 0xFFFF_FFFF, hostSendTsMillis: 0xDEAD_BEEF, payload: Data()),
                ["seq": 0xFFFF_FFFF, "hostTs": 0xDEAD_BEEF, "payloadHex": ""],
            ),
        ]

        // MARK: RecoveryMessage

        func rc(_ name: String, _ msg: RecoveryMessage, _ extra: [String: Any]) -> [String: Any] {
            var r: [String: Any] = ["variant": name, "hex": hex(msg.encode())]
            r.merge(extra) { a, _ in a }
            return r
        }

        root["recovery"] = [
            rc("ack", .ack(streamSeq: 123), ["streamSeq": 123]),
            rc(
                "requestLTRRefresh",
                .requestLTRRefresh(
                    fromFrameID: 10,
                    toFrameID: 12,
                    lastDecodedFrameID: RecoveryMessage.noFrameDecodedSentinel,
                ),
                ["from": 10, "to": 12, "lastDecoded": RecoveryMessage.noFrameDecodedSentinel],
            ),
            rc("requestIDR", .requestIDR(lastDecodedFrameID: 9), ["lastDecoded": 9]),
            rc("requestCursorShape", .requestCursorShape(shapeID: 0xABCD), ["shapeID": 0xABCD]),
            rc(
                "networkStats",
                .networkStats(NetworkStatsReport(
                    framesReceived: 100, fecRecovered: 5, unrecovered: 2, latestHostSendTs: 999, clientHoldMs: 3,
                    owdJitterMicros: 1500, owdTrendMilli: UInt32(bitPattern: -1234), owdTrendFlags: (255 << 8) | 0x1,
                    pacerLateFrames: 4, pacerPresentGaps: 6, pacerDepth: 2,
                )),
                [
                    "framesReceived": 100,
                    "fecRecovered": 5,
                    "unrecovered": 2,
                    "latestHostSendTs": 999,
                    "clientHoldMs": 3,
                    "owdJitterMicros": 1500,
                    "owdTrendMilli": UInt32(bitPattern: -1234),
                    "owdTrendFlags": (255 << 8) | 0x1,
                    "pacerLateFrames": 4,
                    "pacerPresentGaps": 6,
                    "pacerDepth": 2,
                ],
            ),
            rc(
                "requestFragments",
                .requestFragments(frameID: 0x0102_0304, fragIndices: [0x0005, 0x000A]),
                ["frameID": 0x0102_0304, "fragIndices": [0x0005, 0x000A]],
            ),
        ]

        // MARK: Mux header

        root["muxBare"] = [
            [
                "channelID": 0x0102_0304,
                "payloadHex": hex([9, 8, 7]),
                "hex": hex(VideoMuxHeaderCodec.encode(channelID: 0x0102_0304, payload: Data([9, 8, 7]))),
            ],
        ]
        let muxHeader = MuxFrameFragmentHeader(
            channelID: 0xAABB_CCDD,
            streamSeq: 1,
            frameID: 2,
            fragIndex: 3,
            fragCount: 4,
            flags: .keyframe,
            payloadLength: 2,
        )
        root["muxFragment"] = [
            [
                "channelID": 0xAABB_CCDD,
                "streamSeq": 1,
                "frameID": 2,
                "fragIndex": 3,
                "fragCount": 4,
                "flags": FrameFragmentHeader.Flags.keyframe.rawValue,
                "payloadHex": hex([0xEE, 0xFF]),
                "hex": hex(muxHeader.encode(payload: Data([0xEE, 0xFF]))),
            ],
        ]

        // MARK: CoordinateMapping (numeric — bit-pattern exact)

        func coordRecord(nx: Double, ny: Double, bx: Double, by: Double, bw: Double, bh: Double) -> [String: Any] {
            let p = CoordinateMapping.windowPoint(
                normalized: VideoPoint(x: nx, y: ny),
                windowBounds: VideoRect(x: bx, y: by, width: bw, height: bh),
            )
            return [
                "nx": nx,
                "ny": ny,
                "bx": bx,
                "by": by,
                "bw": bw,
                "bh": bh,
                "outXBits": p.x.bitPattern,
                "outYBits": p.y.bitPattern,
            ]
        }

        root["coordWindowPoint"] = [
            coordRecord(nx: 0.5, ny: 0.25, bx: 100.0, by: 200.0, bw: 800.0, bh: 600.0),
            coordRecord(nx: 0.0, ny: 1.0, bx: -50.0, by: 0.0, bw: 1024.0, bh: 768.0),
        ]

        // MARK: YCbCr coefficients (f32 — bit-pattern exact)

        func ycbcrRecord(_ range: ColorRange, _ name: String) -> [String: Any] {
            let c = YCbCrConversion.coefficients(range)
            return [
                "range": name,
                "lumaScale": c.lumaScale.bitPattern,
                "lumaBias": c.lumaBias.bitPattern,
                "chromaBias": c.chromaBias.bitPattern,
                "crToR": c.crToR.bitPattern,
                "cbToG": c.cbToG.bitPattern,
                "crToG": c.crToG.bitPattern,
                "cbToB": c.cbToB.bitPattern,
            ]
        }

        root["ycbcr"] = [ycbcrRecord(.video, "video"), ycbcrRecord(.full, "full")]

        // MARK: AdaptiveFEC decisions

        func tierRecord(loss: Double, prevTier: UInt8, allowOff: Bool) -> [String: Any] {
            [
                "lossBits": loss.bitPattern,
                "prevTier": prevTier,
                "allowOff": allowOff,
                "tier": AdaptiveFECPolicy.tier(forLossRate: loss, previousTier: prevTier, allowOff: allowOff),
            ]
        }

        var tierCases: [[String: Any]] = []
        for loss in [0.0, 0.001, 0.005, 0.015, 0.02, 0.05, 0.10, 0.15] {
            for prev in [UInt8(0), 1, 2, 3, 4] {
                for allowOff in [false, true] {
                    tierCases.append(tierRecord(loss: loss, prevTier: prev, allowOff: allowOff))
                }
            }
        }

        root["adaptiveTier"] = tierCases

        func groupSizeRecord(tier: UInt8, def: Int) -> [String: Any] {
            let g = AdaptiveFECPolicy.groupSize(forTier: tier, default: def)
            return ["tier": tier, "def": def, "groupSize": g.map { $0 as Any } ?? NSNull()]
        }

        root["adaptiveGroupSize"] = (0...7).map { groupSizeRecord(tier: UInt8($0), def: 5) } + [groupSizeRecord(
            tier: 200,
            def: 7,
        )]

        // MARK: - Realtime controllers (FLOAT-determinism parity)

//
        // The controllers' decisions are internal (not on the wire), but their f64 EWMA / OLS / median
        // math is the trickiest code in the port. These vectors drive each pure controller through a
        // deterministic input sequence and dump the resulting float STATE as IEEE bit patterns, proving
        // the Rust port reproduces Swift's floating-point arithmetic operation-for-operation. The inputs
        // use the SAME literal expressions the Rust replay uses, so accumulated f64 values are identical.

        // MARK: TrendlineEstimator — windowed OLS slope + adaptive threshold (the float-heaviest path).

        do {
            var est = TrendlineEstimator()
            var arrival = 1000.0
            var ts: UInt32 = 5000
            est.note(arrivalMs: arrival, sendTs: ts)
            for _ in 0..<60 { arrival += 16
                ts &+= 16
                est.note(arrivalMs: arrival, sendTs: ts)
            } // steady
            for _ in 0..<40 { arrival += 41
                ts &+= 16
                est.note(arrivalMs: arrival, sendTs: ts)
            } // +25ms ramp
            root["trendlineDrive"] = [
                "modifiedTrendBits": est.modifiedTrend.bitPattern,
                "thresholdBits": est.threshold.bitPattern,
                "stateRaw": est.state.rawValue, "numDeltas": est.numDeltas,
                "wireTrendMilli": est.wireTrendMilli, "wireTrendFlags": est.wireTrendFlags,
            ]
        }

        // MARK: OwdLateDetector — two-bucket min baseline + per-sample deviation (bits-or-null per step).

        do {
            var d = OwdLateDetector()
            let interval = 1000.0 / 60.0
            var arrival = 5000.0
            var send: UInt32 = 91000
            var steps: [[String: Any]] = []
            func step(_ darr: Double, _ dsend: UInt32) {
                arrival += darr
                send &+= dsend
                let v = d.note(arrivalMs: arrival, sendTs: send, intervalMs: interval)
                steps.append(["devBits": v.map { $0.bitPattern as Any } ?? NSNull()])
            }
            for _ in 0..<30 { step(16.7, 17) } // warm
            step(16.7 + 40, 17) // spike
            for _ in 0..<5 { step(16.7 + 30, 17) } // queue build
            for _ in 0..<12 { step(1, 17) } // drain back toward baseline
            root["owdLateDrive"] = steps
        }

        // MARK: PacerDepthPolicy — interval-ring median + late-threshold float math.

        do {
            var dp = PacerDepthPolicy(adaptEnabled: true)
            var t = 0.0
            // 30 arrivals at a deliberately uneven cadence so the median is exercised (not all equal).
            let gaps = [1.0 / 60, 1.0 / 60, 1.0 / 50, 1.0 / 60, 1.0 / 72, 1.0 / 60]
            for i in 0..<30 { t += gaps[i % gaps.count]
                dp.noteArrival(t)
                dp.notePresent(t)
            }
            root["pacerDepthFloats"] = [
                "expectedIntervalBits": dp.expectedIntervalSeconds.bitPattern,
                "lateThresholdBits": dp.lateThresholdSeconds.bitPattern,
            ]
            var hinted = PacerDepthPolicy(adaptEnabled: true)
            hinted.setIntervalHint(1.0 / 30.0)
            root["pacerDepthHinted"] = [
                "expectedIntervalBits": hinted.expectedIntervalSeconds.bitPattern,
                "lateThresholdBits": hinted.lateThresholdSeconds.bitPattern,
            ]
        }

        // MARK: SlopDeskProtocol — the wire-message vectors, now FROZEN

        // `terminalWireMessages`, `blocksWireMessages`, `metadataWireMessages` and `workspaceWireMessages`
        // were emitted from here, through `WireMessage.encode()`. `docs/63` G.4 deleted that encoder — the
        // client's live path takes the FLAT RECORD through `slopdesk_mux_transport_send` and has not wanted
        // bytes since G.3 moved the socket to Rust — so this generator can no longer produce them, and the
        // four keys moved to `FROZEN_KEYS`.
//
        // They are not less pinned for it. `rust/slopdesk-wire/tests/golden_vectors.rs` opens the same
        // corpus, decodes each pinned frame, asserts every field against the values the generator wrote
        // beside the hex, re-encodes and asserts byte-identical output. That is a STRONGER pin than the
        // emission was: a generator can only ever agree with itself, and the replay checks the hex against
        // the fields rather than against another run of the same encoder.

        // NOTE: metadataCodecPayloads vectors are FROZEN in golden_vectors.json — `docs/63` §G.4 deleted
        // `MetadataCodec`'s response-side encoders. The client encodes REQUESTS and decodes RESPONSES, and
        // the host half of the codec had no Swift caller left once `Sources/` lost its host target, so this
        // generator can no longer produce these bytes. They are replayed by
        // `the_pinned_metadata_payloads_decode_to_the_pinned_fields_and_re_encode_identically` in
        // `rust/slopdesk-wire/tests/golden_vectors.rs`, which decodes each payload, asserts every field
        // against the values written beside the hex, and re-encodes byte-identically — a STRONGER pin than
        // the emission was, since a generator can only ever agree with itself.

        // NOTE: muxEnvelopes vectors are FROZEN in golden_vectors.json — this generator no longer imports
        // `MuxEnvelopeCodec`, because `docs/63` G.3 deleted it along with the rest of the Swift client mux.
        // The twelve cases are replayed by `every_pinned_mux_envelope_encodes_to_the_bytes_swift_encoded` in
        // `rust/slopdesk-wire/tests/golden_mux_envelopes.rs`, which CONSTRUCTS each frame from the record's
        // own fields and encodes it — the direction the corpus would otherwise lose. The decode direction
        // is `golden_vectors.rs`'s, and both are kept: they are opposite directions, not duplication.

        // MARK: - Host pure-geometry deciders (FLOAT-determinism parity)

//
        // The host capture-region / virtual-display / window-placement / system-dialog / size-negotiation
        // math is CoreGraphics-faithful (standardized width/height, CGRectNull) and float-heavy. These
        // vectors drive each pure decider through diverse + edge inputs and dump every float as an IEEE bit
        // pattern (inputs AND outputs), so JSON float formatting can never blur the comparison and the Rust
        // port is proven to reproduce Swift's arithmetic operation-for-operation. CGRectNull (∞,∞,0,0) is
        // dumped as its raw component bits and matched against Rust `VideoRect::NULL`.

        // NOTE: captureUnion / captureRetarget vectors are FROZEN in golden_vectors.json — this generator
        // does not import the capture-region math, so it cannot emit them. They are replayed by
        // `every_pinned_capture_union_encloses_what_swift_enclosed` and
        // `every_pinned_retarget_gate_opens_exactly_where_swift_opened_it` in
        // `rust/slopdesk-video/tests/golden_vectors.rs`, which is where the arithmetic now lives. (This
        // note used to claim a Rust `slopdesk_core` crate validated them via a `golden_parity` test;
        // neither existed, and while the note stood the 23 cases were pinned by nothing at all.)

        // NOTE: virtualDisplayGeometry / vdOriginToRight / vdChipPixelLimit / vdRefreshRates vectors are
        // FROZEN in golden_vectors.json, for the same reason as the capture keys above. They are now
        // replayed TWICE, like the placement keys below: `VirtualDisplayGoldenVectorTests` through the Swift
        // face, and `every_pinned_virtual_display_geometry_reports_what_swift_reported` and its three
        // siblings in `rust/slopdesk-video/tests/golden_vectors.rs` through `virtual_display`, which is
        // where the arithmetic lives. (The claim about a `slopdesk_core::virtual_display_geometry` crate is
        // gone with the note that made it; the replay above found `vdRefreshRates` STALE while it stood —
        // 6281fae2 added the 2x-oversample mode and, with no reader, the corpus kept recording the
        // superseded law. Both sides pin that disagreement explicitly rather than skipping it.)

        // NOTE: windowPlacement / windowFits vectors are FROZEN in golden_vectors.json, for the same
        // reason as the two notes above. They are now replayed TWICE: `WindowPlacementGoldenVectorTests`
        // through the Swift face, and `every_pinned_placement_puts_the_window_where_swift_put_it` in
        // `rust/slopdesk-video/tests/golden_vectors.rs` through `window_placement`, which is where the
        // arithmetic lives. The Swift side keeps only what CoreGraphics defines — the standardized rect
        // extent against the raw size field — so the two replays pin the two halves they each own.

        // MARK: UDPReceiveLoopPolicy.nextBackoff / shouldRearm

        // `UDPReceiveLoopPolicy` is ONE type now, in `SlopDeskVideoProtocol`, folding the byte-identical
        // host and client twins the corpus used to have to disambiguate between.
        func udpBackoffRecord(_ n: Int) -> [String: Any] {
            ["n": n, "backoffBits": UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: n).bitPattern]
        }

        root["udpBackoff"] = [0, 1, 2, 3, 4, 5, 8, 16, 17, 100].map(udpBackoffRecord)
        root["udpRearm"] = [
            ["alive": true, "rearm": UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: true)],
            ["alive": false, "rearm": UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: false)],
        ]

        // MARK: WorkspaceStateCodec (docs/45 — the host workspace document)

        // Deterministic fixtures: every UUID is a FIXED byte pattern, never `UUID()`. The corpus must be
        // reproducible across machines and runs, and the codec's canonical emission order is exactly what
        // these vectors exist to pin.
        func wsUUID(_ byte: UInt8) -> UUID {
            UUID(uuid: (
                byte,
                byte,
                byte,
                byte,
                byte,
                byte,
                byte,
                byte,
                byte,
                byte,
                byte,
                byte,
                byte,
                byte,
                byte,
                byte,
            ))
        }

        let wsPane = wsUUID(0xA1)
        let wsTab = wsUUID(0xB2)
        let wsSplit = wsUUID(0xC3)

        func wsHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

        // A state exercising: a normal string field, a ZERO-LENGTH value (the title-retirement signal — a
        // present-and-empty entry, not an absent one), the all-zero root objectID, and an out-of-order
        // insertion that must emit in canonical order regardless.
        let wsState = HostWorkspaceState([
            WorkspaceEntry(key: WorkspaceKey(kind: 3, objectID: wsPane, field: 8), value: Data("vi .".utf8)),
            WorkspaceEntry(
                key: WorkspaceKey(kind: 0, objectID: WorkspaceObjectKind.rootObjectID, field: 2),
                value: Data("mac-studio".utf8),
            ),
            WorkspaceEntry(key: WorkspaceKey(kind: 3, objectID: wsPane, field: 3), value: Data()),
            WorkspaceEntry(key: WorkspaceKey(kind: 2, objectID: wsTab, field: 0), value: Data("slopdesk".utf8)),
        ])

        let wsBase = HostWorkspaceState([
            WorkspaceEntry(
                key: WorkspaceKey(kind: 3, objectID: wsPane, field: 3),
                value: Data("main.go - NVIM".utf8),
            ),
            WorkspaceEntry(key: WorkspaceKey(kind: 3, objectID: wsPane, field: 99), value: Data("gone".utf8)),
        ])

        // `layoutStructure` at depth 1 and at the depth cap (`SplitNode.maxDepth` = 12). Depth 13 is not a
        // vector: it does not ENCODE to anything valid, it is a DECODE rejection, pinned by
        // `WorkspaceStateCodecHostileTests`.
        func wsNested(_ depth: Int) -> WorkspaceLayoutNode {
            var node = WorkspaceLayoutNode.leaf(PaneID(raw: wsPane))
            for i in 0..<depth {
                node = .split(
                    id: SplitNodeID(raw: wsUUID(UInt8(0xD0 &+ i))),
                    axis: i.isMultiple(of: 2) ? .horizontal : .vertical,
                    children: [node],
                )
            }
            return node
        }

        root["workspaceStateCodec"] = [
            "key": wsHex(WorkspaceStateCodec.encode(key: WorkspaceKey(kind: 3, objectID: wsPane, field: 8))),
            "snapshot": wsHex(WorkspaceStateCodec.encodeSnapshot(wsState)),
            "diff": wsHex(WorkspaceStateCodec.encodeDiff(wsState.diff(from: wsBase))),
            "emptyDiff": wsHex(WorkspaceStateCodec.encodeDiff(wsState.diff(from: wsState))),
            "layoutDepth1": wsHex(WorkspaceStateCodec.encodeLayout(wsNested(1))),
            "layoutDepth11": wsHex(WorkspaceStateCodec.encodeLayout(wsNested(11))),
            "layoutDepthCap": wsHex(WorkspaceStateCodec.encodeLayout(wsNested(SplitNode.maxDepth))),
            "layoutFanout": wsHex(WorkspaceStateCodec.encodeLayout(
                .split(
                    id: SplitNodeID(raw: wsSplit),
                    axis: .vertical,
                    children: (0..<4).map { .leaf(PaneID(raw: wsUUID(UInt8(0xE0 &+ $0)))) },
                ),
            )),
            // Weights ride as a raw `bitPattern` — never a re-parsed decimal (the bit-exact float rule).
            "weightFlexThird": wsHex(WorkspaceStateCodec.encodeWeight(.flex(1.0 / 3.0))),
            "weightFixed240": wsHex(WorkspaceStateCodec.encodeWeight(.fixed(240))),
            // One `splitNode/weight` cell carries ALL of a split's child weights, in child order — a divider
            // drag moves a leading/trailing PAIR, so a per-child cell would let a diff carry half a drag.
            "weightsPair": wsHex(WorkspaceStateCodec.encodeWeights([.flex(1.0 / 3.0), .fixed(240)])),
            "weightsEmpty": wsHex(WorkspaceStateCodec.encodeWeights([])),
            // A bare UUID field value. An ABSENT optional is an absent KEY, never the all-zero UUID.
            "uuidValue": wsHex(WorkspaceStateCodec.encodeUUID(wsTab)),
            // `session/detachedPanes` — the pair is fixed-width, so here the zero UUID IS the "no origin
            // tab" sentinel.
            "detachedPanes": wsHex(WorkspaceStateCodec.encodeDetachedPanes([
                (wsPane, wsTab),
                (wsUUID(0xA2), nil),
            ])),
            // `pane/videoTarget`. `displayID` carries its own presence byte rather than overloading `0`,
            // which is a legitimate display id (the main one).
            "videoTargetDisplay": wsHex(WorkspaceStateCodec.encodeVideoTarget(
                VideoEndpoint(windowID: 0, title: "Display 1", appName: "", displayID: 0),
            )),
            "videoTargetWindow": wsHex(WorkspaceStateCodec.encodeVideoTarget(
                VideoEndpoint(windowID: 0x1234_5678, title: "main.swift", appName: "Ghostty", displayID: nil),
            )),
        ]

        // MARK: workspaceIntentArgs (docs/45 §5.4 — the verb-3 payloads)

        // The op BYTES are frozen the moment this vector exists: a renumbering decodes cleanly into the
        // wrong meaning, because every value is length-prefixed.
        root["workspaceIntentOps"] = WorkspaceIntentOp.allCases.map { ["name": "\($0)", "op": Int($0.rawValue)] }

        root["workspaceIntentArgs"] = [
            "rename": wsHex(WorkspaceIntentArgs.encode(id: wsTab, name: "slopdesk")),
            "renameEmpty": wsHex(WorkspaceIntentArgs.encode(id: wsTab, name: "")),
            "flag": wsHex(WorkspaceIntentArgs.encode(id: wsPane, flag: true)),
            "identity": wsHex(WorkspaceIntentArgs.encode(pane: PaneID(raw: wsPane))),
            // The new pane's id is PROPOSED BY THE CLIENT, so an optimistic overlay can insert the leaf
            // without waiting a round trip to learn what the host called it.
            "split": wsHex(WorkspaceIntentArgs.encode(
                target: wsPane,
                axis: .vertical,
                before: true,
                newPane: PaneID(raw: wsUUID(0xA3)),
                spawnCwd: "/Volumes/Lacie",
            )),
            "move": wsHex(WorkspaceIntentArgs.encode(
                source: PaneID(raw: wsPane),
                target: PaneID(raw: wsUUID(0xA4)),
                axis: .horizontal,
                before: false,
            )),
            "reorderTabs": wsHex(WorkspaceIntentArgs.encode(
                session: SessionID(raw: wsUUID(0xF1)),
                tabOrder: [TabID(raw: wsTab), TabID(raw: wsUUID(0xB3))],
            )),
            "spawnTab": wsHex(WorkspaceIntentArgs.encode(
                session: SessionID(raw: wsUUID(0xF1)),
                newPane: PaneID(raw: wsUUID(0xA5)),
                position: .afterCurrent,
                spawnCwd: "",
            )),
            // A new session carries the cwd it INHERITS alongside its name — without it a new window's
            // starting directory is unrepresentable and silently becomes the host default.
            "newSession": wsHex(WorkspaceIntentArgs.encode(
                newSession: SessionID(raw: wsUUID(0xF2)),
                newPane: PaneID(raw: wsUUID(0xA6)),
                name: "notes",
                spawnCwd: "/Volumes/Lacie",
            )),
            "swapPanes": wsHex(WorkspaceIntentArgs.encode(
                swap: PaneID(raw: wsPane), with: PaneID(raw: wsUUID(0xA4)),
            )),
            // A ROOT-edge dock names the container, not a target leaf — no `(source,target,axis,before)`
            // triple can express wrapping the whole tab root.
            "dockAtTabEdge": wsHex(WorkspaceIntentArgs.encode(
                dock: PaneID(raw: wsPane), tab: TabID(raw: wsTab), edge: .bottom,
            )),
            // The layout blob is the SAME grammar `tab/layoutStructure` carries, so a client can round-trip
            // the shape it is looking at straight back as an intent.
            "setTabLayout": wsHex(WorkspaceIntentArgs.encode(
                tab: TabID(raw: wsTab),
                layout: .split(
                    id: SplitNodeID(raw: wsSplit),
                    axis: .horizontal,
                    children: [.leaf(PaneID(raw: wsPane)), .leaf(PaneID(raw: wsUUID(0xA4)))],
                ),
            )),
            // The only intent that can write `pane/kind`.
            "spawnDetachedDesktop": wsHex(WorkspaceIntentArgs.encode(
                detachedPane: PaneID(raw: wsUUID(0xA7)),
                kind: .desktop,
                video: VideoEndpoint(windowID: 0, title: "Desktop", appName: "", displayID: 0),
            )),
            "spawnDetachedNoTarget": wsHex(WorkspaceIntentArgs.encode(
                detachedPane: PaneID(raw: wsUUID(0xA7)), kind: .terminal, video: nil,
            )),
            // The re-point carries the SAME `videoTarget` blob the mint does, so the display switcher and the
            // pane's birth speak one grammar. A zero length UNBINDS.
            "setPaneVideoTarget": wsHex(WorkspaceIntentArgs.encode(
                pane: PaneID(raw: wsUUID(0xA7)),
                video: VideoEndpoint(windowID: 0, title: "Desktop", appName: "", displayID: 1),
            )),
            "setPaneVideoTargetUnbound": wsHex(WorkspaceIntentArgs.encode(
                pane: PaneID(raw: wsUUID(0xA7)), video: nil,
            )),
            // The reopen index counts from the NEWEST end of the ring — Open-Quickly's Recent rows reopen
            // row N, not always the newest.
            "reopenClosedTab": wsHex(WorkspaceIntentArgs.encode(reopenLIFOIndex: 1, position: .afterCurrent)),
            // The LEADING weight only — the op is sum-preserving, so naming the trailing one too would let a
            // hostile pair sum to something the solver has to repair anyway.
            "dividerWeight": wsHex(WorkspaceIntentArgs.encode(
                split: SplitNodeID(raw: wsSplit), leadingIndex: 1, leadingWeight: 1.0 / 3.0,
            )),
        ]

        // The epoch the versioning ladder below opens its document with. It was `workspaceWireMessages`'
        // epoch too, until G.4 froze that key — see the note above `metadataCodecPayloads`.
        let wsEpoch = wsUUID(0x77)

        // MARK: workspaceDocumentVersioning (docs/60 §D.6.4 — the ~30 lines around the shared decision)

        // The one cross-language pin the golden corpus exists to carry HERE rather than in a suite: the
        // DECISION is one implementation already (`WorkspaceIntentApplier` marshals into
        // `slopdesk_wire::document::apply`, docs/55), but the VERSIONING around it is written twice —
        // `LoopbackWorkspaceDocument` on this side, `rust/slopdesk-hostserver`'s `WorkspaceDocument` on the
        // host's. The two reach the same numbers by opposite routes, and that equivalence is what nothing
        // checked after `docs/60` F.9 deleted the Swift host:
//
        //   - Swift opens at `stateNum = 0` and `install` BUMPS to 1, publishing a kind-0 snapshot;
        //   - Rust opens at `state_num = 1` and `install` does NOT bump, because `add_subscriber` is what
//     publishes and a bump there would make the first snapshot claim to be the second.
//
        // So the ladder these vectors pin starts AT the install, where both documents are at 1. The
        // pre-install number is the one value the two spell differently, by design, and no subscriber can
        // observe it — nothing is published at it on either side — so `opening` below pins the VERDICT of
        // an intent served against a document with no topology, and deliberately not a number.
//
        // What is pinned per step: the op byte, its args, the verdict, the version AFTER it, whether the
        // document is still pristine, whether the step PUBLISHED at all, and the diff those two consecutive
        // states produce. NOT the frames — the host's go out through `subscriber.rs`, which diffs against
        // each subscriber's ACKED base and coalesces; that is a per-subscriber concern the loopback has no
        // counterpart for, so diffing it would compare the wrong thing.
//
        // ⚠️ The script may name NO op that mints host-side. `document::apply` takes an `IdSource` seam for
        // the ops that need a fresh id, and this side has no such parameter: `WorkspaceIntentApplier` hands
        // the crate a pool of `UUID()`s, which is random per run. Every op below is one of the fourteen
        // `apply` dispatches that take no `ids` at all — adoptWorkspace, rename{Pane,Tab,Session},
        // reorderTabs, focusTab, setZoom, setSyncInput — so every id in play is either already in the
        // fixture or refused. `split`, `close*`, `move`, `spawn*`, `detach`, `new/closeSession`, `break`
        // and `dock` all mint and would make this corpus unreproducible; a client-proposed `newPane:` does
        // NOT make `split` safe, because the node that comes to hold the two leaves is minted host-side
        // either way.

        let wdvSession = SessionID(raw: wsUUID(0x51))
        let wdvTabOne = TabID(raw: wsUUID(0x71))
        let wdvTabTwo = TabID(raw: wsUUID(0x72))
        let wdvGhostTab = TabID(raw: wsUUID(0x7F))
        let wdvPaneOne = PaneID(raw: wsUUID(0x11))
        let wdvPaneTwo = PaneID(raw: wsUUID(0x12))

        // Two single-pane tabs in one session — enough shape that a focus change, a swap and a per-tab flag
        // each have somewhere to land, and small enough that the whole snapshot is readable in the corpus.
        // The fixture is built independently on both sides, so `installSnapshot` also pins that the two
        // languages encode the SAME topology to the same bytes before any intent runs.
        let wdvSeed = WorkspaceTopology(
            tree: TreeWorkspace(
                sessions: [Session(
                    id: wdvSession,
                    name: "slop-desk",
                    tabs: [
                        Tab(id: wdvTabOne, title: "one", root: .leaf(wdvPaneOne), activePane: wdvPaneOne),
                        Tab(id: wdvTabTwo, title: "two", root: .leaf(wdvPaneTwo), activePane: wdvPaneTwo),
                    ],
                    specs: [
                        wdvPaneOne: PaneSpec(kind: .terminal, title: "zsh"),
                        wdvPaneTwo: PaneSpec(kind: .terminal, title: "zsh"),
                    ],
                )],
                activeSessionID: wdvSession,
            ),
            hostDisplayName: "mac-studio",
        )

        let wdvBox = WorkspaceMirrorBox()
        let wdvDocument = LoopbackWorkspaceDocument(box: wdvBox, epoch: wsEpoch)

        // One step of the script, served through the REAL document so the versioning under test is
        // the shipped one and not a transcription of it. `@MainActor` because the document is a
        // main-actor class; a local `func` does not inherit the enclosing method's isolation.
        @MainActor
        func wdvStep(_ name: String, _ op: UInt8, _ args: Data) -> [String: Any] {
            let before = wdvDocument.snapshot
            let versionBefore = wdvDocument.stateNum
            let status = wdvDocument.serve(WorkspaceIntent(intentID: wsUUID(0x9E), op: op, args: args))
            let after = wdvDocument.snapshot
            return [
                "name": name,
                "op": Int(op),
                "argsHex": wsHex(args),
                "status": Int(status.rawValue),
                "stateNum": Int(wdvDocument.stateNum),
                "pristine": wdvDocument.isPristine,
                // A version moves if and ONLY if the value moved — so the corpus carries both facts and a
                // build where they come apart diverges rather than agreeing on a coincidence.
                "published": wdvDocument.stateNum != versionBefore,
                "diffHex": wsHex(WorkspaceStateCodec.encodeDiff(after.diff(from: before))),
            ]
        }

        // Served BEFORE the install: no topology at all, which is the one state where every mutation is a
        // silent no-op and has to be told apart from a refusal on the merits.
        let wdvOpening: [String: Any] = {
            let args = WorkspaceIntentArgs.encode(id: wdvTabOne.raw, name: "build")
            let versionBefore = wdvDocument.stateNum
            let status = wdvDocument.serve(WorkspaceIntent(
                intentID: wsUUID(0x9E),
                op: WorkspaceIntentOp.renameTab.rawValue,
                args: args,
            ))
            return [
                "op": Int(WorkspaceIntentOp.renameTab.rawValue),
                "argsHex": wsHex(args),
                "status": Int(status.rawValue),
                "pristine": wdvDocument.isPristine,
                // OBSERVED, not asserted: a pre-install serve that ever started publishing would emit
                // `true` here and fail the pin, where a hard-coded `false` would hide it for ever.
                "published": wdvDocument.stateNum != versionBefore,
            ]
        }()

        var wdvInstallState = HostWorkspaceState()
        wdvInstallState.write(topology: wdvSeed)
        wdvDocument.install(wdvInstallState, pristine: true)

        // Read off the DOCUMENT the instant the install lands, not off the value handed to it: the three
        // facts pinned here are the install's EFFECT, and a literal `1`/`true`/`wdvInstallState` would go on
        // agreeing with the corpus long after the effect stopped matching.
        let wdvInstallStateNum = Int(wdvDocument.stateNum)
        let wdvInstallPristine = wdvDocument.isPristine
        let wdvInstallSnapshot = wsHex(WorkspaceStateCodec.encodeSnapshot(wdvDocument.snapshot))

        let wdvSteps: [[String: Any]] = [
            // Two accepted mutations in a row, so the base/new pair the next diff is computed against is
            // never the install's.
            wdvStep(
                "renameTab",
                WorkspaceIntentOp.renameTab.rawValue,
                WorkspaceIntentArgs.encode(id: wdvTabOne.raw, name: "build"),
            ),
            wdvStep(
                "renamePane",
                WorkspaceIntentOp.renamePane.rawValue,
                WorkspaceIntentArgs.encode(id: wdvPaneOne.raw, name: "editor"),
            ),
            // ACCEPTED and changed nothing: it must consume no version and still clear pristine, because
            // `adoptWorkspace` is the one op that may not run twice and renaming a tab to its own name is
            // still taking ownership of this workspace.
            wdvStep(
                "renameTabToItsOwnName",
                WorkspaceIntentOp.renameTab.rawValue,
                WorkspaceIntentArgs.encode(id: wdvTabOne.raw, name: "build"),
            ),
            // An op byte no build knows. Refused by name rather than guessed at, and it costs no version.
            wdvStep("unknownOp", 0xFE, Data()),
            // A topology EXISTS now, so this not-found is the refusal-on-the-merits half of `opening`.
            wdvStep(
                "renameGhostTab",
                WorkspaceIntentOp.renameTab.rawValue,
                WorkspaceIntentArgs.encode(id: wdvGhostTab.raw, name: "ghost"),
            ),
            // The bootstrap, arriving after the first accepted intent already ended pristine. `stale` is
            // decided BEFORE the payload is parsed, which is why empty args are enough to pin it.
            wdvStep("adoptAfterOwnership", WorkspaceIntentOp.adoptWorkspace.rawValue, Data()),
            // Four accepted mutations in a row, each touching a different half of the topology — the tab
            // MRU, the tab order, a `session/*` cell and a `tab/zoomedPane` — so a versioning bug that only
            // shows on one shape of write has somewhere to show.
            wdvStep(
                "focusOtherTab",
                WorkspaceIntentOp.focusTab.rawValue,
                WorkspaceIntentArgs.encode(tab: wdvTabTwo),
            ),
            wdvStep(
                "reorderTabs",
                WorkspaceIntentOp.reorderTabs.rawValue,
                WorkspaceIntentArgs.encode(session: wdvSession, tabOrder: [wdvTabTwo, wdvTabOne]),
            ),
            wdvStep(
                "renameSession",
                WorkspaceIntentOp.renameSession.rawValue,
                WorkspaceIntentArgs.encode(id: wdvSession.raw, name: "notes"),
            ),
            wdvStep(
                "zoomPane",
                WorkspaceIntentOp.setZoom.rawValue,
                WorkspaceIntentArgs.encode(id: wdvPaneTwo.raw, flag: true),
            ),
            wdvStep(
                "armSyncInput",
                WorkspaceIntentOp.setSyncInput.rawValue,
                WorkspaceIntentArgs.encode(id: wdvTabOne.raw, flag: true),
            ),
            // The no-op again, this time mid-ladder rather than against the freshly installed state: an
            // idempotent set is what makes a duplicated intent free.
            wdvStep(
                "armSyncInputAgain",
                WorkspaceIntentOp.setSyncInput.rawValue,
                WorkspaceIntentArgs.encode(id: wdvTabOne.raw, flag: true),
            ),
        ]

        root["workspaceDocumentVersioning"] = [
            "opening": wdvOpening,
            "installStateNum": wdvInstallStateNum,
            "installPristine": wdvInstallPristine,
            "installSnapshot": wdvInstallSnapshot,
            "steps": wdvSteps,
            "snapshot": wsHex(WorkspaceStateCodec.encodeSnapshot(wdvDocument.snapshot)),
        ]

        return root
    }

    // swiftlint:enable function_body_length
}
