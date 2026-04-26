//! sleep-core: offline sleep tracking engine.
//!
//! Layered design:
//! - `engine`: session state machine, in-memory buffers, orchestration.
//! - `signal`: feature extraction from HR / accelerometer samples.
//! - `models`: inference backends (placeholder rule-based, future: Core ML rescorer).
//! - `db`:     SQLite repo for sessions / samples / stage_timeline / audio_events.
//! - `alarm`:  smart alarm state + trigger evaluation.
//! - `bindings`: `swift-bridge` FFI surface (feature-gated at compile time).

pub mod alarm;
pub mod bindings;
pub mod db;
pub mod engine;
pub mod models;
pub mod signal;

pub use engine::config::EngineConfig;
pub use engine::state::{SessionSummary, SleepEngine, Stage};

/// Crate-wide error type.
#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("no active session")]
    NoActiveSession,
    #[error("session already running: {0}")]
    SessionAlreadyRunning(String),
    #[error("db: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, CoreError>;
