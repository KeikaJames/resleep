//! Inference backends.
//!
//! `RuleInference` is a deliberately simple, explainable baseline:
//! - high motion energy → Wake
//! - low motion + HR falling → Deep
//! - low motion + HR flat   → Light
//! - low motion + HR rising → Rem
//!
//! The tiny-transformer (Core ML) is wired from Swift and will be consumed
//! here as a rescorer once the xcframework path is in place.

use crate::engine::state::Stage;
use crate::signal::features::FeatureSnapshot;

pub trait StageInference {
    fn infer(&self, feats: &FeatureSnapshot) -> (Stage, f32);
}

#[derive(Debug, Default)]
pub struct RuleInference;

impl RuleInference {
    pub fn new() -> Self { Self }
}

impl StageInference for RuleInference {
    fn infer(&self, f: &FeatureSnapshot) -> (Stage, f32) {
        if f.hr_sample_count < 3 && f.accel_sample_count < 3 {
            return (Stage::Wake, 0.3);
        }

        // Motion gate.
        let motion_high = f.accel_energy > 1.2 || f.accel_std > 0.35;
        if motion_high {
            return (Stage::Wake, 0.75);
        }

        // HR trend.
        let slope = f.hr_slope;
        let (stage, conf) = if slope < -0.2 {
            (Stage::Deep, 0.65)
        } else if slope > 0.2 {
            (Stage::Rem, 0.6)
        } else {
            (Stage::Light, 0.55)
        };
        (stage, conf)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn high_motion_is_wake() {
        let f = FeatureSnapshot {
            accel_energy: 3.0,
            accel_sample_count: 10,
            hr_sample_count: 10,
            ..Default::default()
        };
        let (s, c) = RuleInference::new().infer(&f);
        assert_eq!(s, Stage::Wake);
        assert!(c > 0.5);
    }

    #[test]
    fn hr_falling_is_deep() {
        let f = FeatureSnapshot {
            hr_sample_count: 10,
            accel_sample_count: 10,
            hr_slope: -1.0,
            accel_energy: 0.1,
            ..Default::default()
        };
        let (s, _) = RuleInference::new().infer(&f);
        assert_eq!(s, Stage::Deep);
    }
}
