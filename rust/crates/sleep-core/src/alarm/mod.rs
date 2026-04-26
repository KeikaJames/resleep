//! Smart alarm: arm a target wake-up time + a preceding window; trigger when
//! user is in a light stage within the window, or immediately on reaching target.

use crate::engine::state::Stage;

#[derive(Debug, Default)]
pub struct SmartAlarm {
    target_ms: Option<u64>,
    window_ms: u64,
    armed: bool,
}

impl SmartAlarm {
    pub fn arm(&mut self, target_ms: u64, window_minutes: u32) {
        self.target_ms = Some(target_ms);
        self.window_ms = (window_minutes as u64) * 60 * 1000;
        self.armed = true;
    }

    pub fn disarm(&mut self) {
        self.armed = false;
    }

    pub fn should_trigger(&self, now_ms: u64, stage: Stage, confidence: f32) -> bool {
        if !self.armed {
            return false;
        }
        let Some(target) = self.target_ms else {
            return false;
        };
        if now_ms >= target {
            return true;
        }
        let window_start = target.saturating_sub(self.window_ms);
        if now_ms < window_start {
            return false;
        }
        // Prefer light/rem transitions; require some confidence.
        matches!(stage, Stage::Light | Stage::Rem) && confidence >= 0.5
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn does_not_trigger_before_window() {
        let mut a = SmartAlarm::default();
        // target at t=10min, window=5min => window starts at t=5min
        a.arm(10 * 60 * 1000, 5);
        assert!(!a.should_trigger(1 * 60 * 1000, Stage::Light, 0.9));
    }

    #[test]
    fn triggers_on_light_within_window() {
        let mut a = SmartAlarm::default();
        a.arm(10 * 60 * 1000, 5);
        assert!(a.should_trigger((10 * 60 * 1000) - 60_000, Stage::Light, 0.7));
    }

    #[test]
    fn always_triggers_at_target() {
        let mut a = SmartAlarm::default();
        a.arm(5_000, 1);
        assert!(a.should_trigger(5_000, Stage::Deep, 0.0));
    }
}
