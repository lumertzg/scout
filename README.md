# Scout

Scout is a terminal project picker. It lists directories from a given path and
uses fuzzy search to select one. The default path is `~/Projects`.

Scout can print the selected path or open it with tmux or Kitty. Active sessions
are marked in green.

## Build

Requires Zig 0.16.

```sh
zig build -Doptimize=ReleaseFast
```

The binary is written to `zig-out/bin/scout`.

## Usage

```sh
scout [--path DIR] [--backend path|tmux|kitty]
```

The default path is `~/Projects`. The default backend is `path`.

- `path` prints the selected directory.
- `tmux` opens or switches to a tmux session.
- `kitty` opens or switches to a Kitty session.

Set the default backend with `SCOUT_BACKEND`:

```sh
SCOUT_BACKEND=tmux scout
```

## Kitty

Requires Kitty 0.43 or newer and the `kitten` command.
The `tab_bar_filter session:~` setting is required for Scout's Kitty integration.

Linux:

```conf
allow_remote_control socket-only
listen_on unix:@scout
tab_bar_filter session:~
```

macOS:

```conf
allow_remote_control socket-only
listen_on unix:scout
tab_bar_filter session:~
```

Restart Kitty after changing its configuration.

To open Scout in an overlay:

```conf
map ctrl+b>f launch --type=overlay --cwd=current scout --backend=kitty
```

## License

[MIT](LICENSE)
