//! One module per section of the gate this crate replaces, and the registry that names them all.
//!
//! A rule lands here by being added to [`registry`] — there is no macro, no inventory crate and no
//! link-time registration, because the one property this list must have is that a reader can see
//! the whole enforced set in one screen. A rule that is written but not registered is a rule that
//! runs never, and the way to notice that is for the list to be short enough to read.

pub mod agent_fold;
pub mod byte_scanners;
pub mod chrome_split;
pub mod cli_config;
pub mod client_layers;
pub mod client_memos;
pub mod code_panel;
pub mod command_surface;
pub mod crate_policy;
pub mod cross_twins;
pub mod device_frames;
pub mod device_law;
pub mod device_streams;
pub mod held_values;
pub mod host_probes;
pub mod hot_paths;
pub mod ink_floor;
pub mod latency_ratchets;
pub mod macui_memos;
pub mod overlay_split;
pub mod pane_wiring;
pub mod panel_floor;
pub mod panel_shells;
pub mod rust_boundaries;
pub mod screend;
pub mod screend_wire;
pub mod settings_catalog;
pub mod settings_rows;
pub mod split_surfaces;
pub mod superd_bodies;
pub mod supervisor_envelope;
pub mod terminal_config;
pub mod terminal_grammar;
pub mod terminal_surface;
pub mod ui_seams;
pub mod ui_split;
pub mod transport_lanes;
pub mod video_client;
pub mod video_control;
pub mod video_host;
pub mod video_ports;
pub mod video_seams;
pub mod video_wire;
pub mod window_placement;
pub mod wire_codecs;
pub mod workspace_document;
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
            name: "big-endian-helpers",
            origin: "docs/20 §2",
            check: wire_codecs::big_endian_helpers,
        },
        Rule {
            name: "cursor-overlay-and-progress",
            origin: "scripts/check-supervisor.sh",
            check: video_seams::cursor_lands_where_click_does,
        },
        Rule {
            name: "client-session",
            origin: "scripts/check-supervisor.sh",
            check: video_seams::client_session_decides_once_hello,
        },
        Rule {
            name: "client-view",
            origin: "scripts/check-supervisor.sh",
            check: video_seams::pane_pans_scales_adopts_snaps,
        },
        Rule {
            name: "client-jitter",
            origin: "scripts/check-supervisor.sh",
            check: video_seams::buffer_sized_by_one_estimate,
        },
        Rule {
            name: "client-input",
            origin: "scripts/check-supervisor.sh",
            check: video_seams::click_lands_where_cursor_no,
        },
        Rule {
            name: "scroll-hint",
            origin: "scripts/check-supervisor.sh",
            check: video_seams::scroll_hint_one_encoding_far,
        },
        Rule {
            name: "client-gestures",
            origin: "scripts/check-supervisor.sh",
            check: video_seams::client_gesture_policies_are_asked,
        },
        Rule {
            name: "paced-send",
            origin: "scripts/check-supervisor.sh",
            check: video_seams::paced_send_schedule_one_answer,
        },
        Rule {
            name: "host-session-machine",
            origin: "scripts/check-supervisor.sh",
            check: video_seams::host_session_machine_crosses_by,
        },
        Rule {
            name: "parked-window",
            origin: "scripts/check-supervisor.sh",
            check: window_placement::parked_window_placed_by_one,
        },
        Rule {
            name: "off-screen-rescue",
            origin: "scripts/check-supervisor.sh",
            check: window_placement::off_screen_rescue_decides_once,
        },
        Rule {
            name: "discovery-and-resend",
            origin: "scripts/check-supervisor.sh",
            check: window_placement::one_discovery_one_resend_schedule,
        },
        Rule {
            name: "raise-rule",
            origin: "scripts/check-supervisor.sh",
            check: window_placement::raise_rule_read_once_off,
        },
        Rule {
            name: "ledger-and-accumulator",
            origin: "scripts/check-supervisor.sh",
            check: window_placement::ledger_accumulator_cross_by_value,
        },
        Rule {
            name: "keybind-grammar",
            origin: "scripts/check-supervisor.sh",
            check: terminal_config::one_keybind_grammar_no_callback,
        },
        Rule {
            name: "terminal-config-emitter",
            origin: "scripts/check-supervisor.sh",
            check: terminal_config::one_terminal_config_emitter_swift,
        },
        Rule {
            name: "named-key-table",
            origin: "scripts/check-supervisor.sh",
            check: terminal_config::one_named_key_table_what,
        },
        Rule {
            name: "reset-backstop",
            origin: "scripts/check-supervisor.sh",
            check: terminal_config::reset_backstop_built_from_set,
        },
        Rule {
            name: "pane-directory",
            origin: "scripts/check-supervisor.sh",
            check: terminal_config::one_rule_for_pane_directory,
        },
        Rule {
            name: "keybindings-search",
            origin: "scripts/check-supervisor.sh",
            check: terminal_config::keybindings_search_crosses_once_for,
        },
        Rule {
            name: "client-send-keys",
            origin: "scripts/check-supervisor.sh",
            check: terminal_config::client_send_keys_asks_one,
        },
        Rule {
            name: "config-name-table",
            origin: "scripts/check-supervisor.sh",
            check: terminal_config::one_config_name_table_goto,
        },
        Rule {
            name: "scrcpy-control",
            origin: "scripts/check-supervisor.sh",
            check: device_streams::one_writer_for_scrcpy_control,
        },
        Rule {
            name: "wait-scan",
            origin: "scripts/check-supervisor.sh",
            check: device_streams::wait_stream_scanned_once_off,
        },
        Rule {
            name: "watch-vocabulary",
            origin: "scripts/check-supervisor.sh",
            check: workspace_layout::what_watch_decides_what_prints,
        },
        Rule {
            name: "borderless-dwell",
            origin: "scripts/check-supervisor.sh",
            check: workspace_layout::one_dwell_decides_who_owns,
        },
        Rule {
            name: "divider-weight",
            origin: "scripts/check-supervisor.sh",
            check: workspace_layout::one_pixel_weight_conversion_seam,
        },
        Rule {
            name: "rail-badge-gates",
            origin: "scripts/check-supervisor.sh",
            check: workspace_layout::rail_render_reads_its_badge,
        },
        Rule {
            name: "client-core-draws-nothing",
            origin: "scripts/check-supervisor.sh",
            check: client_layers::presentation_logic_draws_nothing_both,
        },
        Rule {
            name: "code-panel-font-pair",
            origin: "scripts/check-supervisor.sh",
            check: code_panel::font_pair_agrees_across_the_seam,
        },
        Rule {
            name: "code-panel-one-implementation",
            origin: "scripts/check-supervisor.sh",
            check: code_panel::dressing_is_one_implementation,
        },
        Rule {
            name: "motion-run-rule",
            origin: "scripts/check-supervisor.sh",
            check: terminal_grammar::one_motion_run_rule_answers,
        },
        Rule {
            name: "key-vocabulary",
            origin: "scripts/check-supervisor.sh",
            check: terminal_grammar::one_key_vocabulary_whichever_grammar,
        },
        Rule {
            name: "styled-vt-grammar",
            origin: "scripts/check-supervisor.sh",
            check: terminal_grammar::one_vt_grammar_for_styled,
        },
        Rule {
            name: "paste-guard",
            origin: "scripts/check-supervisor.sh",
            check: terminal_grammar::one_paste_guard_secret_one,
        },
        Rule {
            name: "copy-mode-clustering",
            origin: "scripts/check-supervisor.sh",
            check: terminal_grammar::one_clustering_answers_cursor_badge,
        },
        Rule {
            name: "foreground-process-vocabulary",
            origin: "scripts/check-supervisor.sh",
            check: host_probes::one_vocabulary_for_foreground_process,
        },
        Rule {
            name: "hostd-binary-order",
            origin: "scripts/check-supervisor.sh",
            check: host_probes::hostd_finds_program_by_one,
        },
        Rule {
            name: "fuzzy-ranking",
            origin: "scripts/check-supervisor.sh",
            check: client_memos::one_fuzzy_ranking_for_every,
        },
        Rule {
            name: "rail-fingerprint",
            origin: "scripts/check-supervisor.sh",
            check: client_memos::rail_fingerprint_asks_for_its,
        },
        Rule {
            name: "screend-frame-encoder",
            origin: "scripts/check-supervisor.sh",
            check: device_frames::one_encoder_for_screend_frame,
        },
        Rule {
            name: "scrcpy-stream-reader",
            origin: "scripts/check-supervisor.sh",
            check: device_frames::one_reader_for_scrcpy_stream,
        },
        Rule {
            name: "split-drop-zone",
            origin: "scripts/check-supervisor.sh",
            check: split_surfaces::the_drop_overlay_draws_one_shape,
        },
        Rule {
            name: "split-cheat-sheet",
            origin: "scripts/check-supervisor.sh",
            check: split_surfaces::one_cheat_sheet_two_layouts,
        },
        Rule {
            name: "split-toast-card",
            origin: "scripts/check-supervisor.sh",
            check: split_surfaces::one_notification_card_two_corners,
        },
        Rule {
            name: "split-palette",
            origin: "scripts/check-supervisor.sh",
            check: split_surfaces::one_palette_two_frameworks,
        },
        Rule {
            name: "split-bespoke-settings",
            origin: "scripts/check-supervisor.sh",
            check: split_surfaces::one_bespoke_settings_surface,
        },
        Rule {
            name: "cli-folder-frecency",
            origin: "scripts/check-supervisor.sh",
            check: cli_config::folders_rank_once_and_a_jump_reads_it,
        },
        Rule {
            name: "config-file-reader",
            origin: "scripts/check-supervisor.sh",
            check: cli_config::the_config_file_has_one_reader,
        },
        Rule {
            name: "number-spelled-once",
            origin: "scripts/check-supervisor.sh",
            check: cli_config::a_number_is_spelled_once,
        },
        Rule {
            name: "swipe-nav-handle",
            origin: "scripts/check-supervisor.sh",
            check: cli_config::the_swipe_nav_operating_point_is_a_handle,
        },
        Rule {
            name: "plain-text-vt-grammar",
            origin: "scripts/check-supervisor.sh",
            check: byte_scanners::one_vt_grammar_for_plain_text,
        },
        Rule {
            name: "shell-word-quoting",
            origin: "scripts/check-supervisor.sh",
            check: byte_scanners::one_shell_word_wherever_a_path_is_typed,
        },
        Rule {
            name: "width-table",
            origin: "scripts/check-supervisor.sh",
            check: byte_scanners::one_width_table_under_that_clustering,
        },
        Rule {
            name: "escape-end-grammar",
            origin: "scripts/check-supervisor.sh",
            check: byte_scanners::one_grammar_for_where_an_escape_ends,
        },
        Rule {
            name: "find-bar-engine",
            origin: "scripts/check-supervisor.sh",
            check: byte_scanners::the_find_bar_asks_the_same_engine,
        },
        Rule {
            name: "base64-and-secret-notation",
            origin: "scripts/check-supervisor.sh",
            check: byte_scanners::one_base64_and_one_secret_notation,
        },
        Rule {
            name: "escape-decoding",
            origin: "scripts/check-supervisor.sh",
            check: byte_scanners::one_reading_of_an_escape,
        },
        Rule {
            name: "tab-badge-ladder",
            origin: "scripts/check-supervisor.sh",
            check: agent_fold::one_badge_ladder_for_a_tab_row,
        },
        Rule {
            name: "hook-body-reading",
            origin: "scripts/check-supervisor.sh",
            check: agent_fold::one_reading_of_a_hook_body,
        },
        Rule {
            name: "pane-detector-probes",
            origin: "scripts/check-supervisor.sh",
            check: agent_fold::one_pane_detector_and_the_probes_only_probe,
        },
        Rule {
            name: "secret-shape-vocabulary",
            origin: "scripts/check-supervisor.sh",
            check: agent_fold::one_vocabulary_of_secret_shapes,
        },
        Rule {
            name: "fresh-install-payload",
            origin: "scripts/check-supervisor.sh",
            check: agent_fold::what_a_fresh_install_carries,
        },
        Rule {
            name: "device-console-grammar",
            origin: "scripts/check-supervisor.sh",
            check: transport_lanes::one_grammar_per_device_console,
        },
        Rule {
            name: "superd-frame-spelling",
            origin: "scripts/check-supervisor.sh",
            check: transport_lanes::one_spelling_of_the_superd_frame,
        },
        Rule {
            name: "receive-buffer",
            origin: "scripts/check-supervisor.sh",
            check: transport_lanes::one_receive_buffer_and_one_narrowing,
        },
        Rule {
            name: "arena-reader",
            origin: "scripts/check-supervisor.sh",
            check: transport_lanes::one_arena_reader_and_one_interner,
        },
        Rule {
            name: "nwconnection-channel",
            origin: "scripts/check-supervisor.sh",
            check: transport_lanes::one_nwconnection_byte_channel,
        },
        Rule {
            name: "write-loop",
            origin: "scripts/check-supervisor.sh",
            check: transport_lanes::one_write_loop_and_one_read_exactly,
        },
        Rule {
            name: "overlay-host-ambient-layer",
            origin: "scripts/check-supervisor.sh",
            check: overlay_split::the_overlay_host_holds_no_ambient_layer,
        },
        Rule {
            name: "split-peek-card",
            origin: "scripts/check-supervisor.sh",
            check: overlay_split::one_peek_card_two_frameworks,
        },
        Rule {
            name: "keystroke-and-peek-rules",
            origin: "scripts/check-supervisor.sh",
            check: overlay_split::the_keystroke_table_and_peek_rules_are_rusts,
        },
        Rule {
            name: "split-global-search",
            origin: "scripts/check-supervisor.sh",
            check: overlay_split::one_global_search_two_frameworks,
        },
        Rule {
            name: "split-picker",
            origin: "scripts/check-supervisor.sh",
            check: overlay_split::one_picker_two_frameworks,
        },
        Rule {
            name: "stage-d-ledger",
            origin: "scripts/check-supervisor.sh",
            check: overlay_split::the_stage_d_ledger_is_empty,
        },
        Rule {
            name: "split-navigator",
            origin: "scripts/check-supervisor.sh",
            check: chrome_split::one_navigator_per_platform,
        },
        Rule {
            name: "split-titlebar-band",
            origin: "scripts/check-supervisor.sh",
            check: chrome_split::one_titlebar_band_one_connection_reading,
        },
        Rule {
            name: "split-panel-chrome",
            origin: "scripts/check-supervisor.sh",
            check: chrome_split::one_panel_chrome_one_tab_reading,
        },
        Rule {
            name: "device-panel-floor",
            origin: "scripts/check-supervisor.sh",
            check: panel_floor::the_device_panel_floor_builds_for_the_phone,
        },
        Rule {
            name: "device-panels-both-platforms",
            origin: "scripts/check-supervisor.sh",
            check: panel_floor::both_device_panels_draw_on_both_platforms,
        },
        Rule {
            name: "code-panel-crosses",
            origin: "scripts/check-supervisor.sh",
            check: panel_floor::the_code_panel_crosses,
        },
        Rule {
            name: "terminal-pane-wiring",
            origin: "scripts/check-supervisor.sh",
            check: pane_wiring::one_terminal_wiring_and_its_teardown_order,
        },
        Rule {
            name: "escape-monitor",
            origin: "scripts/check-supervisor.sh",
            check: pane_wiring::one_escape_monitor_installed_and_removed_once,
        },
        Rule {
            name: "phone-key-path",
            origin: "scripts/check-supervisor.sh",
            check: pane_wiring::the_phone_key_path_is_rust,
        },
        Rule {
            name: "tree-repair",
            origin: "scripts/check-supervisor.sh",
            check: cross_twins::one_tree_repair_in_rust,
        },
        Rule {
            name: "cross-language-twins",
            origin: "scripts/check-supervisor.sh",
            check: cross_twins::four_cross_language_twins,
        },
        Rule {
            name: "loop-shaped-crossings",
            origin: "scripts/check-supervisor.sh",
            check: cross_twins::the_loop_shaped_crossings_are_whole_collection_doors,
        },
        Rule {
            name: "settings-option-groups",
            origin: "scripts/check-supervisor.sh",
            check: settings_catalog::the_option_groups_cross_whole_and_once,
        },
        Rule {
            name: "settings-constant-answers",
            origin: "scripts/check-supervisor.sh",
            check: settings_catalog::the_cheat_sheet_and_menu_bar_hold_their_constants,
        },
        Rule {
            name: "ui-split-shape",
            origin: "docs/56 §3",
            check: ui_split::the_ui_split_holds_its_shape,
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
            name: "catalog-indexed-once",
            origin: "docs/55 §8",
            check: held_values::a_catalog_is_indexed_not_rescanned,
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
            origin: "scripts/check-supervisor.sh",
            check: device_law::one_device_panel_law,
        },
        Rule {
            name: "client-pasteboard-and-open",
            origin: "scripts/check-supervisor.sh",
            check: device_law::one_pasteboard_and_one_open,
        },
        Rule {
            name: "small-rules-spelled-once",
            origin: "scripts/check-supervisor.sh",
            check: device_law::the_small_rules_are_spelled_once,
        },
        Rule {
            name: "panel-vocabulary",
            origin: "scripts/check-supervisor.sh",
            check: panel_shells::one_panel_vocabulary_four_surfaces,
        },
        Rule {
            name: "device-panel-twins",
            origin: "scripts/check-supervisor.sh",
            check: panel_shells::two_device_panels_drawn_twice,
        },
        Rule {
            name: "device-panel-shells",
            origin: "scripts/check-supervisor.sh",
            check: panel_shells::one_set_of_shells_and_one_caps_heading,
        },
        Rule {
            name: "design-floor",
            origin: "scripts/check-supervisor.sh",
            check: panel_shells::one_design_floor_two_renderers,
        },
        Rule {
            name: "settings-row-naming",
            origin: "scripts/check-supervisor.sh",
            check: settings_rows::a_setting_is_named_once,
        },
        Rule {
            name: "settings-key-spelling",
            origin: "scripts/check-supervisor.sh",
            check: settings_rows::a_settings_key_is_spelled_once,
        },
        Rule {
            name: "settings-page-shape",
            origin: "scripts/check-supervisor.sh",
            check: settings_rows::a_settings_page_is_shaped_once,
        },
        Rule {
            name: "chord-editor-twins",
            origin: "scripts/check-supervisor.sh",
            check: settings_rows::one_chord_editor_drawn_twice,
        },
        Rule {
            name: "untrusted-regex-engine",
            origin: "scripts/check-supervisor.sh",
            check: hot_paths::one_regex_engine_over_untrusted,
        },
        Rule {
            name: "palette-ranking",
            origin: "scripts/check-supervisor.sh",
            check: hot_paths::palette_ranks_once_per_query,
        },
        Rule {
            name: "nerd-font-splitter",
            origin: "scripts/check-supervisor.sh",
            check: hot_paths::nerd_font_run_splitter_linear,
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
