import CoreGraphics // CGRect/CGPoint/CGSize for the host geometry deciders
import Foundation
import SlopDeskProtocol // WireMessage, MuxEnvelopeCodec (terminal/PTY path)
import SlopDeskVideoClient // TrendlineEstimator, OwdLateDetector, PacerDepthPolicy
import SlopDeskVideoHost // NetworkEstimate, FPSGovernor (pure controllers)

// `UDPReceiveLoopPolicy` is a byte-identical twin exported by BOTH the host and client modules. The
// host module also exports a TYPE named `SlopDeskVideoHost`, so `SlopDeskVideoHost.UDPReceiveLoopPolicy`
// resolves to that type, not the module — qualification is impossible; this scoped `import enum` is the
// only disambiguator to the host copy (pairs with the wholesale import → duplicate_imports, silenced).
// swiftlint:disable:next duplicate_imports
import enum SlopDeskVideoHost.UDPReceiveLoopPolicy // host/client twin → host copy
import SlopDeskVideoProtocol

// slopdesk-corevectors — emits a deterministic JSON corpus of golden vectors from the
// REAL Swift `SlopDeskVideoProtocol` codecs, using ONLY the public API. The Rust
// `slopdesk-core` crate's `golden_parity` integration test replays this corpus and
// asserts byte-/bit-identical output, proving the two implementations agree on the wire.
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

// MARK: NetworkEstimate — EWMA RTT / min-RTT re-baseline / loss EWMA.

do {
    var est = NetworkEstimate()
    // (rttMillis | nil, framesReceived, unrecovered, owdJitterMicros)
    let folds: [(Int?, UInt32, UInt32, UInt32)] = [
        (50, 1000, 0, 100), (50, 1000, 0, 200), (500, 1000, 50, 9000), (80, 1000, 0, 100),
        (nil, 1000, 0, 100), (6, 3, 1, 500), (300, 1000, 0, 100), (40, 1000, 0, 100),
        (60, 1000, 0, 100), (120, 1000, 0, 100), (5, 1000, 1000, 100), (50, 1000, 0, 100),
    ]
    var steps: [[String: Any]] = []
    for (rtt, frames, unrec, jit) in folds {
        est.fold(rttMillis: rtt, framesReceived: frames, unrecovered: unrec, owdJitterMicros: jit)
        steps.append([
            "rtt": rtt.map { $0 as Any } ?? NSNull(), "frames": frames, "unrec": unrec, "jitter": jit,
            "smoothedBits": est.smoothedRTTMillis.bitPattern,
            "minBits": est.minRTTMillis.bitPattern,
            "lossRateBits": est.lossRate.bitPattern,
            "lastLossBits": est.lastLossSample.bitPattern,
        ])
    }
    root["networkEstimateFold"] = steps
}

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

// MARK: FPSGovernor — bytes-per-frame EWMA fold.

do {
    var gov = FPSGovernor(baseFps: 60)
    let sizes: [Int] = [10000, 20000, 15000, 30000, 12000, 18000, 22000, 9000, 40000, 11000]
    for s in sizes { gov.noteEncodedFrame(bytes: s, isAnchor: false) }
    gov.noteEncodedFrame(bytes: 500_000, isAnchor: true) // anchor excluded
    root["fpsGovernorEwma"] = ["bytesEwmaBits": gov.bytesPerFrameEWMA.bitPattern]
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
]

// MARK: SlopDeskProtocol — MuxEnvelopeCodec.encode (byte parity)

func muxRecord(_ kind: String, _ f: MuxFrame, _ fields: [String: Any]) -> [String: Any] {
    var r = fields
    r["kind"] = kind
    r["hex"] = hex(MuxEnvelopeCodec.encode(f))
    return r
}

root["muxEnvelopes"] = [
    muxRecord(
        "channelOpen",
        .channelOpen(
            channelID: 1,
            sessionID: WireMessage.newSessionID,
            lastReceivedSeq: 0,
            channelClass: 0,
            initialCwd: nil,
        ),
        [
            "channelId": UInt32(1),
            "sessionIdHex": hex(uuidBytes(WireMessage.newSessionID)),
            "lastReceivedSeq": Int64(0),
            "channelClass": Int(0),
        ],
    ),
    muxRecord(
        "channelOpen",
        .channelOpen(channelID: UInt32.max, sessionID: sidA, lastReceivedSeq: -1, channelClass: 255, initialCwd: nil),
        [
            "channelId": UInt32.max,
            "sessionIdHex": hex(uuidBytes(sidA)),
            "lastReceivedSeq": Int64(-1),
            "channelClass": Int(255),
        ],
    ),
    muxRecord(
        "channelOpenAck",
        .channelOpenAck(channelID: 3, accepted: true),
        ["channelId": UInt32(3), "accepted": true],
    ),
    muxRecord(
        "channelOpenAck",
        .channelOpenAck(channelID: 5, accepted: false),
        ["channelId": UInt32(5), "accepted": false],
    ),
    muxRecord(
        "channelData",
        .channelData(channelID: 9, payload: WireMessage.output(seq: 42, bytes: Data("vt ✅".utf8)).encode()),
        ["channelId": UInt32(9), "payloadHex": hex(WireMessage.output(seq: 42, bytes: Data("vt ✅".utf8)).encode())],
    ),
    muxRecord(
        "channelData",
        .channelData(channelID: 4, payload: Data()),
        ["channelId": UInt32(4), "payloadHex": ""],
    ),
    muxRecord("channelClose", .channelClose(channelID: 6), ["channelId": UInt32(6)]),
    muxRecord(
        "windowAdjust",
        .windowAdjust(channelID: 7, bytesToAdd: 262_144),
        ["channelId": UInt32(7), "bytesToAdd": UInt64(262_144)],
    ),
    muxRecord(
        "windowAdjust",
        .windowAdjust(channelID: 1, bytesToAdd: UInt32.max),
        ["channelId": UInt32(1), "bytesToAdd": UInt64(UInt32.max)],
    ),
]

// MARK: - Host pure-geometry deciders (FLOAT-determinism parity)

//
// The host capture-region / virtual-display / window-placement / system-dialog / size-negotiation
// math is CoreGraphics-faithful (standardized width/height, CGRectNull) and float-heavy. These
// vectors drive each pure decider through diverse + edge inputs and dump every float as an IEEE bit
// pattern (inputs AND outputs), so JSON float formatting can never blur the comparison and the Rust
// port is proven to reproduce Swift's arithmetic operation-for-operation. CGRectNull (∞,∞,0,0) is
// dumped as its raw component bits and matched against Rust `VideoRect::NULL`.

/// The four IEEE bit patterns of a `CGRect`'s raw components, under `<prefix>X/Y/W/H` keys.
func rectBits(_ prefix: String, _ r: CGRect) -> [String: Any] {
    [
        prefix + "X": r.origin.x.bitPattern,
        prefix + "Y": r.origin.y.bitPattern,
        prefix + "W": r.size.width.bitPattern,
        prefix + "H": r.size.height.bitPattern,
    ]
}

// NOTE: captureUnion / captureRetarget vectors are FROZEN in golden_vectors.json. Their logic
// lives solely in the Rust core (slopdesk_core::capture_region, reached via the C ABI);
// golden_parity validates the core against the frozen corpus, so no Swift dumper section is needed.

// NOTE: virtualDisplayGeometry / vdOriginToRight / vdChipPixelLimit / vdRefreshRates vectors are
// FROZEN in golden_vectors.json. Their logic lives solely in the Rust core
// (slopdesk_core::virtual_display_geometry, reached via the C ABI); golden_parity validates the
// core against the frozen corpus, so no Swift dumper section is needed here.

// NOTE: windowPlacement / windowFits vectors are FROZEN in golden_vectors.json. Their logic
// lives solely in the Rust core (`slopdesk_core::window_placement`, reached via the C ABI); the
// `golden_parity` test still validates the core against the frozen corpus, so no Swift dumper
// section is needed here.

// MARK: SystemDialogDetector.classify / detect

func sdWindowDict(_ w: SystemDialogDetector.WindowSnapshot) -> [String: Any] {
    [
        "windowID": w.windowID,
        "ownerName": w.ownerName,
        "bundleID": w.bundleID,
        "isOnScreen": w.isOnScreen,
        "title": w.title,
        "fWBits": w.frame.size.width.bitPattern,
        "fHBits": w.frame.size.height.bitPattern,
    ]
}

func sdSnap(
    _ id: UInt32,
    _ owner: String,
    _ bundle: String,
    _ on: Bool,
    _ w: Double,
    _ h: Double,
    _ title: String,
) -> SystemDialogDetector.WindowSnapshot {
    .init(
        windowID: id,
        ownerName: owner,
        bundleID: bundle,
        isOnScreen: on,
        title: title,
        frame: CGRect(x: 830, y: 201, width: w, height: h),
    )
}

func sdDialogDict(_ d: SystemDialogDetector.Dialog) -> [String: Any] {
    [
        "windowID": d.windowID,
        "owner": d.owner,
        "title": d.title,
        "width": d.width,
        "height": d.height,
        "isSecure": d.isSecure,
    ]
}

func sdClassifyRecord(_ name: String, _ w: SystemDialogDetector.WindowSnapshot, minSize: Int) -> [String: Any] {
    let d = SystemDialogDetector.classify(w, minSize: minSize)
    return [
        "name": name,
        "minSize": minSize,
        "window": sdWindowDict(w),
        "dialog": d.map(sdDialogDict) ?? NSNull(),
    ]
}

let sdMin = SystemDialogDetector.minSize // 60
root["systemDialogClassify"] = [
    sdClassifyRecord(
        "securityAgentByBundle",
        sdSnap(1966, "SecurityAgent", "com.apple.SecurityAgent", true, 260, 312, ""),
        minSize: sdMin,
    ),
    sdClassifyRecord("securityAgentByOwner", sdSnap(8, "SecurityAgent", "", true, 260, 312, ""), minSize: sdMin),
    sdClassifyRecord("coreauthd", sdSnap(7, "coreauthd", "com.apple.coreauthd", true, 260, 312, ""), minSize: sdMin),
    sdClassifyRecord(
        "regularApp",
        sdSnap(1783, "Google Chrome", "com.google.Chrome", true, 700, 500, ""),
        minSize: sdMin,
    ),
    sdClassifyRecord(
        "offscreen",
        sdSnap(1967, "SecurityAgent", "com.apple.SecurityAgent", false, 500, 500, ""),
        minSize: sdMin,
    ),
    sdClassifyRecord(
        "roundingPasses595",
        sdSnap(11, "SecurityAgent", "com.apple.SecurityAgent", true, 59.5, 59.5, ""),
        minSize: sdMin,
    ),
    sdClassifyRecord(
        "roundingFails594",
        sdSnap(12, "SecurityAgent", "com.apple.SecurityAgent", true, 59.4, 200, ""),
        minSize: sdMin,
    ),
    sdClassifyRecord(
        "roundingUp605",
        sdSnap(14, "SecurityAgent", "com.apple.SecurityAgent", true, 60.5, 60.5, ""),
        minSize: sdMin,
    ),
    sdClassifyRecord(
        "negativeSizeStandardizes",
        sdSnap(16, "SecurityAgent", "com.apple.SecurityAgent", true, -400, -200, ""),
        minSize: sdMin,
    ),
    sdClassifyRecord(
        "emptyOwnerFallsBackToBundle",
        sdSnap(18, "", "com.apple.SecurityAgent", true, 400, 200, ""),
        minSize: sdMin,
    ),
    sdClassifyRecord(
        "customMinRejects",
        sdSnap(22, "SecurityAgent", "com.apple.SecurityAgent", true, 80, 80, ""),
        minSize: 100,
    ),
    sdClassifyRecord(
        "customMinAccepts",
        sdSnap(23, "SecurityAgent", "com.apple.SecurityAgent", true, 120, 120, ""),
        minSize: 100,
    ),
    sdClassifyRecord(
        "unicodeTitle",
        sdSnap(26, "SecurityAgent", "com.apple.SecurityAgent", true, 400, 200, "Authenticate · 認証 🔐"),
        minSize: sdMin,
    ),
    sdClassifyRecord("bothIdentifiersEmptyRejected", sdSnap(21, "", "", true, 400, 200, ""), minSize: sdMin),
]

func sdDetectRecord(_ name: String, _ windows: [SystemDialogDetector.WindowSnapshot], minSize: Int) -> [String: Any] {
    [
        "name": name,
        "minSize": minSize,
        "windows": windows.map(sdWindowDict),
        "dialogs": SystemDialogDetector.detect(windows, minSize: minSize).map(sdDialogDict),
    ]
}

root["systemDialogDetect"] = [
    sdDetectRecord("mixed", [
        sdSnap(1, "Google Chrome", "com.google.Chrome", true, 700, 500, ""),
        sdSnap(1966, "SecurityAgent", "com.apple.SecurityAgent", true, 260, 312, ""),
        sdSnap(1967, "SecurityAgent", "com.apple.SecurityAgent", false, 500, 500, ""),
        sdSnap(3, "Finder", "com.apple.finder", true, 900, 600, ""),
    ], minSize: sdMin),
    sdDetectRecord("empty", [], minSize: sdMin),
    sdDetectRecord("allRejected", [
        sdSnap(1, "Google Chrome", "com.google.Chrome", true, 700, 500, ""),
        sdSnap(2, "Finder", "com.apple.finder", true, 900, 600, ""),
    ], minSize: sdMin),
    sdDetectRecord("multipleAccepts", [
        sdSnap(30, "SecurityAgent", "com.apple.SecurityAgent", true, 400, 200, ""),
        sdSnap(31, "Google Chrome", "com.google.Chrome", true, 800, 600, ""),
        sdSnap(32, "SecurityAgent", "com.apple.SecurityAgent", true, 50, 50, ""),
        sdSnap(33, "coreauthd", "", true, 300, 150, ""),
    ], minSize: sdMin),
]

// MARK: SizeNegotiation.clamp / isStaleEpoch

func sizeClampRecord(_ name: String, desired: VideoSize, minS: VideoSize, maxS: VideoSize) -> [String: Any] {
    let (w, h) = SizeNegotiation.clamp(desired: desired, min: minS, max: maxS)
    return [
        "name": name,
        "desWBits": desired.width.bitPattern,
        "desHBits": desired.height.bitPattern,
        "minWBits": minS.width.bitPattern,
        "minHBits": minS.height.bitPattern,
        "maxWBits": maxS.width.bitPattern,
        "maxHBits": maxS.height.bitPattern,
        "w": w,
        "h": h,
    ]
}

let sgMin = VideoSize(width: 320, height: 240)
let sgMax = VideoSize(width: 3840, height: 2160)
root["sizeNegotiationClamp"] = [
    sizeClampRecord("inside", desired: VideoSize(width: 1280, height: 800), minS: sgMin, maxS: sgMax),
    sizeClampRecord("clampLow", desired: VideoSize(width: 100, height: 50), minS: sgMin, maxS: sgMax),
    sizeClampRecord("clampHigh", desired: VideoSize(width: 9999, height: 9999), minS: sgMin, maxS: sgMax),
    sizeClampRecord("swappedPolicy", desired: VideoSize(width: 1280, height: 800), minS: sgMax, maxS: sgMin),
    sizeClampRecord(
        "huge",
        desired: VideoSize(width: 1_000_000, height: 1_000_000),
        minS: sgMin,
        maxS: VideoSize(width: 1_000_000, height: 1_000_000),
    ),
    sizeClampRecord("roundHalfUp", desired: VideoSize(width: 1280.5, height: 800.5), minS: sgMin, maxS: sgMax),
    sizeClampRecord("roundDown", desired: VideoSize(width: 1280.4, height: 800.4), minS: sgMin, maxS: sgMax),
    sizeClampRecord("nanInf", desired: VideoSize(width: Double.nan, height: Double.infinity), minS: sgMin, maxS: sgMax),
    sizeClampRecord("negative", desired: VideoSize(width: -500, height: -1), minS: sgMin, maxS: sgMax),
    sizeClampRecord(
        "minEqMax",
        desired: VideoSize(width: 10, height: 9999),
        minS: VideoSize(width: 640, height: 480),
        maxS: VideoSize(width: 640, height: 480),
    ),
    sizeClampRecord(
        "zeroMin",
        desired: VideoSize(width: 0, height: 0),
        minS: VideoSize(width: 0, height: 0),
        maxS: sgMax,
    ),
    sizeClampRecord(
        "negativeMin",
        desired: VideoSize(width: 0, height: 0),
        minS: VideoSize(width: -100, height: -100),
        maxS: sgMax,
    ),
]

func epochRecord(_ epoch: UInt32, _ lastApplied: UInt32) -> [String: Any] {
    ["epoch": epoch, "lastApplied": lastApplied, "stale": SizeNegotiation.isStaleEpoch(epoch, lastApplied: lastApplied)]
}

root["sizeNegotiationEpoch"] = [
    epochRecord(5, 5),
    epochRecord(3, 5),
    epochRecord(0, 5),
    epochRecord(6, 5),
    epochRecord(UInt32.max, 5),
    epochRecord(1, 0),
    epochRecord(0, 0),
]

// MARK: StaticIDRDecider (drive sequence → per-check decision)

func staticIdrScenario(
    _ name: String,
    heartbeat: Double,
    quietWindow: Double,
    ops: [(op: String, t: Double, forced: Bool, hasBuffer: Bool)],
) -> [String: Any] {
    let d = StaticIDRDecider(heartbeat: heartbeat, quietWindow: quietWindow)
    var outOps: [[String: Any]] = []
    for o in ops {
        switch o.op {
        case "complete":
            d.onCompleteFrame(now: o.t)
            outOps.append(["op": "complete", "tBits": o.t.bitPattern])
        case "synthetic":
            d.recordSynthetic(now: o.t)
            outOps.append(["op": "synthetic", "tBits": o.t.bitPattern])
        default: // "check"
            let dec = d.shouldReencode(now: o.t, forcedLatched: o.forced, hasRetainedBuffer: o.hasBuffer)
            outOps.append([
                "op": "check",
                "tBits": o.t.bitPattern,
                "forced": o.forced,
                "hasBuffer": o.hasBuffer,
                "decision": dec,
            ])
        }
    }
    return [
        "name": name,
        "heartbeatBits": heartbeat.bitPattern,
        "quietWindowBits": quietWindow.bitPattern,
        "ops": outOps,
    ]
}

root["staticIdrDrive"] = [
    staticIdrScenario("production", heartbeat: 2.5, quietWindow: 1.0, ops: [
        (op: "check", t: 0.5, forced: false, hasBuffer: false), // no buffer ⇒ false
        (op: "check", t: 0.5, forced: true, hasBuffer: false), // no buffer beats forced ⇒ false
        (op: "check", t: 0.5, forced: false, hasBuffer: true), // armed, none emitted, quiet ⇒ true
        (op: "complete", t: 10.0, forced: false, hasBuffer: false),
        (op: "check", t: 10.9, forced: false, hasBuffer: true), // within quiet window ⇒ false
        (op: "check", t: 10.9, forced: true, hasBuffer: true), // quiet suppresses forced ⇒ false
        (op: "check", t: 11.0, forced: false, hasBuffer: true), // quiet cleared, no synthetic ⇒ true
        (op: "synthetic", t: 11.0, forced: false, hasBuffer: false),
        (op: "check", t: 12.5, forced: false, hasBuffer: true), // sub-heartbeat since synthetic ⇒ false
        (op: "check", t: 13.5, forced: false, hasBuffer: true), // one heartbeat since synthetic ⇒ true
        (op: "check", t: 13.4, forced: true, hasBuffer: true), // forced once quiet ⇒ true
        (op: "complete", t: 20.0, forced: false, hasBuffer: false),
        (op: "check", t: 20.5, forced: true, hasBuffer: true), // re-entered quiet ⇒ false
        (op: "check", t: 21.0, forced: false, hasBuffer: true), // quiet cleared, long past synthetic ⇒ true
    ]),
    staticIdrScenario("defaultQuiet", heartbeat: 1.0, quietWindow: 1.0, ops: [
        (op: "check", t: 0.001, forced: false, hasBuffer: true), // armed ⇒ true
        (op: "complete", t: 10.0, forced: false, hasBuffer: false),
        (op: "check", t: 10.999, forced: false, hasBuffer: true), // within quiet ⇒ false
        (op: "check", t: 11.0, forced: false, hasBuffer: true), // quiet boundary cleared ⇒ true
        (op: "synthetic", t: 11.0, forced: false, hasBuffer: false),
        (op: "check", t: 11.5, forced: false, hasBuffer: true), // sub-heartbeat ⇒ false
        (op: "check", t: 12.0, forced: false, hasBuffer: true), // one heartbeat since synthetic ⇒ true
    ]),
]

// MARK: UDPReceiveLoopPolicy.nextBackoff / shouldRearm

// `UDPReceiveLoopPolicy` resolves to the host copy via the scoped `import enum` at the top of the
// file (the Rust port unifies the host+client twins into one `udp_receive_loop_policy`).
func udpBackoffRecord(_ n: Int) -> [String: Any] {
    ["n": n, "backoffBits": UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: n).bitPattern]
}

root["udpBackoff"] = [0, 1, 2, 3, 4, 5, 8, 16, 17, 100].map(udpBackoffRecord)
root["udpRearm"] = [
    ["alive": true, "rearm": UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: true)],
    ["alive": false, "rearm": UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: false)],
]

// MARK: emit

let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
