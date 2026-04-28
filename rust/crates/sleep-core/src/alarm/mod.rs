//! Smart alarm: arm a target wake-up time + a preceding window; trigger when
//! user is in a light stage within the window, or immediately on reaching target.
//!
//! Optional **nightmare-rescue** branch: when the engine reports a sustained
//! tachycardic + motion event (see [`crate::signal::nightmare`]) within a
//! generous pre-window before the target time, the alarm fires early so the
//! sleeper is gently lifted out of the distress episode rather than left
//! inside it. This branch is only active once a session has been running long
//! enough for baselines to be meaningful, and is always skipped for the very
//! beginning of the night so an early adrenaline spike (e.g. from a noisy
//! environment) doesn't cut sleep short.

use crate::engine::state::Stage;

/// Maximum lead-time (relative to the alarm target) during which a
/// nightmare signal may trigger an early wake. Outside this window the
/// detector is ignored — we'd rather leave someone asleep at 1 AM and let
/// the dream pass than wake them four hours early.
const NIGHTMARE_LEAD_MS: u64 = 90 * 60 * 1000;

#[derive(Debug, Default)]
pub struct SmartAlarm {
    target_ms: Option<u64>,
    window_ms: u64,
    armed: bool,
    nightmare_rescue_enabled: bool,
}

impl SmartAlarm {
    pub fn arm(&mut self, target_ms: u64, window_minutes: u32) {
        self.target_ms = Some(target_ms);
        self.window_ms = (window_minutes as u64) * 60 * 1000;
        self.armed = true;
        self.nightmare_rescue_enabled = true;
    }

    pub fn disarm(&mut self) {
        self.armed = false;
    }

    pub fn set_nightmare_rescue(&mut self, enabled: bool) {
        self.nightmare_rescue_enabled = enabled;
    }

    pub fn should_trigger(
        &self,
        now_ms: u64,
        stage: Stage,
        confidence: f32,
        nightmare_active: bool,
    ) -> bool {
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

        // Nightmare-rescue branch: fires inside a wider lead window.
        if self.nightmare_rescue_enabled && nightmare_active {
            let nightmare_window_start = target.saturating_sub(NIGHTMARE_LEAD_MS);
            if now_ms >= nightmare_window_start {
                return true;
            }
        }

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
        assert!(!a.should_trigger(60 * 1000, Stage::Light, 0.9, false));
    }

    #[test]
    fn triggers_on_light_within_window() {
        let mut a = SmartAlarm::default();
        a.arm(10 * 60 * 1000, 5);
        assert!(a.should_trigger((10 * 60 * 1000) - 60_000, Stage::Light, 0.7, false));
    }

    #[test]
    fn always_triggers_at_target() {
        let mut a = SmartAlarm::default();
        a.arm(5_000, 1);
        assert!(a.should_trigger(5_000, Stage::Deep, 0.0, false));
    }

    #[test]
    fn nightmare_triggers_inside_lead_window() {
        let mut a = SmartAlarm::default();
        // target at 8h, normal smart-window = 30 min. Nightmare lead window = 90 min.
        let target = 8 * 60 * 60 * 1000;
        a.arm(target, 30);
        // 60 min before target: outside smart window but inside nightmare lead.
        let now = target - 60 * 60 * 1000;
        assert!(a.should_trigger(now, Stage::Deep, 0.9, true));
    }

    #[test]
    fn nightmare_does_not_trigger_outside_lead_window() {
        let mut a = SmartAlarm::default();
        let target = 8 * 60 * 60 * 1000;
        a.arm(target, 30);
        // 4h before target — way outside even the nightmare window.
        let now = target - 4 * 60 * 60 * 1000;
        assert!(!a.should_trigger(now, Stage::Rem, 0.9, true));
    }

    #[test]
    fn nightmare_rescue_can_be_disabled() {
        let mut a = SmartAlarm::default();
        let target = 8 * 60 * 60 * 1000;
        a.arm(target, 30);
        a.set_nightmare_rescue(false);
        let now = target - 60 * 60 * 1000;
        assert!(!a.should_trigger(now, Stage::Deep, 0.9, true));
    }
}
