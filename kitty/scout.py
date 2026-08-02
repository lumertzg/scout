"""Kitty-side session bridge used by Scout."""

import os
import tempfile
from pathlib import Path

from kitty.boss import Boss
from kittens.tui.handler import result_handler


SESSION_ROOT = Path("/tmp/scout")
SESSION_DIRECTORY = SESSION_ROOT / "kitty-sessions"
SESSION_FILE_MODE = 0o600
SESSION_DIRECTORY_MODE = 0o700


def main(_args: list[str]) -> None:
    """Satisfy Kitty's custom-kitten loader; this kitten has no UI."""


@result_handler(no_ui=True)
def handle_result(
    args: list[str],
    _answer: None,
    target_window_id: int,
    boss: Boss,
) -> str | None:
    """Run one small, machine-readable operation requested by Scout."""
    command_args = args[1:]
    if not command_args:
        raise ValueError("expected --list or --open PATH")

    command = command_args[0]
    if command == "--list" and len(command_args) == 1:
        return list_active_sessions(boss)
    if command == "--open" and len(command_args) == 2:
        session_path = write_session_file(command_args[1])
        target_window = boss.window_id_map.get(target_window_id)
        boss.call_remote_control(
            target_window,
            ("action", "goto_session", str(session_path)),
        )
        return None

    raise ValueError("expected --list or --open PATH")


def list_active_sessions(boss: Boss) -> str:
    """Return active Kitty session names, one per line."""
    names = sorted({name for name in boss.all_loaded_session_names if name})
    return "\n".join(names)


def write_session_file(project_path: str) -> Path:
    """Write a minimal session file without exposing a shell command."""
    if any(character in project_path for character in "\x00\r\n"):
        raise ValueError("project path contains a control character")

    path = Path(project_path).expanduser().resolve()
    if not path.is_dir():
        raise ValueError(f"project path is not a directory: {project_path}")

    SESSION_ROOT.mkdir(mode=SESSION_DIRECTORY_MODE, parents=True, exist_ok=True)
    SESSION_DIRECTORY.mkdir(mode=SESSION_DIRECTORY_MODE, exist_ok=True)
    os.chmod(SESSION_ROOT, SESSION_DIRECTORY_MODE)
    os.chmod(SESSION_DIRECTORY, SESSION_DIRECTORY_MODE)

    session_path = SESSION_DIRECTORY / f"{path.name}.session"
    content = f"cd {path}\nlaunch\n"
    temporary_path: str | None = None
    try:
        descriptor, temporary_path = tempfile.mkstemp(
            prefix=".scout-",
            suffix=".session",
            dir=SESSION_DIRECTORY,
            text=True,
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as session_file:
            session_file.write(content)
        os.chmod(temporary_path, SESSION_FILE_MODE)
        os.replace(temporary_path, session_path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except FileNotFoundError:
                pass

    return session_path
