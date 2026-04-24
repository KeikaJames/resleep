//! sleep-cli: feed fake samples to the engine and print a SessionSummary.
use anyhow::Result;
use clap::{Parser, Subcommand};
use sleep_core::{EngineConfig, SleepEngine};

#[derive(Parser, Debug)]
#[command(name = "sleep-cli", version, about = "Offline sleep engine CLI")]
struct Cli {
    /// Path to the local SQLite database.
    #[arg(long, default_value = "/tmp/sleep.db")]
    db: String,
    /// Optional model path for future Core ML wiring (ignored by rule engine).
    #[arg(long, default_value = "")]
    model: String,
    /// Opaque user id.
    #[arg(long, default_value = "local-user")]
    user: String,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Run a fake 60-second session with canned samples.
    Demo,
    /// Print the current SQLite row counts.
    Stats,
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let cli = Cli::parse();
    let cfg = EngineConfig::new(cli.db, cli.model, cli.user);
    let mut engine = SleepEngine::new(cfg)?;

    match cli.cmd {
        Cmd::Demo => run_demo(&mut engine)?,
        Cmd::Stats => println!("(stats placeholder — wire up sql queries as needed)"),
    }

    Ok(())
}

fn run_demo(engine: &mut SleepEngine) -> Result<()> {
    let t0 = 1_700_000_000_000u64;
    let id = engine.start_session(t0)?;
    tracing::info!(session = %id, "demo session started");

    for minute in 0..60u64 {
        let ts = t0 + minute * 60_000;
        // HR drifts down; motion spikes occasionally.
        let hr = 70.0 - minute as f32 * 0.15;
        let is_restless = minute % 17 == 0;
        let accel = if is_restless { 0.6 } else { 0.03 };
        engine.push_heart_rate(hr, ts)?;
        engine.push_accelerometer(accel, accel, accel, ts)?;
    }

    let summary = engine.end_session()?;
    println!("{}", serde_json::to_string_pretty(&summary)?);
    Ok(())
}
