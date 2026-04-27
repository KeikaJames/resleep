//! Classical actigraphy sleep/wake classifiers.
//!
//! These algorithms operate on per-epoch (typically 1-minute) activity counts
//! derived from accelerometer magnitude. They are deterministic, published,
//! and used as ground-truth references in a large body of sleep research.
//!
//! References:
//! - Cole RJ, Kripke DF, Gruen W, Mullaney DJ, Gillin JC. (1992)
//!   "Automatic sleep/wake identification from wrist activity." Sleep 15(5).
//! - Sadeh A, Sharkey KM, Carskadon MA. (1994)
//!   "Activity-based sleep-wake identification: an empirical test of
//!   methodological issues." Sleep 17(3).
//! - van Hees VT et al. (2018) "Estimating sleep parameters using an
//!   accelerometer without sleep diary." Scientific Reports 8.
//!
//! All implementations are pure functions over `&[f32]` activity-count slices
//! with no allocation in the hot path.

/// Cole-Kripke (1992) wrist actigraphy classifier.
///
/// For each epoch `i`, a weighted sum of activity counts at offsets
/// `i-4 .. i+2` is compared against threshold `1.0`. Sums >= 1.0 are wake.
/// Standard scale factor `P = 0.0001` for wrist-band counts (paper).
///
/// Returns one prediction per input epoch: `true` = wake, `false` = sleep.
/// Edge epochs missing context are treated as sleep (conservative).
pub fn cole_kripke(activity_counts: &[f32]) -> Vec<bool> {
    const P: f32 = 0.0001;
    // Weights for offsets -4, -3, -2, -1, 0, +1, +2 (Cole 1992, "best" set).
    const W: [f32; 7] = [106.0, 54.0, 58.0, 76.0, 230.0, 74.0, 67.0];
    let n = activity_counts.len();
    let mut out = vec![false; n];
    for i in 0..n {
        let mut s = 0.0_f32;
        for (k, &w) in W.iter().enumerate() {
            // offset -4 .. +2 maps to k 0..=6
            let offset = k as isize - 4;
            let idx = i as isize + offset;
            if idx < 0 || idx >= n as isize {
                continue;
            }
            s += w * activity_counts[idx as usize];
        }
        out[i] = (P * s) >= 1.0;
    }
    out
}

/// Sadeh (1994) wrist actigraphy classifier.
///
/// `score = 7.601 - 0.065 * AVG5 - 1.08 * NAT5 - 0.056 * SD6 - 0.703 * LOG10(AC+1)`
/// where the window is the 11-epoch window centered on the current epoch.
///   AVG5 = mean activity in the 5-epoch window centered at i
///   NAT5 = count of epochs with activity 50..100 in same window
///   SD6  = std of activity in the previous 6 epochs (i-5..=i)
///   AC   = activity at i
/// score >= 0 → sleep, score < 0 → wake.
pub fn sadeh(activity_counts: &[f32]) -> Vec<bool> {
    let n = activity_counts.len();
    let mut out = vec![false; n];
    for i in 0..n {
        // AVG5: window i-2 .. i+2
        let lo5 = i.saturating_sub(2);
        let hi5 = (i + 2).min(n.saturating_sub(1));
        let win5 = &activity_counts[lo5..=hi5];
        let avg5 = mean(win5);
        let nat5 = win5.iter().filter(|&&v| v >= 50.0 && v < 100.0).count() as f32;

        // SD6: window i-5 .. i  (6 epochs ending at i)
        let lo6 = i.saturating_sub(5);
        let win6 = &activity_counts[lo6..=i];
        let sd6 = std(win6);

        let ac = activity_counts[i];
        let score =
            7.601 - 0.065 * avg5 - 1.08 * nat5 - 0.056 * sd6 - 0.703 * (ac + 1.0).log10();
        out[i] = score < 0.0; // wake when negative
    }
    out
}

/// Convenience: ensemble of Cole-Kripke + Sadeh. An epoch is `wake` only if
/// both agree; this reduces false-wake noise during quiet sleep.
pub fn ck_sadeh_ensemble(activity_counts: &[f32]) -> Vec<bool> {
    let a = cole_kripke(activity_counts);
    let b = sadeh(activity_counts);
    a.iter().zip(b.iter()).map(|(x, y)| *x && *y).collect()
}

/// Compute one activity count per epoch from a stream of accelerometer
/// magnitudes (sqrt(x^2+y^2+z^2) - 1.0, "ENMO"). Counts are sum-of-absolute
/// deviations within an epoch, scaled to roughly match wrist-actigraphy
/// units. This is *not* an exact ActiGraph emulation — it's a calibrated
/// proxy that works well in concert with the published threshold constants.
pub fn enmo_to_counts(enmo: &[f32], samples_per_epoch: usize) -> Vec<f32> {
    if samples_per_epoch == 0 {
        return Vec::new();
    }
    enmo.chunks(samples_per_epoch)
        .map(|chunk| {
            // ActiGraph-like: integrate band-pass-filtered |a-1g|. Without
            // a real BPF we use absolute mean × empirical gain.
            let s: f32 = chunk.iter().map(|x| x.abs()).sum();
            s * 1000.0 / chunk.len().max(1) as f32
        })
        .collect()
}

/// van Hees-style sustained-inactivity sleep-onset detector.
///
/// Returns the index of the first epoch in `enmo_per_epoch` after which the
/// rolling window of length `window_epochs` stays below `threshold` for
/// at least `sustain_epochs` continuous epochs. `None` if no such window.
///
/// Threshold defaults: window 5, sustain 30, threshold 0.013 g (HDCZA paper).
pub fn detect_sleep_onset(
    enmo_per_epoch: &[f32],
    window_epochs: usize,
    sustain_epochs: usize,
    threshold: f32,
) -> Option<usize> {
    let n = enmo_per_epoch.len();
    if window_epochs == 0 || n < window_epochs + sustain_epochs {
        return None;
    }
    let mut quiet_run = 0usize;
    let mut start: Option<usize> = None;
    for i in (window_epochs - 1)..n {
        let win = &enmo_per_epoch[i + 1 - window_epochs..=i];
        let m = mean(win);
        if m < threshold {
            if quiet_run == 0 {
                start = Some(i + 1 - window_epochs);
            }
            quiet_run += 1;
            if quiet_run >= sustain_epochs {
                return start;
            }
        } else {
            quiet_run = 0;
            start = None;
        }
    }
    None
}

fn mean(xs: &[f32]) -> f32 {
    if xs.is_empty() {
        0.0
    } else {
        xs.iter().sum::<f32>() / xs.len() as f32
    }
}

fn std(xs: &[f32]) -> f32 {
    if xs.len() < 2 {
        return 0.0;
    }
    let m = mean(xs);
    let var = xs.iter().map(|x| (x - m).powi(2)).sum::<f32>() / xs.len() as f32;
    var.sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cole_kripke_classifies_quiet_as_sleep() {
        let counts = vec![0.0; 32];
        let pred = cole_kripke(&counts);
        assert!(pred.iter().all(|&w| !w), "all-zero counts must be sleep");
    }

    #[test]
    fn cole_kripke_classifies_high_activity_as_wake() {
        // Sustained high counts → wake throughout the centre band.
        let counts = vec![500.0; 32];
        let pred = cole_kripke(&counts);
        // Edges (first/last few) may be sleep due to truncated windows; centre
        // must be wake.
        assert!(pred[10..20].iter().all(|&w| w));
    }

    #[test]
    fn sadeh_classifies_quiet_as_sleep() {
        let counts = vec![0.0; 32];
        let pred = sadeh(&counts);
        assert!(pred.iter().all(|&w| !w));
    }

    #[test]
    fn sadeh_classifies_high_activity_as_wake() {
        let counts = vec![500.0; 32];
        let pred = sadeh(&counts);
        assert!(pred[5..28].iter().all(|&w| w));
    }

    #[test]
    fn ensemble_is_intersection() {
        let mut counts = vec![0.0; 32];
        // Single spike — Sadeh might call wake, CK only if weighted sum crosses.
        counts[16] = 500.0;
        let ens = ck_sadeh_ensemble(&counts);
        let ck = cole_kripke(&counts);
        let sd = sadeh(&counts);
        for i in 0..32 {
            assert_eq!(ens[i], ck[i] && sd[i]);
        }
    }

    #[test]
    fn enmo_to_counts_chunks_correctly() {
        let enmo = vec![0.1; 12];
        let counts = enmo_to_counts(&enmo, 4);
        assert_eq!(counts.len(), 3);
        for c in counts {
            // 0.1 abs mean × 1000 = 100 per epoch
            assert!((c - 100.0).abs() < 1e-3);
        }
    }

    #[test]
    fn detect_sleep_onset_finds_quiet_window() {
        let mut enmo = vec![0.05_f32; 60]; // active period
        enmo.extend(vec![0.005_f32; 60]); // quiet period
        let onset = detect_sleep_onset(&enmo, 5, 30, 0.013);
        assert!(onset.is_some());
        let i = onset.unwrap();
        assert!(i >= 60 - 5, "onset should be near start of quiet block");
    }

    #[test]
    fn detect_sleep_onset_returns_none_when_always_active() {
        let enmo = vec![0.05_f32; 200];
        assert!(detect_sleep_onset(&enmo, 5, 30, 0.013).is_none());
    }
}
