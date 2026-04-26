//! SQLite repository. Single-writer, application-owned connection.
use crate::db::schema::LOCAL_SCHEMA_SQL;
use crate::Result;
use rusqlite::{params, Connection};

#[derive(Debug, Clone, Copy)]
#[repr(i32)]
pub enum SampleKind {
    HeartRate = 1,
    Accelerometer = 2,
    AudioEvent = 3,
    Hrv = 4,
}

pub struct Repo {
    conn: Connection,
}

impl Repo {
    pub fn open(path: &str) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(LOCAL_SCHEMA_SQL)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        Ok(Self { conn })
    }

    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(LOCAL_SCHEMA_SQL)?;
        Ok(Self { conn })
    }

    pub fn insert_session(&self, id: &str, started_at_ms: u64, user_id: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO sessions (id, user_id, started_at_ms, ended_at_ms, uploaded) \
             VALUES (?1, ?2, ?3, NULL, 0)",
            params![id, user_id, started_at_ms as i64],
        )?;
        Ok(())
    }

    pub fn close_session(&self, id: &str, ended_at_ms: u64) -> Result<()> {
        self.conn.execute(
            "UPDATE sessions SET ended_at_ms = ?1 WHERE id = ?2",
            params![ended_at_ms as i64, id],
        )?;
        Ok(())
    }

    pub fn insert_sample(
        &self,
        session_id: &str,
        ts_ms: u64,
        kind: SampleKind,
        value_json: &str,
    ) -> Result<()> {
        self.conn.execute(
            "INSERT INTO samples (session_id, ts_ms, kind, value_json) VALUES (?1, ?2, ?3, ?4)",
            params![session_id, ts_ms as i64, kind as i32, value_json],
        )?;
        Ok(())
    }

    pub fn insert_stage_transition(
        &self,
        session_id: &str,
        ts_ms: u64,
        stage: i32,
        confidence: f32,
    ) -> Result<()> {
        self.conn.execute(
            "INSERT INTO stage_timeline (session_id, ts_ms, stage, confidence) VALUES (?1, ?2, ?3, ?4)",
            params![session_id, ts_ms as i64, stage, confidence as f64],
        )?;
        Ok(())
    }

    pub fn count_sessions(&self) -> Result<i64> {
        let n: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM sessions", [], |r| r.get(0))?;
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opens_and_inserts() {
        let r = Repo::open_in_memory().unwrap();
        r.insert_session("s1", 1000, "u").unwrap();
        r.insert_sample("s1", 1500, SampleKind::HeartRate, "60")
            .unwrap();
        r.insert_stage_transition("s1", 2000, 1, 0.6).unwrap();
        r.close_session("s1", 3000).unwrap();
        assert_eq!(r.count_sessions().unwrap(), 1);
    }
}
