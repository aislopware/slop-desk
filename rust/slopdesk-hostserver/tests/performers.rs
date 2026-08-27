//! The six host-global doors, and the table that routes to them.
//!
//! What is asserted here is what the Swift's six shims had no way to assert: that the routing table
//! and the performers AGREE. Each shim used to re-derive "is this my verb" from the byte, so a verb
//! could reach a performer that did not own it and the only witness was a wrong answer at runtime.
//! [`Performers`] takes the answer [`slopdesk_muxsession::metadata_admission::performer`] already
//! gave, and the first test below drives every one of the twelve verbs through the real function
//! rather than through a hand-written expectation.
//!
//! Everything here is a fake. No pasteboard, no Launch Services, no superd, no code-server: the
//! decisions are the whole subject, and each production door has one line of body.

#![expect(
    clippy::unwrap_used,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use slopdesk_hostserver::agentaction::{AgentActions, InstallsAgentHooks};
use slopdesk_hostserver::code::{CodeBridge, CodeServerManager, CodeServerSeams, Profile as CodeProfile};
use slopdesk_hostserver::codeaction::CodeActions;
use slopdesk_hostserver::ensure::{EnsuredService, Profile as EnsureProfile};
use slopdesk_hostserver::pathaction::OpensPaths;
use slopdesk_hostserver::route::Performers;
use slopdesk_hostserver::service::{Endpoint, LogSink, ServiceHandle, SpawnFailed, Spawner};
use slopdesk_hostsession::{MetadataAnswer, MetadataPerformer, MetadataRequest};
use slopdesk_muxsession::metadata_admission::{Performer, performer};
use slopdesk_sidecars::service_lifecycle::ServiceState;
use slopdesk_wire::MetadataStatus;
use slopdesk_wire::metadata::MetadataVerb;
use slopdesk_wire::metadata::codec::{
    CodeFontSpec, CodeOpenDisposition, decode_agent_hook_status, decode_code_open_disposition,
    decode_service_endpoint, encode_code_font_spec,
};

/// A probe interval no test can outrun, so a readiness probe fires exactly once per fixture.
const NEVER_AGAIN: Duration = Duration::from_secs(3600);

// MARK: - Driving one request

/// One request at `verb`, routed the way production routes it.
fn ask(door: &dyn MetadataPerformer, verb: MetadataVerb, payload: &[u8]) -> MetadataAnswer {
    door.perform(&MetadataRequest {
        request_id: 7,
        verb: verb.as_byte(),
        payload,
        performer: performer(verb.as_byte()),
        master_fd: 9,
        shell_pid: 4242,
    })
}

/// The typed status of an answer.
const fn status_of(answer: &MetadataAnswer) -> MetadataStatus {
    MetadataStatus::from_byte(answer.status).unwrap()
}

// MARK: - The routing table

/// A door that answers `ok` with its own name, so a test can read WHICH seat was reached.
#[derive(Debug)]
struct Named(&'static str);

impl MetadataPerformer for Named {
    fn perform(&self, _request: &MetadataRequest<'_>) -> MetadataAnswer {
        MetadataAnswer::ok(self.0.as_bytes().to_vec())
    }
}

/// A table whose six seats each announce themselves.
fn labelled() -> Performers {
    Performers {
        path: Arc::new(Named("path")),
        agent: Arc::new(Named("agent")),
        clipboard: Arc::new(Named("clipboard")),
        code: Arc::new(Named("code")),
        simulator: Arc::new(Named("simulator")),
        android: Arc::new(Named("android")),
    }
}

/// The anchor: every verb the admission table names goes to the seat it names, checked against the
/// real function rather than against a list written here.
#[test]
fn every_named_verb_reaches_the_seat_the_admission_table_names() {
    let table = labelled();
    for verb in MetadataVerb::ALL {
        let seat = match performer(verb.as_byte()) {
            Performer::Path => "path",
            Performer::Agent => "agent",
            Performer::Clipboard => "clipboard",
            Performer::CodeServer => "code",
            Performer::Simulator => "simulator",
            Performer::Android => "android",
            // The read verbs never arrive: `HostMetadata` answers them and delegates the rest.
            Performer::Builder => continue,
        };
        let answer = ask(&table, verb, b"");
        assert_eq!(
            String::from_utf8(answer.payload).unwrap(),
            seat,
            "verb {} went to the wrong door",
            verb.as_byte(),
        );
    }
}

/// A builder verb cannot arrive — the only caller filters it out — and if one ever did it is
/// answered rather than misrouted into a seat that would perform an effect.
#[test]
fn a_builder_verb_is_refused_rather_than_routed() {
    let answer = labelled().perform(&MetadataRequest {
        request_id: 7,
        verb: MetadataVerb::GitStatus.as_byte(),
        payload: b"",
        performer: Performer::Builder,
        master_fd: 9,
        shell_pid: 4242,
    });
    assert_eq!(status_of(&answer), MetadataStatus::UnsupportedVerb);
    assert!(answer.payload.is_empty());
}

/// An unfilled seat answers AT ONCE. Dropping the request instead would make the client's pending
/// registry wait out its own timeout for an answer that was never coming.
#[test]
fn an_empty_seat_answers_unsupported_rather_than_nothing() {
    let table = Performers::unserved();
    for verb in [
        MetadataVerb::OpenPath,
        MetadataVerb::InstallAgentHooks,
        MetadataVerb::SetClipboard,
        MetadataVerb::EnsureCodeServer,
        MetadataVerb::EnsureSimulatorServer,
        MetadataVerb::EnsureAndroidBridge,
    ] {
        assert_eq!(
            status_of(&ask(&table, verb, b"")),
            MetadataStatus::UnsupportedVerb,
            "verb {} answered something other than unsupported",
            verb.as_byte(),
        );
    }
}

// MARK: - The agent hooks (11–13)

/// An installer that answers what the test wants and counts what it was asked.
#[derive(Debug)]
struct Hooks {
    installed: AtomicBool,
    writable: bool,
    installs: AtomicUsize,
    uninstalls: AtomicUsize,
}

impl Hooks {
    fn new(installed: bool, writable: bool) -> Arc<Self> {
        Arc::new(Self {
            installed: AtomicBool::new(installed),
            writable,
            installs: AtomicUsize::new(0),
            uninstalls: AtomicUsize::new(0),
        })
    }
}

/// The installer as the performer takes it — by value, so the test keeps its own handle on the
/// state. A newtype rather than `impl … for Arc<Hooks>`, which the orphan rule refuses.
#[derive(Clone, Debug)]
struct Shared(Arc<Hooks>);

impl InstallsAgentHooks for Shared {
    fn install(&self) -> bool {
        self.0.installs.fetch_add(1, Ordering::SeqCst);
        if self.0.writable {
            self.0.installed.store(true, Ordering::SeqCst);
        }
        self.0.writable
    }

    fn uninstall(&self) -> bool {
        self.0.uninstalls.fetch_add(1, Ordering::SeqCst);
        if self.0.writable {
            self.0.installed.store(false, Ordering::SeqCst);
        }
        self.0.writable
    }

    fn is_installed(&self) -> bool {
        self.0.installed.load(Ordering::SeqCst)
    }
}

/// The two flags are two facts. Installed-but-inactive is the state the settings card exists to be
/// able to say, and a performer that folded them into one would paint a green over hooks that are
/// written and cannot fire.
#[test]
fn the_status_verb_reports_installation_and_the_listener_separately() {
    let door = Hooks::new(true, true);
    let live = Arc::new(AtomicBool::new(false));
    let watching = Arc::clone(&live);
    let actions = AgentActions::new(
        Shared(Arc::clone(&door)),
        Arc::new(move || watching.load(Ordering::SeqCst)),
    );

    let flags = decode_agent_hook_status(&ask(&actions, MetadataVerb::AgentHookStatus, b"").payload).unwrap();
    assert!(flags.installed);
    assert!(
        !flags.listener_active,
        "hooks in settings.json say nothing about whether the socket is bound",
    );

    live.store(true, Ordering::SeqCst);
    let flags = decode_agent_hook_status(&ask(&actions, MetadataVerb::AgentHookStatus, b"").payload).unwrap();
    assert!(
        flags.listener_active,
        "the flag is read at PERFORM time — a bind that happened after composition must show",
    );
}

/// Install and uninstall move the state and answer `ok`; a settings file that cannot be written
/// answers `error`, because the client asked for a change that did not happen.
#[test]
fn install_and_uninstall_answer_whether_the_state_actually_moved() {
    let door = Hooks::new(false, true);
    let actions = AgentActions::new(Shared(Arc::clone(&door)), Arc::new(|| true));

    assert_eq!(
        status_of(&ask(&actions, MetadataVerb::InstallAgentHooks, b"")),
        MetadataStatus::Ok,
    );
    assert!(door.installed.load(Ordering::SeqCst));
    assert_eq!(
        status_of(&ask(&actions, MetadataVerb::UninstallAgentHooks, b"")),
        MetadataStatus::Ok,
    );
    assert!(!door.installed.load(Ordering::SeqCst));

    let refusing = Hooks::new(false, false);
    let actions = AgentActions::new(Shared(Arc::clone(&refusing)), Arc::new(|| true));
    assert_eq!(
        status_of(&ask(&actions, MetadataVerb::InstallAgentHooks, b"")),
        MetadataStatus::Error,
    );
    assert_eq!(refusing.installs.load(Ordering::SeqCst), 1);
}

/// The three verbs are host-GLOBAL, so a payload is ignored rather than refused — deliberately the
/// opposite of the two ensure verbs, which have nothing to scope AND a structured reply a future
/// field could extend.
#[test]
fn the_agent_verbs_ignore_a_payload_rather_than_refusing_it() {
    let door = Hooks::new(true, true);
    let actions = AgentActions::new(Shared(door), Arc::new(|| true));
    assert_eq!(
        status_of(&ask(&actions, MetadataVerb::AgentHookStatus, b"unexpected")),
        MetadataStatus::Ok,
    );
}

// MARK: - The ensure verbs (21, 22)

/// A supervised child that is always up.
#[derive(Debug)]
struct Backend;

impl ServiceHandle for Backend {
    fn is_running(&self) -> bool {
        true
    }

    fn terminate(&self) {}

    fn relinquish(&self) {}
}

/// Every argv a fixture's spawner was handed.
type Argv = Arc<Mutex<Vec<Vec<String>>>>;

/// A service over fakes: `binary` decides whether the host has one, `refuses` whether the spawn
/// throws.
fn ensured(
    verb: MetadataVerb,
    binary: Option<&str>,
    refuses: bool,
    unspawnable: ServiceState,
) -> (Arc<EnsuredService>, Argv) {
    let argv = Argv::default();
    let recorded = Arc::clone(&argv);
    let spawner: Spawner = Arc::new(move |_binary, arguments, _sink: LogSink| {
        recorded
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(arguments.to_vec());
        if refuses {
            return Err(SpawnFailed {
                reason: "superd is not running".to_owned(),
            });
        }
        let handle: Arc<dyn ServiceHandle> = Arc::new(Backend);
        Ok(handle)
    });
    let found = binary.map(str::to_owned);
    let service = Arc::new(EnsuredService::new(
        EnsureProfile {
            verb,
            binary_locator: Arc::new(move || found.clone()),
            spawner,
            arguments: vec!["--port".to_owned(), "0".to_owned()],
            parse_port: Arc::new(|_line| None),
            parse_version: None,
            unspawnable,
        },
        Arc::new(|_port| false),
        NEVER_AGAIN,
    ));
    (service, argv)
}

/// A host with no binary reports `unavailable` and never spawns — and it is an `ok` ANSWER, not a
/// failed verb: "there is nothing here to run" is what the panel's install hint renders.
#[test]
fn a_missing_binary_is_an_available_answer_of_unavailable() {
    let (service, argv) = ensured(
        MetadataVerb::EnsureSimulatorServer,
        None,
        false,
        ServiceState::Unavailable,
    );
    let answer = ask(service.as_ref(), MetadataVerb::EnsureSimulatorServer, b"");
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    let endpoint = decode_service_endpoint(&answer.payload).unwrap();
    assert_eq!(endpoint.state_byte, ServiceState::Unavailable.byte());
    assert_eq!(endpoint.port, 0, "an unavailable service has no port");
    assert!(argv.lock().unwrap().is_empty());
}

/// The two services answer a FAILED spawn differently, and the difference is the whole reason the
/// profile carries it: a `baguette` that will not exec means the host has no simulator server,
/// while an `androidd` that will not exec means superd was busy.
#[test]
fn a_failed_spawn_reports_what_that_service_says_it_means() {
    let (simulator, _argv) = ensured(
        MetadataVerb::EnsureSimulatorServer,
        Some("/bin/baguette"),
        true,
        ServiceState::Unavailable,
    );
    let answer = ask(simulator.as_ref(), MetadataVerb::EnsureSimulatorServer, b"");
    assert_eq!(
        decode_service_endpoint(&answer.payload).unwrap().state_byte,
        ServiceState::Unavailable.byte(),
    );

    let (android, _argv) = ensured(
        MetadataVerb::EnsureAndroidBridge,
        Some("/bin/slopdesk-androidd"),
        true,
        ServiceState::Starting,
    );
    let answer = ask(android.as_ref(), MetadataVerb::EnsureAndroidBridge, b"");
    assert_eq!(
        decode_service_endpoint(&answer.payload).unwrap().state_byte,
        ServiceState::Starting.byte(),
        "a transient spawn refusal must keep the client polling, not raise an install hint",
    );
}

/// A payload carrying bytes is a client this build does not understand. Refusing it is what stops a
/// future field being silently dropped by an old host that would then look like it had honoured a
/// request it never read — so the spawn must not happen either.
#[test]
fn an_ensure_verb_refuses_a_payload_and_does_not_spawn() {
    let (service, argv) = ensured(
        MetadataVerb::EnsureSimulatorServer,
        Some("/bin/baguette"),
        false,
        ServiceState::Unavailable,
    );
    let answer = ask(
        service.as_ref(),
        MetadataVerb::EnsureSimulatorServer,
        b"/some/root",
    );
    assert_eq!(status_of(&answer), MetadataStatus::Error);
    assert!(answer.payload.is_empty());
    assert!(argv.lock().unwrap().is_empty());
}

/// A verb this service does not own takes the same exit rather than a second opinion about the
/// routing table.
#[test]
fn an_ensure_service_refuses_the_other_services_verb() {
    let (service, argv) = ensured(
        MetadataVerb::EnsureSimulatorServer,
        Some("/bin/baguette"),
        false,
        ServiceState::Unavailable,
    );
    let answer = ask(service.as_ref(), MetadataVerb::EnsureAndroidBridge, b"");
    assert_eq!(status_of(&answer), MetadataStatus::Error);
    assert!(argv.lock().unwrap().is_empty());
}

// MARK: - The workbench verbs (18–20)

/// A bridge that never claims a window, so verb 19 falls through to the CLI arm.
#[derive(Debug)]
struct NoWindows;

impl CodeBridge for NoWindows {
    fn start(&self, _path: &str) {}

    fn open(&self, _target: &str) -> bool {
        false
    }

    fn stop(&self) {}
}

/// A Launch Services that records and accepts.
#[derive(Debug, Default)]
struct Opened {
    paths: Mutex<Vec<String>>,
}

/// The same shape as [`Shared`], and for the same orphan-rule reason.
#[derive(Clone, Debug)]
struct Launcher(Arc<Opened>);

impl OpensPaths for Launcher {
    fn open(&self, path: &str) -> bool {
        self.0
            .paths
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(path.to_owned());
        true
    }

    fn reveal(&self, _path: &str) {}
}

/// The font spec the seeder was last handed.
type Font = Arc<Mutex<Option<CodeFontSpec>>>;

/// A manager over fakes. `binary` decides whether this host has code-server at all, which is what
/// verb 19's routing turns on.
fn workbench(binary: Option<&str>) -> (Arc<CodeServerManager>, Font) {
    let font = Font::default();
    let recorded = Arc::clone(&font);
    let found = binary.map(str::to_owned);
    let handle: Spawner = Arc::new(|_binary, _arguments, _sink: LogSink| {
        let live: Arc<dyn ServiceHandle> = Arc::new(Backend);
        Ok(live)
    });
    let seams = CodeServerSeams {
        binary_locator: Arc::new(move || found.clone()),
        spawner: handle,
        readiness_probe: Arc::new(|_port| false),
        settings_seeder: Arc::new(|| {}),
        // Never zero: the CLI must not be able to report the open landed, or the fallback arm this
        // suite is about would never be reached.
        cli_runner: Arc::new(|_binary, _arguments| Some(1)),
        missing_extensions: Arc::new(Vec::new),
        font_sync: Arc::new(move |spec| {
            *recorded.lock().unwrap_or_else(PoisonError::into_inner) = Some(spec.clone());
            true
        }),
        profile_reader: Arc::new(|| {
            Some(CodeProfile {
                arguments: vec!["--auth".to_owned(), "none".to_owned()],
                bridge_socket: "/tmp/slopdesk-test.sock".to_owned(),
            })
        }),
        is_directory: Arc::new(|path| PathBuf::from(path).is_dir()),
        bridge: Arc::new(NoWindows),
    };
    let manager = Arc::new(CodeServerManager::new(
        seams,
        NEVER_AGAIN,
        Duration::from_millis(1),
    ));
    (manager, font)
}

/// A performer over `manager`, with `$HOME` pinned so the tilde arm is not this machine's.
fn actions(manager: &Arc<CodeServerManager>, opener: &Arc<Opened>) -> CodeActions<Launcher> {
    CodeActions::new(
        Arc::clone(manager),
        Launcher(Arc::clone(opener)),
        "/home/tester".to_owned(),
    )
}

/// A root the host cannot see is `notFound`. Never hand out an endpoint for a path this host has no
/// business serving — and a relative one is malformed, which is a different answer.
#[test]
fn ensure_refuses_a_root_it_cannot_see_and_a_root_that_is_not_one() {
    let (manager, _font) = workbench(Some("/bin/code-server"));
    let opener = Arc::new(Opened::default());
    let door = actions(&manager, &opener);

    assert_eq!(
        status_of(&ask(&door, MetadataVerb::EnsureCodeServer, b"relative/path")),
        MetadataStatus::Error,
    );
    assert_eq!(
        status_of(&ask(
            &door,
            MetadataVerb::EnsureCodeServer,
            b"/no/such/directory/anywhere",
        )),
        MetadataStatus::NotFound,
    );
    let answer = ask(&door, MetadataVerb::EnsureCodeServer, b"/tmp");
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    assert_eq!(
        decode_service_endpoint(&answer.payload).unwrap().state_byte,
        ServiceState::Starting.byte(),
        "a spawned-but-unprobed child is starting, and the client polls",
    );
}

/// The disposition byte is how the client learns which of the two opens happened. A directory is
/// never the editor's, and a host with no code-server has nothing to route to.
#[test]
fn open_routes_a_file_to_the_workbench_and_everything_else_to_the_host() {
    let scratch = std::env::temp_dir().join("slopdesk-performers-open");
    std::fs::create_dir_all(&scratch).unwrap();
    let file = scratch.join("main.rs");
    std::fs::write(&file, b"fn main() {}").unwrap();

    let opener = Arc::new(Opened::default());
    let (manager, _font) = workbench(Some("/bin/code-server"));
    let door = actions(&manager, &opener);

    let answer = ask(
        &door,
        MetadataVerb::OpenInCodeServer,
        file.to_string_lossy().as_bytes(),
    );
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    assert_eq!(
        decode_code_open_disposition(&answer.payload).unwrap(),
        CodeOpenDisposition::Workbench,
    );
    assert!(
        opener.paths.lock().unwrap().is_empty(),
        "a file on a host with code-server must not reach Launch Services",
    );

    let answer = ask(
        &door,
        MetadataVerb::OpenInCodeServer,
        scratch.to_string_lossy().as_bytes(),
    );
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    assert_eq!(
        decode_code_open_disposition(&answer.payload).unwrap(),
        CodeOpenDisposition::HostDefault,
        "a folder is not something the editor opens",
    );

    // The same file, on a host that has no code-server at all.
    let barren = Arc::new(Opened::default());
    let (empty, _font) = workbench(None);
    let answer = ask(
        &actions(&empty, &barren),
        MetadataVerb::OpenInCodeServer,
        file.to_string_lossy().as_bytes(),
    );
    assert_eq!(status_of(&answer), MetadataStatus::Ok);
    assert_eq!(
        decode_code_open_disposition(&answer.payload).unwrap(),
        CodeOpenDisposition::HostDefault,
    );
    assert_eq!(barren.paths.lock().unwrap().len(), 1);

    std::fs::remove_dir_all(&scratch).unwrap();
}

/// The `:line[:col]` suffix is split off for the EXISTENCE check and put back for the open —
/// otherwise every ⌘-click on a compiler diagnostic would report the file missing.
#[test]
fn open_checks_the_bare_path_and_forwards_the_line_suffix() {
    let scratch = std::env::temp_dir().join("slopdesk-performers-suffix");
    std::fs::create_dir_all(&scratch).unwrap();
    let file = scratch.join("lib.rs");
    std::fs::write(&file, b"").unwrap();

    let opener = Arc::new(Opened::default());
    let (manager, _font) = workbench(Some("/bin/code-server"));
    let target = format!("{}:42:7", file.to_string_lossy());
    let answer = ask(
        &actions(&manager, &opener),
        MetadataVerb::OpenInCodeServer,
        target.as_bytes(),
    );
    assert_eq!(
        decode_code_open_disposition(&answer.payload).unwrap(),
        CodeOpenDisposition::Workbench,
        "the existence check must run on the path, not on `path:42:7`",
    );

    std::fs::remove_dir_all(&scratch).unwrap();
}

/// A relative target is malformed and a `~` against a home this performer does not have is refused
/// — the same rule verb 9 applies, which is the point of there being one function.
#[test]
fn open_refuses_a_relative_target_and_a_tilde_it_cannot_expand() {
    let opener = Arc::new(Opened::default());
    let (manager, _font) = workbench(Some("/bin/code-server"));
    let door = actions(&manager, &opener);

    assert_eq!(
        status_of(&ask(&door, MetadataVerb::OpenInCodeServer, b"src/main.rs")),
        MetadataStatus::Error,
    );
    assert_eq!(
        status_of(&ask(&door, MetadataVerb::OpenInCodeServer, b"")),
        MetadataStatus::Error,
    );
    assert_eq!(
        status_of(&ask(&door, MetadataVerb::OpenInCodeServer, b"~other/notes.md")),
        MetadataStatus::Error,
        "`~user` is refused rather than resolved through getpwnam",
    );
    // A tilde this performer CAN expand resolves against the pinned home, and then does not exist.
    assert_eq!(
        status_of(&ask(&door, MetadataVerb::OpenInCodeServer, b"~/notes.md")),
        MetadataStatus::NotFound,
    );
    assert!(opener.paths.lock().unwrap().is_empty());
}

/// A spec that decodes always answers `ok` — already-in-sync is success, not failure — and a
/// malformed one never reaches the settings file.
#[test]
fn the_font_verb_folds_a_decodable_spec_and_drops_everything_else() {
    let (manager, font) = workbench(Some("/bin/code-server"));
    let opener = Arc::new(Opened::default());
    let door = actions(&manager, &opener);

    let spec = CodeFontSpec {
        family: "JetBrains Mono".to_owned(),
        size: 13.0,
        line_height: 1.35,
    };
    assert_eq!(
        status_of(&ask(
            &door,
            MetadataVerb::SyncCodeFont,
            &encode_code_font_spec(&spec)
        )),
        MetadataStatus::Ok,
    );
    assert_eq!(font.lock().unwrap().as_ref(), Some(&spec));

    *font.lock().unwrap() = None;
    assert_eq!(
        status_of(&ask(&door, MetadataVerb::SyncCodeFont, b"\xff\xff")),
        MetadataStatus::Error,
    );
    assert!(
        font.lock().unwrap().is_none(),
        "a spec that will not decode must never reach a file the workbench trusts",
    );
}

/// A performer answering a verb it does not own says so about the ROUTE rather than inventing a
/// second opinion about who owns a byte.
#[test]
fn a_performer_handed_a_stranger_verb_answers_unsupported() {
    let (manager, _font) = workbench(Some("/bin/code-server"));
    let opener = Arc::new(Opened::default());
    assert_eq!(
        status_of(&ask(&actions(&manager, &opener), MetadataVerb::OpenPath, b"/tmp",)),
        MetadataStatus::UnsupportedVerb,
    );

    let door = Hooks::new(true, true);
    assert_eq!(
        status_of(&ask(
            &AgentActions::new(Shared(door), Arc::new(|| true)),
            MetadataVerb::ReadClipboard,
            b"",
        )),
        MetadataStatus::UnsupportedVerb,
    );
}

/// The three ensure verbs share one wire body, and it is built in one place so a fourth caller
/// cannot invent a fourth spelling of `[state][port]`.
#[test]
fn all_three_ensure_verbs_answer_the_same_three_bytes() {
    let payload = slopdesk_hostserver::ensure::endpoint_payload(Endpoint {
        state: ServiceState::Ready,
        port: 62636,
    });
    assert_eq!(payload.len(), 3);
    let endpoint = decode_service_endpoint(&payload).unwrap();
    assert_eq!(endpoint.state_byte, ServiceState::Ready.byte());
    assert_eq!(endpoint.port, 62636);
}
