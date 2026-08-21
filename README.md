# Scout

Scout is a terminal project picker. It lists directories from a given path and
uses fuzzy search to select one. The default path is `~/Projects`.

Scout can print the selected path or open it with tmux or Herdr. Active
sessions are marked in green.

## Install

Download the archive for your platform from the
[latest release](https://github.com/lumertzg/scout/releases/latest), extract it,
and place `scout` somewhere on `PATH`.

To build from source, install Zig 0.16 and run:

```sh
zig build -Doptimize=ReleaseFast
mkdir -p ~/.local/bin
install -m 755 zig-out/bin/scout ~/.local/bin/scout
```

## Shell integration

The default `path` backend prints the selected project. Add a helper to your
shell configuration to change directory after selection.

Bash or Zsh:

```sh
sp() {
  local project
  project="$(scout "$@")" || return
  [ -n "$project" ] && cd -- "$project"
}
```

Fish:

```fish
function sp
    set -l project (scout $argv)
    or return
    test -n "$project"; and cd -- "$project"
end
```

## Usage

```sh
scout [QUERY] [--path DIR] [--backend path|tmux|herdr]
```

The default path is `~/Projects`. The default backend is `path`.

Pass a project name or fuzzy query to select it without opening the picker.
An exact project name takes priority over other fuzzy matches. A unique fuzzy
match also opens directly. Queries with no match or multiple matches open the
picker with the query entered so it can be refined or selected.

```sh
scout scout --backend tmux
```

- `path` prints the selected directory.
- `tmux` opens or switches to a tmux session.
- `herdr` opens or focuses a Herdr workspace and attaches to Herdr when needed.

Set the default backend with `SCOUT_BACKEND`:

```sh
SCOUT_BACKEND=tmux scout
```

## Herdr

[Herdr](https://herdr.dev/docs/socket-api/) must be installed. Scout starts and
attaches to Herdr when needed. When already running inside Herdr, Scout switches
workspaces without nesting another client. `HERDR_SOCKET_PATH` and
`HERDR_SESSION` select a non-default Herdr session.

```sh
SCOUT_BACKEND=herdr scout
```

## License

[MIT](LICENSE)
