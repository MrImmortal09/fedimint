/// The env var for maximum open connections the API can handle
pub const FM_MAX_CLIENT_CONNECTIONS_ENV: &str = "FM_MAX_CLIENT_CONNECTIONS";
pub const FM_PEER_ID_SORT_BY_URL_ENV: &str = "FM_PEER_ID_SORT_BY_URL";

/// Environment variable for UI bind address
pub const FM_UI_BIND_ENV: &str = "FM_UI_BIND";

/// Environment variable for the session count determining when to cleanup old
/// checkpoints.
pub const FM_DB_CHECKPOINT_RETENTION_ENV: &str = "FM_DB_CHECKPOINT_RETENTION";

/// Default number of checkpoints from the current session should be retained on
/// disk.
pub const FM_DB_CHECKPOINT_RETENTION_DEFAULT: u64 = 1;

/// Use iroh for networking
pub const FM_FORCE_IROH_ENV: &str = "FM_FORCE_IROH";
