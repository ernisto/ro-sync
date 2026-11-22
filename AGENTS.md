# AGENTS.md

## Overview

`ro-sync` is a Lune CLI (Luau) that syncs Roblox developer products with a YAML manifest via a 3-way merge between local changes, the lock file, and live Roblox Open Cloud state.

## Toolchain & setup

```sh
pesde install   # deps (ro_cloud); tools: lune, pesde, stylua, luau-lsp (CI uses rokit)
```

`.env` (`KEY=value` lines, quotes optional) supplies the API key; `utils/env.luau` (mirrors lxit) reads it over `process.env`: `env.string/number/bool(name, default?)` error when missing, `env.secret.string` registers values for `env.redact`, `env.save` rewrites a key.

## Verify (mirrors CI: .github/workflows/check.yml)

```sh
stylua --check lib cli utils tests --config-path stylua.toml
luau-lsp analyze --platform standard --base-luaurc .luaurc --ignore **/*_packages/** lib cli utils tests
pesde x ernisto/test --   # runs all *.spec.luau (unit + integration), no network needed
```

- Tests use a tiny homegrown framework: `tests/expect.luau` (assertions), `tests/mock.luau`, `tests/sync_mock.luau` (product/lock/api builders). Alias `@test` → `tests/`.
- Integration specs are still offline: they use a mock `product_api` and round-trip YAML through `tests/integration/assets/` (tmp files are cleaned up by the specs).

## Running

Dispatch is on positionals in `cli/init.luau`; bare invocation (or `--help`) prints help, an unknown command prints an error + help and exits 1. Do **not** use `--` before subcommand args — `utils/cli` treats `--` as "forward everything remaining".

```sh
lune run cli sync cloud.yml --cache cloud-state.yml --push
lune run cli place load lobby --cache dev-state.yml --output lobby.rbxl
lune run cli place play lobby --cache dev-state.yml --data '{"match":10}'   # JSON only
lune run cli place edit lobby --cache dev-state.yml
lune run cli place run  lobby --cache dev-state.yml --script "require(tests)"
```

Global flags (`cli/args.luau`): `--cache` (lock file, default `cloud-state.yml`), `--api-key` (default `$API_KEY`; global since caches extending an Open Cloud data store need it), `--yes/-y` (auto-accept prompts), `--help/-h`. Prefer `API_KEY` in `.env` over `--api-key`.

`sync [FILES...]`: manifests (default `cloud.yml`, extra files merge into the first). Flags: `--push` (cloud is only updated when present), `--pull [FILE]` (fetch cloud before reconciling; FILE gets the cloud version, without it only the cache updates), `--pull-new [FILE]` (import every cloud resource), `--resolve-to cloud|local` (conflict winner), `--dry` (report only: lock, manifest and files untouched). `--push`/`--dry` map to one `sync_mode` (`lib/sync.luau`; none = `receive`) and exclude each other.

`codegen [FILE]` (default `cloud.yml`, skipped if missing): assets are resolved by hashing the manifest's files against the lock (`{ asset_id, universe, owner }` per hash, no paths); files without an uploaded asset are copied into Studio's `content/ro-sync` and emitted as `rbxasset://` uris; places/products/passes are emitted as `{ place_id|product_id|pass_id, data }` (identity never inside `data`, staged ones get ids -1, -2, ...); the lock file is not written.

`state upload` / `state download`: move a `--cache` state to/from an Open Cloud data store entry. `upload --store NAME --key KEY [--scope S] [--universe ID] [--ref [FILE]]` writes the state file's content to the entry (refuses states that already `extends`); `--ref FILE` writes a state `{ version, universe_id, extends: { rbxstore } }` referencing it, bare `--ref` replaces the uploaded state with it. `download [--content [FILE]]` reads the entry the state's `extends.rbxstore` names, overlays the state's own fields (minus `extends`) and prints it; `--content FILE` writes it there, bare `--content` replaces the referencing state.

## Architecture

- `cli/init.luau` — dispatcher; `cli/commands/` holds `sync` and `place load|play|edit|run`. `place_ref.luau` resolves a `<name>` positional to `{ place_id, universe_id }` from the `--cache` lock file. `play`/`edit` open Roblox deep links; `run` executes a script via `luau_task_exec` and streams logs.
- `lib/state/` — types + YAML I/O split into `parser`, `encoder`, `diff`; `cli/state_fs.luau` loads/saves manifest + lock together. **Manifest** (`cloud.yml`) is user-edited; **lock file** (`cloud-state.yml`) is auto-generated (`product_id`, `icon_id`, `icon_hash`, last-pushed `input` snapshot — never edit its `input` block by hand).
- `lib/sync.luau` — `sync_product` 3-way merge: diff local vs lock → `sending`; diff cloud vs lock → `receiving`; fields changed on both sides are recorded as `input.conflicts` and persisted back into the manifest; then push/pull non-conflicting changes. `icon_hash` (SHA-256) avoids re-uploading identical icons.
- One resource per API: `place`/`universe` sync only Open Cloud fields; develop-API settings sit under a `configuration:` sub-table backed by `place_configuration`/`universe_configuration` (own lock nested as `configuration` in the parent lock, reconciled after the parent). Fields are declared as `base.field_map` (`manifest_field = { apiField, lua_type, nested_map? }`) driving validation, diff and api mapping.
- `lib/api.luau` wraps the Open Cloud calls; `luau_packages/` is pesde-managed (`@pkg` alias) — don't hand-edit.

## Conventions

- Path aliases (`.luaurc`): `@pkg`, `@utils`, `@lib`, `@cli`, `@test`, `@lune`. Strict language mode — `luau-lsp analyze` must pass.
- StyLua (`stylua.toml`): single quotes, no call parens for single-arg calls, sorted requires.
- Releases read git tags (`scripts/bump_version.luau` syncs the version in `pesde.toml` before `pesde publish`). The release workflow also bundles `cli/init.luau` with darklua (`.darklua.json`) and `lune build`s it into `ro-sync-<tag>-<os>-<arch>.zip` assets for aftman/rokit. There is no README.md in the repo.
