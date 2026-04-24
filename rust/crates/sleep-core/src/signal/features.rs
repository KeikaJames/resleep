//! Rolling feature extraction. Mirrors the Python training feature contract:
//! hr_mean, hr_std, hr_slope, accel_mean, accel_std, accel_energy.

use std::collections::VecDeque;

const HR_WINDOW: usize = 64;
const ACCEL_WINDOW: usize = 256;

#[derive(Debug, Clone, Default)]
pub struct FeatureSnapshot {
    pub hr_mean: f32,
    pub hr_std: f32,
    pub hr_slope: f32,
    pub accel_mean: f32,
    pub accel_std: f32,
    pub accel_energy: f32,
    pub hr_sample_count: usize,
    pub accel_sample_count: usize,
}

#[derive(Debug)]
pub struct FeatureBuffers {
    hr: VecDeque<(u64, f32)>,
    accel_mag: VecDeque<(u64, f32)>,
}

impl FeatureBuffers {
    pub fn new() -> Self {
        Self {
            hr: VecDeque::with_capacity(HR_WINDOW),
            accel_mag: VecDeque::with_capacity(ACCEL_WINDOW),
        }
    }

    pub fn reset(&mut self) {
        self.hr.clear();
        self.accel_mag.clear();
    }

    pub fn push_hr(&mut self, bpm: f32, ts_ms: u64) {
        if self.hr.len() == HR_WINDOW {
            self.hr.pop_front();
        }
        self.hr.push_back((ts_ms, bpm));
    }

    pub fn push_accel(&mut self, x: f32, y: f32, z: f32, ts_ms: u64) {
        let mag = (x * x + y * y + z * z).sqrt();
        if self.accel_mag.len() == ACCEL_WINDOW {
            self.accel_mag.pop_front();
        }
        self.accel_mag.push_back((ts_ms, mag));
    }

    pub fn snapshot(&self) -> FeatureSnapshot {
        let (hr_mean, hr_std, hr_slope) = stats_with_slope(&self.hr);
        let (accel_mean, accel_std, accel_energy) = stats_with_energy(&self.accel_mag);
        FeatureSnapshot {
            hr_mean,
            hr_std,
            hr_slope,
            accel_mean,
            accel_std,
            accel_energy,
            hr_sample_count: self.hr.len(),
            accel_sample_count: self.accel_mag.len(),
        }
    }
}

impl Default for FeatureBuffers {
    fn default() -> Self {
        Self::new()
    }
}

fn stats_with_slope(series: &VecDeque<(u64, f32)>) -> (f32, f32, f32) {
    if series.is_empty() {
        return (0.0, 0.0, 0.0);
    }
    let n = series.len() as f32;
    let mean = series.iter().map(|(_, v)| *v).sum::<f32>() / n;
    let var = series.iter().map(|(_, v)| (*v - mean).powi(2)).sum::<f32>() / n;
    let std = var.sqrt();

    // Least-squares slope using normalized time (seconds from first sample).
    let t0 = series.front().map(|(t, _)| *t).unwrap_or(0);
    let mut sx = 0.0;
    let mut sy = 0.0;
    let mut sxx = 0.0;
    let mut sxy = 0.0;
    for (t, v) in series {
        let x = (*t - t0) as f32 / 1000.0;
        sx += x;
        sy += *v;
        sxx += x * x;
        sxy += x * *v;
    }
    let denom = n * sxx - sx * sx;
    let slope = if denom.abs() > f32::EPSILON { (n * sxy - sx * sy) / denom } else { 0.0 };
    (mean, std, slope)
}

fn stats_with_energy(series: &VecDeque<(u64, f32)>) -> (f32, f32, f32) {
    if series.is_empty() {
        return (0.0, 0.0, 0.0);
    }
    let n = series.len() as f32;
    let mean = series.iter().map(|(_, v)| *v).sum::<f32>() / n;
    let var = series.iter().map(|(_, v)| (*v - mean).powi(2)).sum::<f32>() / n;
    let std = var.sqrt();
    // Energy = mean of squared magnitudes (rough proxy).
    let energy = series.iter().map(|(_, v)| v * v).sum::<f32>() / n;
    (mean, std, energy)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_snapshot_is_zero() {
        let b = FeatureBuffers::new();
        let s = b.snapshot();
        assert_eq!(s.hr_mean, 0.0);
        assert_eq!(s.accel_energy, 0.0);
    }

    #[test]
    fn hr_mean_is_correct() {
        let mut b = FeatureBuffers::new();
        for (i, v) in [60.0_f32, 62.0, 64.0].iter().enumerate() {
            b.push_hr(*v, (i as u64) * 1000);
        }
        let s = b.snapshot();
        assert!((s.hr_mean - 62.0).abs() < 1e-3);
        assert!(s.hr_slope > 0.0);
    }
}
