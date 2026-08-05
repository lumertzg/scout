# Scout

Scout is a terminal project picker with fuzzy search. It lists projects from a
directory and either prints the selected path or opens it with tmux or Kitty.
Active tmux and Kitty sessions appear first and are marked in green. Git
projects show their branch and status.

## Requirements

- Zig 0.16
- libgit2 development headers and library (tested with 1.9.6)
- `tmux` when Scout runs with `--backend=tmux`
- Kitty 0.43 or newer and its `kitten` command when Scout runs with
  `--backend=kitty`
- A remote-control socket through `KITTY_LISTEN_ON` for the Kitty backend

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

<details>
<summary>Path backend</summary>


Print the selected project path without opening a terminal session. This is
the default backend:

```sh
scout
```

You can also select it explicitly:

```sh
scout --backend=path
```

</details>

<details>
<summary>Tmux backend</summary>


Open the selected project in a tmux session:

```sh
scout --backend=tmux
```

</details>

<details>
<summary>Kitty backend</summary>


The Kitty backend uses Kitty's native remote-control commands to list active
sessions and switch projects through Kitty's session action.

The Kitty backend requires a remote-control socket. Configure one with
`listen_on` and allow socket connections with `allow_remote_control`. The
`socket-only` mode shown below avoids enabling remote control through the
terminal. On Linux, prefer an abstract Unix socket:

```conf
allow_remote_control socket-only
listen_on unix:@scout
```

On macOS and systems without abstract Unix sockets, use a filesystem-backed
Unix socket:

```conf
allow_remote_control socket-only
listen_on unix:scout
```

`listen_on` applies to all Kitty instances and can be overridden with Kitty's
`--listen-on` command-line option. Kitty expands environment variables and
resolves relative Unix socket paths from the temporary directory. Unless the
address contains `{kitty_pid}`, Kitty appends its process ID to the address.

Restart Kitty after changing `listen_on`. Reloading the config does not apply
the change. Kitty exports the resolved socket address as `KITTY_LISTEN_ON` to
programs launched inside it, which is how Scout finds the socket.

You can run Scout directly from a Kitty shell:

```sh
scout --backend=kitty
```

You can also launch Scout as an overlay:

```conf
map ctrl+b>f launch --type=overlay --cwd=current scout --backend=kitty
```

Scout requires `KITTY_LISTEN_ON` for every Kitty operation. It reads active
sessions in the background through that socket, so remote-control
replies cannot conflict with picker input.

Recommended Kitty configuration for showing the active session's tabs along
with tabs that do not belong to a session:
```conf
tab_bar_filter session:~ or session:^$
```

</details>

## Performance

Scout streams directory batches into the picker, then enriches them with
terminal session and Git metadata in the background. Filtering reuses its
working storage.

## License

[MIT](LICENSE).
