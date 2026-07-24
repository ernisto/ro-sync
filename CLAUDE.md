# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`ro-sync` is a Lune CLI tool that syncs Roblox developer products with a YAML manifest. It performs a 3-way merge between local changes, the lock file (last known state), and the live Roblox Open Cloud state.

## Toolchain

All tools are managed via [mise](https://mise.jdx.dev/):

```sh
mise install   # installs lune, pesde, stylua, luau-lsp
```

Install dependencies:

```sh
pesde install
```

## Running

The CLI dispatches on a subcommand (first positional). A bare invocation with no subcommand defaults to `sync`. Do **not** use `--` before subcommand args — utils/cli treats `--` as "forward everything remaining".

```sh
# 3-way sync (default command)
lune run cli sync --cache cloud-state.yml --push cloud.yml
lune run cli --api-key <KEY>            # bare -> sync

# place operations (resolve <name> against the --cache lock file)
lune run cli place load lobby --cache dev-state.yml --output lobby.rbxl
lune run cli place play lobby --cache dev-state.yml --data '{"match":10}'
lune run cli place edit lobby --cache dev-state.yml
lune run cli place run  lobby --cache dev-state.yml --script "require(tests)"
```

`--cache` is the lock/state file, `--push` is the manifest (these replaced the old `--state`/`--manifest` flags). `--data` must be valid JSON. Set `API_KEY` in a `.env` file (TOML: `API_KEY = "..."`) instead of `--api-key`.

## Formatting

```sh
stylua .
```

StyLua config is in `stylua.toml`: single quotes preferred, no call parentheses for single-arg calls, requires sorted.

## Architecture

### Entry point — `cli/init.luau`

A thin dispatcher: reads the first two positionals (`cmd`, `sub`) and `require`s the matching module in `cli/commands/` (`sync`, `load_place`, `play_place`, `edit_place`, `run_place`). Unknown commands error with the available list.

- `cli/commands/sync.luau` — the 3-way sync flow (auth, resource recovery, reconcile). Reads `--cache`/`--push`.
- `cli/commands/place_ref.luau` — shared helper: resolves a `<name>` positional to `{ place_id, universe_id }` from the `--cache` lock file, and reads the api key.
- `load_place` downloads a place `.rbxl`; `play_place`/`edit_place` open Roblox player/studio deep links; `run_place` runs a Luau script via `luau_task_exec` and streams logs.

### `lib/state.luau`

Defines all types and handles YAML I/O:
- **Manifest** (`cloud.yml`): user-edited list of products with desired fields.
- **Lock file** (`cloud-state.yml`): auto-generated; tracks `product_id`, `icon_id`, `icon_hash`, and the last-pushed `input` snapshot per product. Never edit the `input` block inside the lock file manually.

### `lib/sync.luau` — core logic

`sync_product` implements a 3-way merge per product:
1. **Diff local**: compare current `input` against last pushed `input` in the lock → `sending`
2. **Diff cloud**: pull live product state, compare against lock → `receiving`
3. **Conflict detection**: fields changed both locally and remotely are recorded into `input.conflicts` in the manifest (persisted back to `cloud.yml`)
4. **Push** non-conflicting local changes; **pull** non-conflicting cloud changes back into the manifest.

`icon_hash` (SHA-256) is used to detect icon changes without re-uploading identical images.

### `utils/`

| File | Purpose |
|------|---------|
| `cli.luau` | Parses `--key value`, `--key=value`, `-f` flags, and `--` forwarding |
| `env.luau` | Reads from `.env` (TOML) then `process.env` |
| `tbl.luau` | Immutable (`applied`, `subtraction`, `intersection`, `changes`) and mutating (`apply`, `subtract`) table helpers |

### Path aliases (`.luaurc`)

| Alias | Resolves to |
|-------|-------------|
| `@pkg` | `lune_packages/` |
| `@utils` | `utils/` |
| `@lib` | `lib/` |
| `@lune` | Lune built-in type defs |
