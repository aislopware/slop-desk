//! `slopdesk-synclient` — one synthetic gesture at the host's input path, over real UDP.
//!
//!   slopdesk-synclient hello                  # just hello + print ack, hold 2s
//!   slopdesk-synclient click X Y              # one down+up at normalized (X,Y)
//!   slopdesk-synclient clickburst [N]         # N rapid clicks down/up back-to-back
//!   slopdesk-synclient drag X1 Y1 X2 Y2 [STEPS]
//!   slopdesk-synclient suite                  # the click-burst then the drag-select
//!   slopdesk-synclient redundantup            # a click whose mouseUp is sent 3×
//!   slopdesk-synclient lostup                 # down + drags with NO up, then a fresh click
//!
//! `slopdesk-ops video-input` starts an isolated host, runs one of these, and reads the
//! injection trace back out of the log. The gestures themselves are in
//! `slopdesk_devtools::synclient`.

use std::process::ExitCode;
use std::thread::sleep;
use std::time::Duration;

use slopdesk_devtools::synclient::{CURSOR_PORT, Client, MEDIA_PORT, Motion, along};

/// The window the harness defaults to, matching the `WID` default of `slopdesk-ops video-input`.
const WINDOW_ID: u32 = 267;

/// The usage line, which is also the error for an unknown command.
const USAGE: &str = "usage: slopdesk-synclient <hello|suite|redundantup|lostup|click X Y|clickburst \
                     [N]|drag X1 Y1 X2 Y2 [STEPS]>";

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match run(&arguments) {
        Ok(()) => ExitCode::SUCCESS,
        Err(complaint) => {
            eprintln!("{complaint}");
            ExitCode::FAILURE
        },
    }
}

/// Dial, say hello, then play the gesture.
fn run(arguments: &[String]) -> Result<(), String> {
    let command = arguments.first().map_or("hello", String::as_str);
    let mut client =
        Client::dial(MEDIA_PORT, CURSOR_PORT).map_err(|error| format!("cannot dial the host: {error}"))?;
    let ack = client
        .hello(WINDOW_ID)
        .map_err(|error| format!("hello failed: {error}"))?;
    println!("ACK: {ack:?}");
    if !ack.accepted() {
        return Err("!! hello not accepted".to_owned());
    }
    sleep(Duration::from_millis(200));

    match command {
        "suite" => suite(&mut client)?,
        "redundantup" => redundant_up(&mut client)?,
        "lostup" => lost_up(&mut client)?,
        "hello" => sleep(Duration::from_secs(2)),
        "click" => {
            let (x, y) = (coordinate(arguments, 1)?, coordinate(arguments, 2)?);
            click(&mut client, x, y)?;
            println!("click at ({x},{y})");
        },
        "clickburst" => {
            let count = count(arguments, 1, 10)?;
            for step in 0..count {
                let x = 0.2 + 0.03 * f64::from(step);
                // Back-to-back, with no gap between down and up: provoke a host reorder.
                click(&mut client, x, 0.2)?;
                sleep(Duration::from_millis(50));
            }
            println!("{count} rapid clicks sent");
        },
        "drag" => {
            let (x1, y1) = (coordinate(arguments, 1)?, coordinate(arguments, 2)?);
            let (x2, y2) = (coordinate(arguments, 3)?, coordinate(arguments, 4)?);
            let steps = count(arguments, 5, 12)?;
            sent(client.send(Motion::Down, x1, y1, 1))?;
            sweep(&mut client, (x1, y1), (x2, y2), steps, steps)?;
            sent(client.send(Motion::Up, x2, y2, 1))?;
            println!("drag ({x1},{y1})->({x2},{y2}) in {steps} steps");
        },
        other => return Err(format!("unknown command {other:?}\n{USAGE}")),
    }
    sleep(Duration::from_millis(400));
    client.close();
    Ok(())
}

/// One connection, one source port (the host stays pinned to us).
///
/// Exercises the down/up-inversion race (rapid clicks) then a drag-select, all in arrival order.
fn suite(client: &mut Client) -> Result<(), String> {
    println!(">> 15 rapid clicks (caret moves; must NOT leave a selection)");
    for step in 0..15 {
        let x = 0.10 + 0.035 * f64::from(step);
        click(client, x, 0.20)?;
        sleep(Duration::from_millis(40));
    }
    sleep(Duration::from_millis(600));
    println!(">> drag-select across line 2");
    let (start, end) = ((0.05, 0.40), (0.75, 0.40));
    sent(client.send(Motion::Down, start.0, start.1, 1))?;
    sweep(client, start, end, 14, 15)?;
    sent(client.send(Motion::Up, end.0, end.1, 1))?;
    sleep(Duration::from_millis(600));
    Ok(())
}

/// Mimic the real client: a click whose mouseUp is sent 3× (loss-resilience).
///
/// The host must post ONE leftMouseUp and SUPPRESS the other two (no spurious extra `*MouseUp`).
fn redundant_up(client: &mut Client) -> Result<(), String> {
    println!(">> click with 3x redundant mouseUp");
    sent(client.send(Motion::Down, 0.3, 0.21, 1))?;
    for _ in 0..3 {
        sent(client.send(Motion::Up, 0.3, 0.21, 1))?;
    }
    sleep(Duration::from_millis(400));
    Ok(())
}

/// Simulate a DROPPED mouseUp: down + drags, NO up. Then a fresh click elsewhere.
///
/// In fixed mode the host's button-balance must inject a synthetic release before the fresh down,
/// so the click does not start inside the stranded selection.
fn lost_up(client: &mut Client) -> Result<(), String> {
    println!(">> down + 6 drags, NO up (simulates a lost release)");
    sent(client.send(Motion::Down, 0.05, 0.21, 1))?;
    for step in 1..=6 {
        let x = 0.05 + 0.06 * f64::from(step);
        sent(client.send(Motion::Drag, x, 0.21, 1))?;
        sleep(Duration::from_millis(20));
    }
    sleep(Duration::from_millis(500));
    println!(">> fresh click far away (must auto-release the stuck button first)");
    click(client, 0.8, 0.6)?;
    sleep(Duration::from_millis(500));
    Ok(())
}

/// A down immediately followed by an up at the same point.
fn click(client: &mut Client, x: f64, y: f64) -> Result<(), String> {
    sent(client.send(Motion::Down, x, y, 1))?;
    sent(client.send(Motion::Up, x, y, 1))?;
    Ok(())
}

/// `events` drag events walking from `start` towards `end`, each `step/divisor` of the way.
///
/// The two callers deliberately differ in whether the LAST drag lands on `end`. `suite`'s
/// drag-select stops one step short, so the release carries the final point — which is the shape
/// that provoked the ordering bug. The standalone `drag` command walks all the way there first, so
/// its release moves nothing. Collapsing them into one loop would quietly retire one of the two
/// gestures the harness exists to replay.
fn sweep(
    client: &mut Client,
    start: (f64, f64),
    end: (f64, f64),
    events: u32,
    divisor: u32,
) -> Result<(), String> {
    for step in 1..=events {
        let fraction = f64::from(step) / f64::from(divisor);
        let x = along(start.0, end.0, fraction);
        let y = along(start.1, end.1, fraction);
        sent(client.send(Motion::Drag, x, y, 1))?;
        sleep(Duration::from_millis(12));
    }
    Ok(())
}

/// A send that did not go out.
///
/// Takes the whole `Result` rather than the error, so the call site reads `sent(client.send(…))?`
/// and the error is consumed rather than borrowed out of a `map_err`.
fn sent(result: std::io::Result<()>) -> Result<(), String> {
    result.map_err(|error| format!("send failed: {error}"))
}

/// A positional coordinate.
fn coordinate(arguments: &[String], at: usize) -> Result<f64, String> {
    arguments
        .get(at)
        .ok_or_else(|| USAGE.to_owned())?
        .parse()
        .map_err(|_| format!("argument {at} is not a number\n{USAGE}"))
}

/// A positional count, or `fallback` when it was not given.
fn count(arguments: &[String], at: usize, fallback: u32) -> Result<u32, String> {
    arguments.get(at).map_or(Ok(fallback), |written| {
        written
            .parse()
            .map_err(|_| format!("argument {at} is not a count\n{USAGE}"))
    })
}
