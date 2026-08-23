//! One module per section of the gate this crate replaces, and the registry that names them all.
//!
//! A rule lands here by being added to [`registry`] — there is no macro, no inventory crate and no
//! link-time registration, because the one property this list must have is that a reader can see
//! the whole enforced set in one screen. A rule that is written but not registered is a rule that
//! runs never, and the way to notice that is for the list to be short enough to read.

pub mod client_layers;
pub mod code_panel;
pub mod crate_policy;
pub mod device_streams;
pub mod hot_paths;
pub mod rust_boundaries;
pub mod screend;
pub mod screend_wire;
pub mod superd_bodies;
pub mod supervisor_envelope;
pub mod terminal_config;
pub mod terminal_surface;
pub mod video_client;
pub mod video_control;
pub mod video_host;
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
