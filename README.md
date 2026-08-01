# Scout

Scout is a terminal project picker for tmux. It scans the directories directly
below a root, filters them with a built-in fuzzy matcher, and opens the selected
project in a tmux session. Active sessions appear first with a green marker.
The selected Git repository shows its branch and status.

## Requirements

- Zig 0.16
- libgit2 development headers and library (tested with 1.9.6)
- `tmux`, unless Scout runs with `--no-tmux`

## Build

```sh
zig build -Doptimize=ReleaseFast
```

The binary is written to `zig-out/bin/scout`.

## Usage

Scout searches `~/Projects` by default:

```sh
scout
```

Choose another root directory:

```sh
scout --path ~/projects
```

Print the selected path instead of opening a tmux session:

```sh
scout --no-tmux
```

## Performance

Scout streams directory batches into the picker, then enriches them with tmux
and Git metadata in the background. Filtering reuses its working storage and
constructs an absolute path only after selection.

## License

[MIT](LICENSE).
