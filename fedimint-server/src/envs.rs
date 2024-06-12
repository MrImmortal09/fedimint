/// The env var for maximum open connections the API can handle
pub const FM_MAX_CLIENT_CONNECTIONS_ENV: &str = "FM_MAX_CLIENT_CONNECTIONS";
pub const FM_PEER_ID_SORT_BY_URL_ENV: &str = "FM_PEER_ID_SORT_BY_URL";

/// Environment variable for the session count determining when to cleanup old
/// checkpoints.
pub const FM_DB_CHECKPOINT_SESSION_DIFFERENCE_ENV: &str = "FM_DB_CHECKPOINT_SESSION_DIFFERENCE";
/// Environment variable for how often (in # of sessions) to checkpoint the
/// database.
pub const FM_DB_CHECKPOINT_FREQ_ENV: &str = "FM_DB_CHECKPOINT_FREQ";
