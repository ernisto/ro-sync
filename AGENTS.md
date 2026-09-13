# AGENTS.md

## Overview

`ro-sync` is a Lune CLI (Luau) that syncs Roblox developer products with a YAML manifest via a 3-way merge between local changes, the lock file, and live Roblox Open Cloud state.

## Toolchain & setup

```sh
pesde install   # deps (ro_cloud); tools: lune, pesde, stylua, luau-lsp (CI uses rokit)
```

`.env` (TOML: `API_KEY = "..."`) supplies the API key; `utils/env.luau` falls back to `process.env`.

## Verify (mirrors CI: .github/workflows/check.yml)

```sh
stylua --check lib cli utils tests --config-path stylua.toml
luau-lsp analyze --platform standard --base-luaurc .luaurc --ignore **/*_packages/** lib cli utils tests
pesde x ernisto/test --   # runs all *.spec.luau (unit + integration), no network needed
```

- Tests use a tiny homegrown framework: `tests/expect.luau` (assertions), `tests/mock.luau`, `tests/sync_mock.luau` (product/lock/api builders). Alias `@test` → `tests/`.
- Integration specs are still offline: they use a mock `product_api` and round-trip YAML through `tests/integration/assets/` (tmp files are cleaned up by the specs).

## Running

Dispatch is on positionals in `cli/init.luau`; bare invocation defaults to `sync`. Do **not** use `--` before subcommand args — `utils/cli` treats `--` as "forward everything remaining".

```sh
lune run cli sync --cache cloud-state.yml --push cloud.yml
lune run cli place load lobby --cache dev-state.yml --output lobby.rbxl
lune run cli place play lobby --cache dev-state.yml --data '{"match":10}'   # JSON only
lune run cli place edit lobby --cache dev-state.yml
lune run cli place run  lobby --cache dev-state.yml --script "require(tests)"
```

Global flags (`cli/args.luau`): `--cache` (lock file, default `cloud-state.yml`), `--push` (manifest), `--remote-cache`, `--yes/-y` (auto-accept prompts), `--help/-h`. Set `API_KEY` in `.env` instead of `--api-key`.

## Architecture

- `cli/init.luau` — dispatcher; `cli/commands/` holds `sync` and `place load|play|edit|run`. `place_ref.luau` resolves a `<name>` positional to `{ place_id, universe_id }` from the `--cache` lock file. `play`/`edit` open Roblox deep links; `run` executes a script via `luau_task_exec` and streams logs.
- `lib/state/` — types + YAML I/O split into `parser`, `encoder`, `diff`; `cli/state_fs.luau` loads/saves manifest + lock together. **Manifest** (`cloud.yml`) is user-edited; **lock file** (`cloud-state.yml`) is auto-generated (`product_id`, `icon_id`, `icon_hash`, last-pushed `input` snapshot — never edit its `input` block by hand).
- `lib/sync.luau` — `sync_product` 3-way merge: diff local vs lock → `sending`; diff cloud vs lock → `receiving`; fields changed on both sides are recorded as `input.conflicts` and persisted back into the manifest; then push/pull non-conflicting changes. `icon_hash` (SHA-256) avoids re-uploading identical icons.
- `lib/api.luau` wraps the Open Cloud calls; `lune_packages/` is pesde-managed (`@pkg` alias) — don't hand-edit.

## Conventions

- Path aliases (`.luaurc`): `@pkg`, `@utils`, `@lib`, `@cli`, `@test`, `@lune`. Strict language mode — `luau-lsp analyze` must pass.
- StyLua (`stylua.toml`): single quotes, no call parens for single-arg calls, sorted requires.
- Releases read git tags (`scripts/bump_version.luau` syncs the version in `pesde.toml` before `pesde publish`). There is no README.md in the repo.
