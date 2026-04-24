//! FFI surface for Swift via `swift-bridge`.
//!
//! Types are prefixed `Ffi*` so they don't collide with SleepKit's native
//! Swift models when generated into the same module. `RustSleepEngineClient.swift`
//! is responsible for mapping them to SleepKit's `EngineConfig`/`SessionSummary`.
//!
//! Mutability note: swift-bridge requires exclusive `&mut self` to access the
//! underlying engine. All Rust-side synchronization therefore stays inside the
//! Swift client (`RustSleepEngineClient`), which guarantees single-threaded
//! access from `@MainActor`.

use crate::engine::config::EngineConfig as CoreConfig;
use crate::engine::state::{SleepEngine as CoreEngine, SessionSummary as CoreSummary, Stage as CoreStage};

#[swift_bridge::bridge]
mod ffi {
    #[swift_bridge(swift_repr = "struct")]
    struct FfiEngineConfig {
        db_path: String,
        model_path: String,
        user_id: String,
    }

    #[swift_bridge(swift_repr = "struct")]
    struct FfiSessionSummary {
        session_id: String,
        duration_sec: u32,
        time_in_wake_sec: u32,
        time_in_light_sec: u32,
        time_in_deep_sec: u32,
        time_in_rem_sec: u32,
        sleep_score: u8,
    }

    extern "Rust" {
        type FfiSleepEngine;

        fn ffi_sleep_engine_new(config: FfiEngineConfig) -> Result<FfiSleepEngine, String>;

        fn start_session(&mut self, started_at_ms: u64) -> Result<String, String>;
        fn end_session(&mut self) -> Result<FfiSessionSummary, String>;

        fn push_heart_rate(&mut self, bpm: f32, ts_ms: u64) -> Result<(), String>;
        fn push_accelerometer(
            &mut self,
            x: f32,
            y: f32,
            z: f32,
            ts_ms: u64,
        ) -> Result<(), String>;

        // 0=wake, 1=light, 2=deep, 3=rem.
        fn current_stage(&self) -> u8;
        fn current_confidence(&self) -> f32;

        fn arm_smart_alarm(
            &mut self,
            target_ms: u64,
            window_minutes: u32,
        ) -> Result<(), String>;
        fn check_alarm_trigger(&self, now_ms: u64) -> bool;
    }
}

pub struct FfiSleepEngine {
    inner: CoreEngine,
}

fn ffi_sleep_engine_new(config: ffi::FfiEngineConfig) -> Result<FfiSleepEngine, String> {
    let cfg = CoreConfig::new(config.db_path, config.model_path, config.user_id);
    CoreEngine::new(cfg)
        .map(|inner| FfiSleepEngine { inner })
        .map_err(|e| e.to_string())
}

impl FfiSleepEngine {
    fn start_session(&mut self, started_at_ms: u64) -> Result<String, String> {
        self.inner
            .start_session(started_at_ms)
            .map_err(|e| e.to_string())
    }

    fn end_session(&mut self) -> Result<ffi::FfiSessionSummary, String> {
        self.inner
            .end_session()
            .map(to_ffi_summary)
            .map_err(|e| e.to_string())
    }

    fn push_heart_rate(&mut self, bpm: f32, ts_ms: u64) -> Result<(), String> {
        self.inner
            .push_heart_rate(bpm, ts_ms)
            .map_err(|e| e.to_string())
    }

    fn push_accelerometer(
        &mut self,
        x: f32,
        y: f32,
        z: f32,
        ts_ms: u64,
    ) -> Result<(), String> {
        self.inner
            .push_accelerometer(x, y, z, ts_ms)
            .map_err(|e| e.to_string())
    }

    fn current_stage(&self) -> u8 {
        match self.inner.current_stage() {
            CoreStage::Wake => 0,
            CoreStage::Light => 1,
            CoreStage::Deep => 2,
            CoreStage::Rem => 3,
        }
    }

    fn current_confidence(&self) -> f32 {
        self.inner.current_confidence()
    }

    fn arm_smart_alarm(
        &mut self,
        target_ms: u64,
        window_minutes: u32,
    ) -> Result<(), String> {
        self.inner.arm_smart_alarm(target_ms, window_minutes);
        Ok(())
    }

    fn check_alarm_trigger(&self, now_ms: u64) -> bool {
        self.inner.check_alarm_trigger(now_ms)
    }
}

fn to_ffi_summary(s: CoreSummary) -> ffi::FfiSessionSummary {
    ffi::FfiSessionSummary {
        session_id: s.session_id,
        duration_sec: clamp_u32(s.duration_sec),
        time_in_wake_sec: clamp_u32(s.time_in_wake_sec),
        time_in_light_sec: clamp_u32(s.time_in_light_sec),
        time_in_deep_sec: clamp_u32(s.time_in_deep_sec),
        time_in_rem_sec: clamp_u32(s.time_in_rem_sec),
        sleep_score: s.sleep_score.clamp(0, 100) as u8,
    }
}

fn clamp_u32(v: i64) -> u32 {
    if v < 0 {
        0
    } else if v > u32::MAX as i64 {
        u32::MAX
    } else {
        v as u32
    }
}
