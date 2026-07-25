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

```sh
lune run cli -- --api-key <KEY> [--manifest cloud.yml] [--state cloud-state.yml] [--import]
```

Or set `API_KEY` in a `.env` file (TOML format: `API_KEY = "..."`).

## Formatting

```sh
stylua .
```

StyLua config is in `stylua.toml`: single quotes preferred, no call parentheses for single-arg calls, requires sorted.

## Architecture

### Entry point — `cli.luau`

Reads CLI args/env, constructs a `cloud_api` adapter (translating between the flat internal format and the `ro_cloud` library's API), then spawns concurrent `sync_product` calls for every product in the manifest.

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
