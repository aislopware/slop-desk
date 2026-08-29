import CoreGraphics // CGRect/CGPoint/CGSize for the host geometry deciders
import Foundation
import SlopDeskProtocol // WireMessage (the terminal/PTY path)
import SlopDeskVideoClient // TrendlineEstimator, OwdLateDetector, PacerDepthPolicy
import SlopDeskVideoProtocol

// LoopbackWorkspaceDocument + WorkspaceMirrorBox — the SWIFT half of the versioning ladder
// `workspaceDocumentVersioning` pins against `rust/slopdesk-hostserver`'s. Headless: the target
// holds no view framework, so naming it here does not drag the client UI into the generator.
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel // WorkspaceStateCodec (the host workspace document, docs/45)

// slopdesk-corevectors — emits a deterministic JSON corpus of golden vectors through the
// REAL `SlopDeskVideoProtocol` faces, using ONLY the public API.
//
// It is no longer a PARITY dumper: there is one implementation, in Rust, and these faces are its
// marshallers. What the corpus pins now is the pair the one-implementation rule cannot check by
// itself — the ABI and the marshalling. A field reordered in a `#[repr(C)]` record, a length
// spelled in the wrong unit, an endianness flipped on the way out: each still produces a Rust
// suite that passes and bytes on the wire that a peer of an older build cannot read. The frozen
// corpus catches exactly that class, and `slopdesk-gate golden` diffs against it rather than
// regenerating it.
//
// Determinism: floats that feed bytes use exactly-representable values; pure-numeric
// outputs (coordinate math, YCbCr, loss thresholds) are emitted as IEEE bit patterns so
// JSON float formatting can never blur the comparison. Re-running this dumper produces a
// byte-identical file (sorted keys), so the committed corpus stays clean in git.

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

func cursorUpdateRecord(shapeID: UInt16, visible: Bool, x: Double, y: Double, hx: Double, hy: Double) -> [String: Any] {
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
    return ["shapeID": shapeID, "w": w, "h": h, "hx": hx, "hy": hy, "bitmapHex": hex(bitmap), "hex": hex(s.encode())]
}

root["cursorShape"] = [
    cursorShapeRecord(shapeID: 7, w: 32.0, h: 32.0, hx: 4.0, hy: 4.0, bitmap: [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]),
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
    wg("bounds", .bounds(VideoRect(x: 1.0, y: 2.0, width: 3.0, height: 4.0)), ["x": 1.0, "y": 2.0, "w": 3.0, "h": 4.0]),
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
    ie("mouseMove", .mouseMove(normalized: VideoPoint(x: 0.25, y: 0.75), tag: 42), ["nx": 0.25, "ny": 0.75, "tag": 42]),
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
            "tag": 10,
        ],
    ),
    ie(
        "key",
        .key(keyCode: 0x35, down: true, modifiers: .init(rawValue: InputModifiers.option.rawValue), tag: 11),
        ["keyCode": 0x35, "down": true, "mods": InputModifiers.option.rawValue, "tag": 11],
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
        .hello(protocolVersion: 7, requestedWindowID: 0xDEAD_BEEF, viewport: VideoSize(width: 1280.0, height: 800.0)),
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
    vc("resizeAck", .resizeAck(captureWidth: 640, captureHeight: 480, epoch: 3), ["cw": 640, "ch": 480, "epoch": 3]),
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
        SystemDialogSummary(windowID: 9, owner: "SecurityAgent", title: "", width: 400, height: 200, isSecure: true),
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
        .helloDisplay(protocolVersion: 7, requestedDisplayID: 1, viewport: VideoSize(width: 1280.0, height: 800.0)),
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
            config: AudioStreamConfig(format: .aacEld, sampleRate: 48000, channels: 2, cookie: Data([0xDE, 0xAD])),
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
        .requestLTRRefresh(fromFrameID: 10, toFrameID: 12, lastDecodedFrameID: RecoveryMessage.noFrameDecodedSentinel),
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

// MARK: SlopDeskProtocol — terminal WireMessage.encode (byte parity)

//
// Each record carries a `kind` discriminator + the fields needed to reconstruct the
// message in Rust, plus the full encoded frame `hex`. The Rust `golden_parity` test rebuilds
// the message from the fields, re-encodes, and asserts byte-identical output. Session ids are
// FIXED byte patterns (never `UUID()`) so the corpus regenerates byte-identically.

let sidA = UUID(uuid: (
    0x11,
    0x22,
    0x33,
    0x44,
    0x55,
    0x66,
    0x77,
    0x88,
    0x99,
    0xAA,
    0xBB,
    0xCC,
    0xDD,
    0xEE,
    0xFF,
    0x00,
))
let sidB = UUID(uuid: (
    0x01,
    0x02,
    0x03,
    0x04,
    0x05,
    0x06,
    0x07,
    0x08,
    0x09,
    0x0A,
    0x0B,
    0x0C,
    0x0D,
    0x0E,
    0x0F,
    0x10,
))

// The UUID's 16 raw bytes via the public Foundation API (`dataBytes` is internal to the module).
func uuidBytes(_ u: UUID) -> [UInt8] { withUnsafeBytes(of: u.uuid) { Array($0) } }

func wmRecord(_ kind: String, _ m: WireMessage, _ fields: [String: Any]) -> [String: Any] {
    var r = fields
    r["kind"] = kind
    r["hex"] = hex(m.encode())
    return r
}

root["terminalWireMessages"] = [
    wmRecord(
        "output",
        .output(seq: 1, bytes: Data("hello".utf8)),
        ["seq": Int64(1), "bytesHex": hex(Data("hello".utf8))],
    ),
    wmRecord(
        "output",
        .output(seq: Int64.max, bytes: Data()),
        ["seq": Int64.max, "bytesHex": ""],
    ),
    wmRecord(
        "output",
        .output(seq: 42, bytes: Data([0x1B, 0x5B, 0x32, 0x4A])),
        ["seq": Int64(42), "bytesHex": hex([0x1B, 0x5B, 0x32, 0x4A])],
    ),
    wmRecord("exit", .exit(code: -1), ["code": Int(-1)]),
    wmRecord("exit", .exit(code: Int32.min), ["code": Int(Int32.min)]),
    wmRecord(
        "input",
        .input(Data([0x00, 0xFF, 0x80, 0x7F])),
        ["bytesHex": hex([0x00, 0xFF, 0x80, 0x7F])],
    ),
    wmRecord(
        "hello",
        .hello(protocolVersion: 1, sessionID: WireMessage.newSessionID, lastReceivedSeq: 0),
        [
            "protocolVersion": Int(1),
            "sessionIdHex": hex(uuidBytes(WireMessage.newSessionID)),
            "lastReceivedSeq": Int64(0),
        ],
    ),
    wmRecord(
        "hello",
        .hello(protocolVersion: UInt16.max, sessionID: sidA, lastReceivedSeq: Int64.max),
        ["protocolVersion": Int(UInt16.max), "sessionIdHex": hex(uuidBytes(sidA)), "lastReceivedSeq": Int64.max],
    ),
    wmRecord(
        "resize",
        .resize(cols: 80, rows: 24, pxWidth: 640, pxHeight: 384),
        ["cols": Int(80), "rows": Int(24), "pxWidth": Int(640), "pxHeight": Int(384)],
    ),
    wmRecord(
        "resize",
        .resize(cols: 65535, rows: 65535, pxWidth: 65535, pxHeight: 65535),
        ["cols": Int(65535), "rows": Int(65535), "pxWidth": Int(65535), "pxHeight": Int(65535)],
    ),
    wmRecord("ack", .ack(seq: -1), ["seq": Int64(-1)]),
    wmRecord("bye", .bye, [:]),
    wmRecord("ping", .ping(timestampMS: 1_749_700_000_123), ["timestampMs": UInt64(1_749_700_000_123)]),
    wmRecord("pong", .pong(timestampMS: UInt64.max), ["timestampMs": UInt64.max]),
    wmRecord(
        "helloAck",
        .helloAck(sessionID: sidB, resumeFromSeq: 9, returningClient: true),
        ["sessionIdHex": hex(uuidBytes(sidB)), "resumeFromSeq": Int64(9), "returningClient": true],
    ),
    wmRecord(
        "helloAck",
        .helloAck(sessionID: WireMessage.newSessionID, resumeFromSeq: 0, returningClient: false),
        [
            "sessionIdHex": hex(uuidBytes(WireMessage.newSessionID)),
            "resumeFromSeq": Int64(0),
            "returningClient": false,
        ],
    ),
    wmRecord("title", .title("build ✅ done 🚀 — café"), ["title": "build ✅ done 🚀 — café"]),
    wmRecord("title", .title(""), ["title": ""]),
    wmRecord("bell", .bell, [:]),
    wmRecord("commandStatus", .commandStatus(.running), ["cmd": "running"]),
    wmRecord(
        "commandStatus",
        .commandStatus(.idle(exitCode: 130, durationMS: 12000)),
        ["cmd": "idle", "hasExit": true, "exitCode": Int(130), "durationMs": UInt64(12000)],
    ),
    wmRecord(
        "commandStatus",
        .commandStatus(.idle(exitCode: Int32.min, durationMS: UInt32.max)),
        ["cmd": "idle", "hasExit": true, "exitCode": Int(Int32.min), "durationMs": UInt64(UInt32.max)],
    ),
    wmRecord(
        "commandStatus",
        .commandStatus(.idle(exitCode: nil, durationMS: 0)),
        ["cmd": "idle", "hasExit": false, "exitCode": Int(0), "durationMs": UInt64(0)],
    ),
    wmRecord(
        "notification",
        .notification(title: "CI", body: "green ✅ — đa byte"),
        ["title": "CI", "body": "green ✅ — đa byte"],
    ),
    wmRecord(
        "notification",
        .notification(title: "", body: "build done"),
        ["title": "", "body": "build done"],
    ),
    wmRecord(
        "notification",
        .notification(title: "semis;in;title", body: "and;in;body;too"),
        ["title": "semis;in;title", "body": "and;in;body;too"],
    ),
    // Claude-Code agent status (terminal CONTROL, host → client).
    // type 26 foregroundProcess: coarse process-watch path, body = UTF-8 basename.
    wmRecord("foregroundProcess", .foregroundProcess(name: "claude"), ["name": "claude"]),
    wmRecord("foregroundProcess", .foregroundProcess(name: ""), ["name": ""]),
    wmRecord(
        "foregroundProcess",
        .foregroundProcess(name: "node — café 🚀"),
        ["name": "node — café 🚀"],
    ),
    // type 27 claudeStatus: rich hook path, body = [state][kind][UInt16 labelLen][label UTF-8].
    // state = ClaudeStatus.urgency (0 none/1 idle/2 done/3 working/4 needsPermission);
    // kind = NotificationKind (0 none/1 permission/2 waitingForInput/3 other).
    wmRecord(
        "claudeStatus",
        .claudeStatus(state: 0, kind: 0, label: ""),
        ["state": Int(0), "kindByte": Int(0), "label": ""],
    ),
    wmRecord(
        "claudeStatus",
        .claudeStatus(state: 4, kind: 1, label: "Allow Bash(rm -rf)?"),
        ["state": Int(4), "kindByte": Int(1), "label": "Allow Bash(rm -rf)?"],
    ),
    wmRecord(
        "claudeStatus",
        .claudeStatus(state: 2, kind: 3, label: "Done — ✅ build green 🚀"),
        ["state": Int(2), "kindByte": Int(3), "label": "Done — ✅ build green 🚀"],
    ),
    // Secure-input echo signal (terminal CONTROL, host → client).
    // type 31 inputEcho: 1-byte body = [UInt8 enabled] (1 = canonical echo on, 0 = no-echo password prompt).
    wmRecord("inputEcho", .inputEcho(enabled: false), ["enabled": false]),
    wmRecord("inputEcho", .inputEcho(enabled: true), ["enabled": true]),
    // OSC 9;4 taskbar progress (terminal CONTROL, host → client).
    // type 32 progress: 2-byte body = [UInt8 state][UInt8 percent].
    // state = ProgressState (0 clear / 1 in-progress / 2 error / 3 indeterminate); percent 0…100.
    wmRecord("progress", .progress(state: 1, percent: 40), ["state": Int(1), "percent": Int(40)]),
    wmRecord("progress", .progress(state: 3, percent: 0), ["state": Int(3), "percent": Int(0)]),
    wmRecord("progress", .progress(state: 2, percent: 80), ["state": Int(2), "percent": Int(80)]),
    wmRecord("progress", .progress(state: 0, percent: 0), ["state": Int(0), "percent": Int(0)]),
    // OSC 7 cwd edge (terminal CONTROL, host → client).
    // type 33 cwd: UTF-8 path body, same string shape as title.
    wmRecord("cwd", .cwd("/Users/me/project dir"), ["path": "/Users/me/project dir"]),
    // Host-computed By-Project sidebar key (terminal CONTROL, host → client).
    // type 34 projectKey: UTF-8 path body (git toplevel else cwd), same string shape as title/cwd.
    wmRecord("project_key", .projectKey("/Users/me/project dir"), ["path": "/Users/me/project dir"]),
    // Host-pushed project git summary (terminal CONTROL, host → client).
    // type 35 projectGitStatus: [UInt16 BE rootLen][root][UInt16 BE branchLen][branch]
    //   [Int32 BE ahead][Int32 BE behind][Int32 BE stash]
    //   [UInt32 BE staged][UInt32 BE modified][UInt32 BE untracked][UInt32 BE conflicted][UInt32 BE changed].
    wmRecord(
        "project_git_status",
        .projectGitStatus(WireMessage.ProjectGitStatus(
            repoRoot: "/Users/me/project dir", branch: "feature/tiếng-việt", ahead: 2, behind: 1,
            stashCount: 3, staged: 4, modified: 5, untracked: 6, conflicted: 7, changedCount: 15,
        )),
        [
            "repoRoot": "/Users/me/project dir",
            "branch": "feature/tiếng-việt",
            "ahead": Int(2), "behind": Int(1), "stash": Int(3),
            "staged": Int(4), "modified": Int(5), "untracked": Int(6), "conflicted": Int(7),
            "changed": Int(15),
        ],
    ),
    wmRecord(
        "project_git_status",
        .projectGitStatus(WireMessage.ProjectGitStatus(
            repoRoot: "/r", branch: "", ahead: 0, behind: 0, stashCount: 0,
            staged: 0, modified: 0, untracked: 0, conflicted: 0, changedCount: 0,
        )),
        [
            "repoRoot": "/r", "branch": "",
            "ahead": Int(0), "behind": Int(0), "stash": Int(0),
            "staged": Int(0), "modified": Int(0), "untracked": Int(0), "conflicted": Int(0),
            "changed": Int(0),
        ],
    ),
    // Host-latched agent-session intent (terminal CONTROL, host → client).
    // type 36 agentSessionIntent: UTF-8 intent body, same string shape as title/cwd; "" = cleared.
    wmRecord(
        "agent_session_intent",
        .agentSessionIntent("fix the flaky CI test — tiếng Việt"),
        ["intent": "fix the flaky CI test — tiếng Việt"],
    ),
    wmRecord("agent_session_intent", .agentSessionIntent(""), ["intent": ""]),
]

// Warp-style "Blocks" wire messages (terminal CONTROL).
// type 15 requestBlockOutput (c→h): body = [UInt32 index].
// type 28 commandBlock (h→c): metadata only = [UInt32 index][UInt8 hasExit][Int32 BE exit]
//   [UInt8 hasDuration][UInt32 BE duration][UInt8 complete][UInt32 BE outputLen]
//   [UInt32 BE promptOrdinal][UInt16 BE cmdLen][cmd].
// type 29 blockOutput (h→c): [UInt32 index][UInt32 BE outputLen][output bytes].
root["blocksWireMessages"] = [
    wmRecord("requestBlockOutput", .requestBlockOutput(index: 0), ["index": UInt32(0)]),
    wmRecord("requestBlockOutput", .requestBlockOutput(index: 0x0102_0304), ["index": UInt32(0x0102_0304)]),
    wmRecord("requestBlockOutput", .requestBlockOutput(index: UInt32.max), ["index": UInt32.max]),
    wmRecord(
        "commandBlock",
        .commandBlock(
            index: 7, exitCode: 0, durationMS: 1250, complete: true, outputLen: 3, commandText: "ls",
            promptOrdinal: 8,
        ),
        [
            "index": UInt32(7),
            "hasExit": true,
            "exitCode": Int(0),
            "hasDuration": true,
            "durationMs": UInt64(1250),
            "complete": true,
            "outputLen": UInt64(3),
            "commandText": "ls",
            "promptOrdinal": UInt32(8),
        ],
    ),
    wmRecord(
        "commandBlock",
        .commandBlock(
            index: 0, exitCode: nil, durationMS: nil, complete: false, outputLen: 0, commandText: "",
            promptOrdinal: 0,
        ),
        [
            "index": UInt32(0),
            "hasExit": false,
            "exitCode": Int(0),
            "hasDuration": false,
            "durationMs": UInt64(0),
            "complete": false,
            "outputLen": UInt64(0),
            "commandText": "",
            "promptOrdinal": UInt32(0),
        ],
    ),
    wmRecord(
        "commandBlock",
        .commandBlock(
            index: 42,
            exitCode: Int32.min,
            durationMS: UInt32.max,
            complete: true,
            outputLen: 262_144,
            commandText: "grep · 文字 🚀",
            promptOrdinal: UInt32.max,
        ),
        [
            "index": UInt32(42),
            "hasExit": true,
            "exitCode": Int(Int32.min),
            "hasDuration": true,
            "durationMs": UInt64(UInt32.max),
            "complete": true,
            "outputLen": UInt64(262_144),
            "commandText": "grep · 文字 🚀",
            "promptOrdinal": UInt32.max,
        ],
    ),
    wmRecord(
        "blockOutput",
        .blockOutput(index: 5, output: Data([0xAA, 0xBB, 0xCC])),
        ["index": UInt32(5), "outputHex": hex([0xAA, 0xBB, 0xCC])],
    ),
    wmRecord(
        "blockOutput",
        .blockOutput(index: 0, output: Data()),
        ["index": UInt32(0), "outputHex": ""],
    ),
    wmRecord(
        "blockOutput",
        .blockOutput(index: 42, output: Data([0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x00, 0xFF])),
        ["index": UInt32(42), "outputHex": hex([0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x00, 0xFF])],
    ),
]

// Host metadata RPC envelope (terminal CONTROL). ONE generic request/response pair carrying a
// verb/status byte + a client-chosen requestID + an opaque length-prefixed payload (the per-verb
// MetadataCodec rides inside, pinned by its OWN samples below).
// type 16 metadataRequest (c→h): body = [UInt32 BE requestID][UInt8 verb][UInt32 BE payloadLen][payload].
// type 30 metadataResponse (h→c): body = [UInt32 BE requestID][UInt8 status][UInt32 BE payloadLen][payload].
// verb / status carry the RAW byte (forward-tolerant of an unknown value).
let metaDiffPath = Data("Sources/main.swift".utf8)
let metaUnicodePayload = Data("héllo · 文字 🚀".utf8)
root["metadataWireMessages"] = [
    // request: empty payload (pane-scoped verb), min requestID.
    wmRecord(
        "metadataRequest",
        .metadataRequest(requestID: 0, verb: 1, payload: Data()),
        ["requestId": UInt32(0), "verb": Int(1), "payloadHex": ""],
    ),
    // request: parameterized verb (gitDiff) with a UTF-8 path payload, mid requestID.
    wmRecord(
        "metadataRequest",
        .metadataRequest(requestID: 0x0102_0304, verb: 5, payload: metaDiffPath),
        ["requestId": UInt32(0x0102_0304), "verb": Int(5), "payloadHex": hex(metaDiffPath)],
    ),
    // request: unknown future verb byte + arbitrary bytes, max requestID (forward-tolerance pin).
    wmRecord(
        "metadataRequest",
        .metadataRequest(requestID: UInt32.max, verb: 200, payload: Data([0x00, 0xFF, 0x80, 0x7F])),
        ["requestId": UInt32.max, "verb": Int(200), "payloadHex": hex([0x00, 0xFF, 0x80, 0x7F])],
    ),
    // request: openPath — a SIDE-EFFECTING verb (9) carrying a raw UTF-8 ABSOLUTE host path
    // (revealPath = 10 is byte-identical save the verb byte; one sample pins the envelope shape).
    wmRecord(
        "metadataRequest",
        .metadataRequest(requestID: 0x0A0B_0C0D, verb: 9, payload: Data("/Users/me/project/main.swift".utf8)),
        [
            "requestId": UInt32(0x0A0B_0C0D),
            "verb": Int(9),
            "payloadHex": hex(Data("/Users/me/project/main.swift".utf8)),
        ],
    ),
    // request: installAgentHooks — a SIDE-EFFECTING agent verb (11) with an EMPTY payload
    // (uninstallAgentHooks = 12 / agentHookStatus = 13 are byte-identical save the verb byte; one sample
    // pins the agent-hooks verb family on the wire, mirroring the single openPath sample above for 9/10).
    wmRecord(
        "metadataRequest",
        .metadataRequest(requestID: 0x0B0C_0D0E, verb: 11, payload: Data()),
        ["requestId": UInt32(0x0B0C_0D0E), "verb": Int(11), "payloadHex": ""],
    ),
    // response: ok, empty payload (e.g. an empty list / cleared field).
    wmRecord(
        "metadataResponse",
        .metadataResponse(requestID: 0, status: 0, payload: Data()),
        ["requestId": UInt32(0), "status": Int(0), "payloadHex": ""],
    ),
    // response: ok with a raw opaque payload (e.g. cwd / gitDiff bytes).
    wmRecord(
        "metadataResponse",
        .metadataResponse(requestID: 7, status: 0, payload: Data([0xAA, 0xBB, 0xCC])),
        ["requestId": UInt32(7), "status": Int(0), "payloadHex": hex([0xAA, 0xBB, 0xCC])],
    ),
    // response: unsupportedVerb, empty payload (host did not recognize the verb).
    wmRecord(
        "metadataResponse",
        .metadataResponse(requestID: 42, status: 3, payload: Data()),
        ["requestId": UInt32(42), "status": Int(3), "payloadHex": ""],
    ),
    // response: unknown future status byte + a multi-byte UTF-8 payload (forward-tolerance pin).
    wmRecord(
        "metadataResponse",
        .metadataResponse(requestID: 99, status: 200, payload: metaUnicodePayload),
        ["requestId": UInt32(99), "status": Int(200), "payloadHex": hex(metaUnicodePayload)],
    ),
    // response: agentHookStatus — status .ok + a flag payload (the only agent-hooks reply
    // carrying one). This record pins the metadataResponse ENVELOPE around an opaque 1-byte payload and
    // stays FROZEN as-is even though the live verb-13 payload is the 2-byte [installed][listenerActive]
    // flags (see docs/20) — the payload is opaque to the envelope codec, so the envelope bytes pinned
    // here are unaffected.
    wmRecord(
        "metadataResponse",
        .metadataResponse(requestID: 0x0B0C_0D0E, status: 0, payload: Data([0x01])),
        ["requestId": UInt32(0x0B0C_0D0E), "status": Int(0), "payloadHex": hex([0x01])],
    ),
]

// The per-verb MetadataCodec payload encodings that ride INSIDE the opaque metadataResponse
// payload. These PIN the exact bytes of every structured list codec (manual BE, [UInt16 count]-prefixed,
// length-prefixed UTF-8 strings) so a refactor cannot silently shift a field. The cwd / gitDiff /
// readAgentSession verbs carry RAW bytes (no nested codec) and so have no sample here.
func mcRecord(_ kind: String, _ hexStr: String, _ note: String) -> [String: Any] {
    ["kind": kind, "hex": hexStr, "note": note]
}

root["metadataCodecPayloads"] = [
    // ProcessList ([UInt16 count] then [UInt32 pid][UInt32 uptimeSec][UInt16 nameLen][name]).
    mcRecord("processList", hex(MetadataCodec.encodeProcessList([])), "empty"),
    mcRecord(
        "processList",
        hex(MetadataCodec.encodeProcessList([
            .init(pid: 0x0102_0304, uptimeSec: 42, name: "-zsh"),
            .init(pid: 0xDEAD_BEEF, uptimeSec: 3600, name: "claude 🚀"),
        ])),
        "two entries; unicode name",
    ),
    // PortList ([UInt16 count] then [UInt16 port][UInt8 proto][UInt16 nameLen][procName]).
    mcRecord("portList", hex(MetadataCodec.encodePortList([])), "empty (No listening ports)"),
    mcRecord(
        "portList",
        hex(MetadataCodec.encodePortList([
            .init(port: 8080, proto: 0, procName: "node"),
            .init(port: 53, proto: 1, procName: "mDNSResponder"),
        ])),
        "tcp + udp entries",
    ),
    // DirListing ([UInt16 count] then [UInt8 isDir][UInt16 nameLen][leafName]).
    mcRecord(
        "dirListing",
        hex(MetadataCodec.encodeDirListing([
            .init(isDir: true, name: "Sources"),
            .init(isDir: false, name: "README.md"),
            .init(isDir: true, name: "docs"),
        ])),
        "dir/file leaf names",
    ),
    // GitStatus ([UInt8 hasRepo]; if repo: branch, remote, repoRoot, [Int32 ahead][Int32 behind][Int32 stash], files).
    mcRecord("gitStatus", hex(MetadataCodec.encodeGitStatus(.noRepo)), "no repo (single 0x00 byte)"),
    mcRecord(
        "gitStatus",
        hex(MetadataCodec.encodeGitStatus(.init(
            hasRepo: true,
            branch: "main",
            remoteURL: "git@github.com:aislopware/slop-desk.git",
            repoRoot: "/Users/me/slopdesk",
            ahead: 3,
            behind: 0,
            stashCount: 2,
            files: [
                .init(statusCode: 0x12, path: "Sources/main.swift"),
                .init(statusCode: 0xFF, path: "docs/x.md"),
            ],
        ))),
        "repo: branch+remote+repoRoot+ahead/behind+stash+files",
    ),
    // AgentSessionList ([UInt16 count] then kind, id, title, cwd, [Int64 mtimeMS]).
    mcRecord(
        "agentSessionList",
        hex(MetadataCodec.encodeAgentSessionList([
            .init(
                agentKindByte: 0,
                id: "9f3c",
                title: "Fix the wire codec",
                cwd: "/Users/me/project",
                mtimeMS: 1_749_700_000_123,
            ),
            .init(agentKindByte: 1, id: "c42", title: "", cwd: "/tmp/x", mtimeMS: -1),
        ])),
        "claude + codex sessions",
    ),
    // HostVitals ([UInt8 cpu%][UInt8 mem%][UInt8 pressure][UInt32 disk free MiB]) — fixed 7 bytes,
    // no count prefix. `UInt32.max` in the disk field is the "host could not read it" sentinel.
    mcRecord(
        "hostVitals",
        hex(MetadataCodec.encodeHostVitals(
            .init(cpuPercent: 34, memoryPercent: 61, pressure: .normal, diskFreeMiB: 245_760),
        )),
        "cpu/mem percents, pressure normal, 240 GiB free",
    ),
    mcRecord(
        "hostVitals",
        hex(MetadataCodec.encodeHostVitals(
            .init(cpuPercent: 250, memoryPercent: 100, pressure: .critical, diskFreeMiB: nil),
        )),
        "percent clamped at the source; pressure critical; disk unreadable sentinel",
    ),
]

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

// MARK: workspaceWireMessages (docs/45 §5.2 — types 17 / 37)

// The ENVELOPE only. `SlopDeskProtocol` never parses workspace state, so these vectors pin framing:
// the hoisted 33-byte header, the length-prefix discipline, and the extreme state numbers that share
// the `output.seq` idiom.
let wsEpoch = wsUUID(0x77)

func wsWireRecord(_ name: String, _ message: WireMessage) -> [String: Any] {
    ["name": name, "hex": wsHex(message.encode()), "wireByteCount": message.wireByteCount]
}

root["workspaceWireMessages"] = [
    wsWireRecord("requestEmpty", .workspaceRequest(requestSeq: 0, verb: 0, payload: Data())),
    wsWireRecord("requestMaxSeq", .workspaceRequest(requestSeq: UInt32.max, verb: 3, payload: Data([0x01, 0x02]))),
    wsWireRecord("requestUnknownVerb", .workspaceRequest(requestSeq: 7, verb: 250, payload: Data())),
    wsWireRecord("eventSnapshot", .workspaceEvent(
        kind: 0, epoch: wsEpoch, baseStateNum: 0, newStateNum: 42, payload: Data("snap".utf8),
    )),
    wsWireRecord("eventDiff", .workspaceEvent(
        kind: 1, epoch: wsEpoch, baseStateNum: 41, newStateNum: 42, payload: Data("diff".utf8),
    )),
    wsWireRecord("eventPresence", .workspaceEvent(
        kind: 2, epoch: wsEpoch, baseStateNum: 0, newStateNum: 0, payload: Data([0x00, 0x00]),
    )),
    wsWireRecord("eventIntentResult", .workspaceEvent(
        kind: 3, epoch: wsEpoch, baseStateNum: 0, newStateNum: 42, payload: Data([0xAA]),
    )),
    wsWireRecord("eventReset", .workspaceEvent(
        kind: 4, epoch: wsEpoch, baseStateNum: 0, newStateNum: 0, payload: Data(),
    )),
    // Int64 extremes: `stateNum` shares the seq idiom, and a sign error here surfaces only after
    // months of uptime.
    wsWireRecord("eventExtremeStateNums", .workspaceEvent(
        kind: 1, epoch: wsEpoch, baseStateNum: Int64.min, newStateNum: Int64.max, payload: Data(),
    )),
    wsWireRecord("eventUnknownKind", .workspaceEvent(
        kind: 250, epoch: wsEpoch, baseStateNum: 0, newStateNum: 0, payload: Data(),
    )),
]

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

/// One step of the script, served through the REAL document so the versioning under test is the
/// shipped one and not a transcription of it.
///
/// `@MainActor` because a `func` in top-level code is nonisolated even though the statements around
/// it are not, and the document is a main-actor class.
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

// MARK: emit

let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
