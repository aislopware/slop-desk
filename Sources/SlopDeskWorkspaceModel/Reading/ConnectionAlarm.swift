// ConnectionAlarm — how loud one link-island reading is allowed to be.
//
// The READING is `SlopDeskClientCore/Chrome/ConnectionReading.swift`: which state the link is in,
// what each run says, which readings may climb and on what evidence. Only the RUNG descended, and
// only because `SlopDeskSlate` resolves it to an ink and a weight
// (`Slate.Native.connectionAlarmInk(_:)` / `connectionAlarmWeight(_:)`) — the design floor may name
// the ladder without naming the instrument that walks it.
//
// A two-channel ladder, brightness and weight, with NO hue: a row of digits has nothing to hang a
// palette on, and an instrument that lights a different colour per fault asks the eye to learn one
// before it can read a number.

/// How loud one reading is allowed to be — the island's whole state axis, and the only one it has.
/// `quiet` is the metadata grey every healthy reading rests in, `raised` is worth knowing about,
/// `loud` is worth acting on.
package enum ConnectionAlarm: Equatable, Sendable {
    case quiet
    case raised
    case loud
}
