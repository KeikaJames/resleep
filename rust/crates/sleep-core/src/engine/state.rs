//! Session state machine + orchestration.
use crate::alarm::SmartAlarm;
use crate::db::repo::Repo;
use crate::engine::config::EngineConfig;
use crate::models::inference::{RuleInference, StageInference};
use crate::signal::features::FeatureBuffers;
use crate::{CoreError, Result};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// High-level sleep stage. Matches Swift's `SleepStage` enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(i32)]
pub enum Stage {
    Wake = 0,
    Light = 1,
    Deep = 2,
    Rem = 3,
}

impl Stage {
    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(Stage::Wake),
            1 => Some(Stage::Light),
            2 => Some(Stage::Deep),
            3 => Some(Stage::Rem),
            _ => None,
        }
    }
}

/// Session summary returned to Swift at end of tracking.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSummary {
    pub session_id: String,
    pub duration_sec: i64,
    pub time_in_wake_sec: i64,
    pub time_in_light_sec: i64,
    pub time_in_deep_sec: i64,
    pub time_in_rem_sec: i64,
    /// 0-100.
    pub sleep_score: i32,
}

struct ActiveSession {
    id: String,
    started_at_ms: u64,
    /// Timestamp at which the current stage was entered.
    last_stage_ms: u64,
    /// Latest observed sample timestamp (used to close out accounting on end_session).
    last_sample_ms: u64,
    last_stage: Stage,
    /// seconds spent in each stage, indexed by `Stage as usize`.
    time_in_stage_sec: [i64; 4],
}

pub struct SleepEngine {
    cfg: EngineConfig,
    repo: Repo,
    features: FeatureBuffers,
    inference: RuleInference,
    alarm: SmartAlarm,
    current_stage: Stage,
    current_confidence: f32,
    session: Option<ActiveSession>,
}

impl SleepEngine {
    pub fn new(cfg: EngineConfig) -> Result<Self> {
        let repo = Repo::open(&cfg.db_path)?;
        Ok(Self {
            cfg,
            repo,
            features: FeatureBuffers::new(),
            inference: RuleInference::new(),
            alarm: SmartAlarm::default(),
            current_stage: Stage::Wake,
            current_confidence: 0.0,
            session: None,
        })
    }

    pub fn config(&self) -> &EngineConfig {
        &self.cfg
    }

    pub fn start_session(&mut self, started_at_ms: u64) -> Result<String> {
        if let Some(s) = &self.session {
            return Err(CoreError::SessionAlreadyRunning(s.id.clone()));
        }
        let id = Uuid::new_v4().to_string();
        self.repo
            .insert_session(&id, started_at_ms, &self.cfg.user_id)?;
        self.features.reset();
        self.current_stage = Stage::Wake;
        self.current_confidence = 0.0;
        self.session = Some(ActiveSession {
            id: id.clone(),
            started_at_ms,
            last_stage_ms: started_at_ms,
            last_sample_ms: started_at_ms,
            last_stage: Stage::Wake,
            time_in_stage_sec: [0; 4],
        });
        Ok(id)
    }

    pub fn end_session(&mut self) -> Result<SessionSummary> {
        let Some(mut s) = self.session.take() else {
            return Err(CoreError::NoActiveSession);
        };
        let end_ms = s.last_sample_ms.max(s.started_at_ms);
        let delta = ((end_ms.saturating_sub(s.last_stage_ms)) / 1000) as i64;
        s.time_in_stage_sec[s.last_stage as usize] += delta;

        self.repo.close_session(&s.id, end_ms)?;

        let duration_sec = ((end_ms.saturating_sub(s.started_at_ms)) / 1000) as i64;
        let summary = SessionSummary {
            session_id: s.id.clone(),
            duration_sec,
            time_in_wake_sec: s.time_in_stage_sec[Stage::Wake as usize],
            time_in_light_sec: s.time_in_stage_sec[Stage::Light as usize],
            time_in_deep_sec: s.time_in_stage_sec[Stage::Deep as usize],
            time_in_rem_sec: s.time_in_stage_sec[Stage::Rem as usize],
            sleep_score: compute_sleep_score(&s.time_in_stage_sec, duration_sec),
        };
        Ok(summary)
    }

    pub fn push_heart_rate(&mut self, bpm: f32, ts_ms: u64) -> Result<()> {
        let Some(s) = self.session.as_mut() else {
            return Err(CoreError::NoActiveSession);
        };
        s.last_sample_ms = ts_ms.max(s.last_sample_ms);
        self.features.push_hr(bpm, ts_ms);
        self.repo.insert_sample(
            &s.id,
            ts_ms,
            crate::db::repo::SampleKind::HeartRate,
            &bpm.to_string(),
        )?;
        self.recompute_stage(ts_ms);
        Ok(())
    }

    pub fn push_accelerometer(&mut self, x: f32, y: f32, z: f32, ts_ms: u64) -> Result<()> {
        let Some(s) = self.session.as_mut() else {
            return Err(CoreError::NoActiveSession);
        };
        s.last_sample_ms = ts_ms.max(s.last_sample_ms);
        self.features.push_accel(x, y, z, ts_ms);
        let json = format!(r#"{{"x":{x},"y":{y},"z":{z}}}"#);
        self.repo.insert_sample(
            &s.id,
            ts_ms,
            crate::db::repo::SampleKind::Accelerometer,
            &json,
        )?;
        self.recompute_stage(ts_ms);
        Ok(())
    }

    fn recompute_stage(&mut self, ts_ms: u64) {
        let feats = self.features.snapshot();
        let (stage, conf) = self.inference.infer(&feats);
        self.current_confidence = conf;

        if stage != self.current_stage {
            if let Some(s) = self.session.as_mut() {
                let delta = ((ts_ms.saturating_sub(s.last_stage_ms)) / 1000) as i64;
                s.time_in_stage_sec[s.last_stage as usize] += delta;
                s.last_stage = stage;
                s.last_stage_ms = ts_ms;
                let _ = self
                    .repo
                    .insert_stage_transition(&s.id, ts_ms, stage as i32, conf);
            }
            self.current_stage = stage;
        }
    }

    pub fn current_stage(&self) -> Stage {
        self.current_stage
    }

    pub fn current_confidence(&self) -> f32 {
        self.current_confidence
    }

    pub fn arm_smart_alarm(&mut self, target_ms: u64, window_minutes: u32) {
        self.alarm.arm(target_ms, window_minutes);
    }

    pub fn check_alarm_trigger(&self, now_ms: u64) -> bool {
        self.alarm
            .should_trigger(now_ms, self.current_stage, self.current_confidence)
    }
}

fn compute_sleep_score(time_in_stage: &[i64; 4], duration_sec: i64) -> i32 {
    if duration_sec <= 0 {
        return 0;
    }
    let asleep = time_in_stage[Stage::Light as usize]
        + time_in_stage[Stage::Deep as usize]
        + time_in_stage[Stage::Rem as usize];
    let efficiency = (asleep as f32 / duration_sec as f32).clamp(0.0, 1.0);
    let deep_ratio = time_in_stage[Stage::Deep as usize] as f32 / duration_sec.max(1) as f32;
    let rem_ratio = time_in_stage[Stage::Rem as usize] as f32 / duration_sec.max(1) as f32;
    // Simple heuristic: weight efficiency heaviest, reward deep + rem.
    let score = 60.0 * efficiency
        + 25.0 * deep_ratio.clamp(0.0, 0.4) / 0.4
        + 15.0 * rem_ratio.clamp(0.0, 0.25) / 0.25;
    score.round().clamp(0.0, 100.0) as i32
}
