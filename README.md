# Scout

Scout is a terminal project picker for tmux and Kitty. It scans the directories
directly below a root and filters them with a built-in fuzzy matcher. It prints
the selected path by default, or opens it in a terminal session with a selected
backend. Active tmux sessions appear first with a green marker.
The selected Git repository shows its branch and status.

## Requirements

- Zig 0.16
- libgit2 development headers and library (tested with 1.9.6)
- `tmux` when Scout runs with `--backend=tmux`
- Kitty 0.43 or newer and its `kitten` command when Scout runs with
  `--backend=kitty`

## Build

```sh
zig build -Doptimize=ReleaseFast
```

The binary is written to `zig-out/bin/scout`.

## Usage

Scout searches `~/Projects` by default. Use `--path` with any backend to choose
a different root:

```sh
scout --path ~/projects
```

Set `SCOUT_BACKEND` to change the default backend. An explicit `--backend`
argument takes precedence:

```sh
SCOUT_BACKEND=kitty scout
SCOUT_BACKEND=kitty scout --backend=path
```

### Path backend

Print the selected project path without opening a terminal session. This is
the default backend:

```sh
scout
```

You can also select it explicitly:

```sh
scout --backend=path
```

### Tmux backend

Open the selected project in a tmux session:

```sh
scout --backend=tmux
```

### Kitty backend

The Kitty backend uses the custom kitten in `kitty/scout.py`. Kitty loads
custom kittens from its config directory, so install the file there first:

```sh
mkdir -p ~/.config/kitty
cp kitty/scout.py ~/.config/kitty/scout.py
```

Use a symlink instead if you want Kitty to use the working copy:

```sh
ln -sfn "$PWD/kitty/scout.py" ~/.config/kitty/scout.py
```

The kitten lists active Kitty sessions and creates or switches to a basic
`.session` file under `/tmp/scout/kitty-sessions`. Scout talks only to this
kitten; the Python code handles the Kitty session action inside Kitty.

The recommended setup grants access only to Scout when it runs as an overlay:

```conf
map ctrl+b>f launch --type=overlay --allow-remote-control --cwd=current scout --backend=kitty
```

`--allow-remote-control` creates a private connection for the launched child,
which `kitten @` uses through `KITTY_LISTEN_ON`. This avoids enabling remote
control for every program running inside Kitty.

To run Scout directly from a Kitty shell, enable remote control in
`kitty.conf`, then reload or restart Kitty:

```conf
allow_remote_control yes
```

```sh
scout --backend=kitty
```

For direct shell launches, Scout reads active Kitty sessions before opening the
picker so the remote-control reply cannot conflict with picker input. The
mapped overlay can read them in the background through its private channel.

Reload Kitty after installing or changing the kitten:

```sh
kitty @ load-config
```

Recommended Kitty configuration for showing only the active session's tabs:
```conf
tab_bar_filter session:~
```

## Performance

Scout streams directory batches into the picker, then enriches them with
terminal session and Git metadata in the background. Filtering reuses its
working storage.

## License

[MIT](LICENSE).
