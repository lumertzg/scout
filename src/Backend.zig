//! Project selection and terminal handoff modes.

/// User-facing backend selected by the CLI.
pub const Backend = enum {
    path,
    tmux,
    kitty,
    herdr,
};

/// Backends that open a project instead of printing its path.
pub const TerminalBackend = enum {
    tmux,
    kitty,
    herdr,
};
