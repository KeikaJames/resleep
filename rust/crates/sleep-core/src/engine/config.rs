/// Engine construction config. Paths are OS-local; user_id is an opaque stable token.
#[derive(Debug, Clone)]
pub struct EngineConfig {
    /// Absolute path to the SQLite database file.
    pub db_path: String,
    /// Absolute path to a Core ML model artefact (may be empty for rule-only mode).
    pub model_path: String,
    /// Stable opaque user identifier (never a phone/email).
    pub user_id: String,
}

impl EngineConfig {
    pub fn new(db_path: impl Into<String>, model_path: impl Into<String>, user_id: impl Into<String>) -> Self {
        Self {
            db_path: db_path.into(),
            model_path: model_path.into(),
            user_id: user_id.into(),
        }
    }
}
