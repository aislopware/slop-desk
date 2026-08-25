import CSlopDeskFFI
import Foundation

/// The Swift face of `rust/slopdesk-muxsession`'s `metadata_admission`, reached through the
/// `metadata_admission` door.
///
/// Two answers a metadata request needs before any host work starts: whether this session has room
/// to serve it, and who serves it. Neither needs a descriptor, a pasteboard or a subprocess — the
/// first is a counter and the second is a table over one wire byte — so both live over there and
/// this side performs what they name.
///
/// Not `Sendable` and deliberately unlocked: ``MuxChannelSession`` holds every counter call under
/// its `metadataInFlightLock`, exactly as it did when the count was a stored property.
final class MetadataAdmission {
    /// Who serves an admitted verb. Mirrors `metadata_admission::Performer`'s discriminants.
    enum Performer: UInt8 {
        /// Verbs 9–10: the host's Finder / Launch Services.
        case path = 1
        /// Verbs 11–13: the agent hooks, and their live state.
        case agent = 2
        /// Verbs 15–16: the host pasteboard.
        case clipboard = 3
        /// Verbs 18–20: the embedded workbench.
        case codeServer = 4
        /// Verb 21: the host's simulator server.
        case simulator = 5
        /// Verb 22: the host's Android bridge.
        case android = 6
        /// Every read verb, and every byte this build does not serve.
        case builder = 7
    }

    /// The far side, which owns the count and the cap.
    private let handle: OpaquePointer?

    /// A fresh counter at this build's cap.
    init() { handle = slopdesk_metadata_admission_new() }

    deinit { slopdesk_metadata_admission_free(handle) }

    /// The per-session cap, for the one caller that has to NAME it: a test. The rule never crosses.
    static var cap: UInt32 { slopdesk_metadata_admission_cap() }

    /// Takes a slot if one is free. `true` obliges the caller to ``release()`` exactly once.
    func admit() -> Bool { slopdesk_metadata_admission_admit(handle) }

    /// Returns a slot taken by an ``admit()`` that answered `true`.
    func release() { slopdesk_metadata_admission_release(handle) }

    /// How many work items are admitted and unfinished.
    var inFlight: UInt32 { slopdesk_metadata_admission_in_flight(handle) }

    /// Who serves `verb`. An unserved byte answers ``Performer/builder``, which is where the
    /// `unsupportedVerb` answer already lives — a second place that recognises "unknown" is how the
    /// two would drift.
    static func performer(for verb: UInt8) -> Performer {
        Performer(rawValue: slopdesk_metadata_performer(verb)) ?? .builder
    }
}
