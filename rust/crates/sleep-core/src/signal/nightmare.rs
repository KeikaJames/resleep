//! Nightmare / sleep-distress detector.
//!
//! Goal: emit an "early-wake" signal when sensor evidence suggests the
//! sleeper is currently in a distressing dream — most often manifesting
//! during REM as a sustained tachycardic episode coupled with elevated
//! body movement. This is **not** a clinical instrument; it's the same
//! family of heuristics SleepCycle's "wake from a nightmare" uses, and
//! it is deliberately conservative so we never wake someone unprompted
//! during normal sleep.
//!
//! The detector keeps two rolling baselines:
//!
//!   * **HR baseline** — the median heart-rate over the last `BASELINE_WIN_MS`,
//!     computed from a small windowed buffer. We use the median (not the
//!     mean) so a single noisy beat doesn't poison the reference.
//!   * **Motion baseline** — the median of recent per-second ENMO values
//!     ("Euclidean norm minus one"; standard accel-magnitude metric). A
//!     sleeping body usually has ENMO close to 0, so the baseline is
//!     small and a real movement pops out clearly.
//!
//! A nightmare signal is **active** when, at the current timestamp:
//!
//!   1. The session has been running long enough for baselines to be
//!      stable (> `MIN_SESSION_MS`).
//!   2. Current heart-rate is at least `HR_SPIKE_RATIO` above the rolling
//!      HR baseline (≈ 25 % default).
//!   3. Recent motion (over the last `MOTION_WIN_MS`) is at least
//!      `MOTION_SPIKE_RATIO` above the motion baseline (≈ 4×).
//!   4. The HR spike has persisted for at least `MIN_HR_PERSIST_MS` —
//!      this rules out single startled-by-noise transients.
//!
//! Once active, the signal latches for `LATCH_MS` so a downstream
//! consumer (the smart alarm) can react cleanly without a flicker race.

use std::collections::VecDeque;

const BASELINE_WIN_MS: u64 = 10 * 60 * 1000; // 10 minutes
const MOTION_WIN_MS: u64 = 60 * 1000; // 1 minute
const MIN_SESSION_MS: u64 = 20 * 60 * 1000; // 20 minutes — ensures baseline is meaningful
const MIN_HR_PERSIST_MS: u64 = 45_000; // sustained for 45 s
const LATCH_MS: u64 = 3 * 60 * 1000; // hold "active" for 3 minutes after evidence

const HR_SPIKE_RATIO: f32 = 1.25; // 25 % above baseline
const MOTION_SPIKE_RATIO: f32 = 4.0; // 4× above baseline (low baselines, so this is small absolute)
const MOTION_FLOOR: f32 = 0.02; // raw ENMO threshold under which motion is "still"
const HR_BUFFER_CAPACITY: usize = 1200; // ~10 minutes at up to 2 Hz
const MOTION_BUFFER_CAPACITY: usize = 1200; // 10 minutes at up to 2 Hz

#[derive(Debug)]
struct Sample<T> {
    ts_ms: u64,
    value: T,
}

#[derive(Debug, Default)]
pub struct NightmareDetector {
    session_start_ms: Option<u64>,
    hr_buffer: VecDeque<Sample<f32>>,
    motion_buffer: VecDeque<Sample<f32>>,
    /// Timestamp at which the current sustained HR spike began. Reset
    /// whenever the spike condition breaks.
    hr_spike_start_ms: Option<u64>,
    /// Timestamp at which the signal latched true.
    latched_until_ms: u64,
}

impl NightmareDetector {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub fn note_session_start(&mut self, ts_ms: u64) {
        self.session_start_ms = Some(ts_ms);
    }

    pub fn push_hr(&mut self, bpm: f32, ts_ms: u64) {
        if bpm <= 0.0 || !bpm.is_finite() {
            return;
        }
        self.hr_buffer.push_back(Sample { ts_ms, value: bpm });
        // Drop samples older than the baseline window.
        while let Some(front) = self.hr_buffer.front() {
            if ts_ms.saturating_sub(front.ts_ms) > BASELINE_WIN_MS {
                self.hr_buffer.pop_front();
            } else {
                break;
            }
        }
        if self.hr_buffer.len() > HR_BUFFER_CAPACITY {
            self.hr_buffer.pop_front();
        }
    }

    pub fn push_motion(&mut self, enmo: f32, ts_ms: u64) {
        if !enmo.is_finite() || enmo < 0.0 {
            return;
        }
        self.motion_buffer.push_back(Sample { ts_ms, value: enmo });
        while let Some(front) = self.motion_buffer.front() {
            if ts_ms.saturating_sub(front.ts_ms) > BASELINE_WIN_MS {
                self.motion_buffer.pop_front();
            } else {
                break;
            }
        }
        if self.motion_buffer.len() > MOTION_BUFFER_CAPACITY {
            self.motion_buffer.pop_front();
        }
    }

    /// Re-evaluate the detector at `now_ms` and return `true` while the
    /// signal is active. Pure read — does not mutate latching state if the
    /// caller hasn't called `tick`.
    pub fn is_active(&self, now_ms: u64) -> bool {
        now_ms < self.latched_until_ms
    }

    /// Drives the detector forward to `now_ms`. Should be called whenever
    /// fresh sensor data arrives. Returns the new value of `is_active`.
    pub fn tick(&mut self, now_ms: u64) -> bool {
        let started = match self.session_start_ms {
            Some(t) => t,
            None => return false,
        };
        if now_ms.saturating_sub(started) < MIN_SESSION_MS {
            return false;
        }

        let hr_baseline = match median(&self.hr_buffer) {
            Some(v) if v > 30.0 => v,
            _ => return false,
        };
        // Recent HR over the last MOTION_WIN_MS (we reuse the short window
        // for the spike check — 1 min of HR is enough to confirm it's not
        // a one-beat artefact).
        let recent_hr = recent_window_mean(&self.hr_buffer, now_ms, MOTION_WIN_MS);
        let recent_hr = match recent_hr {
            Some(v) => v,
            None => return false,
        };

        let hr_spiked = recent_hr >= hr_baseline * HR_SPIKE_RATIO;
        // Track sustained spike persistence (tick-driven).
        match (hr_spiked, self.hr_spike_start_ms) {
            (true, None) => self.hr_spike_start_ms = Some(now_ms),
            (false, Some(_)) => self.hr_spike_start_ms = None,
            _ => {}
        }
        let tick_persisted = self
            .hr_spike_start_ms
            .map(|s| now_ms.saturating_sub(s) >= MIN_HR_PERSIST_MS)
            .unwrap_or(false);
        // Also consult buffer history so persistence is recoverable from
        // raw data alone (e.g. when tick is called sparsely or the engine
        // restarts mid-spike).
        let buffer_persisted =
            hr_spike_span_ms(&self.hr_buffer, hr_baseline * HR_SPIKE_RATIO) >= MIN_HR_PERSIST_MS;
        let persisted = tick_persisted || buffer_persisted;

        let motion_baseline = median(&self.motion_buffer).unwrap_or(0.0).max(MOTION_FLOOR);
        let recent_motion =
            recent_window_mean(&self.motion_buffer, now_ms, MOTION_WIN_MS).unwrap_or(0.0);
        let motion_spiked =
            recent_motion >= motion_baseline * MOTION_SPIKE_RATIO && recent_motion >= MOTION_FLOOR;

        if persisted && motion_spiked && hr_spiked {
            self.latched_until_ms = now_ms + LATCH_MS;
        }

        self.is_active(now_ms)
    }
}

/// Walks the HR buffer from newest to oldest, summing the time span
/// during which the value was at or above `threshold` *contiguously*.
/// Returns the elapsed span in milliseconds.
fn hr_spike_span_ms(buf: &VecDeque<Sample<f32>>, threshold: f32) -> u64 {
    let mut newest_ts: Option<u64> = None;
    let mut oldest_ts: Option<u64> = None;
    for s in buf.iter().rev() {
        if s.value >= threshold {
            if newest_ts.is_none() {
                newest_ts = Some(s.ts_ms);
            }
            oldest_ts = Some(s.ts_ms);
        } else if newest_ts.is_some() {
            break;
        }
    }
    match (newest_ts, oldest_ts) {
        (Some(n), Some(o)) => n.saturating_sub(o),
        _ => 0,
    }
}

fn median(buf: &VecDeque<Sample<f32>>) -> Option<f32> {
    if buf.is_empty() {
        return None;
    }
    let mut v: Vec<f32> = buf.iter().map(|s| s.value).collect();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = v.len();
    if n % 2 == 1 {
        Some(v[n / 2])
    } else {
        Some((v[n / 2 - 1] + v[n / 2]) / 2.0)
    }
}

fn recent_window_mean(buf: &VecDeque<Sample<f32>>, now_ms: u64, win_ms: u64) -> Option<f32> {
    let mut sum = 0.0_f32;
    let mut n = 0u32;
    for s in buf.iter().rev() {
        if now_ms.saturating_sub(s.ts_ms) > win_ms {
            break;
        }
        sum += s.value;
        n += 1;
    }
    if n == 0 {
        None
    } else {
        Some(sum / n as f32)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_signal_before_session_warmup() {
        let mut d = NightmareDetector::new();
        d.note_session_start(0);
        // Push some baseline HRs at 60 bpm + zero motion for only 5 minutes.
        for i in 0..300 {
            d.push_hr(60.0, i * 1000);
            d.push_motion(0.0, i * 1000);
        }
        // Even a hard spike at t=5min should not register — too early.
        for i in 300..360 {
            d.push_hr(120.0, i * 1000);
            d.push_motion(0.5, i * 1000);
        }
        assert!(!d.tick(360 * 1000));
    }

    #[test]
    fn fires_on_sustained_hr_and_motion_spike() {
        let mut d = NightmareDetector::new();
        d.note_session_start(0);
        // 25 minutes of calm baseline (60 bpm, ENMO near zero).
        for i in 0..(25 * 60) {
            d.push_hr(60.0, i * 1000);
            d.push_motion(0.005, i * 1000);
        }
        // Now a ~1-minute HR spike to 90 bpm + ENMO 0.15 (~5× baseline).
        let spike_start: u64 = 25 * 60;
        for i in spike_start..(spike_start + 60) {
            d.push_hr(90.0, i * 1000);
            d.push_motion(0.15, i * 1000);
        }
        let now = (spike_start + 60) * 1000;
        let active = d.tick(now);
        assert!(
            active,
            "detector should fire on sustained HR + motion spike"
        );
    }

    #[test]
    fn does_not_fire_on_motion_alone() {
        // E.g. position change without HR change.
        let mut d = NightmareDetector::new();
        d.note_session_start(0);
        for i in 0..(25 * 60) {
            d.push_hr(60.0, i * 1000);
            d.push_motion(0.005, i * 1000);
        }
        for i in (25 * 60)..(26 * 60) {
            d.push_hr(60.0, i * 1000);
            d.push_motion(0.20, i * 1000);
        }
        assert!(!d.tick(26 * 60 * 1000));
    }

    #[test]
    fn does_not_fire_on_hr_alone() {
        let mut d = NightmareDetector::new();
        d.note_session_start(0);
        for i in 0..(25 * 60) {
            d.push_hr(60.0, i * 1000);
            d.push_motion(0.005, i * 1000);
        }
        for i in (25 * 60)..(26 * 60) {
            d.push_hr(95.0, i * 1000);
            d.push_motion(0.005, i * 1000);
        }
        assert!(!d.tick(26 * 60 * 1000));
    }

    #[test]
    fn signal_latches_briefly_after_spike() {
        let mut d = NightmareDetector::new();
        d.note_session_start(0);
        for i in 0..(25 * 60) {
            d.push_hr(60.0, i * 1000);
            d.push_motion(0.005, i * 1000);
        }
        for i in (25 * 60)..(26 * 60) {
            d.push_hr(90.0, i * 1000);
            d.push_motion(0.15, i * 1000);
        }
        let t0 = 26 * 60 * 1000;
        assert!(d.tick(t0));
        // 1 minute after spike ends, signal should still be latched.
        assert!(d.is_active(t0 + 60_000));
        // 5 minutes later, latch should have expired.
        assert!(!d.is_active(t0 + 5 * 60_000));
    }
}
