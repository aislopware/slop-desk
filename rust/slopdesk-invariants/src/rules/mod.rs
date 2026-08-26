//! One module per section of the gate this crate replaces, and the registry that names them all.
//!
//! A rule lands here by being added to [`registry`] — there is no macro, no inventory crate and no
//! link-time registration, because the one property this list must have is that a reader can see
//! the whole enforced set in one screen. A rule that is written but not registered is a rule that
//! runs never, and the way to notice that is for the list to be short enough to read.

pub mod agent_fold;
pub mod apple_floors;
pub mod byte_scanners;
pub mod choice_tokens;
pub mod chrome_split;
pub mod cli_config;
pub mod cli_vocabulary;
pub mod client_layers;
pub mod client_memos;
pub mod code_panel;
pub mod command_surface;
pub mod crate_defaults;
pub mod crate_policy;
pub mod cross_twins;
pub mod crossed_tables;
pub mod deleted_host_swift;
pub mod design_ratchets;
pub mod device_frames;
pub mod device_law;
pub mod device_streams;
pub mod doc_citations;
pub mod frozen_pairs;
pub mod gate_health;
pub mod held_values;
pub mod host_probes;
pub mod hot_paths;
pub mod ink_floor;
pub mod latency_ratchets;
pub mod macui_memos;
pub mod overlay_split;
pub mod package_graph;
pub mod pane_wiring;
pub mod panel_floor;
pub mod panel_predicates;
pub mod panel_shells;
pub mod path_confinement;
pub mod phone_parity;
pub mod rate_and_range;
pub mod repo_invariants;
pub mod rust_boundaries;
pub mod screend;
pub mod screend_wire;
pub mod settings_catalog;
pub mod settings_is_a_file;
pub mod shared_constants;
pub mod sidecar_clis;
pub mod sidecar_seams;
pub mod sidecar_wires;
pub mod split_surfaces;
pub mod superd_bodies;
pub mod supervisor_envelope;
pub mod terminal_config;
pub mod terminal_grammar;
pub mod terminal_surface;
pub mod transport_lanes;
pub mod two_shells;
pub mod ui_seams;
pub mod ui_split;
pub mod video_client;
pub mod video_control;
pub mod video_host;
pub mod video_ports;
pub mod video_seams;
pub mod video_wire;
pub mod window_placement;
pub mod wire_codecs;
pub mod workspace_document;
pub mod workspace_files;
pub mod workspace_layout;

use crate::Rule;

/// Every rule, in the order the shell ran them.
#[must_use]
#[expect(
    clippy::too_many_lines,
    reason = "the whole enforced set on one screen is the property this list exists to have"
)]
pub fn registry() -> Vec<Rule> {
    vec![
        Rule {
            name: "rendezvous-address",
            origin: "docs/51 §1",
            check: supervisor_envelope::rendezvous_address,
        },
        Rule {
            name: "control-socket-export",
            origin: "docs/51 §1",
            check: supervisor_envelope::control_socket_export,
        },
        Rule {
            name: "shell-integration-env-keys",
            origin: "docs/51 §6.4",
            check: supervisor_envelope::shell_integration_env_keys,
        },
        Rule {
            name: "superd-private-paths",
            origin: "docs/51 §1",
            check: supervisor_envelope::superd_private_paths,
        },
        Rule {
            name: "protocol-version",
            origin: "docs/51 §2, docs/49",
            check: supervisor_envelope::protocol_version,
        },
        Rule {
            name: "verbs",
            origin: "docs/51 §3",
            check: supervisor_envelope::verbs,
        },
        Rule {
            name: "listener-kinds",
            origin: "docs/51 §3b",
            check: supervisor_envelope::listener_kinds,
        },
        Rule {
            name: "frame-envelope",
            origin: "docs/20 §4",
            check: supervisor_envelope::frame_envelope,
        },
        Rule {
            name: "batch-bodies",
            origin: "docs/51 §6.13-6.14",
            check: superd_bodies::batch_bodies,
        },
        Rule {
            name: "read-chunk",
            origin: "docs/51 §5",
            check: superd_bodies::read_chunk,
        },
        Rule {
            name: "host-owes-superd",
            origin: "docs/51 §6.5, §6.7, §1",
            check: superd_bodies::host_owes_superd,
        },
        Rule {
            name: "screend-address",
            origin: "docs/52",
            check: screend::address,
        },
        Rule {
            name: "screend-verbs",
            origin: "docs/52",
            check: screend::verbs,
        },
        Rule {
            name: "screend-hello-and-status",
            origin: "docs/52, docs/49",
            check: screend_wire::hello_and_status,
        },
        Rule {
            name: "screend-reset-flags-and-ceiling",
            origin: "docs/52 §4",
            check: screend_wire::reset_flags_and_ceiling,
        },
        Rule {
            name: "opaque-budget",
            origin: "docs/20 §7",
            check: screend_wire::opaque_budget,
        },
        Rule {
            name: "deleted-screen-swift",
            origin: "docs/52 §4, docs/51 §6.8",
            check: screend_wire::deleted_screen_swift,
        },
        Rule {
            name: "video-send-path",
            origin: "docs/55 §4b",
            check: video_wire::send_path,
        },
        Rule {
            name: "video-receive-path",
            origin: "docs/55 §4b",
            check: video_wire::receive_path,
        },
        Rule {
            name: "video-ladder-and-recovery",
            origin: "docs/55 §4b",
            check: video_wire::ladder_and_recovery,
        },
        Rule {
            name: "video-mux-and-input",
            origin: "docs/55 §4",
            check: video_wire::mux_and_input,
        },
        Rule {
            name: "video-metadata-wires",
            origin: "docs/55 §4b",
            check: video_wire::metadata_wires,
        },
        Rule {
            name: "video-frame-measurements",
            origin: "docs/55 §4b",
            check: video_wire::frame_measurements,
        },
        Rule {
            name: "video-pure-policies",
            origin: "docs/55 §4b",
            check: video_wire::pure_policies,
        },
        Rule {
            name: "terminal-mode-tracker",
            origin: "docs/55 §4b",
            check: video_wire::mode_tracker,
        },
        Rule {
            name: "input-surface",
            origin: "docs/55 §4b",
            check: terminal_surface::input_surface,
        },
        Rule {
            name: "grid-geometry",
            origin: "docs/55 §4b",
            check: terminal_surface::grid_geometry,
        },
        Rule {
            name: "link-scan",
            origin: "docs/55 §4b",
            check: terminal_surface::link_scan,
        },
        Rule {
            name: "command-blocks",
            origin: "docs/55 §4b",
            check: terminal_surface::command_blocks,
        },
        Rule {
            name: "search-surface",
            origin: "docs/55 §4b",
            check: terminal_surface::search_surface,
        },
        Rule {
            name: "video-admission",
            origin: "docs/55 §4b",
            check: video_control::admission,
        },
        Rule {
            name: "video-rate-law",
            origin: "docs/55 §4b",
            check: video_control::rate_law,
        },
        Rule {
            name: "video-frame-rate",
            origin: "docs/55 §4b",
            check: video_control::frame_rate,
        },
        Rule {
            name: "video-presentation-depth",
            origin: "docs/55 §4b",
            check: video_control::presentation_depth,
        },
        Rule {
            name: "video-gradient",
            origin: "docs/55 §4b",
            check: video_client::gradient,
        },
        Rule {
            name: "video-decode-admission",
            origin: "docs/55 §4b",
            check: video_client::decode_admission,
        },
        Rule {
            name: "video-audio-row",
            origin: "docs/55 §4b",
            check: video_client::audio_row,
        },
        Rule {
            name: "video-present-queue",
            origin: "docs/55 §4b",
            check: video_client::present_queue,
        },
        Rule {
            name: "video-scroll-laws",
            origin: "docs/55 §4b",
            check: video_client::scroll_laws,
        },
        Rule {
            name: "video-swipe-nav",
            origin: "docs/55 §4b",
            check: video_client::swipe_nav,
        },
        Rule {
            name: "video-client-mux",
            origin: "docs/55 §4b",
            check: video_client::client_mux,
        },
        Rule {
            name: "video-reassembly",
            origin: "docs/55 §4b",
            check: video_client::reassembly,
        },
        Rule {
            name: "video-host-mux",
            origin: "docs/55 §4",
            check: video_host::host_mux,
        },
        Rule {
            name: "video-window-feed",
            origin: "docs/55 §4b",
            check: video_host::window_feed,
        },
        Rule {
            name: "video-send-path-decisions",
            origin: "docs/55 §4b",
            check: video_host::send_path_decisions,
        },
        Rule {
            name: "video-accumulators",
            origin: "docs/55 §4b",
            check: video_host::accumulators,
        },
        Rule {
            name: "video-geometry",
            origin: "docs/55 §4b",
            check: video_host::geometry,
        },
        Rule {
            name: "video-control-channel",
            origin: "docs/20 §9",
            check: wire_codecs::video_control_channel,
        },
        Rule {
            name: "terminal-wire",
            origin: "docs/20 §2",
            check: wire_codecs::terminal_wire,
        },
        Rule {
            name: "mux-layer",
            origin: "docs/20 §4",
            check: wire_codecs::mux_layer,
        },
        Rule {
            name: "git-dialect",
            origin: "docs/56 inc. 45",
            check: wire_codecs::git_dialect,
        },
        Rule {
            name: "payload-channels",
            origin: "docs/20 §7, docs/45 §5.2",
            check: wire_codecs::payload_channels,
        },
        Rule {
            name: "wire-vocabularies",
            origin: "docs/20 §7, docs/45 §5.2",
            check: wire_codecs::wire_vocabularies,
        },
        Rule {
            name: "unsafe-policy",
            origin: "docs/51 §6.15, docs/55 §5, docs/57",
            check: crate_policy::unsafe_policy,
        },
        Rule {
            name: "apple-family",
            origin: "docs/57 §1-3",
            check: crate_policy::apple_family,
        },
        Rule {
            name: "flops-opt-out",
            origin: "CLAUDE.md, golden/",
            check: crate_policy::flops_opt_out,
        },
        Rule {
            name: "one-home-per-operation",
            origin: "docs/51 §6.15, docs/55",
            check: rust_boundaries::one_home_per_operation,
        },
        Rule {
            name: "replay-buffer",
            origin: "docs/55 §6",
            check: rust_boundaries::replay_buffer,
        },
        Rule {
            name: "agent-detection",
            origin: "docs/50, docs/55 §6",
            check: rust_boundaries::agent_detection,
        },
        Rule {
            name: "one-probe-per-reading",
            origin: "docs/55 §6, docs/57 §5",
            check: rust_boundaries::one_probe_per_reading,
        },
        Rule {
            name: "hevc-encode-is-rusts",
            origin: "docs/57 §5",
            check: rust_boundaries::hevc_encode_is_rusts,
        },
        Rule {
            name: "hevc-decode-is-rusts",
            origin: "docs/57 §5",
            check: rust_boundaries::hevc_decode_is_rusts,
        },
        Rule {
            name: "capture-is-rusts",
            origin: "docs/57 §5",
            check: rust_boundaries::capture_is_rusts,
        },
        Rule {
            name: "agent-vocabularies",
            origin: "docs/55",
            check: rust_boundaries::agent_vocabularies,
        },
        Rule {
            name: "document-field-vocabulary",
            origin: "docs/45 §5.3",
            check: workspace_document::field_vocabulary,
        },
        Rule {
            name: "intent-verbs",
            origin: "docs/45 §5.3, docs/55 §8",
            check: workspace_document::intent_verbs,
        },
        Rule {
            name: "topology-and-reaping",
            origin: "docs/45 §5.3",
            check: workspace_document::topology_and_reaping,
        },
        Rule {
            name: "workspace-scalar-codec",
            origin: "docs/55 §6",
            check: workspace_document::scalar_codec,
        },
        Rule {
            name: "workspace-state-file",
            origin: "docs/55 §6",
            check: workspace_document::state_file,
        },
        Rule {
            name: "optional-fills",
            origin: "docs/55 §8",
            check: workspace_document::optional_fills,
        },
        Rule {
            name: "one-run-one-ladder",
            origin: "docs/45 §5.1",
            check: workspace_document::one_run_one_ladder,
        },
        Rule {
            name: "one-replica-three-layers",
            origin: "docs/45 §7.1",
            check: workspace_document::one_replica_three_layers,
        },
        Rule {
            name: "big-endian-helpers",
            origin: "docs/20 §2",
            check: wire_codecs::big_endian_helpers,
        },
        Rule {
            name: "cursor-overlay-and-progress",
            origin: "check-supervisor.sh (deleted)",
            check: video_seams::cursor_lands_where_click_does,
        },
        Rule {
            name: "client-session",
            origin: "check-supervisor.sh (deleted)",
            check: video_seams::client_session_decides_once_hello,
        },
        Rule {
            name: "client-view",
            origin: "check-supervisor.sh (deleted)",
            check: video_seams::pane_pans_scales_adopts_snaps,
        },
        Rule {
            name: "client-jitter",
            origin: "check-supervisor.sh (deleted)",
            check: video_seams::buffer_sized_by_one_estimate,
        },
        Rule {
            name: "client-input",
            origin: "check-supervisor.sh (deleted)",
            check: video_seams::click_lands_where_cursor_no,
        },
        Rule {
            name: "scroll-hint",
            origin: "check-supervisor.sh (deleted)",
            check: video_seams::scroll_hint_one_encoding_far,
        },
        Rule {
            name: "client-gestures",
            origin: "check-supervisor.sh (deleted)",
            check: video_seams::client_gesture_policies_are_asked,
        },
        Rule {
            name: "paced-send",
            origin: "check-supervisor.sh (deleted)",
            check: video_seams::paced_send_schedule_one_answer,
        },
        Rule {
            name: "host-session-machine",
            origin: "check-supervisor.sh (deleted)",
            check: video_seams::host_session_machine_crosses_by,
        },
        Rule {
            name: "parked-window",
            origin: "check-supervisor.sh (deleted)",
            check: window_placement::parked_window_placed_by_one,
        },
        Rule {
            name: "off-screen-rescue",
            origin: "check-supervisor.sh (deleted)",
            check: window_placement::off_screen_rescue_decides_once,
        },
        Rule {
            name: "discovery-and-resend",
            origin: "check-supervisor.sh (deleted)",
            check: window_placement::one_discovery_one_resend_schedule,
        },
        Rule {
            name: "raise-rule",
            origin: "check-supervisor.sh (deleted)",
            check: window_placement::raise_rule_read_once_off,
        },
        Rule {
            name: "ledger-and-accumulator",
            origin: "check-supervisor.sh (deleted)",
            check: window_placement::ledger_accumulator_cross_by_value,
        },
        Rule {
            name: "keybind-grammar",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_config::one_keybind_grammar_no_callback,
        },
        Rule {
            name: "terminal-config-emitter",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_config::one_terminal_config_emitter_swift,
        },
        Rule {
            name: "named-key-table",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_config::one_named_key_table_what,
        },
        Rule {
            name: "reset-backstop",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_config::reset_backstop_built_from_set,
        },
        Rule {
            name: "pane-directory",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_config::one_rule_for_pane_directory,
        },
        Rule {
            name: "client-send-keys",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_config::client_send_keys_asks_one,
        },
        Rule {
            name: "config-name-table",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_config::one_config_name_table_goto,
        },
        Rule {
            name: "scrcpy-control",
            origin: "check-supervisor.sh (deleted)",
            check: device_streams::one_writer_for_scrcpy_control,
        },
        Rule {
            name: "wait-scan",
            origin: "check-supervisor.sh (deleted)",
            check: device_streams::wait_stream_scanned_once_off,
        },
        Rule {
            name: "watch-vocabulary",
            origin: "check-supervisor.sh (deleted)",
            check: workspace_layout::what_watch_decides_what_prints,
        },
        Rule {
            name: "borderless-dwell",
            origin: "check-supervisor.sh (deleted)",
            check: workspace_layout::one_dwell_decides_who_owns,
        },
        Rule {
            name: "divider-weight",
            origin: "check-supervisor.sh (deleted)",
            check: workspace_layout::one_pixel_weight_conversion_seam,
        },
        Rule {
            name: "rail-badge-gates",
            origin: "check-supervisor.sh (deleted)",
            check: workspace_layout::rail_render_reads_its_badge,
        },
        Rule {
            name: "client-core-draws-nothing",
            origin: "check-supervisor.sh (deleted)",
            check: client_layers::presentation_logic_draws_nothing_both,
        },
        Rule {
            name: "code-panel-font-pair",
            origin: "check-supervisor.sh (deleted)",
            check: code_panel::font_pair_agrees_across_the_seam,
        },
        Rule {
            name: "code-panel-one-implementation",
            origin: "check-supervisor.sh (deleted)",
            check: code_panel::dressing_is_one_implementation,
        },
        Rule {
            name: "motion-run-rule",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_grammar::one_motion_run_rule_answers,
        },
        Rule {
            name: "key-vocabulary",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_grammar::one_key_vocabulary_whichever_grammar,
        },
        Rule {
            name: "styled-vt-grammar",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_grammar::one_vt_grammar_for_styled,
        },
        Rule {
            name: "paste-guard",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_grammar::one_paste_guard_secret_one,
        },
        Rule {
            name: "copy-mode-clustering",
            origin: "check-supervisor.sh (deleted)",
            check: terminal_grammar::one_clustering_answers_cursor_badge,
        },
        Rule {
            name: "foreground-process-vocabulary",
            origin: "check-supervisor.sh (deleted)",
            check: host_probes::one_vocabulary_for_foreground_process,
        },
        Rule {
            name: "hostd-binary-order",
            origin: "check-supervisor.sh (deleted)",
            check: host_probes::hostd_finds_program_by_one,
        },
        Rule {
            name: "fuzzy-ranking",
            origin: "check-supervisor.sh (deleted)",
            check: client_memos::one_fuzzy_ranking_for_every,
        },
        Rule {
            name: "rail-fingerprint",
            origin: "check-supervisor.sh (deleted)",
            check: client_memos::rail_fingerprint_asks_for_its,
        },
        Rule {
            name: "screend-frame-encoder",
            origin: "check-supervisor.sh (deleted)",
            check: device_frames::one_encoder_for_screend_frame,
        },
        Rule {
            name: "scrcpy-stream-reader",
            origin: "check-supervisor.sh (deleted)",
            check: device_frames::one_reader_for_scrcpy_stream,
        },
        Rule {
            name: "simulator-dialect",
            origin: "docs/47-simulator-panel.md",
            check: device_frames::one_dialect_for_the_simulator_server,
        },
        Rule {
            name: "panel-virtual-finger",
            origin: "docs/47-simulator-panel.md",
            check: device_frames::one_virtual_finger_for_both_panels,
        },
        Rule {
            name: "split-drop-zone",
            origin: "check-supervisor.sh (deleted)",
            check: split_surfaces::the_drop_overlay_draws_one_shape,
        },
        Rule {
            name: "split-cheat-sheet",
            origin: "check-supervisor.sh (deleted)",
            check: split_surfaces::one_cheat_sheet_two_layouts,
        },
        Rule {
            name: "split-toast-card",
            origin: "check-supervisor.sh (deleted)",
            check: split_surfaces::one_notification_card_two_corners,
        },
        Rule {
            name: "split-palette",
            origin: "check-supervisor.sh (deleted)",
            check: split_surfaces::one_palette_two_frameworks,
        },
        Rule {
            name: "cli-folder-frecency",
            origin: "check-supervisor.sh (deleted)",
            check: cli_config::folders_rank_once_and_a_jump_reads_it,
        },
        Rule {
            name: "config-file-reader",
            origin: "check-supervisor.sh (deleted)",
            check: cli_config::the_config_file_has_one_reader,
        },
        Rule {
            name: "number-spelled-once",
            origin: "check-supervisor.sh (deleted)",
            check: cli_config::a_number_is_spelled_once,
        },
        Rule {
            name: "swipe-nav-handle",
            origin: "check-supervisor.sh (deleted)",
            check: cli_config::the_swipe_nav_operating_point_is_a_handle,
        },
        Rule {
            name: "plain-text-vt-grammar",
            origin: "check-supervisor.sh (deleted)",
            check: byte_scanners::one_vt_grammar_for_plain_text,
        },
        Rule {
            name: "shell-word-quoting",
            origin: "check-supervisor.sh (deleted)",
            check: byte_scanners::one_shell_word_wherever_a_path_is_typed,
        },
        Rule {
            name: "width-table",
            origin: "check-supervisor.sh (deleted)",
            check: byte_scanners::one_width_table_under_that_clustering,
        },
        Rule {
            name: "escape-end-grammar",
            origin: "check-supervisor.sh (deleted)",
            check: byte_scanners::one_grammar_for_where_an_escape_ends,
        },
        Rule {
            name: "find-bar-engine",
            origin: "check-supervisor.sh (deleted)",
            check: byte_scanners::the_find_bar_asks_the_same_engine,
        },
        Rule {
            name: "base64-and-secret-notation",
            origin: "check-supervisor.sh (deleted)",
            check: byte_scanners::one_base64_and_one_secret_notation,
        },
        Rule {
            name: "escape-decoding",
            origin: "check-supervisor.sh (deleted)",
            check: byte_scanners::one_reading_of_an_escape,
        },
        Rule {
            name: "tab-badge-ladder",
            origin: "check-supervisor.sh (deleted)",
            check: agent_fold::one_badge_ladder_for_a_tab_row,
        },
        Rule {
            name: "hook-body-reading",
            origin: "check-supervisor.sh (deleted)",
            check: agent_fold::one_reading_of_a_hook_body,
        },
        Rule {
            name: "pane-detector-probes",
            origin: "check-supervisor.sh (deleted)",
            check: agent_fold::one_pane_detector_and_the_probes_only_probe,
        },
        Rule {
            name: "secret-shape-vocabulary",
            origin: "check-supervisor.sh (deleted)",
            check: agent_fold::one_vocabulary_of_secret_shapes,
        },
        Rule {
            name: "fresh-install-payload",
            origin: "check-supervisor.sh (deleted)",
            check: agent_fold::what_a_fresh_install_carries,
        },
        Rule {
            name: "device-console-grammar",
            origin: "check-supervisor.sh (deleted)",
            check: transport_lanes::one_grammar_per_device_console,
        },
        Rule {
            name: "superd-frame-spelling",
            origin: "check-supervisor.sh (deleted)",
            check: transport_lanes::one_spelling_of_the_superd_frame,
        },
        Rule {
            name: "receive-buffer",
            origin: "check-supervisor.sh (deleted)",
            check: transport_lanes::one_receive_buffer_and_one_narrowing,
        },
        Rule {
            name: "arena-reader",
            origin: "check-supervisor.sh (deleted)",
            check: transport_lanes::one_arena_reader_and_one_interner,
        },
        Rule {
            name: "nwconnection-channel",
            origin: "check-supervisor.sh (deleted)",
            check: transport_lanes::one_nwconnection_byte_channel,
        },
        Rule {
            name: "write-loop",
            origin: "check-supervisor.sh (deleted)",
            check: transport_lanes::one_write_loop_and_one_read_exactly,
        },
        Rule {
            name: "overlay-host-ambient-layer",
            origin: "check-supervisor.sh (deleted)",
            check: overlay_split::the_overlay_host_holds_no_ambient_layer,
        },
        Rule {
            name: "split-peek-card",
            origin: "check-supervisor.sh (deleted)",
            check: overlay_split::one_peek_card_two_frameworks,
        },
        Rule {
            name: "keystroke-and-peek-rules",
            origin: "check-supervisor.sh (deleted)",
            check: overlay_split::the_keystroke_table_and_peek_rules_are_rusts,
        },
        Rule {
            name: "split-global-search",
            origin: "check-supervisor.sh (deleted)",
            check: overlay_split::one_global_search_two_frameworks,
        },
        Rule {
            name: "split-picker",
            origin: "check-supervisor.sh (deleted)",
            check: overlay_split::one_picker_two_frameworks,
        },
        Rule {
            name: "stage-d-ledger",
            origin: "check-supervisor.sh (deleted)",
            check: overlay_split::the_stage_d_ledger_is_empty,
        },
        Rule {
            name: "split-navigator",
            origin: "check-supervisor.sh (deleted)",
            check: chrome_split::one_navigator_per_platform,
        },
        Rule {
            name: "split-titlebar-band",
            origin: "check-supervisor.sh (deleted)",
            check: chrome_split::one_titlebar_band_one_connection_reading,
        },
        Rule {
            name: "split-panel-chrome",
            origin: "check-supervisor.sh (deleted)",
            check: chrome_split::one_panel_chrome_one_tab_reading,
        },
        Rule {
            name: "device-panel-floor",
            origin: "check-supervisor.sh (deleted)",
            check: panel_floor::the_device_panel_floor_builds_for_the_phone,
        },
        Rule {
            name: "device-panels-both-platforms",
            origin: "check-supervisor.sh (deleted)",
            check: panel_floor::both_device_panels_draw_on_both_platforms,
        },
        Rule {
            name: "code-panel-crosses",
            origin: "check-supervisor.sh (deleted)",
            check: panel_floor::the_code_panel_crosses,
        },
        Rule {
            name: "terminal-pane-wiring",
            origin: "check-supervisor.sh (deleted)",
            check: pane_wiring::one_terminal_wiring_and_its_teardown_order,
        },
        Rule {
            name: "escape-monitor",
            origin: "check-supervisor.sh (deleted)",
            check: pane_wiring::one_escape_monitor_installed_and_removed_once,
        },
        Rule {
            name: "one-connect-one-ladder",
            origin: "docs/45 Phase 6",
            check: pane_wiring::one_connect_one_ladder,
        },
        Rule {
            name: "phone-key-path",
            origin: "check-supervisor.sh (deleted)",
            check: pane_wiring::the_phone_key_path_is_rust,
        },
        Rule {
            name: "tree-repair",
            origin: "check-supervisor.sh (deleted)",
            check: cross_twins::one_tree_repair_in_rust,
        },
        Rule {
            name: "cross-language-twins",
            origin: "check-supervisor.sh (deleted)",
            check: cross_twins::four_cross_language_twins,
        },
        Rule {
            name: "loop-shaped-crossings",
            origin: "check-supervisor.sh (deleted)",
            check: cross_twins::the_loop_shaped_crossings_are_whole_collection_doors,
        },
        Rule {
            name: "settings-is-a-file",
            origin: "docs/58",
            check: settings_is_a_file::the_settings_gui_stays_deleted,
        },
        Rule {
            name: "defaults-suite-env-key",
            origin: "docs/55 §shared constants, docs/58",
            check: settings_is_a_file::the_defaults_suite_variable_is_spelled_once,
        },
        Rule {
            name: "choice-tokens-are-the-tables",
            origin: "docs/58 §the one duplication still standing",
            check: choice_tokens::a_choice_enum_spells_exactly_the_tables_stops,
        },
        Rule {
            name: "settings-constant-answers",
            origin: "check-supervisor.sh (deleted)",
            check: settings_catalog::the_cheat_sheet_and_menu_bar_hold_their_constants,
        },
        Rule {
            name: "ui-split-shape",
            origin: "docs/56 §3",
            check: ui_split::the_ui_split_holds_its_shape,
        },
        Rule {
            name: "phone-root-key-rung",
            origin: "docs/56 §3",
            check: phone_parity::the_phone_dispatches_chords_at_the_root,
        },
        Rule {
            name: "phone-editing-chords",
            origin: "docs/56 §3",
            check: phone_parity::the_phones_terminal_takes_editing_chords,
        },
        Rule {
            name: "one-config-one-behaviour",
            origin: "docs/56 §3",
            check: phone_parity::one_config_file_produces_one_behaviour,
        },
        Rule {
            name: "code-panel-settles-once",
            origin: "docs/56 §3",
            check: phone_parity::the_code_panel_settles_once,
        },
        Rule {
            name: "panel-named-surface",
            origin: "docs/56 §3",
            check: phone_parity::the_panel_opens_on_a_named_surface,
        },
        Rule {
            name: "one-clear-key",
            origin: "docs/56 §3",
            check: phone_parity::one_clear_key_per_filter_field,
        },
        Rule {
            name: "mirror-takes-typed-text",
            origin: "docs/56 §3",
            check: phone_parity::a_mirrored_device_takes_typed_text,
        },
        Rule {
            name: "silent-paste-probe",
            origin: "docs/56 increment 78",
            check: phone_parity::the_paste_plate_asks_a_silent_question,
        },
        Rule {
            name: "swipe-peel-two-drivers",
            origin: "docs/56 §3",
            check: phone_parity::the_swipe_peel_chip_has_two_drivers,
        },
        Rule {
            name: "ipad-trackpad-pointer",
            origin: "docs/56 §3",
            check: phone_parity::an_ipad_trackpad_is_a_pointer,
        },
        Rule {
            name: "pane-drop-one-rule",
            origin: "docs/56 increment 82",
            check: phone_parity::the_pane_move_drop_is_one_rule,
        },
        Rule {
            name: "link-island-one-reading",
            origin: "docs/56 increment 83",
            check: phone_parity::the_link_island_is_one_reading,
        },
        Rule {
            name: "host-synthesises-nothing",
            origin: "docs/57 §5",
            check: apple_floors::the_host_synthesises_no_event,
        },
        Rule {
            name: "host-decodes-no-window",
            origin: "docs/57 §5",
            check: apple_floors::the_host_decodes_no_window_record,
        },
        Rule {
            name: "host-decides-no-region",
            origin: "docs/56 increment 86",
            check: apple_floors::the_host_decides_no_capture_region,
        },
        Rule {
            name: "no-cross-target-clone",
            origin: "docs/56 §3",
            check: two_shells::no_body_crosses_the_ui_split,
        },
        Rule {
            name: "owned-copy-one-speller",
            origin: "docs/56 §3",
            check: two_shells::owned_copy_has_one_speller,
        },
        Rule {
            name: "shared-vocabulary-ceiling",
            origin: "docs/56 §3",
            check: two_shells::the_shared_vocabulary_only_shrinks,
        },
        Rule {
            name: "state-file-one-answer",
            origin: "docs/55 §6",
            check: workspace_files::one_answer_to_what_survives_a_restart,
        },
        Rule {
            name: "workspace-file-one-answer",
            origin: "docs/55 §6",
            check: workspace_files::one_answer_to_the_saved_arrangement,
        },
        Rule {
            name: "solvers-live-in-rust",
            origin: "docs/55 §6",
            check: workspace_files::the_solvers_live_in_rust,
        },
        Rule {
            name: "abi-enum-byte-maps",
            origin: "docs/55",
            check: workspace_files::every_abi_enum_crosses_as_one_byte,
        },
        Rule {
            name: "drop-client-one-layout",
            origin: "docs/53 §3",
            check: sidecar_wires::the_drop_client_holds_no_layout,
        },
        Rule {
            name: "drop-type-bytes",
            origin: "docs/53 §3",
            check: sidecar_wires::the_drop_type_bytes_are_one_alphabet,
        },
        Rule {
            name: "android-bridge-both-ways",
            origin: "docs/48 §4",
            check: sidecar_wires::the_android_bridge_agrees_both_ways,
        },
        Rule {
            name: "inspector-frame-one-spelling",
            origin: "docs/54 §3",
            check: sidecar_wires::the_inspector_frame_has_one_spelling,
        },
        Rule {
            name: "inspector-tags-one-alphabet",
            origin: "docs/54 §3",
            check: sidecar_wires::the_inspector_tags_are_one_alphabet,
        },
        Rule {
            name: "announce-lines-one-string",
            origin: "docs/49 §6",
            check: sidecar_wires::every_announce_line_is_one_string,
        },
        Rule {
            name: "sidecar-version-policy",
            origin: "docs/49 §6",
            check: sidecar_wires::the_sidecar_version_policy_is_one_table,
        },
        Rule {
            name: "ctl-verbs-one-alphabet",
            origin: "docs/50 §5",
            check: sidecar_clis::the_ctl_verb_sets_are_one_alphabet,
        },
        Rule {
            name: "codeseed-one-alphabet",
            origin: "docs/DECISIONS.md, stage 22",
            check: sidecar_clis::the_codeseed_subcommands_are_one_alphabet,
        },
        Rule {
            name: "agenthooks-one-alphabet",
            origin: "docs/DECISIONS.md, stage 23",
            check: sidecar_clis::the_hooks_installer_is_one_alphabet,
        },
        Rule {
            name: "probe-one-alphabet",
            origin: "docs/DECISIONS.md, stages 24 and 25",
            check: sidecar_clis::the_probe_subcommands_are_one_alphabet,
        },
        Rule {
            name: "git-status-linked-once",
            origin: "docs/DECISIONS.md, stage 26",
            check: sidecar_clis::the_git_status_is_linked_and_asked_once,
        },
        Rule {
            name: "pointer-tables-one-table",
            origin: "docs/56, increment 50",
            check: sidecar_clis::the_pointer_tables_are_one_table,
        },
        Rule {
            name: "video-surface-split",
            origin: "docs/56 §3",
            check: ui_split::the_video_surface_stays_split,
        },
        Rule {
            name: "video-halves-agree",
            origin: "docs/56 §3",
            check: ui_split::the_two_video_halves_agree,
        },
        Rule {
            name: "ui-test-edges",
            origin: "docs/56 §3.5 step 5",
            check: ui_seams::a_test_target_is_the_same_edge,
        },
        Rule {
            name: "canvas-registration",
            origin: "docs/56 stage F, P5",
            check: ui_seams::the_canvas_registers_itself_in_appkit,
        },
        Rule {
            name: "leaf-seam-shapes",
            origin: "docs/56 stage F, P4",
            check: ui_seams::one_seam_two_shapes_one_installer,
        },
        Rule {
            name: "audio-row-is-rusts",
            origin: "docs/57 §5",
            check: held_values::the_audio_row_is_rusts,
        },
        Rule {
            name: "length-prefix-parsed-once",
            origin: "docs/55 §4",
            check: held_values::a_length_prefix_is_parsed_once,
        },
        Rule {
            name: "one-emission-order",
            origin: "docs/55 §4c",
            check: held_values::the_document_has_one_emission_order,
        },
        Rule {
            name: "macui-git-ladder",
            origin: "docs/55 §8",
            check: macui_memos::the_git_line_stays_measured,
        },
        Rule {
            name: "macui-corpus-once",
            origin: "docs/55 §8",
            check: macui_memos::open_quickly_builds_its_corpus_once,
        },
        Rule {
            name: "macui-unthemed-cache",
            origin: "docs/55 §8",
            check: macui_memos::the_canvas_remembers_unthemed_leaves,
        },
        Rule {
            name: "macui-leaf-kind",
            origin: "docs/55 §8",
            check: macui_memos::the_gui_leaf_remembers_its_kind,
        },
        Rule {
            name: "macui-pane-count",
            origin: "docs/55 §8",
            check: macui_memos::the_container_counts_without_arrays,
        },
        Rule {
            name: "macui-terminal-reach",
            origin: "docs/55 §8",
            check: macui_memos::the_terminal_reach_is_a_set,
        },
        Rule {
            name: "macui-glyph-guard",
            origin: "docs/55 §8",
            check: macui_memos::the_plate_guards_its_glyph_name,
        },
        Rule {
            name: "macui-spinner-dots",
            origin: "docs/55 §8",
            check: macui_memos::both_spinners_fill_through_coregraphics,
        },
        Rule {
            name: "macui-divider-readout",
            origin: "docs/55 §8",
            check: macui_memos::the_divider_hides_before_it_cuts,
        },
        Rule {
            name: "ops-daemon-container",
            origin: "docs/46",
            check: repo_invariants::an_ops_harness_that_starts_a_daemon_contains_it,
        },
        Rule {
            name: "green-tree-marker",
            origin: "docs/DECISIONS.md 2026-08-16",
            check: frozen_pairs::the_green_tree_marker_means_one_thing,
        },
        Rule {
            name: "liveness-bytes",
            origin: "docs/20 §6",
            check: frozen_pairs::the_liveness_bytes_agree,
        },
        Rule {
            name: "bucket-from-the-crate",
            origin: "docs/55 §6",
            check: rate_and_range::an_anti_flood_bucket_comes_from_the_crate,
        },
        Rule {
            name: "undecodable-stream-ends",
            origin: "docs/48",
            check: crossed_tables::an_undecodable_stream_ends,
        },
        Rule {
            name: "multi-loss-threshold",
            origin: "docs/55 §4b",
            check: crossed_tables::the_multi_loss_threshold_is_one_answer,
        },
        Rule {
            name: "level-bytes-through-doors",
            origin: "docs/55 §4b",
            check: crossed_tables::the_level_bytes_are_read_through_doors,
        },
        Rule {
            name: "dead-rust-expansion",
            origin: "docs/55 §8",
            check: crossed_tables::the_dead_rust_expansion_stays_deleted,
        },
        Rule {
            name: "one-pacing-schedule",
            origin: "docs/55 §4b",
            check: crossed_tables::one_pacing_schedule_and_one_gap,
        },
        Rule {
            name: "shipped-tables-are-the-crates",
            origin: "docs/55 §8",
            check: crossed_tables::the_shipped_tables_are_the_crates,
        },
        Rule {
            name: "no-second-path-opinion",
            origin: "docs/55 §6",
            check: path_confinement::no_second_path_opinion_in_swift,
        },
        Rule {
            name: "confinement-lexical-and-singular",
            origin: "docs/55 §6",
            check: path_confinement::the_confinement_rule_is_lexical_and_singular,
        },
        Rule {
            name: "confinement-door-reachable",
            origin: "docs/55 §2",
            check: path_confinement::the_confinement_door_is_reachable,
        },
        Rule {
            name: "mux-type-refused",
            origin: "docs/20 §4",
            check: path_confinement::an_unknown_mux_type_is_refused,
        },
        Rule {
            name: "one-panel-predicate",
            origin: "docs/55 §8",
            check: panel_predicates::one_device_panel_predicate,
        },
        Rule {
            name: "instrument-voice-minted-once",
            origin: "docs/55 §8",
            check: panel_predicates::the_instrument_voice_is_minted_once,
        },
        Rule {
            name: "android-level-array",
            origin: "docs/48",
            check: panel_predicates::the_android_level_filter_is_androidds,
        },
        Rule {
            name: "android-keycode-ratchet",
            origin: "docs/55 §8",
            check: panel_predicates::the_android_keycode_table_only_shrinks,
        },
        Rule {
            name: "one-cursor-label",
            origin: "docs/56",
            check: panel_predicates::the_cursor_style_has_one_label,
        },
        Rule {
            name: "seeded-names",
            origin: "docs/55 §8",
            check: crate_defaults::the_seeded_names_are_the_crates,
        },
        Rule {
            name: "encoder-defaults",
            origin: "docs/55 §8",
            check: crate_defaults::the_encoder_defaults_are_the_crates,
        },
        Rule {
            name: "rail-relabel-once",
            origin: "docs/55 §8",
            check: crate_defaults::a_rail_relabelling_crosses_once,
        },
        Rule {
            name: "one-line-col-splitter",
            origin: "docs/55 §8",
            check: crate_defaults::the_open_target_splits_once,
        },
        Rule {
            name: "one-ring-wrap",
            origin: "docs/55 §8",
            check: crate_defaults::a_ring_wraps_through_one_rule,
        },
        Rule {
            name: "master-owned-duplicate",
            origin: "docs/51 §2.3",
            check: sidecar_seams::a_master_crosses_owned,
        },
        Rule {
            name: "two-sidecar-lifecycles",
            origin: "docs/55 §6",
            check: sidecar_seams::two_sidecar_lifecycles_five_faces,
        },
        Rule {
            name: "one-deadline-latch",
            origin: "docs/55 §6",
            check: sidecar_seams::one_re_armable_deadline,
        },
        Rule {
            name: "one-pasteboard-clip",
            origin: "docs/55 §6",
            check: sidecar_seams::one_pasteboard_clip,
        },
        Rule {
            name: "one-sidecar-encoder",
            origin: "docs/22 §8",
            check: sidecar_seams::one_sidecar_encoder,
        },
        Rule {
            name: "one-debug-gate",
            origin: "docs/46",
            check: sidecar_seams::one_debug_gate_spelling,
        },
        Rule {
            name: "one-channel-tag",
            origin: "docs/17 §3.3",
            check: sidecar_seams::one_channel_tag,
        },
        Rule {
            name: "video-path-lends",
            origin: "docs/55 §8",
            check: video_ports::the_video_path_lends_what_it_holds,
        },
        Rule {
            name: "scroll-phase-table",
            origin: "docs/56 §3",
            check: video_ports::the_scroll_phases_are_one_table,
        },
        Rule {
            name: "quantiser-knob-clamps",
            origin: "docs/55 §4",
            check: video_ports::a_quantiser_knob_clamps_rather_than_rejects,
        },
        Rule {
            name: "settings-sheet-defaults",
            origin: "docs/55 §8",
            check: video_ports::the_settings_sheet_shows_the_encoders_defaults,
        },
        Rule {
            name: "env-knob-reject-rule",
            origin: "docs/55 §4",
            check: video_ports::the_reject_reading_of_an_env_knob_is_rusts,
        },
        Rule {
            name: "mirror-topology-memo",
            origin: "docs/55 §8",
            check: latency_ratchets::the_mirror_topology_is_projected_once,
        },
        Rule {
            name: "three-projections",
            origin: "docs/55 §4c",
            check: latency_ratchets::three_projections_read_once_per_pass,
        },
        Rule {
            name: "index-doors-guess",
            origin: "docs/55 §4",
            check: latency_ratchets::the_index_doors_guess_they_do_not_probe,
        },
        Rule {
            name: "scan-and-mirror-derive-once",
            origin: "docs/55 §4c, §8",
            check: latency_ratchets::the_scan_and_the_mirror_derive_once,
        },
        Rule {
            name: "canvas-drag-decides-once",
            origin: "docs/56 §3",
            check: command_surface::the_canvas_drag_decides_once,
        },
        Rule {
            name: "palette-verb-platform",
            origin: "docs/56 §3.6",
            check: command_surface::a_palette_verb_names_its_platform_once,
        },
        Rule {
            name: "palette-reaches-bindings",
            origin: "docs/56 §3.6",
            check: command_surface::every_keybinding_is_reachable_from_the_palette,
        },
        Rule {
            name: "keybinding-platform",
            origin: "docs/56 §3.6",
            check: command_surface::a_keybinding_names_its_platform_once,
        },
        Rule {
            name: "chord-table-held",
            origin: "docs/55 §8",
            check: command_surface::the_chord_table_is_held_not_rebuilt,
        },
        Rule {
            name: "frameworkless-value-floor",
            origin: "docs/56 stage F, P6",
            check: ink_floor::a_frameworkless_value_goes_to_the_floor,
        },
        Rule {
            name: "mac-scene-environment",
            origin: "docs/56 §3.5",
            check: ink_floor::the_mac_injects_no_environment_it_does_not_read,
        },
        Rule {
            name: "fold-gate-condition",
            origin: "docs/56 increments 61 and 63",
            check: ink_floor::the_fold_is_shut_from_both_sides,
        },
        Rule {
            name: "two-test-trees",
            origin: "docs/56 F4c",
            check: ink_floor::two_test_trees_one_relaxation,
        },
        Rule {
            name: "drop-chip-and-pill",
            origin: "docs/56 §3.5",
            check: ink_floor::one_drop_chip_two_drawings,
        },
        Rule {
            name: "named-ink-tables",
            origin: "docs/56 §3.5",
            check: ink_floor::a_named_ink_table_answers_every_renderer,
        },
        Rule {
            name: "static-mirror-deleted",
            origin: "docs/56 §3.5",
            check: ink_floor::the_static_mirror_stays_deleted,
        },
        Rule {
            name: "device-panel-law",
            origin: "check-supervisor.sh (deleted)",
            check: device_law::one_device_panel_law,
        },
        Rule {
            name: "device-list-sectioning",
            origin: "docs/47-simulator-panel.md",
            check: device_law::one_sectioning_for_both_panels,
        },
        Rule {
            name: "client-pasteboard-and-open",
            origin: "check-supervisor.sh (deleted)",
            check: device_law::one_pasteboard_and_one_open,
        },
        Rule {
            name: "small-rules-spelled-once",
            origin: "check-supervisor.sh (deleted)",
            check: device_law::the_small_rules_are_spelled_once,
        },
        Rule {
            name: "panel-vocabulary",
            origin: "check-supervisor.sh (deleted)",
            check: panel_shells::one_panel_vocabulary_four_surfaces,
        },
        Rule {
            name: "device-panel-twins",
            origin: "check-supervisor.sh (deleted)",
            check: panel_shells::two_device_panels_drawn_twice,
        },
        Rule {
            name: "device-panel-shells",
            origin: "check-supervisor.sh (deleted)",
            check: panel_shells::one_set_of_shells_and_one_caps_heading,
        },
        Rule {
            name: "design-floor",
            origin: "check-supervisor.sh (deleted)",
            check: panel_shells::one_design_floor_two_renderers,
        },
        Rule {
            name: "untrusted-regex-engine",
            origin: "check-supervisor.sh (deleted)",
            check: hot_paths::one_regex_engine_over_untrusted,
        },
        Rule {
            name: "palette-ranking",
            origin: "check-supervisor.sh (deleted)",
            check: hot_paths::palette_ranks_once_per_query,
        },
        Rule {
            name: "nerd-font-splitter",
            origin: "check-supervisor.sh (deleted)",
            check: hot_paths::nerd_font_run_splitter_linear,
        },
        Rule {
            name: "outbound-frame-merge",
            origin: "docs/59 §4, §8 rule 2",
            check: hot_paths::the_outbound_frame_merges_once,
        },
        Rule {
            name: "one-batch-one-pass-one-lock",
            origin: "docs/59 §4, step 4",
            check: hot_paths::one_batch_one_pass_one_lock,
        },
        Rule {
            name: "one-open-one-route",
            origin: "docs/59 §5, step 6",
            check: hot_paths::one_open_one_route,
        },
        Rule {
            name: "one-relation-one-table",
            origin: "docs/59 §5, step 7",
            check: hot_paths::one_relation_one_table,
        },
        Rule {
            name: "one-arc-one-ladder",
            origin: "docs/59 §5, step 5b",
            check: hot_paths::one_arc_one_ladder,
        },
        Rule {
            name: "one-metadata-verb-one-performer",
            origin: "docs/59 §5, step 8",
            check: hot_paths::one_metadata_verb_one_performer,
        },
        Rule {
            name: "subscriber-set-one-table",
            origin: "docs/59 §4, §8 rule 3",
            check: hot_paths::the_subscriber_set_is_one_table,
        },
        Rule {
            name: "live-docs-cite-real-files",
            origin: "CLAUDE.md §Read before you touch",
            check: repo_invariants::live_docs_cite_files_that_exist,
        },
        Rule {
            name: "comments-cite-real-files",
            origin: "CLAUDE.md §Read before you touch",
            check: repo_invariants::source_comments_cite_files_that_exist,
        },
        Rule {
            name: "injected-sinks-are-bound",
            origin: "docs/55 §6",
            check: repo_invariants::every_injected_sink_has_someone_who_binds_it,
        },
        Rule {
            name: "no-app-layer-crypto",
            origin: "CLAUDE.md §Rules",
            check: repo_invariants::no_app_layer_crypto,
        },
        Rule {
            name: "no-swiftpm-build-plugin",
            origin: "CLAUDE.md §Rules",
            check: repo_invariants::no_swiftpm_build_plugin,
        },
        Rule {
            name: "no-fused-multiply-add",
            origin: "CLAUDE.md §Rules",
            check: repo_invariants::no_fused_multiply_add,
        },
        Rule {
            name: "scripting-is-rust",
            origin: "CLAUDE.md §Rules, docs/46",
            check: repo_invariants::scripting_is_rust,
        },
        Rule {
            name: "release-ships-every-sidecar",
            origin: "docs/49",
            check: repo_invariants::the_release_ships_every_sidecar_the_host_needs,
        },
        Rule {
            name: "every-sidecar-is-pinned",
            origin: "docs/49",
            check: repo_invariants::every_shipped_sidecar_carries_its_own_version,
        },
        Rule {
            name: "formula-installs-every-binary",
            origin: "docs/49",
            check: repo_invariants::the_formula_installs_every_binary_the_release_ships,
        },
        Rule {
            name: "no-stranded-rust-module",
            origin: "CLAUDE.md §Rules",
            check: repo_invariants::no_rust_module_is_written_and_then_never_called,
        },
        Rule {
            name: "pkill-never-reaches-the-host",
            origin: "CLAUDE.md §Rules",
            check: repo_invariants::pkill_never_reaches_the_developers_host,
        },
        Rule {
            name: "shell-quoting-one-owner",
            origin: "docs/46",
            check: repo_invariants::shell_quoting_has_one_owner,
        },
        Rule {
            name: "shared-number-asked-or-ratcheted",
            origin: "CLAUDE.md §Rules",
            check: shared_constants::a_shared_number_is_asked_for_or_ratcheted,
        },
        Rule {
            name: "field-vocabularies-agree",
            origin: "docs/20",
            check: shared_constants::the_field_vocabularies_agree,
        },
        Rule {
            name: "wire-enums-agree",
            origin: "docs/20",
            check: shared_constants::the_wire_enums_agree,
        },
        Rule {
            name: "wire-flag-bits-agree",
            origin: "docs/20",
            check: shared_constants::the_wire_flag_bits_agree,
        },
        Rule {
            name: "constant-allowlists-alive",
            origin: "docs/55 §6",
            check: shared_constants::every_allowlist_entry_is_alive,
        },
        Rule {
            name: "ffi-doors-are-opened",
            origin: "docs/55 §3",
            check: gate_health::every_ffi_door_is_opened_or_declared_deliberate,
        },
        Rule {
            name: "deleted-host-swift",
            origin: "docs/50 §3, docs/51 §6.14, docs/52",
            check: deleted_host_swift::deleted_host_swift,
        },
        Rule {
            name: "spawn-request-flags",
            origin: "docs/51 §3",
            check: deleted_host_swift::spawn_request_flags_cross,
        },
        Rule {
            name: "source-dirs-are-targets",
            origin: "docs/46",
            check: package_graph::every_source_directory_is_a_target,
        },
        Rule {
            name: "linked-artifacts-are-built",
            origin: "docs/49",
            check: package_graph::every_linked_artifact_is_built_by_the_release,
        },
        Rule {
            name: "docc-links-resolve",
            origin: "CLAUDE.md §Rules, docs/55",
            check: doc_citations::every_docc_link_resolves,
        },
        Rule {
            name: "read-first-table-resolves",
            origin: "CLAUDE.md §Read before you touch",
            check: doc_citations::the_read_first_table_resolves,
        },
        Rule {
            name: "docs-cite-live-paths",
            origin: "docs/DECISIONS.md 2026-08-16",
            check: doc_citations::every_cited_path_exists,
        },
        Rule {
            name: "opaque-cap-inequality",
            origin: "check-supervisor.sh (deleted), docs/55 §8",
            check: shared_constants::the_opaque_cap_carries_its_inequality,
        },
        Rule {
            name: "cli-help-has-one-author",
            origin: "check-supervisor.sh (deleted) CLI block, docs/55 §8",
            check: cli_vocabulary::the_cli_help_has_one_author,
        },
        Rule {
            name: "client-control-vocabulary",
            origin: "rust/slopdesk-clientctl/src/lib.rs, docs/55 §8",
            check: cli_vocabulary::the_client_control_socket_has_one_vocabulary,
        },
        Rule {
            name: "ui-shell-cli-docs",
            origin: "check-supervisor.sh (deleted) CLI block, docs/55 §8",
            check: cli_vocabulary::the_ui_shell_docs_describe_the_shipped_cli,
        },
        Rule {
            name: "design-token-leaks",
            origin: "check-ds-leaks.sh (deleted), DESIGN.md",
            check: design_ratchets::design_tokens_are_not_bypassed,
        },
        Rule {
            name: "menu-shortcutless",
            origin: "check-menu-shortcutless.sh (deleted), docs/DECISIONS.md E1",
            check: design_ratchets::the_menu_bar_owns_no_chord,
        },
    ]
}

#[cfg(test)]
mod tests {
    /// A registry with two rules of the same name would make `--only` ambiguous and a differential
    /// diff unattributable.
    #[test]
    fn every_rule_name_is_unique() {
        let names: std::collections::BTreeSet<_> = super::registry().iter().map(|rule| rule.name).collect();
        assert_eq!(names.len(), super::registry().len());
    }

    /// Every rule must pass on the real tree. This is the gate itself, run as a test — which is
    /// what lets `cargo test` in this crate stand in for the whole shell script during development.
    #[test]
    fn the_live_tree_satisfies_every_rule() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(std::path::Path::parent)
            .expect("repository root is two levels above this crate")
            .to_path_buf();
        let tree = crate::Tree::load(&root).expect("load the repository");
        let violations = crate::run(&tree, None);
        assert!(violations.is_empty(), "{}", violations.join("\n"));
    }
}
