# Scout

Scout is a terminal project picker for tmux. It scans the directories directly
below a root, filters them with a built-in fuzzy matcher, and opens the selected
project in a tmux session. Active sessions appear first with a green marker.

## Requirements

- Zig 0.16
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

List project names without opening the picker:

```sh
scout list
```

## Performance

The picker is optimized for roots with up to 1024 projects. Scout stores project
names in one contiguous buffer, keeps their offsets in a separate array, and
constructs an absolute path only after selection. The matcher allocates its
working buffers once and reuses them while the query changes.

If a root contains more than 1024 projects, the picker uses the first 1024
returned by directory enumeration. `scout list` still prints every discovered
project.

## License

[MIT](LICENSE).
