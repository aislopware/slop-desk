// slopdesk_ffi_device_panel.h — the Android and Simulator panels: their streams, controls, consoles and lists
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_DEVICE_PANEL_H
#define SLOPDESK_FFI_DEVICE_PANEL_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// The scrcpy STREAM's client end. rust/slopdesk-androidd's `stream` module owns
// the framing: the four-byte codec id, the twelve-byte header, the 32 MiB cap,
// the cursor-and-compact reassembler.
//
// A byte stream cannot be reassembled by a pure function — the half-message left
// over from one recv is what the next one completes — so the parser is a HANDLE,
// the same shape slopdesk_inspector_decoder_* uses for the same reason.
// ---------------------------------------------------------------------------

#define SLOPDESK_ANDROID_STREAM_OK 0u
#define SLOPDESK_ANDROID_STREAM_PENDING 1u
// Terminal: a desynchronised stream has no start marker to resynchronise on, so
// the connection is redialled rather than recovered.
#define SLOPDESK_ANDROID_STREAM_CORRUPT 2u
// The body buffer was too small; `payload_len` says how much was needed and
// NOTHING was consumed — grow and call again.
#define SLOPDESK_ANDROID_STREAM_AGAIN 5u

#define SLOPDESK_ANDROID_STREAM_KIND_CODEC 1u
#define SLOPDESK_ANDROID_STREAM_KIND_SESSION 2u
#define SLOPDESK_ANDROID_STREAM_KIND_CONFIGURATION 3u
#define SLOPDESK_ANDROID_STREAM_KIND_ACCESS_UNIT 4u

typedef struct {
    // One of the SLOPDESK_ANDROID_STREAM_KIND_* values.
    uint8_t kind;
    // Live only for an access unit.
    bool is_keyframe;
    // Live only for a session message.
    uint32_t width;
    uint32_t height;
    // Bytes written into `body` — or, under AGAIN, bytes it would need.
    uint32_t payload_len;
} SlopDeskAndroidStreamMessage;

typedef struct SlopDeskAndroidStreamParser SlopDeskAndroidStreamParser;

SlopDeskAndroidStreamParser *slopdesk_android_stream_new(void);
void slopdesk_android_stream_free(SlopDeskAndroidStreamParser *handle);
void slopdesk_android_stream_append(SlopDeskAndroidStreamParser *handle,
                                    const unsigned char *chunk, size_t chunk_len);
uint32_t slopdesk_android_stream_next(SlopDeskAndroidStreamParser *handle,
                                      SlopDeskAndroidStreamMessage *out,
                                      unsigned char *body, size_t body_cap);
// Narrower than the daemon's own codec parse, which knows AV1 too: a decode
// session gains AV1 only on M3-class hardware and later.
bool slopdesk_android_stream_decodable_codec(const unsigned char *identifier, size_t len);

// ---------------------------------------------------------------------------
// ANNEX-B NAL units — slopdesk_nal_split's other half. That door walks the
// length-prefixed framing VideoToolbox speaks; these walk the start-code framing
// MediaCodec produces, which is what arrives over scrcpy's stream.
//
// The bytes do not cross for a walk: an access unit is most of a frame and the
// caller already holds it, so the answer is WHERE the units sit. Only the
// rewrite copies, because a rewrite is by definition a different buffer.
// ---------------------------------------------------------------------------

size_t slopdesk_annexb_split(const unsigned char *annexb, size_t len,
                             SlopDeskNalSpan *out, size_t cap);
// NOTE: `slopdesk_annexb_parameter_sets` LEFT (2026-08-29). Its one caller walked
// a config packet for the sets a format description wanted, and both halves of
// that — the walk AND the framework call — are
// `slopdesk_panel_video_configure_annexb` now, on one side of the boundary.
// 0 means REFUSED, not "did not fit": a buffer holding no start code at all is
// not Annex-B, and passing it through would silently mis-frame a payload that is
// already length-prefixed. A real rewrite is never empty.
size_t slopdesk_annexb_to_avcc(const unsigned char *annexb, size_t len,
                               unsigned char *out, size_t cap);

// ---------------------------------------------------------------------------
// The scrcpy CONTROL channel's client end. rust/slopdesk-androidd's `control`
// module owns every layout, transcribed from `app/src/control_msg.c` at v4.1.
//
// ONE door, not nine: the encoders differ only in which fields they read, and
// every field is a scalar or one string, so the kind tag selects the encoder.
//
// GET_CLIPBOARD (8) and UHID_* (12..14) have no kind here, exactly as they have
// no variant on the Rust side. They are unrepresentable, not merely unused: the
// bridge gives the client ONE full-duplex connection, and a device reply would
// land in the middle of the H.264 stream.
// ---------------------------------------------------------------------------

#define SLOPDESK_ANDROID_CONTROL_TOUCH 0u
#define SLOPDESK_ANDROID_CONTROL_SCROLL 1u
#define SLOPDESK_ANDROID_CONTROL_KEY 2u
#define SLOPDESK_ANDROID_CONTROL_TEXT 3u
// Always sequence zero — a non-zero sequence asks the device to acknowledge.
#define SLOPDESK_ANDROID_CONTROL_SET_CLIPBOARD 4u
#define SLOPDESK_ANDROID_CONTROL_BACK_OR_SCREEN_ON 5u
#define SLOPDESK_ANDROID_CONTROL_DISPLAY_POWER 6u
#define SLOPDESK_ANDROID_CONTROL_START_APP 7u
#define SLOPDESK_ANDROID_CONTROL_BODILESS 8u

typedef struct {
    // One of the SLOPDESK_ANDROID_CONTROL_* values.
    uint8_t kind;
    // A MotionEvent action for a touch, a KeyEvent action for a key or a back press.
    uint8_t action;
    // The type byte, for a bodiless message.
    uint8_t bodiless_type;
    // SET_CLIPBOARD's paste flag, or SET_DISPLAY_POWER's on flag.
    bool flag;
    uint64_t pointer_id;
    // Signed, because a drag legitimately leaves the frame.
    int32_t x;
    int32_t y;
    uint16_t width;
    uint16_t height;
    float pressure;
    float horizontal;
    float vertical;
    uint32_t action_button;
    uint32_t buttons;
    uint32_t keycode;
    uint32_t repeat_count;
    uint32_t meta_state;
} SlopDeskAndroidControl;

// 0 means REFUSED, which a real message's length can never be: every one is at
// least its type byte. Refused are an unserved kind, an action byte naming no
// action, a reply-bearing bodiless type, and an empty text or package name.
size_t slopdesk_android_control_encode(const SlopDeskAndroidControl *request,
                                       const unsigned char *text, size_t text_len,
                                       unsigned char *out, size_t cap);

// ---------------------------------------------------------------------------
// The two device consoles' line grammars — `slopdesk_devicelog`.
//
// A PURE door: the record names byte offsets INTO THE CALLER'S OWN LINE, so
// nothing crosses back but six numbers and a severity and neither side
// allocates. The grammars stay apart in two doors, because `logcat -v time`
// and `log stream --style compact` put different things in the same slots and
// a console that guessed would mis-colour every row of one device.
//
// An unrecognised line is not a failure: it answers PLAIN, an empty time and
// name, and a message covering the whole input. Both sources emit their own
// banners, and a swallowed banner is a console that looks like it silently
// lost the boundary between two runs.

// `logcat`'s V/D and the unified log's Df — most of a busy device's output.
#define SLOPDESK_DEVICE_LOG_PLAIN 0
// The unified log's Db and A. `logcat` never answers this.
#define SLOPDESK_DEVICE_LOG_DEBUG 1
#define SLOPDESK_DEVICE_LOG_INFO 2
// `logcat`'s W. The unified log never answers this.
#define SLOPDESK_DEVICE_LOG_WARNING 3
#define SLOPDESK_DEVICE_LOG_ERROR 4
// F in both, plus `logcat`'s A — its ASSERT, which a native abort prints.
#define SLOPDESK_DEVICE_LOG_FATAL 5

typedef struct {
    uint32_t time_offset;
    uint32_t time_len;
    uint32_t name_offset;
    uint32_t name_len;
    uint32_t message_offset;
    uint32_t message_len;
    uint8_t severity;
} SlopDeskDeviceLogLine;

// `false` REFUSES a line longer than a uint32_t offset can name, having
// written nothing — a truncated offset would name the wrong bytes of a real
// line and render as a row someone might believe. No source writes one.
bool slopdesk_logcat_parse(const unsigned char *line, size_t len,
                           SlopDeskDeviceLogLine *out);
bool slopdesk_unified_log_parse(const unsigned char *line, size_t len,
                                SlopDeskDeviceLogLine *out);

// One row as plain text — what Copy Line and Copy Console hand over. The row's
// own layout puts the three fields in columns; the copy joins them with a space
// and DROPS the empty ones, so an unparsed banner copies as itself rather than
// with two leading spaces. Both consoles had spelled this beside their own
// presentation folds. 0 for a row whose three fields are all empty.
size_t slopdesk_device_log_plain(const unsigned char *time, size_t time_len,
                                 const unsigned char *name, size_t name_len,
                                 const unsigned char *message, size_t message_len,
                                 unsigned char *out, size_t cap);

// ---------------------------------------------------------------------------
// The Android console's LEVEL FILTER — `slopdesk_androidd::protocol`.
//
// The letter the user picks is interpolated into `*:<level>` and reaches an
// argument vector; `logcat` treats an unparsable filter spec as a fatal error,
// which reads as a console that connects and immediately dies. So androidd
// validates every requested level against one array — and the client's MENU is
// that same array, read here, rather than a second list of the same letters.
//
// It was a second list, and it had drifted short: the menu offered V D I W E
// against an alphabet of V D I W E F. Not a crash — a FATAL filter nobody
// could ask for, on the one severity a console gets opened to find.
//
// This is NOT the same set as SLOPDESK_DEVICE_LOG_* above, and they are not
// meant to converge. Those are the priorities a PRINTED line may carry, so
// they include `logcat`'s A. These are the priorities a SPEC may name, so they
// exclude it and exclude S — silent, a console that prints nothing.

size_t slopdesk_android_log_level_count(void);
// The priority letter at `index`, least severe first. 0 is "no such level",
// which cannot collide with a real answer: every letter is non-empty.
size_t slopdesk_android_log_level_letter(size_t index, uint8_t *out, size_t cap);

// ---------------------------------------------------------------------------
// The two device panels' shared decisions — `slopdesk_devicepanel`.
//
// The Android panel and the simulator panel poll the same kind of host ENSURE
// verb, turn its answer into the same four phases, and back off on the same
// rule. Both Swift models held a byte-identical copy of that ladder; this is
// the one it collapsed onto.
//
// Every answer is a KIND. The host string and the device row it is about stay
// on the caller's side — the panel already holds both, and handing one back
// would be a copy made only to be compared with the one it came from.

// No answer at all (no pane channel, or a host too old for the verb), or a
// service that says ready with nothing dialable. Keep polling.
#define SLOPDESK_DEVICE_PANEL_OFFLINE 0
// The host is bringing the service up — spinner, keep polling.
#define SLOPDESK_DEVICE_PANEL_STARTING 1
// The tool is not installed on the host — the install hint. Polled slowly.
#define SLOPDESK_DEVICE_PANEL_UNAVAILABLE 2
// Reachable. Everything else the panel does hangs off this.
#define SLOPDESK_DEVICE_PANEL_READY 3

// `has_endpoint` is false for a round that got no answer. `host`/`host_len` is
// the address the panel would dial; null or empty is the same non-answer as a
// port of 0, which is why the emptiness test is inside rather than at the call
// site. `state_byte` is the RAW wire byte — an unknown one reads as STARTING,
// the wire's own forward-tolerant rule, not a second copy of it.
uint8_t slopdesk_device_panel_phase(bool has_endpoint, uint8_t state_byte,
                                    uint16_t port, const unsigned char *host,
                                    size_t host_len);

// How many poll intervals that phase waits before asking again — 0 stops the
// loop. An unknown byte takes the slow tier.
uint32_t slopdesk_device_panel_poll_backoff(uint8_t phase_byte);

// A selection with no video yet, given what the device list just said.
#define SLOPDESK_DEVICE_PANEL_CONNECT 0
#define SLOPDESK_DEVICE_PANEL_WAIT 1
#define SLOPDESK_DEVICE_PANEL_GONE 2
#define SLOPDESK_DEVICE_PANEL_STALLED 3
#define SLOPDESK_DEVICE_PANEL_NEVER_READY 4

// `is_listed` false — the device left the list — is GONE whatever the clock
// says, and is the one answer that reads neither other argument.
uint8_t slopdesk_device_panel_stream_verdict(bool is_listed, bool is_running,
                                             bool within_grace);

// Whether an arriving frame has anything to tell the observable layer. Called
// on EVERY frame, so it is what keeps a per-frame assignment — and the whole
// invalidation behind it — off the video path.
bool slopdesk_device_panel_video_is_news(bool has_video,
                                         bool is_awaiting_stream);

// ---------------------------------------------------------------------------
// Where a device panel's frame sits, and what a point in it means —
// `slopdesk_devicepanel::geometry`.
//
// The other half that was written twice, and the half that fails QUIETLY: both
// Swift files said "this is the part that can be wrong in a way nobody notices
// until a tap lands two rows off", in the two places where it could be wrong
// two different ways.
//
// The vocabulary is `SlopDeskVideoPoint`/`Size`/`Rect` above, because the fit
// here IS `slopdesk_geometry_displayed_video_rect` — a panel with its own
// aspect fit is how a click ends up beside the pixel it was drawn for.

// Which system-gesture band a contact starts in, for `slopdesk_panel_system_edge`.
#define SLOPDESK_PANEL_EDGE_NONE 0u
#define SLOPDESK_PANEL_EDGE_BOTTOM 1u
#define SLOPDESK_PANEL_EDGE_TOP 2u

// A pinch's two contacts, which are only ever produced together.
typedef struct {
  SlopDeskVideoPoint first;
  SlopDeskVideoPoint second;
} SlopDeskPinchPair;

// Aspect-fit, centred, on whole points; the ZERO rect for a degenerate input,
// which the view reads as "nothing to draw yet".
SlopDeskVideoRect slopdesk_panel_fitted_rect(SlopDeskVideoSize content,
                                             SlopDeskVideoSize bounds);

// A panel-space point in the frame's own space. False — and `out` untouched —
// for a click on the bars beside the frame, which is not a tap on its edge.
bool slopdesk_panel_device_point(SlopDeskVideoPoint point,
                                 SlopDeskVideoRect fitted,
                                 SlopDeskVideoPoint *out);

// The same for a point that left the frame MID-DRAG: clamped to the last
// addressable point rather than dropped, so a shade-pull still finishes.
SlopDeskVideoPoint slopdesk_panel_clamped_device_point(SlopDeskVideoPoint point,
                                                       SlopDeskVideoRect fitted);

// A point in the fitted rect's space, in the grid the stream says it is
// encoding — the only grid scrcpy's PositionMapper will accept.
SlopDeskVideoPoint slopdesk_panel_video_pixels(SlopDeskVideoPoint point,
                                               SlopDeskVideoRect fitted,
                                               SlopDeskVideoSize video);
bool slopdesk_panel_surface_is_usable(SlopDeskVideoRect fitted,
                                      SlopDeskVideoSize video);

SlopDeskPinchPair slopdesk_panel_pinch_fingers(SlopDeskVideoPoint centre, double spread,
                                               SlopDeskVideoRect fitted);

uint32_t slopdesk_panel_system_edge(SlopDeskVideoPoint point, SlopDeskVideoRect fitted,
                                    bool is_upside_down);

// The wire's geometry fields, saturating rather than wrapping: 16 bits, and a
// size past 65535 would wrap and place every touch at the origin.
uint16_t slopdesk_panel_clamp_u16(double value);
int32_t slopdesk_panel_clamp_i32(double value);

// ---------------------------------------------------------------------------
// A panel's VIRTUAL FINGER — `slopdesk_devicepanel::scroll`.
//
// A wheel or a trackpad becomes ONE continuous contact: planted under the
// cursor, moved by the delta, re-gripped at the edge, lifted when the gesture
// ends. Both panels arrived at this from different directions — a `swipe` verb
// that cost 275 ms of the simulator server's main actor, a `scrcpy` wheel verb
// that scrolls without over-scroll, glow or fling — and the machine they
// arrived at is the same one, twice.
//
// A HANDLE, not a fold: where the contact is must survive between events, and
// a caller carrying that would hold the half that decides where the next plant
// lands. The contacts come back in the FITTED rect's own space; what each
// becomes on the wire is the panel's, because the two protocols disagree about
// which grid a positional message is measured in.

// The gesture began, or the first change of one that began off-view.
#define SLOPDESK_PANEL_SCROLL_BEGAN 0
// The gesture continues.
#define SLOPDESK_PANEL_SCROLL_CHANGED 1
// The fingers left the trackpad — ended or cancelled. An unknown byte reads as
// this one: taken as a `began` it would strand a contact on the device.
#define SLOPDESK_PANEL_SCROLL_ENDED 2
// A classic wheel notch, which carries no phase of its own — the caller arms an
// idle timer and calls the lift.
#define SLOPDESK_PANEL_SCROLL_WHEEL 3

#define SLOPDESK_PANEL_CONTACT_DOWN 0
#define SLOPDESK_PANEL_CONTACT_MOVE 1
#define SLOPDESK_PANEL_CONTACT_UP 2

// The most contacts one event can produce: the re-grip, which moves to the
// boundary, lifts, and plants again. Size by this and never retry.
#define SLOPDESK_PANEL_CONTACT_MAX 4

typedef struct {
  SlopDeskVideoPoint point;
  uint8_t action;
} SlopDeskPanelContact;

typedef struct SlopDeskPanelScroll SlopDeskPanelScroll;

SlopDeskPanelScroll *slopdesk_panel_scroll_new(void);
void slopdesk_panel_scroll_free(SlopDeskPanelScroll *handle);

// One scroll event. Answers how many contacts it produced, writing up to `cap`.
// `angle` un-rotates the delta for a panel whose frame is DRAWN turned while
// its framebuffer is not; zero for one that rotates on the device instead.
size_t slopdesk_panel_scroll_accept(SlopDeskPanelScroll *handle,
                                    SlopDeskVideoSize delta, bool is_precise,
                                    uint8_t phase, SlopDeskVideoPoint pointer,
                                    SlopDeskVideoRect fitted, double angle,
                                    SlopDeskPanelContact *out, size_t cap);
// Close a gesture the caller's idle timer decided is over. 0 with none down.
size_t slopdesk_panel_scroll_lift(SlopDeskPanelScroll *handle,
                                  SlopDeskPanelContact *out, size_t cap);
// Forget the contact silently — the socket went away, so a lift has nowhere to
// go and the device's touch state is moot.
void slopdesk_panel_scroll_abandon(SlopDeskPanelScroll *handle);
// Whether a contact is down, and where.
bool slopdesk_panel_scroll_finger(const SlopDeskPanelScroll *handle,
                                  SlopDeskVideoPoint *out);

// ---------------------------------------------------------------------------
// The simulator server's own dialect — `slopdesk_devicepanel::sim_stream`,
// `::sim_input` and `::sim_routes`.
//
// A FOREIGN wire, not one of slopdesk's own: `baguette serve` defines it and
// this side speaks it. There are no golden vectors to pin and no version byte
// anyone here controls, so what these owe instead is what every untrusted
// decoder owes — a refusal rather than a trap, and not one byte read without a
// bounds check.

#define SLOPDESK_SIM_STREAM_CONFIGURATION 0
#define SLOPDESK_SIM_STREAM_KEYFRAME 1
#define SLOPDESK_SIM_STREAM_DELTA 2
#define SLOPDESK_SIM_STREAM_JPEG 3
// A type byte this build does not know — IGNORE the message, do not drop the
// stream: a newer server may add one.
#define SLOPDESK_SIM_STREAM_UNKNOWN 4

// What one binary downstream message carries. `false` — and `kind` untouched —
// for a message this wire never produces. The PAYLOAD does not cross: it is the
// message minus its first byte, which the caller already holds, and copying it
// here would be a memcpy per access unit sixty times a second.
bool slopdesk_sim_stream_kind(const uint8_t *message, size_t len,
                              uint8_t *kind);

// NOTE: `slopdesk_sim_avcc_parse` and `SlopDeskAvcHeader` LEFT (2026-08-29).
// The only thing that ever wanted an avcC record's parameter sets was a
// `CMVideoFormatDescription`, and `slopdesk_panel_video_configure_avcc` below
// now takes the record whole and builds one — so the sets no longer cross at
// all, and the layout keeps its single reader in
// `slopdesk_devicepanel::sim_stream`.

// ---------------------------------------------------------------------------
// A DEVICE PANEL'S VIDEO STREAM — `slopdesk_ffi::panel_video` over
// `slopdesk-apple-vt`.
//
// Both panels show a phone by feeding an `AVSampleBufferDisplayLayer`, and
// everything between the device's bytes and that layer is here: the format
// description a config packet describes, and the sample buffer each access unit
// becomes. Swift's whole remaining share is `layer.enqueue(sample)`.
//
// The HANDLE exists because the format description outlives the frame — a
// stream is configured once and then fed thousands of access units, every one
// of which is wrapped against THAT description.
typedef struct SlopDeskPanelVideo SlopDeskPanelVideo;

// A stream with no format description yet. Free it exactly once.
SlopDeskPanelVideo *slopdesk_panel_video_new(void);

void slopdesk_panel_video_free(SlopDeskPanelVideo *handle);

// Configure from the simulator server's avcC record; H.264, and the record's
// own `nalUnitHeaderLength` field is honoured rather than assumed. `false`
// leaves the RUNNING description in place — a malformed record mid-stream is a
// reason to keep showing frames against the one that was working.
bool slopdesk_panel_video_configure_avcc(SlopDeskPanelVideo *handle,
                                         const uint8_t *record, size_t len);

// Configure from `scrcpy`'s Annex-B config packet. `hevc` picks BOTH the
// parameter-set walk and the framework entry point, because the two must agree:
// an H.264 walk over an HEVC packet finds nothing, and finding nothing is what
// this refuses.
bool slopdesk_panel_video_configure_annexb(SlopDeskPanelVideo *handle,
                                           const uint8_t *config, size_t len,
                                           bool hevc);

// The stream's encoded pixel size; `false` — outputs untouched — before a
// config packet. Read off the DESCRIPTION rather than any session header the
// device advertised: the encoded frame is routinely smaller than the device,
// and it is the frame the view has to fit.
bool slopdesk_panel_video_dimensions(SlopDeskPanelVideo *handle,
                                     int32_t *width_out, int32_t *height_out);

// One AVCC access unit as a CMSampleBufferRef at +1, or NULL when there is
// nothing to show (no config packet yet, an empty unit, or a framework
// refusal — a caller drops the frame for all three).
//
// ⚠️ THE ANSWER IS RETAINED. The Create rule pointed outwards, the same terms
// the decoder's pixel buffers cross under: Swift's `takeRetainedValue()` IS the
// matching release, and `takeUnretainedValue()` would leak one sample buffer
// per frame.
void *slopdesk_panel_video_sample(SlopDeskPanelVideo *handle,
                                  const uint8_t *avcc, size_t len,
                                  bool is_keyframe);

#define SLOPDESK_SIM_TOUCH_DOWN 0
#define SLOPDESK_SIM_TOUCH_MOVE 1
// An unknown phase byte reads as this one: the only phase whose worst case is a
// contact that ends early.
#define SLOPDESK_SIM_TOUCH_UP 2

#define SLOPDESK_SIM_MODIFIER_SHIFT 1
#define SLOPDESK_SIM_MODIFIER_CONTROL 2
#define SLOPDESK_SIM_MODIFIER_OPTION 4
#define SLOPDESK_SIM_MODIFIER_COMMAND 8

// Synthesized keystrokes, US-ASCII only.
#define SLOPDESK_SIM_TEXT_TYPE 0
// The device's pasteboard — the only route that carries emoji or CJK.
#define SLOPDESK_SIM_TEXT_PASTE 1

typedef struct {
  double width;
  double height;
} SlopDeskSimSurface;

// The SERVER's own defaults, as doors: a number written down on this side would
// be a second copy of a value the server owns.
double slopdesk_sim_default_tap_duration(void);
double slopdesk_sim_default_swipe_duration(void);

// One envelope per verb rather than one door with every field optional: the
// key set changes per type, and a single entry point makes the wrong
// combination representable. COORDINATES ARE NOT PIXELS — every positional
// envelope carries the surface its x/y were measured in, and the host rescales.
size_t slopdesk_sim_input_tap(double x, double y, double duration,
                              SlopDeskSimSurface surface, uint8_t *out,
                              size_t cap);
size_t slopdesk_sim_input_swipe(double from_x, double from_y, double to_x,
                                double to_y, double duration,
                                SlopDeskSimSurface surface, uint8_t *out,
                                size_t cap);
// The `edge` hint — set when the gesture began off-screen — is what lets the
// host drive the home indicator and the shades from a drag.
size_t slopdesk_sim_input_touch(uint8_t phase, double x, double y,
                                const uint8_t *edge, size_t edge_len,
                                bool has_edge, SlopDeskSimSurface surface,
                                uint8_t *out, size_t cap);
size_t slopdesk_sim_input_touch2(uint8_t phase, double x1, double y1, double x2,
                                 double y2, SlopDeskSimSurface surface,
                                 uint8_t *out, size_t cap);
// `hold` above zero is the press-and-hold that summons the power slider.
size_t slopdesk_sim_input_button(const uint8_t *name, size_t name_len,
                                 double hold, uint8_t *out, size_t cap);
size_t slopdesk_sim_input_key(const uint8_t *code, size_t code_len,
                              uint8_t modifiers, uint8_t *out, size_t cap);
size_t slopdesk_sim_input_text(uint8_t route, const uint8_t *text,
                               size_t text_len, uint8_t *out, size_t cap);
size_t slopdesk_sim_input_copy(uint8_t *out, size_t cap);

#define SLOPDESK_SIM_ROUTE_DEVICE_LIST 0
#define SLOPDESK_SIM_ROUTE_BOOT 1
#define SLOPDESK_SIM_ROUTE_SHUTDOWN 2
#define SLOPDESK_SIM_ROUTE_DEFINITION 3
#define SLOPDESK_SIM_ROUTE_STATUS_BAR 4
#define SLOPDESK_SIM_ROUTE_LOCATION 5
#define SLOPDESK_SIM_ROUTE_ORIENTATION 6
#define SLOPDESK_SIM_ROUTE_SCREENSHOT 7
#define SLOPDESK_SIM_ROUTE_LOGS 8
#define SLOPDESK_SIM_ROUTE_FILES 9
#define SLOPDESK_SIM_ROUTE_STREAM 10
#define SLOPDESK_SIM_ROUTE_RESOLVE 11

// Which route to build, and every part any of them needs. A record rather than
// a dozen arguments because most routes ignore most fields — a boot URL sets
// three of these, and the rest are read by nobody.
typedef struct {
  uint32_t kind;
  const uint8_t *host;
  size_t host_len;
  uint16_t port;
  const uint8_t *udid;
  size_t udid_len;
  // The one free value this route carries: an orientation, a log level, a file
  // name, or a reference.
  const uint8_t *arg;
  size_t arg_len;
  uint64_t nonce;
  int32_t scale;
  double quality;
  bool has_quality;
} SlopDeskSimRoute;

// Answers the bytes NEEDED, or 0 for a route that cannot be built. Zero is a
// REFUSAL, not an empty answer: a URL is never empty, and a degenerate endpoint
// is the phase machine's "not ready" rather than a URL that fails at connect.
size_t slopdesk_sim_route(const SlopDeskSimRoute *route, uint8_t *out,
                          size_t cap);

// ---- What the simulator control server ANSWERS ------------------------------
//
// The block above builds the requests; these read the replies. Each is a
// validate-then-drop decode with no framework in it, and each answers a blob in
// `docs/55` §4's measure-then-fill shape. A NUMBER in one is 8 bytes big-endian
// of the `f64` bit pattern, a TEXT is `[u32 BE length][UTF-8]`, a COUNT is
// `[u16 BE]`.

// `/simulators/<udid>/definition.json` → the drawable device. 0 means nothing
// drawable came back, which a degenerate or NaN viewport also is.
// Layout: model, bleed x/y/w/h, viewport w/h, rect x/y/w/h, clipRadius,
// barePath, restPath, then [u16 count] × (id, left/top/width/height percent,
// restPath, pressedPath, envelopeButton).
size_t slopdesk_sim_chrome(const uint8_t *json, size_t json_len, uint8_t *out,
                           size_t cap);
// `/simulators.json` → one list, the running group first. 0 is a top level that
// is not an object; ZERO DEVICES is a real answer, which is why the count rides
// inside the blob rather than being the return.
// Layout: [u16 count] × ([u8 booted], udid, name, runtime, state).
size_t slopdesk_sim_device_list(const uint8_t *json, size_t json_len,
                                uint8_t *out, size_t cap);
// One typed coordinate. Always 16 bytes — latitude then longitude — or 0 for a
// refusal, which DMS, `inf` and `NaN` all are.
size_t slopdesk_sim_coordinate_parse(const uint8_t *text, size_t text_len,
                                     uint8_t *out, size_t cap);
// The fixed-width readout for a pinned position, "37.334886, -122.008988".
// Never empty, so 0 can only mean the caller's buffer was measured wrong.
size_t slopdesk_sim_coordinate_readout(double latitude, double longitude,
                                       uint8_t *out, size_t cap);
// The shortlist of places worth one tap.
// Layout: [u16 count] × (name, latitude, longitude).
size_t slopdesk_sim_places(uint8_t *out, size_t cap);

// The console socket's own envelope. The server batches at ~50 ms, so one of
// these carries a whole burst.
#define SLOPDESK_SIM_LOG_STARTED 0
#define SLOPDESK_SIM_LOG_LINES 1

// One text frame off `/simulators/<udid>/logs`. 0 is IGNORE THIS MESSAGE — a
// `type` this build has no case for, or a payload that is not the envelope —
// never an error to report: a newer server that adds a message must cost the
// console that message and not the socket. An EMPTY batch is a real answer, so
// the count rides inside the blob.
// Layout: [u8 kind], then for LINES a [u32 BE count] and that many runs.
size_t slopdesk_sim_log_message(const uint8_t *text, size_t text_len,
                                uint8_t *out, size_t cap);

// ---------------------------------------------------------------------------
// How the simulator panel ASKS — `slopdesk_devicepanel::sim_control`.
//
// The route table above answers WHERE a request goes; these answer everything
// else about it. What the panel used to spell at eleven `URLSession` call sites
// — a verb, a timeout, a cache policy, a content type, and the two JSON bodies
// it posts — is one table, one success window and two byte answers.

#define SLOPDESK_SIM_CONTROL_DEVICES 0u
#define SLOPDESK_SIM_CONTROL_BOOT 1u
#define SLOPDESK_SIM_CONTROL_SHUTDOWN 2u
#define SLOPDESK_SIM_CONTROL_CHROME 3u
#define SLOPDESK_SIM_CONTROL_RESOURCE 4u
#define SLOPDESK_SIM_CONTROL_ORIENTATION 5u
#define SLOPDESK_SIM_CONTROL_SCREENSHOT 6u
#define SLOPDESK_SIM_CONTROL_THUMBNAIL 7u
#define SLOPDESK_SIM_CONTROL_STATUS_BAR 8u
#define SLOPDESK_SIM_CONTROL_FILES 9u
#define SLOPDESK_SIM_CONTROL_LOCATION 10u

// Everything about one request that is not its URL. `has_payload` is read by
// the status bar and the location ONLY — the two routes with a set form and a
// clear form, where clearing is a DELETE because a body-shaped clear is a
// measured 400, not a no-op. 0 is an operation code no build wrote, which is a
// refusal rather than a fall-through to a neighbour's verb.
// Layout: [u8 ignores_cache][8 bytes BE of the f64 timeout in seconds][method]
//         [content type], the last EMPTY for a request that carries no body.
size_t slopdesk_sim_control_plan(uint32_t operation, bool has_payload,
                                 uint8_t *out, size_t cap);
// Whether the server's status line means the request succeeded — the whole 2xx
// class, since `files` answers 201 for an install. A bool, so there is no 0 to
// mistake for a size.
bool slopdesk_sim_control_status_ok(uint16_t status);
// The integer downscale divisor and the JPEG quality a device-list card is
// captured at. Measured against the live server, not chosen: one rung finer
// triples the bytes for pixels a 176pt box cannot show.
int32_t slopdesk_sim_thumbnail_scale(void);
double slopdesk_sim_thumbnail_quality(void);
// The status-bar override body — Apple's marketing status bar, eight pairs the
// server rejects WHOLE on one bad field. Never empty, so 0 can only mean the
// caller measured its buffer wrong.
size_t slopdesk_sim_status_bar_body(uint8_t *out, size_t cap);
// The location body, `{"latitude":…,"longitude":…}`, rounded to six decimals so
// it cannot disagree with the readout the header echoes. Never empty.
size_t slopdesk_sim_location_body(double latitude, double longitude,
                                  uint8_t *out, size_t cap);

// ---------------------------------------------------------------------------
// What the two device panels SAY — `slopdesk_devicepanel::android` and
// `::simulator`.
//
// The section above is the panel boundary's ordinary rule: every answer is a
// KIND, because the caller already holds the string it is about. That still
// holds for every FOLD below — the stage, the menus, the inks, a device's own
// flags. It does not hold for the panels' COPY, and the settings option
// tables were where that was settled: a table of literals read once into a Swift
// `static let` is not an identity the caller has, it is the single spelling two
// renderers must share. Each panel is drawn by SwiftUI on the phone and AppKit
// on the Mac, so its words had one speller by accident and now have one on
// purpose.
//
// Every table crosses in ONE delivery, never a door per string. The framing is
// a run of `[uint32 length][UTF-8 bytes]`, BIG-ENDIAN — this is read across a C
// boundary, where a width that followed the target would be a bug waiting for a
// 32-bit build — and a table with a variable row count puts a `[uint16 count]`
// ahead of it. The field ORDER is the contract; each door states its own.
//
// SF SYMBOLS CROSS AS NAMES. That is what keeps a verb table whole rather than
// split across two languages, and it costs the compile-time check `SFSafeSymbols`
// gave a Swift literal — so the near side has a test that resolves every crossed
// name through `NSImage(systemSymbolName:)`, which is that check, relocated.

// A text ROLE, resolved to a hue by whichever half is drawing. Four rungs and
// one alarm: a colour cannot descend here, because the design floor sits above
// the panel on the Swift side.
#define SLOPDESK_ANDROID_INK_PRIMARY 0
#define SLOPDESK_ANDROID_INK_SECONDARY 1
#define SLOPDESK_ANDROID_INK_TERTIARY 2
#define SLOPDESK_ANDROID_INK_ICON 3
#define SLOPDESK_ANDROID_INK_ERR 4

// What stands over the mirroring stage. The two loading answers are separate
// because that IS the distinction: a mirror the host is starting and a device
// still booting are two waits with two owners, and the second is tens of
// seconds. The caption for each is field `15 + answer` of the words door.
// The five device families, in RANK order — which is also each one's index into
// `slopdesk_android_device_kinds`. PHONE is the fallback for a device that says
// nothing and reports no screen, so it has to be 0.
#define SLOPDESK_ANDROID_KIND_PHONE 0
#define SLOPDESK_ANDROID_KIND_TABLET 1
#define SLOPDESK_ANDROID_KIND_WATCH 2
#define SLOPDESK_ANDROID_KIND_TV 3
#define SLOPDESK_ANDROID_KIND_AUTOMOTIVE 4

#define SLOPDESK_ANDROID_STAGE_STREAMING 0
#define SLOPDESK_ANDROID_STAGE_STARTING_DEVICE 1
#define SLOPDESK_ANDROID_STAGE_STARTING_MIRROR 2
#define SLOPDESK_ANDROID_STAGE_STALLED 3

// The eight things the stage's toolbar can ask of a device. A plate's identity
// on both halves, so a help string changing cannot rebuild a control the
// pointer is inside.
#define SLOPDESK_ANDROID_ACTION_BACK 0
#define SLOPDESK_ANDROID_ACTION_HOME 1
#define SLOPDESK_ANDROID_ACTION_RECENTS 2
#define SLOPDESK_ANDROID_ACTION_ROTATE 3
#define SLOPDESK_ANDROID_ACTION_CAPTURE 4
#define SLOPDESK_ANDROID_ACTION_PASTE_CLIPBOARD 5
#define SLOPDESK_ANDROID_ACTION_DISPLAY_POWER 6
#define SLOPDESK_ANDROID_ACTION_CONSOLE 7

// Which tray a plate sits on. The console plate sits on NEITHER: it latches,
// and a latched plate is a lit key, which reads as lit only against the panel's
// own tone rather than inside a lit tray.
#define SLOPDESK_ANDROID_TRAY_NAVIGATION 0
#define SLOPDESK_ANDROID_TRAY_ACTION 1
#define SLOPDESK_ANDROID_TRAY_CONSOLE 2

// One entry of a device's context menu. SEPARATOR is a case rather than an
// absent row, because the rule is about the LINE. The two copy verbs carry no
// text: the serial and the name are the caller's own row.
#define SLOPDESK_ANDROID_MENU_SEPARATOR 0
#define SLOPDESK_ANDROID_MENU_OPEN_SCREEN 1
#define SLOPDESK_ANDROID_MENU_COPY_SCREENSHOT 2
#define SLOPDESK_ANDROID_MENU_SHUT_DOWN 3
#define SLOPDESK_ANDROID_MENU_START 4
#define SLOPDESK_ANDROID_MENU_COPY_SERIAL 5
#define SLOPDESK_ANDROID_MENU_COPY_NAME 6

// The four things the panel asks about one device's state, as a bitfield —
// four reads of the SAME two fields, so a caller that asked them separately
// would cross `adb`'s state word four times per row per redraw.
#define SLOPDESK_ANDROID_DEVICE_IS_RUNNING 1
#define SLOPDESK_ANDROID_DEVICE_IS_ATTACHED_BUT_UNUSABLE 2
#define SLOPDESK_ANDROID_DEVICE_CAN_ENTER 4
#define SLOPDESK_ANDROID_DEVICE_IS_STOPPABLE 8

// Which sentence the phrase door is being asked for. One door rather than five,
// because five doors that each format one value into one template would be five
// sites restating the same marshalling.
#define SLOPDESK_ANDROID_PHRASE_NO_MATCHES 0
#define SLOPDESK_ANDROID_PHRASE_START_HELP 1
#define SLOPDESK_ANDROID_PHRASE_SHUT_DOWN_HELP 2
#define SLOPDESK_ANDROID_PHRASE_SHUT_DOWN_ALL_HELP 3
#define SLOPDESK_ANDROID_PHRASE_COPY_TITLE 4
#define SLOPDESK_ANDROID_PHRASE_FILTER_BY_TAG 5

// The panel's fixed words, in one delivery. 28 length-prefixed fields, in the
// order the module doc lists: 15 loose words, then the four stage captions in
// byte order, then the seven menu titles in byte order, then the two constant
// log verbs. The two captionless entries (STREAMING, SEPARATOR) are empty BY
// CONSTRUCTION.
size_t slopdesk_android_words(unsigned char *out, size_t cap);

// A log row's menu, in order, one SLOPDESK_ANDROID_LOG_* byte per row. The tag
// item appears only where there IS a tag.
#define SLOPDESK_ANDROID_LOG_COPY_LINE 0
#define SLOPDESK_ANDROID_LOG_COPY_CONSOLE 1
#define SLOPDESK_ANDROID_LOG_FILTER_BY_TAG 2
size_t slopdesk_android_log_menu(bool has_name, unsigned char *out, size_t cap);

// Every plate the stage's toolbar draws. `[uint16 count]`, then per plate
// `[uint8 tray][uint8 action]` and four length-prefixed strings — the glyph and
// sentence at rest, then the pair while latched. A verb that does not latch
// repeats its own pair, so the near side needs no presence flag.
size_t slopdesk_android_stage_verbs(unsigned char *out, size_t cap);

// How long the model may be loading before the veil admits it. 600 rather than
// the simulator's 400, and measured: a warm emulator's first keyframe arrives
// 0.83 s after the request, because the host has to push the server jar, start
// `app_process` and wait for the device's encoder.
uint32_t slopdesk_android_veil_delay_ms(void);

// 9:19.5 — the proportions of a device that has not reported a screen.
double slopdesk_android_fallback_aspect(void);

// The RAW fields cross, never a caller-computed `is_running`: the rule is
// `has_serial && state == "device"`, and half of it spelled at the call site is
// the drift this whole port exists to end.
uint8_t slopdesk_android_device_flags(bool has_serial, const unsigned char *state,
                                      size_t state_len, bool is_emulator);

// `has_device` false is "no selected device to ask", and then the wait is the
// mirror's by definition. Loading OUTRANKS stalled — the two are reachable in
// one frame while a reattempt is in flight.
uint8_t slopdesk_android_stage(bool shows_loading, bool has_selection,
                               bool is_awaiting_stream, bool has_video,
                               bool has_device, bool device_is_running);

// A device's context menu, in order, one SLOPDESK_ANDROID_MENU_* byte per row.
size_t slopdesk_android_device_menu(bool has_serial, const unsigned char *state,
                                    size_t state_len, bool is_emulator,
                                    bool has_avd_name, unsigned char *out,
                                    size_t cap);

// The header's fact line. `[uint16 count]`, then per fact
// `[uint8 ink][uint8 is_measured][uint8 shows_label]` and three length-prefixed
// strings: the label, the drawn text, and what Copy hands over. A dimension or
// density of 0 or less, or an empty abi/serial, is "the host did not report it".
size_t slopdesk_android_facts(int64_t width, int64_t height, int64_t density,
                              const unsigned char *abi, size_t abi_len,
                              const unsigned char *serial, size_t serial_len,
                              unsigned char *out, size_t cap);

// `adb`'s state word as a sentence — with the one reading the word alone gets
// wrong: an EMULATOR that is `offline` is almost always a boot in progress.
size_t slopdesk_android_explain(const unsigned char *state, size_t state_len,
                                bool is_emulator, unsigned char *out, size_t cap);

// The card's tooltip: a verb for a device that can be opened, its STATE for one
// that cannot.
size_t slopdesk_android_card_help(const unsigned char *name, size_t name_len,
                                  bool has_serial, const unsigned char *state,
                                  size_t state_len, bool is_emulator,
                                  unsigned char *out, size_t cap);

// The one-line fact under the headline, assembled from whatever is known rather
// than templated — so a row missing a field reads as a shorter sentence instead
// of one with a hole in it.
size_t slopdesk_android_summary(const unsigned char *release, size_t release_len,
                                int64_t api_level, int64_t width, int64_t height,
                                bool is_emulator,
                                const unsigned char *manufacturer,
                                size_t manufacturer_len,
                                const unsigned char *model, size_t model_len,
                                unsigned char *out, size_t cap);

// The trailing text on a row that is not running. 0 for a row with neither a
// version to print nor a screen to fall back on.
size_t slopdesk_android_subtitle(const unsigned char *version_label,
                                 size_t version_label_len, bool shows_version,
                                 int64_t width, int64_t height,
                                 unsigned char *out, size_t cap);

// Three states, three sentences — and a live filter answers FIRST, because rows
// exist and the reader is the reason none are showing.
size_t slopdesk_android_console_empty_message(bool has_lines, bool is_log_started,
                                              const unsigned char *level_title,
                                              size_t level_title_len,
                                              const unsigned char *filter,
                                              size_t filter_len,
                                              unsigned char *out, size_t cap);

// One sentence that carries a value, chosen by SLOPDESK_ANDROID_PHRASE_*. Each
// phrase reads exactly one of `value`/`count` and ignores the other. A byte no
// build wrote answers 0 rather than a sentence nobody asked for.
size_t slopdesk_android_phrase(uint8_t phrase, const unsigned char *value,
                               size_t value_len, size_t count,
                               unsigned char *out, size_t cap);

// The tag's ink. COLOUR ONLY FOR A FAILURE — a warning is a grey too, because
// `logcat` at warning level is dozens of lines a minute of framework noise. An
// unknown severity byte recedes rather than alarms.
uint8_t slopdesk_android_log_ink(uint8_t severity_byte);

// The device's screen proportions, or 0 for a device that has not reported
// them — which is what the art-width door's fallback means.
double slopdesk_android_aspect_ratio(int64_t width, int64_t height);

// The card's screen box at a fixed art HEIGHT. The three lengths are the
// caller's design tokens; what is here is the fallback, the multiply, and the
// ORDER of the clamp.
double slopdesk_android_art_width(double ratio, double art, double floor,
                                  double cap);

// Every device family's silhouette and heading, in RANK order: `[u16 count]`,
// then per family two length-prefixed strings — the SF Symbol's NAME and the
// group heading. The INDEX is the kind byte the door below answers, so the face
// reads a classification straight into this table and holds no switch of its own.
size_t slopdesk_android_device_kinds(unsigned char *out, size_t cap);

// Which family a device belongs to, as its kind byte (also its rank, also its
// index into the table above). `hint` is the platform's own word for itself —
// `ro.build.characteristics` or an AVD's `tag.id` — and is read as TOKENS, never
// as a substring: `emulator,nosdcard` is the commonest value there is, and
// `nosdcard` CONTAINS `car`, so a substring test calls every ordinary emulator an
// automotive head unit. A zero on any geometry axis means the device reported no
// screen, which answers the phone rather than dividing by it.
uint8_t slopdesk_android_device_kind(const unsigned char *hint, size_t hint_len,
                                     const unsigned char *name, size_t name_len,
                                     int64_t width, int64_t height,
                                     int64_t density);

// ---------------------------------------------------------------------------
// And what the Simulators surface says — `slopdesk_devicepanel::simulator`.
//
// The same shape, and two sections rather than one for the reason the panels
// are two modules in the wrapped crate: they look alike and share not one byte of protocol,
// so a common vocabulary here would be an abstraction over a coincidence.

// ALARM IS THE ONLY COLOUR THIS PANEL HAS. Three of its surfaces broke that
// rule independently before 2026-08-04 — a green "Live" dot, green info lines,
// a coloured status pill — and what the removals left behind is worth stating
// where both halves read it: a hue means SOMETHING IS WRONG, and nothing else.
#define SLOPDESK_SIMULATOR_INK_PRIMARY 0
#define SLOPDESK_SIMULATOR_INK_SECONDARY 1
#define SLOPDESK_SIMULATOR_INK_TERTIARY 2
#define SLOPDESK_SIMULATOR_INK_ALARM 3

// The five device families, in RANK order — which is also each one's index into
// `slopdesk_simulator_device_kinds`. PHONE is the fallback for a name this build
// does not recognise, so it has to be 0.
#define SLOPDESK_SIMULATOR_KIND_PHONE 0
#define SLOPDESK_SIMULATOR_KIND_PAD 1
#define SLOPDESK_SIMULATOR_KIND_WATCH 2
#define SLOPDESK_SIMULATOR_KIND_TV 3
#define SLOPDESK_SIMULATOR_KIND_VISION 4

// The stage's three definite situations. The caption for each is field
// `16 + answer` of the words door; LIVE's is empty by construction.
#define SLOPDESK_SIMULATOR_STAGE_LIVE 0
#define SLOPDESK_SIMULATOR_STAGE_STARTING 1
#define SLOPDESK_SIMULATOR_STAGE_STALLED 2

// One entry of a device's context menu. The menu differs by exactly one branch.
#define SLOPDESK_SIMULATOR_VERB_OPEN_SCREEN 0
#define SLOPDESK_SIMULATOR_VERB_COPY_SCREENSHOT 1
#define SLOPDESK_SIMULATOR_VERB_SHUTDOWN 2
#define SLOPDESK_SIMULATOR_VERB_BOOT 3
#define SLOPDESK_SIMULATOR_VERB_SEPARATOR 4
#define SLOPDESK_SIMULATOR_VERB_COPY_UDID 5
#define SLOPDESK_SIMULATOR_VERB_COPY_NAME 6

// The four ways a simulated device can be held. The wire spellings are the
// SERVER's own, measured against a live one rather than guessed: it rejects the
// whole body on one bad field, so a plausible synonym costs the entire request.
#define SLOPDESK_SIMULATOR_ORIENTATION_PORTRAIT 0
#define SLOPDESK_SIMULATOR_ORIENTATION_LANDSCAPE_LEFT 1
#define SLOPDESK_SIMULATOR_ORIENTATION_LANDSCAPE_RIGHT 2
#define SLOPDESK_SIMULATOR_ORIENTATION_PORTRAIT_UPSIDE_DOWN 3

// Which sentence the phrase door is being asked for.
#define SLOPDESK_SIMULATOR_PHRASE_NO_MATCHES 0
#define SLOPDESK_SIMULATOR_PHRASE_BOOT_HELP 1
#define SLOPDESK_SIMULATOR_PHRASE_OPEN_HELP 2
#define SLOPDESK_SIMULATOR_PHRASE_SHUTDOWN_HELP 3
#define SLOPDESK_SIMULATOR_PHRASE_SHUTDOWN_ALL_HELP 4
#define SLOPDESK_SIMULATOR_PHRASE_COPY_TITLE 5
#define SLOPDESK_SIMULATOR_PHRASE_LOCATION_PINNED 6
#define SLOPDESK_SIMULATOR_PHRASE_UNREADABLE_DROP 7

// The surface's fixed words, in one delivery. 34 length-prefixed fields: 16
// loose words, the three stage captions, the seven verb titles, then the four
// orientation titles and the four wire spellings — every run in byte order.
size_t slopdesk_simulator_words(unsigned char *out, size_t cap);

// Every plate the toolbar and the console strip draw. `[uint16 count]`, then per
// plate two length-prefixed strings: the SF Symbol's name and the tooltip. The
// latching plates cross as a PAIR, off then on.
size_t slopdesk_simulator_plates(unsigned char *out, size_t cap);

// 400, and measured: a booted device's first keyframe lands 0.09 s after the
// socket opens, so a veil with no delay would flash grey over the bezel on every
// selection. The Android bridge's 600 was measured against its own 0.83 s, and
// merging the two would throw away both measurements.
uint32_t slopdesk_simulator_veil_delay_ms(void);

// The floor between two-finger envelopes. Measured: `touch2-move` occupies the
// server for 25 ms, a thousand times what a `touch1-move` costs.
uint32_t slopdesk_simulator_pinch_interval_ms(void);

// `shows_loading` FIRST — it is the delayed mirror of the model's awaiting flag
// and outranks a stall that has not been waited out. Asked in any other order
// the stage shows "no video" for the 90 ms before every selection's keyframe.
uint8_t slopdesk_simulator_stage(bool is_selected, bool shows_loading,
                                 bool is_awaiting_stream, bool has_video);

// A device's context menu, in order, one SLOPDESK_SIMULATOR_VERB_* byte per row.
size_t slopdesk_simulator_device_menu(bool is_booted, unsigned char *out,
                                      size_t cap);

// THE TRANSITION OUTRANKS THE SUPPRESSION: a device spends seconds in `Booting`,
// and showing its runtime through that is the panel claiming nothing is
// happening while something is. 0 for a settled row whose heading already names
// its runtime.
size_t slopdesk_simulator_row_subtitle(const unsigned char *state, size_t state_len,
                                       bool is_booted, const unsigned char *runtime,
                                       size_t runtime_len, bool shows_runtime,
                                       unsigned char *out, size_t cap);

// The header's fact line, framed exactly as the Android door's. Orientation and
// position appear ONLY when they have something to say — a portrait device and a
// device using live GPS are the ordinary case.
size_t slopdesk_simulator_facts(const unsigned char *udid, size_t udid_len,
                                bool has_resolution, double width, double height,
                                uint8_t orientation_byte,
                                const unsigned char *pinned_readout,
                                size_t pinned_readout_len, unsigned char *out,
                                size_t cap);

// A quarter turn, wrapping — the orientation AFTER the turn. An orientation byte
// no build wrote reads as upright, which is the ordinary case: every rule that
// branches on orientation treats portrait as "nothing to say".
uint8_t slopdesk_simulator_orientation_turned(uint8_t orientation_byte,
                                              bool turn_right);
bool slopdesk_simulator_orientation_is_landscape(uint8_t orientation_byte);

// How far the PANEL must turn the picture, in degrees clockwise. The
// framebuffer never rotates: a rotated device still streams its portrait
// buffer, with its interface drawn sideways INSIDE it.
double slopdesk_simulator_orientation_view_angle(uint8_t orientation_byte);

// `1206 × 2622` — THE MULTIPLICATION SIGN, not a lowercase x. This sits in a row
// of measured figures, and a letter standing in for an operator is the detail
// that makes a panel look improvised.
size_t slopdesk_simulator_pixels(double width, double height, unsigned char *out,
                                 size_t cap);

// The leading block of a UDID, cut on a CHARACTER boundary. The full value is 36
// characters and would own the line; Copy hands over the whole thing.
size_t slopdesk_simulator_shortened_udid(const unsigned char *udid, size_t udid_len,
                                         unsigned char *out, size_t cap);

// A bezel button's tooltip, spelled out from the server's wire token — and
// titled FROM the token when it is one this build has not seen.
size_t slopdesk_simulator_button_label(const unsigned char *id, size_t id_len,
                                       unsigned char *out, size_t cap);

// The box a TURNED device has to fit into, as [width, height]. A rotation does
// not change layout on either framework, so fitting a quarter-turned phone
// against the panel's real bounds overflows the column sideways. `out` takes two
// doubles.
void slopdesk_simulator_footprint(double width, double height, bool turned,
                                  double *out);

// Aspect-FIT, and never above 1: a bezel blown past its artwork is a soft,
// resampled device body. 0 for a degenerate size, which is a bezel not drawn.
double slopdesk_simulator_bezel_fit(double content_width, double content_height,
                                    double width, double height);

// Three states, three sentences; the filter answers first, or a narrowed console
// reads as a dead one.
size_t slopdesk_simulator_console_empty_message(bool has_lines, bool is_started,
                                                const unsigned char *level_title,
                                                size_t level_title_len,
                                                const unsigned char *filter,
                                                size_t filter_len,
                                                unsigned char *out, size_t cap);

// One sentence that carries a value, chosen by SLOPDESK_SIMULATOR_PHRASE_*.
size_t slopdesk_simulator_phrase(uint8_t phrase, const unsigned char *value,
                                 size_t value_len, size_t count,
                                 unsigned char *out, size_t cap);

// The process name's ink. Info is a GREY (user-directed 2026-08-04): a busy
// device emits hundreds of info lines a second, so tinting it spent the
// console's one alarm colour on the state of nothing being wrong. Debug still
// recedes — the one place this differs from the Android console's answer.
uint8_t slopdesk_simulator_log_ink(uint8_t severity_byte);

// Every device family's silhouette and heading, in RANK order — the same layout
// the Android door above documents. The pad is drawn LANDSCAPE: `iphone` and
// `ipad` differ only in ASPECT, and aspect does not survive being 13 points tall.
size_t slopdesk_simulator_device_kinds(unsigned char *out, size_t cap);

// Which family a model NAME names, as its kind byte. From the name because
// `/simulators.json` carries no device-type field and the route that does costs a
// request per device — for a glyph, on a list that polls. Order of the checks is
// the point: two of Apple's five product names contain the word "Apple". An
// unrecognised name answers 0, the phone — a plausible silhouette beside a name
// the reader can see beats a row drawn as a question mark.
uint8_t slopdesk_simulator_device_kind(const unsigned char *name,
                                       size_t name_len);

// ---------------------------------------------------------------------------
// Both panels' SECTIONED device list — `slopdesk_devicepanel::sections`.
//
// The running group first and NOT cut by family, the families after it in rank
// order, the fact a whole group agrees on lifted into its heading, and the
// identity a row animates on. It was one machine written twice — a runtime on
// one panel, an Android version on the other — and each panel is drawn by two
// renderers, so a drift there would have been two products rather than a bug.
//
// The answer names the caller's OWN rows by index; what crosses in words is
// only what the caller does not hold. The layout is:
//
//     [u16 section count], then per section:
//       [u8]                      1 for the running group
//       [u32 length][UTF-8]       the heading
//       [u8]                      1 when the group lifted a fact
//       [u32 length][UTF-8]       that fact, empty when it lifted none
//       [u16 member count], then per member:
//         [u16]                   the row's index in the caller's array
//         [u8]                    1 when the row still prints its own value
//         [u32 length][UTF-8]     the row identity, `heading/key`
//
// EVERY PER-DEVICE ARRAY IS POSITIONAL. One of them a row short would file
// every later device under its neighbour's family, so a length disagreement
// answers 0 — the whole reading, not a shifted one.

// The Android panel's sectioned list. `kinds` are SLOPDESK_ANDROID_KIND_*, one
// per device; `attached` is 1 for a device adb has handed a transport id;
// `api_levels` is ro.build.version.sdk, where anything <= 0 means the device
// reported none; `keys` and `releases` name each device's stable key and its
// release string in `blob`.
size_t slopdesk_android_sections(const unsigned char *kinds, size_t kind_count,
                                 const unsigned char *attached,
                                 size_t attached_count,
                                 const int64_t *api_levels, size_t api_count,
                                 const unsigned char *blob, size_t blob_len,
                                 const SlopDeskWsSpan *keys, size_t key_count,
                                 const SlopDeskWsSpan *releases,
                                 size_t release_count, unsigned char *out,
                                 size_t cap);

// The simulator panel's sectioned list. `kinds` are SLOPDESK_SIMULATOR_KIND_*,
// `booted` is 1 for a running simulator, and `keys` and `runtimes` name each
// device's udid and its runtime in `blob`. An EMPTY runtime is a value the row
// still has and the heading still cannot lift — /simulators.json carries one,
// and a lifted blank prints a heading ending in a dangling separator.
size_t slopdesk_simulator_sections(const unsigned char *kinds,
                                   size_t kind_count,
                                   const unsigned char *booted,
                                   size_t booted_count,
                                   const unsigned char *blob, size_t blob_len,
                                   const SlopDeskWsSpan *keys, size_t key_count,
                                   const SlopDeskWsSpan *runtimes,
                                   size_t runtime_count, unsigned char *out,
                                   size_t cap);

// What an Android device calls its platform version — `Android 15` from the
// release string, `API 34` from the level when there is no release, and NO
// BYTES when the device stated neither. The same spelling the grouping above
// lifts, so a heading can never print a version the grouping did not compare.
size_t slopdesk_android_version_label(const unsigned char *release,
                                      size_t release_len, bool has_release,
                                      int64_t api_level, bool has_api,
                                      unsigned char *out, size_t cap);

// NOTE: the screend wire's client end, superd's control-socket framing, its request/reply
// vocabulary and its two push-body batches were ALL declared here until `docs/60` Batch B. They
// are gone with `Sources/SlopDeskSupervisor` and `Sources/SlopDeskScreen`, the only callers any of
// them ever had. hostd is `rust/slopdesk-hostd` now: it reaches superd through
// `slopdesk-superclient` and screend through `slopdesk-screenclient`, both in-process, so these
// layouts have exactly one spelling again and no C boundary to keep it in step across.

// -- Sidecar versions: is what is RUNNING what is INSTALLED? ----------------------------------- //

// `rust/slopdesk-sidecars`. Every daemon in this tree outlives the process asking about it — superd
// and screend are launch agents, the other three are superd's children — so an upgrade replaces ten
// binaries on disk and changes what is executing for none of them. These three answer the two
// questions that follow from that, and neither of them restarts anything.
//
// All three answer as JSON TEXT: each is a small record with optional fields, and both near-side
// callers already decode JSON on the same line of code. An absent version is an EMPTY pair in and
// an ABSENT key out — never an empty string a UI would print as a version.

// What an upgrade changed, from two MANIFEST.json files and no processes at all:
//   {"product","previousProduct":str|null,"changed":n,
//    "tools":[{"tool","change":"unchanged|changed|added|removed","policy","note","previous"?,
//              "current"?}]}
// An empty `previous` is a first install — every tool reads "added". Zero when `current` is not a
// readable manifest, which is the caller's cue to say so rather than act on a plan it does not have.

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_DEVICE_PANEL_H */
