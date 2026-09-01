//! The host metadata RPC: the verb byte that selects an operation, the status byte that answers it,
//! and the per-verb payload codecs the structured verbs ride.
//!
//! This is stage 3 of moving `slopdesk-hostd` off Swift. Stage 1 was the inner
//! [`WireMessage`](crate::WireMessage) codec and stage 2 the [`mux`](crate::mux) envelope above it;
//! those two carry the RPC, and this is what the RPC actually says.
//!
//! ## One request pair, many operations
//! ONE generic [`MetadataRequest`](crate::WireMessage::MetadataRequest) /
//! [`MetadataResponse`](crate::WireMessage::MetadataResponse) pair on the CONTROL channel backs
//! every host-metadata surface. The verb byte discriminates which operation the host runs against
//! the request's pane — which the mux channel identifies — and/or against the request payload.
//! Verb-multiplexing is why the whole surface costs exactly two message types no matter how many
//! operations it grows.
//!
//! ## Parity
//! `tests/golden_vectors.rs` pins all ten `metadataCodecPayloads` vectors from the committed
//! corpus, field-by-field in both directions. That corpus is generated from the Swift codec and
//! predates this module.

pub mod codec;
pub mod verb;

pub use codec::{
    AGENT_SESSION_FIXED_BYTES, AgentHookStatus, AgentKind, AgentSessionInfo, CLIPBOARD_BASELINE_PROBE,
    ClipboardClip, ClipboardKind, CodeFontSpec, CodeOpenDisposition, DIR_ENTRY_FIXED_BYTES,
    DISK_FREE_UNKNOWN, DirEntry, ElidedClip, FoldedCounts, GIT_FILE_FIXED_BYTES, GitFileChange,
    GitStatusPayload, HostVitals, MAX_CLIPBOARD_CONTENT_BYTES, MemoryPressure, PORT_ENTRY_FIXED_BYTES,
    PROCESS_ENTRY_FIXED_BYTES, PortInfo, PortProtocol, ProcessInfo, SHELL_CANDIDATE_FIXED_BYTES,
    SHELL_GROUP_FIXED_BYTES, ServiceEndpoint, ServiceState, ShellCandidate, ShellCompletionGroup,
    decode_agent_hook_status, decode_agent_session_list, decode_clipboard_read_request,
    decode_clipboard_read_response, decode_clipboard_read_response_leaving_content, decode_clipboard_set,
    decode_clipboard_set_leaving_content, decode_code_font_spec, decode_code_open_disposition,
    decode_dir_listing, decode_git_status, decode_host_vitals, decode_port_list, decode_process_list,
    decode_service_endpoint, decode_shell_complete, decode_shell_complete_request, encode_agent_hook_status,
    encode_agent_hook_status_into, encode_agent_session_list, encode_agent_session_list_into,
    encode_clipboard_read_request, encode_clipboard_read_request_into, encode_clipboard_read_response,
    encode_clipboard_read_response_into, encode_clipboard_set, encode_clipboard_set_into,
    encode_code_font_spec, encode_code_font_spec_into, encode_code_open_disposition,
    encode_code_open_disposition_into, encode_dir_listing, encode_dir_listing_into, encode_git_status,
    encode_git_status_into, encode_host_vitals, encode_host_vitals_into, encode_port_list,
    encode_port_list_into, encode_process_list, encode_process_list_into, encode_service_endpoint,
    encode_service_endpoint_into, encode_shell_complete, encode_shell_complete_into,
    encode_shell_complete_request, encode_shell_complete_request_into, fold_status_codes,
};
pub use verb::{MetadataStatus, MetadataVerb};
