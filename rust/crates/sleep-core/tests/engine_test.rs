use sleep_core::{EngineConfig, SleepEngine};

#[test]
fn end_to_end_fake_session() {
    let tmp = tempfile::tempdir().unwrap();
    let db = tmp.path().join("t.db");
    let cfg = EngineConfig::new(db.to_string_lossy().to_string(), String::new(), "test-user");
    let mut engine = SleepEngine::new(cfg).unwrap();

    let t0 = 1_700_000_000_000u64;
    let id = engine.start_session(t0).unwrap();
    assert!(!id.is_empty());

    // Feed fake samples: initial activity → calm → light sleep.
    for i in 0..20u64 {
        let ts = t0 + i * 1000;
        engine.push_heart_rate(70.0 - (i as f32) * 0.3, ts).unwrap();
        let mag = if i < 5 { 0.5 } else { 0.02 };
        engine.push_accelerometer(mag, mag, mag, ts).unwrap();
    }

    let summary = engine.end_session().unwrap();
    assert_eq!(summary.session_id, id);
    assert!(summary.duration_sec > 0);
}
