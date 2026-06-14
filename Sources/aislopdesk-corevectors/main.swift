import AislopdeskHost // HostOutputSniffer (outbound-PTY control-message sniffer)
import AislopdeskProtocol // WireMessage, MuxEnvelopeCodec (terminal/PTY path)
import AislopdeskVideoClient // TrendlineEstimator, OwdLateDetector, PacerDepthPolicy
import AislopdeskVideoHost // NetworkEstimate, FPSGovernor (pure controllers)

// `UDPReceiveLoopPolicy` is a byte-identical twin exported by BOTH the host and client modules. The
// host module also exports a TYPE named `AislopdeskVideoHost`, so `AislopdeskVideoHost.UDPReceiveLoopPolicy`
// resolves to that type, not the module — qualification is impossible; this scoped `import enum` is the
// only disambiguator to the host copy (pairs with the wholesale import → duplicate_imports, silenced).
// swiftlint:disable:next duplicate_imports
import enum AislopdeskVideoHost.UDPReceiveLoopPolicy // host/client twin → host copy
import AislopdeskVideoProtocol
import CoreGraphics // CGRect/CGPoint/CGSize for the host geometry deciders
import Foundation

// aislopdesk-corevectors — emits a deterministic JSON corpus of golden vectors from the
// REAL Swift `AislopdeskVideoProtocol` codecs, using ONLY the public API. The Rust
// `aislopdesk-core` crate's `golden_parity` integration test replays this corpus and
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

// MARK: NALUnit.join / split

root["naluJoin"] = [
    [
        "unitsHex": [hex([1, 2, 3]), hex([4, 5]), hex([6])],
        "hex": hex(NALUnit.join([[1, 2, 3], [4, 5], [6]].map { Data($0) })),
    ],
    ["unitsHex": [hex([0xAA, 0xBB])], "hex": hex(NALUnit.join([Data([0xAA, 0xBB])]))],
]
func naluSplitRecord(_ avcc: [UInt8]) -> [String: Any] {
    ["avccHex": hex(avcc), "unitsHex": NALUnit.split(Data(avcc)).map { hex($0) }]
}

root["naluSplit"] = [
    naluSplitRecord([0, 0, 0, 1, 0x42, 0, 0, 0, 9, 1, 2]), // valid then truncated tail
    naluSplitRecord([0, 0, 0, 0, 1, 2, 3]), // zero-length prefix
    naluSplitRecord(Array(NALUnit.join([[9], [8, 7]].map { Data($0) })) + [1, 2, 3]), // trailing partial
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
        .scroll(dx: -3.5, dy: 12.0, normalized: VideoPoint(x: 0.0, y: 1.0), tag: 10),
        ["dx": -3.5, "dy": 12.0, "nx": 0.0, "ny": 1.0, "tag": 10],
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
    vc("listSystemDialogs", .listSystemDialogs, [:]),
    vc("systemDialogList", .systemDialogList([
        SystemDialogSummary(windowID: 9, owner: "SecurityAgent", title: "", width: 400, height: 200, isSecure: true),
    ]), ["dialogs": [
        ["windowID": 9, "owner": "SecurityAgent", "title": "", "width": 400, "height": 200, "isSecure": true],
    ]]),
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

// MARK: AislopdeskProtocol — terminal WireMessage.encode (byte parity)

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
]

// MARK: AislopdeskProtocol — MuxEnvelopeCodec.encode (byte parity)

func muxRecord(_ kind: String, _ f: MuxFrame, _ fields: [String: Any]) -> [String: Any] {
    var r = fields
    r["kind"] = kind
    r["hex"] = hex(MuxEnvelopeCodec.encode(f))
    return r
}

root["muxEnvelopes"] = [
    muxRecord(
        "channelOpen",
        .channelOpen(channelID: 1, sessionID: WireMessage.newSessionID, lastReceivedSeq: 0, channelClass: 0),
        [
            "channelId": UInt32(1),
            "sessionIdHex": hex(uuidBytes(WireMessage.newSessionID)),
            "lastReceivedSeq": Int64(0),
            "channelClass": Int(0),
        ],
    ),
    muxRecord(
        "channelOpen",
        .channelOpen(channelID: UInt32.max, sessionID: sidA, lastReceivedSeq: -1, channelClass: 255),
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

// MARK: CaptureRegionMath.unionRegion / shouldRetarget

func crWindowDict(_ w: CaptureRegionMath.WindowSnapshot) -> [String: Any] {
    var d: [String: Any] = ["windowID": w.windowID, "ownerPID": Int(w.ownerPID), "layer": w.layer]
    d.merge(rectBits("f", w.frame)) { a, _ in a }
    return d
}

func crSnap(
    _ id: UInt32,
    _ pid: Int32,
    _ layer: Int,
    _ x: Double,
    _ y: Double,
    _ w: Double,
    _ h: Double,
) -> CaptureRegionMath.WindowSnapshot {
    .init(windowID: id, ownerPID: pid, layer: layer, frame: CGRect(x: x, y: y, width: w, height: h))
}

func crUnionRecord(
    _ name: String,
    target: CGRect,
    targetWindowID: UInt32,
    targetPID: Int32,
    windows: [CaptureRegionMath.WindowSnapshot],
    display: CGRect,
    minOverlapFraction: Double,
) -> [String: Any] {
    let out = CaptureRegionMath.unionRegion(
        targetFrame: target,
        targetWindowID: targetWindowID,
        targetPID: targetPID,
        windowsInFront: windows,
        displayBounds: display,
        minOverlapFraction: minOverlapFraction,
    )
    var r: [String: Any] = [
        "name": name,
        "targetWindowID": targetWindowID,
        "targetPID": Int(targetPID),
        "minOverlapBits": minOverlapFraction.bitPattern,
        "windows": windows.map(crWindowDict),
        "outOriginXBits": out.origin.x.bitPattern,
        "outOriginYBits": out.origin.y.bitPattern,
        "outWidthBits": out.size.width.bitPattern,
        "outHeightBits": out.size.height.bitPattern,
    ]
    r.merge(rectBits("t", target)) { a, _ in a }
    r.merge(rectBits("d", display)) { a, _ in a }
    return r
}

let crDisplay = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let crTarget = CGRect(x: 120, y: 120, width: 700, height: 500)
let crWID: UInt32 = 1783
let crPID: Int32 = 407
root["captureUnion"] = [
    crUnionRecord(
        "noDialog",
        target: crTarget,
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [],
        display: crDisplay,
        minOverlapFraction: 0.30,
    ),
    crUnionRecord(
        "fileDialog",
        target: crTarget,
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [crSnap(1794, crPID, 0, 30, 203, 880, 448)],
        display: crDisplay,
        minOverlapFraction: 0.30,
    ),
    crUnionRecord(
        "otherPID",
        target: crTarget,
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [crSnap(57, 388, 0, 0, 0, 1400, 900)],
        display: crDisplay,
        minOverlapFraction: 0.30,
    ),
    crUnionRecord(
        "selfIgnored",
        target: crTarget,
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [crSnap(crWID, crPID, 0, 120, 120, 700, 500)],
        display: crDisplay,
        minOverlapFraction: 0.30,
    ),
    crUnionRecord(
        "nonZeroLayer",
        target: crTarget,
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [crSnap(99, crPID, 25, 100, 100, 900, 700)],
        display: crDisplay,
        minOverlapFraction: 0.30,
    ),
    crUnionRecord(
        "sliver",
        target: crTarget,
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [crSnap(900, crPID, 0, 815, 120, 600, 500)],
        display: crDisplay,
        minOverlapFraction: 0.30,
    ),
    crUnionRecord(
        "edgeTouch",
        target: crTarget,
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [crSnap(201, crPID, 0, 820, 120, 200, 500)],
        display: crDisplay,
        minOverlapFraction: 0.30,
    ),
    crUnionRecord(
        "clampedToDisplay",
        target: CGRect(x: 0, y: 30, width: 700, height: 500),
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [crSnap(1794, crPID, 0, -90, 100, 880, 448)],
        display: crDisplay,
        minOverlapFraction: 0.30,
    ),
    crUnionRecord(
        "zeroAreaTarget",
        target: CGRect(x: 120, y: 120, width: 0, height: 500),
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [],
        display: crDisplay,
        minOverlapFraction: 0.30,
    ),
    crUnionRecord(
        "offDisplay",
        target: CGRect(x: 5000, y: 5000, width: 100, height: 100),
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [],
        display: crDisplay,
        minOverlapFraction: 0.30,
    ),
    crUnionRecord(
        "zeroAreaDisplay",
        target: crTarget,
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [],
        display: CGRect.zero,
        minOverlapFraction: 0.30,
    ),
    crUnionRecord(
        "boundaryInclusive",
        target: CGRect(x: 0, y: 0, width: 100, height: 100),
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [crSnap(300, crPID, 0, 50, 0, 100, 100)],
        display: crDisplay,
        minOverlapFraction: 0.5,
    ),
    crUnionRecord(
        "justBelowBoundary",
        target: CGRect(x: 0, y: 0, width: 100, height: 100),
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [crSnap(300, crPID, 0, 50, 0, 100, 100)],
        display: crDisplay,
        minOverlapFraction: 0.6,
    ),
    crUnionRecord(
        "negativeSizeWindow",
        target: crTarget,
        targetWindowID: crWID,
        targetPID: crPID,
        windows: [crSnap(1794, crPID, 0, 910, 651, -880, -448)],
        display: crDisplay,
        minOverlapFraction: 0.30,
    ),
]

func crRetargetRecord(_ name: String, current: CGRect, desired: CGRect, minDelta: Double) -> [String: Any] {
    var r: [String: Any] = [
        "name": name,
        "minDeltaBits": minDelta.bitPattern,
        "shouldRetarget": CaptureRegionMath.shouldRetarget(current: current, desired: desired, minDelta: minDelta),
    ]
    r.merge(rectBits("c", current)) { a, _ in a }
    r.merge(rectBits("e", desired)) { a, _ in a }
    return r
}

let crA = CGRect(x: 120, y: 120, width: 700, height: 500)
root["captureRetarget"] = [
    crRetargetRecord("identical", current: crA, desired: crA, minDelta: 8),
    crRetargetRecord(
        "subThreshold",
        current: crA,
        desired: CGRect(x: 117, y: 117, width: 706, height: 506),
        minDelta: 8,
    ),
    crRetargetRecord(
        "exactThreshold",
        current: crA,
        desired: CGRect(x: 128, y: 120, width: 700, height: 500),
        minDelta: 8,
    ),
    crRetargetRecord("minXOver", current: crA, desired: CGRect(x: 128.5, y: 120, width: 700, height: 500), minDelta: 8),
    crRetargetRecord("minYOver", current: crA, desired: CGRect(x: 120, y: 128.5, width: 700, height: 500), minDelta: 8),
    crRetargetRecord(
        "widthOver",
        current: crA,
        desired: CGRect(x: 120, y: 120, width: 708.5, height: 500),
        minDelta: 8,
    ),
    crRetargetRecord(
        "heightOver",
        current: crA,
        desired: CGRect(x: 120, y: 120, width: 700, height: 508.5),
        minDelta: 8,
    ),
    crRetargetRecord(
        "bigExpansion",
        current: crA,
        desired: CGRect(x: 30, y: 120, width: 880, height: 531),
        minDelta: 8,
    ),
    crRetargetRecord(
        "customZeroDelta",
        current: crA,
        desired: CGRect(x: 120, y: 120, width: 700.5, height: 500),
        minDelta: 0,
    ),
]

// MARK: VirtualDisplayGeometry / VirtualDisplayPlanner

func vdGeomRecord(_ pw: Int, _ ph: Int, _ scale: Int, _ maxH: Int, _ ppi: Double) -> [String: Any] {
    let g = VirtualDisplayGeometry(pointWidth: pw, pointHeight: ph, scale: scale, maxHorizontalPixels: maxH)
    let mm = g.sizeInMillimeters(targetPPI: ppi)
    return [
        "pointWidth": pw,
        "pointHeight": ph,
        "scale": scale,
        "maxHorizontalPixels": maxH,
        "ppiBits": ppi.bitPattern,
        "pixelWidth": g.pixelWidth,
        "pixelHeight": g.pixelHeight,
        "exceedsPixelLimit": g.exceedsPixelLimit,
        "mmWidthBits": mm.width.bitPattern,
        "mmHeightBits": mm.height.bitPattern,
    ]
}

root["virtualDisplayGeometry"] = [
    vdGeomRecord(1920, 1080, 2, 7680, 163),
    vdGeomRecord(1440, 900, 1, 7680, 163),
    vdGeomRecord(0, -5, 0, 0, 163), // clamp-to-1 on every field
    vdGeomRecord(3840, 2160, 2, 7680, 163), // exact pixel-limit fit
    vdGeomRecord(3841, 2160, 2, 7680, 163), // over the limit
    vdGeomRecord(3072, 1920, 2, 6144, 163), // base-M exact fit
    vdGeomRecord(3200, 1800, 2, 6144, 163), // base-M over
    vdGeomRecord(2560, 1440, 2, 7680, 220), // hi-PPI
    vdGeomRecord(2560, 1440, 2, 7680, 96), // lo-PPI
    vdGeomRecord(1920, 1080, 2, 7680, Double.nan), // PPI clamp to 1 on NaN
]

func vdOriginRecord(_ name: String, _ rects: [CGRect]) -> [String: Any] {
    let p = VirtualDisplayPlanner.originToRight(of: rects)
    return [
        "name": name,
        "displays": rects.map { [
            "xBits": $0.origin.x.bitPattern,
            "yBits": $0.origin.y.bitPattern,
            "wBits": $0.size.width.bitPattern,
            "hBits": $0.size.height.bitPattern,
        ] },
        "outXBits": p.x.bitPattern,
        "outYBits": p.y.bitPattern,
    ]
}

root["vdOriginToRight"] = [
    vdOriginRecord("empty", []),
    vdOriginRecord("single", [CGRect(x: 0, y: 0, width: 1920, height: 1080)]),
    vdOriginRecord(
        "multi",
        [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 2560, height: 1440)],
    ),
    vdOriginRecord(
        "negativeWidth",
        [CGRect(x: 1000, y: 0, width: -200, height: 1080), CGRect(x: 0, y: 0, width: 500, height: 500)],
    ),
    vdOriginRecord("fractional", [CGRect(x: 0, y: 0, width: 1512.5, height: 982.25)]),
    vdOriginRecord("rightmostNotLast", [
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
        CGRect(x: 5000, y: 0, width: 1000, height: 1080),
        CGRect(x: 1920, y: 0, width: 800, height: 1080),
    ]),
]

func vdChipRecord(_ brand: String) -> [String: Any] {
    ["cpuBrand": brand, "limit": VirtualDisplayPlanner.chipPixelLimit(cpuBrand: brand)]
}

root["vdChipPixelLimit"] = [
    vdChipRecord("Apple M1"),
    vdChipRecord("Apple M1 Max"),
    vdChipRecord("Apple M2 Pro"),
    vdChipRecord("Apple M3"),
    vdChipRecord("Apple M2 Ultra"),
    vdChipRecord("Intel(R) Core(TM) i9"),
    vdChipRecord(""),
    vdChipRecord("apple mx"),
]

func vdRefreshRecord(_ fps: Int) -> [String: Any] {
    ["fps": fps, "ratesBits": VirtualDisplayPlanner.refreshRates(fps: fps).map(\.bitPattern)]
}

root["vdRefreshRates"] = [
    vdRefreshRecord(30),
    vdRefreshRecord(60),
    vdRefreshRecord(90),
    vdRefreshRecord(120),
    vdRefreshRecord(144),
]

// MARK: WindowPlacementMath.placement / fits

func wpPlacementRecord(_ name: String, window: CGSize, display: CGRect) -> [String: Any] {
    let p = WindowPlacementMath.placement(windowSize: window, displayBounds: display)
    var r: [String: Any] = [
        "name": name,
        "winWBits": window.width.bitPattern,
        "winHBits": window.height.bitPattern,
        "outOriginXBits": p.origin.x.bitPattern,
        "outOriginYBits": p.origin.y.bitPattern,
        "outWidthBits": p.size.width.bitPattern,
        "outHeightBits": p.size.height.bitPattern,
        "needsResize": p.needsResize,
    ]
    r.merge(rectBits("d", display)) { a, _ in a }
    return r
}

root["windowPlacement"] = [
    wpPlacementRecord(
        "smaller",
        window: CGSize(width: 1200, height: 800),
        display: CGRect(x: 3840, y: 0, width: 1920, height: 1080),
    ),
    wpPlacementRecord(
        "clampWidth",
        window: CGSize(width: 2400, height: 900),
        display: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    ),
    wpPlacementRecord(
        "clampBoth",
        window: CGSize(width: 4000, height: 3000),
        display: CGRect(x: 100, y: 50, width: 1920, height: 1080),
    ),
    wpPlacementRecord(
        "exact",
        window: CGSize(width: 1920, height: 1080),
        display: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    ),
    wpPlacementRecord(
        "halfPtBoundary",
        window: CGSize(width: 1440.5, height: 900),
        display: CGRect(x: 0, y: 0, width: 1440, height: 900),
    ),
    wpPlacementRecord(
        "halfPtPlusEps",
        window: CGSize(width: 1440.6, height: 900),
        display: CGRect(x: 0, y: 0, width: 1440, height: 900),
    ),
    wpPlacementRecord(
        "negativeOrigin",
        window: CGSize(width: 800, height: 600),
        display: CGRect(x: -1440, y: 300, width: 1440, height: 900),
    ),
    wpPlacementRecord(
        "zeroAreaDisplay",
        window: CGSize(width: 800, height: 600),
        display: CGRect.zero,
    ),
    wpPlacementRecord(
        "negativeSizeDisplay",
        window: CGSize(width: 2000, height: 1500),
        display: CGRect(x: 100, y: 200, width: -1440, height: -900),
    ),
    wpPlacementRecord(
        "negativeWindowWidth",
        window: CGSize(width: -100, height: 600),
        display: CGRect(x: 0, y: 0, width: 1440, height: 900),
    ),
    wpPlacementRecord(
        "fractionalPerAxis",
        window: CGSize(width: 1000.25, height: 750.75),
        display: CGRect(x: 0, y: 25, width: 1000, height: 700),
    ),
]

func wpFitsRecord(_ name: String, size: CGSize, bounds: CGRect) -> [String: Any] {
    var r: [String: Any] = [
        "name": name,
        "sizeWBits": size.width.bitPattern,
        "sizeHBits": size.height.bitPattern,
        "fits": WindowPlacementMath.fits(size, within: bounds),
    ]
    r.merge(rectBits("b", bounds)) { a, _ in a }
    return r
}

let wpVD = CGRect(x: 3840, y: 0, width: 1920, height: 1080)
root["windowFits"] = [
    wpFitsRecord("exact", size: CGSize(width: 1920, height: 1080), bounds: wpVD),
    wpFitsRecord("smaller", size: CGSize(width: 1200, height: 800), bounds: wpVD),
    wpFitsRecord("withinTol", size: CGSize(width: 1920.4, height: 1080), bounds: wpVD),
    wpFitsRecord("widthOver", size: CGSize(width: 1921, height: 1080), bounds: wpVD),
    wpFitsRecord("heightOver", size: CGSize(width: 1920, height: 1200), bounds: wpVD),
    wpFitsRecord(
        "bothAtTol",
        size: CGSize(width: 1440.5, height: 900.5),
        bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
    ),
    wpFitsRecord(
        "zeroBoundsAtTol",
        size: CGSize(width: 0.5, height: 0.5),
        bounds: CGRect.zero,
    ),
    wpFitsRecord(
        "negativeSizeBounds",
        size: CGSize(width: 1920, height: 1080),
        bounds: CGRect(x: 0, y: 0, width: -1920, height: -1080),
    ),
]

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
    var d = StaticIDRDecider(heartbeat: heartbeat, quietWindow: quietWindow)
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

// MARK: InputMotionCoalescer.coalesce (encoded-hex in/out)

func imcMove(_ id: Double) -> InputEvent { .mouseMove(normalized: VideoPoint(x: id, y: id), tag: 0) }
func imcDrag(_ id: Double, _ b: MouseButton = .left) -> InputEvent {
    .mouseDrag(button: b, normalized: VideoPoint(x: id, y: id), clickCount: 1, modifiers: .init(rawValue: 0), tag: 0)
}

func imcDown(_ b: MouseButton = .left) -> InputEvent {
    .mouseDown(button: b, normalized: VideoPoint(x: 0, y: 0), clickCount: 1, modifiers: .init(rawValue: 0), tag: 0)
}

func imcUp(_ b: MouseButton = .left) -> InputEvent {
    .mouseUp(button: b, normalized: VideoPoint(x: 0, y: 0), clickCount: 1, modifiers: .init(rawValue: 0), tag: 0)
}

func imcScroll(_ dy: Double) -> InputEvent { .scroll(dx: 0, dy: dy, normalized: VideoPoint(x: 0, y: 0), tag: 0) }
func imcKey(_ kc: UInt16) -> InputEvent { .key(keyCode: kc, down: true, modifiers: .init(rawValue: 0), tag: 0) }
func imcText(_ s: String) -> InputEvent { .text(s, tag: 0) }

func imcRecord(_ name: String, _ batch: [InputEvent]) -> [String: Any] {
    let out = InputMotionCoalescer.coalesce(batch)
    return [
        "name": name,
        "inputHex": batch.map { hex($0.encode()) },
        "outputHex": out.map { hex($0.encode()) },
    ]
}

root["inputMotionCoalesce"] = [
    imcRecord("empty", []),
    imcRecord("singleMove", [imcMove(0.5)]),
    imcRecord("singleBarrier", [imcDown()]),
    imcRecord("pureMoveRun", [imcMove(0.1), imcMove(0.2), imcMove(0.3)]),
    imcRecord("pureDragRun", [imcDrag(0.1), imcDrag(0.2), imcDrag(0.3)]),
    imcRecord("moveDragBoundary", [imcMove(0.1), imcDrag(0.2), imcMove(0.3)]),
    imcRecord("barrierFlush", [imcMove(0.1), imcMove(0.2), imcDown(), imcMove(0.3), imcUp()]),
    imcRecord("downDragUp", [imcDown(), imcDrag(0.1), imcDrag(0.2), imcDrag(0.3), imcUp()]),
    imcRecord("keyScrollText", [
        imcMove(0.1), imcKey(10), imcMove(0.2), imcScroll(3.0), imcText("a"), imcMove(0.3), imcMove(0.4),
    ]),
    imcRecord("trailingMotion", [imcDown(), imcMove(0.1), imcMove(0.2)]),
    imcRecord("sameClassSplitByBarrier", [imcMove(0.1), imcMove(0.2), imcKey(5), imcMove(0.3), imcMove(0.4)]),
    imcRecord("dragKeepsLatestButton", [imcDrag(0.1, .left), imcDrag(0.2, .right)]),
    imcRecord("alternatingMoveDrag", [imcMove(0.1), imcDrag(0.2), imcMove(0.3), imcDrag(0.4), imcMove(0.5)]),
    imcRecord("adjacentBarriers", [imcDown(.right), imcUp(.right), imcKey(1), imcScroll(1.0), imcText("x")]),
]

// MARK: - VirtualHIDKeyboard (boot-keyboard report parity)

//
// `VirtualHIDKeyboard` maps macOS virtual keycodes → USB HID Keyboard/Keypad usages and folds
// key down/up events into 8-byte boot-protocol reports (the dext input). The Rust port replays
// these byte-for-byte: the keycode→usage table, the modifier byte for every `InputModifiers`
// raw-bit combination, the boot-report layout (sort + 6-key ErrorRollOver), and a scripted
// `HIDKeyboardState` transcript comparing each returned report (only the bytes — never the
// internal pressed set — cross the boundary).

// MARK: hidUsage over the full vk byte range 0x00…0xFF

func vhidUsageRecord(_ vk: UInt16) -> [String: Any] {
    ["vk": vk, "usage": VirtualHIDKeyboard.hidUsage(forVirtualKey: vk).map { $0 as Any } ?? NSNull()]
}

root["vhidHidUsage"] = (0...0xFF).map { vhidUsageRecord(UInt16($0)) }

// MARK: modifierByte over every InputModifiers raw-bit combination 0…63

// Wire bits: shift 1<<0, control 1<<1, option 1<<2, command 1<<3, capsLock 1<<4, function 1<<5.
func vhidModByteRecord(_ raw: UInt8) -> [String: Any] {
    ["raw": raw, "modByte": VirtualHIDKeyboard.modifierByte(InputModifiers(rawValue: raw))]
}

root["vhidModifierByte"] = (0...63).map { vhidModByteRecord(UInt8($0)) }

// MARK: bootReport — representative (modifiers, keys) shapes

func vhidBootRecord(_ name: String, modifiers: UInt8, keys: [UInt8]) -> [String: Any] {
    [
        "name": name,
        "modifiers": modifiers,
        "keysHex": hex(keys),
        "hex": hex(VirtualHIDKeyboard.bootReport(modifiers: modifiers, keys: keys)),
    ]
}

root["vhidBootReport"] = [
    vhidBootRecord("zeroKeys", modifiers: 0, keys: []),
    vhidBootRecord("oneKeyWithShift", modifiers: 0x02, keys: [0x04]),
    vhidBootRecord("sixKeys", modifiers: 0x0A, keys: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09]),
    vhidBootRecord("sevenKeysRollOver", modifiers: 0x0F, keys: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A]),
    vhidBootRecord("unsortedKeys", modifiers: 0, keys: [0x10, 0x04, 0x08]),
    vhidBootRecord("rollOverKeepsModifier", modifiers: 0x01, keys: [1, 2, 3, 4, 5, 6, 7, 8]),
]

// MARK: HIDKeyboardState — scripted transcript (compare returned report bytes only)

func vhidTranscript() -> [[String: Any]] {
    var s = HIDKeyboardState()
    var out: [[String: Any]] = []
    func apply(_ vk: UInt16, _ down: Bool, _ rawMods: UInt8) {
        let r = s.apply(virtualKey: vk, down: down, modifiers: InputModifiers(rawValue: rawMods))
        out.append([
            "op": "apply",
            "vk": vk,
            "down": down,
            "mods": rawMods,
            "reportHex": r.map { hex($0) as Any } ?? NSNull(),
        ])
    }
    func releaseAll() { out.append(["op": "releaseAll", "reportHex": hex(s.releaseAll())]) }
    func releaseAllReport() { out.append(["op": "releaseAllReport", "reportHex": hex(s.releaseAllReport())]) }

    // Type "A": shift down, 'a' down (→ 'A'), 'a' up, shift up.
    apply(0x38, true, 0x01)
    apply(0x00, true, 0x01)
    apply(0x00, false, 0x01)
    apply(0x38, false, 0x00)
    // Hold two regular keys concurrently ('b' then 'c').
    apply(0x0B, true, 0x00)
    apply(0x08, true, 0x00)
    // Unmapped key → nil report.
    apply(0xFFFF, true, 0x00)
    // Pure all-zero report — must NOT clear the folded press state.
    releaseAllReport()
    // A regular key with the Command modifier (modifier byte carries it, key array keeps b/c/x).
    apply(0x07, true, 0x08)
    // Teardown: clears pressed AND ships the all-zero report.
    releaseAll()
    // After releaseAll, the next key must carry ONLY itself (no phantom re-assertion).
    apply(0x06, true, 0x00)
    apply(0x06, true, 0x00) // autorepeat down on a held key re-emits the same report
    apply(0x06, false, 0x00)
    // Release of a key that was never pressed still emits (the `changed` flag is discarded).
    apply(0x02, false, 0x00)
    // capsLock + function modifiers do NOT affect the modifier byte (case comes via shift).
    apply(0x12, true, 0x30)
    // A modifier KEY while a regular key is held re-emits the full state (byte + key array).
    apply(0x37, true, 0x08)
    releaseAll()
    // Drive past the 6-key boot limit → ErrorRollOver on the 7th held key.
    apply(0x00, true, 0x00) // a  → 0x04
    apply(0x01, true, 0x00) // s  → 0x16
    apply(0x02, true, 0x00) // d  → 0x07
    apply(0x03, true, 0x00) // f  → 0x09
    apply(0x04, true, 0x00) // h  → 0x0B
    apply(0x05, true, 0x00) // g  → 0x0A (six keys held — verbatim, no rollover)
    apply(0x06, true, 0x00) // z  → seventh key → ErrorRollOver
    releaseAll()
    return out
}

root["vhidStateTranscript"] = vhidTranscript()

// MARK: - HostOutputSniffer (outbound-PTY control-message parity)

//
// `HostOutputSniffer` is a byte-at-a-time terminal-output state machine that emits inline
// host→client control `WireMessage`s (title / bell / commandStatus / notification). The Rust
// port replays each scripted (chunk, now_ms) step on a fresh sniffer and compares the encoded
// message hex array. The Swift sniffer's wall-clock is a DETERMINISTIC scripted clock (never
// `Date()`): each step pins the clock to a fixed reference date + nowMs/1000 seconds, so the
// C→D duration the Swift `durationMS` measures equals the integer `now_ms - start` the Rust
// port computes — to the millisecond.

/// A deterministic, advanceable wall-clock for `HostOutputSniffer`. `date()` returns a fixed
/// reference instant plus the currently-set `nowMs` (read when a 133;C / 133;D mark completes),
/// so a C at `nowMs = c` and a D at `nowMs = d` yield exactly `d - c` ms of duration.
final class ScriptedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nowMs: UInt64 = 0
    private let reference = Date(timeIntervalSinceReferenceDate: 0)

    func set(_ ms: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        nowMs = ms
    }

    func date() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return reference.addingTimeInterval(Double(nowMs) / 1000.0)
    }
}

func snifferScenario(_ name: String, _ steps: [(bytes: [UInt8], nowMs: UInt64)]) -> [String: Any] {
    let clock = ScriptedClock()
    let sniffer = HostOutputSniffer(clock: { clock.date() })
    var outSteps: [[String: Any]] = []
    for step in steps {
        clock.set(step.nowMs)
        let messages = sniffer.observe(Data(step.bytes))
        outSteps.append([
            "inputHex": hex(step.bytes),
            "nowMs": step.nowMs,
            "messagesHex": messages.map { hex($0.encode()) },
        ])
    }
    return ["name": name, "steps": outSteps]
}

// Control bytes + small builders for terminal escape sequences.
let escByte: UInt8 = 0x1B
let belByte: UInt8 = 0x07
func esc(_ s: String) -> [UInt8] { [escByte] + Array(s.utf8) }
func oscBEL(_ body: String) -> [UInt8] { esc("]" + body) + [belByte] }
func oscST(_ body: String) -> [UInt8] { esc("]" + body) + esc("\\") }

root["hostOutputSniffer"] = [
    snifferScenario("plainText", [(bytes: Array("hello world, no sequences\n".utf8), nowMs: 0)]),
    snifferScenario("osc0Title", [(bytes: oscBEL("0;my title"), nowMs: 0)]),
    snifferScenario("osc2TitleST", [(bytes: oscST("2;窗口 · café 🚀"), nowMs: 0)]),
    snifferScenario("groundBell", [(bytes: Array("abc".utf8) + [belByte] + Array("def".utf8), nowMs: 0)]),
    snifferScenario("commandRunning", [(bytes: oscBEL("133;C"), nowMs: 0)]),
    // C at t=0, idle output at t=5000, D;0 at t=12000 → idle(exit 0, duration 12000ms across chunks).
    snifferScenario("commandCycleAcrossChunks", [
        (bytes: oscBEL("133;C"), nowMs: 0),
        (bytes: Array("building…\n".utf8), nowMs: 5000),
        (bytes: oscBEL("133;D;0"), nowMs: 12000),
    ]),
    // Non-zero exit + non-zero duration (C at 1000, D;130 at 4500 → 3500ms).
    snifferScenario("commandNonZeroExit", [
        (bytes: oscBEL("133;C"), nowMs: 1000),
        (bytes: oscBEL("133;D;130"), nowMs: 4500),
    ]),
    // The 133 mark + its duration measured ACROSS chunk splits (proves cross-chunk parser + clock).
    snifferScenario("commandMarkSplitAcrossChunks", [
        (bytes: esc("]133;"), nowMs: 0),
        (bytes: Array("C".utf8) + [belByte], nowMs: 0),
        (bytes: esc("]133;D;7"), nowMs: 8000),
        (bytes: [belByte], nowMs: 8000),
    ]),
    // A `D` with no matching `C` is ignored (first-prompt phantom).
    snifferScenario("danglingDIgnored", [(bytes: oscBEL("133;D;0"), nowMs: 0)]),
    snifferScenario("osc9Notification", [(bytes: oscBEL("9;build done ✅"), nowMs: 0)]),
    snifferScenario("osc9ProgressIgnored", [
        (bytes: oscBEL("9;4;1;50"), nowMs: 0),
        (bytes: oscBEL("9;42 tests passed"), nowMs: 0),
    ]),
    snifferScenario("osc777Notification", [(bytes: oscBEL("777;notify;CI;all green; done"), nowMs: 0)]),
    snifferScenario("osc777NonNotifyIgnored", [(bytes: oscBEL("777;precmd;x"), nowMs: 0)]),
    // A whole OSC 0 title SPLIT across two observe() chunks (proves cross-chunk parser state).
    snifferScenario("titleSplitAcrossChunks", [
        (bytes: esc("]0;split ti"), nowMs: 0),
        (bytes: Array("tle".utf8) + [belByte], nowMs: 0),
    ]),
    // Consecutive identical titles (OSC 0 then OSC 2 then OSC 0) → deduped to one.
    snifferScenario("consecutiveIdenticalTitlesDedup", [
        (bytes: oscBEL("0;same") + oscBEL("2;same") + oscBEL("0;same"), nowMs: 0),
    ]),
    snifferScenario("differentTitlesNotDeduped", [
        (bytes: oscBEL("0;one") + oscBEL("2;two") + oscBEL("0;one"), nowMs: 0),
    ]),
    // Invalid UTF-8 in the title payload → String(bytes:encoding:.utf8) ?? "" → empty title.
    snifferScenario("invalidUtf8Title", [(bytes: esc("]0;") + [0xFF, 0xFE] + [belByte], nowMs: 0)]),
    // Invalid UTF-8 in the Ps prefix → ps decodes to "" → default branch → nothing.
    snifferScenario("invalidUtf8Ps", [(bytes: esc("]") + [0xFF] + Array(";x".utf8) + [belByte], nowMs: 0)]),
    // DCS/SOS/PM/APC string sequences are swallowed (no spoofed bell/title/status); a real OSC after fires.
    snifferScenario("stringSequencesSwallowed", [
        (bytes: esc("Pq") + [belByte], nowMs: 0), // DCS body + embedded BEL → swallowed
        (bytes: esc("_") + oscBEL("2;pwned") + esc("\\"), nowMs: 0), // APC swallows an embedded title
        (bytes: esc("^junk") + [belByte] + oscBEL("2;real"), nowMs: 0), // PM swallowed, then a real title
    ]),
    // OSC 1 (icon name) and other unrelated OSCs are ignored.
    snifferScenario("unrelatedOscIgnored", [
        (bytes: oscBEL("1;iconname") + oscBEL("8;;https://example.com") + oscBEL("52;c;BASE64=="), nowMs: 0),
    ]),
]

// MARK: emit

let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
