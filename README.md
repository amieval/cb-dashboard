# cb_dashboard (staging)

Standalone Phoenix LiveView dashboard for Composable Beliefs, extracted from the
host `louder` app's observability surface (the "SOD") and decoupled onto the
`cb:` framework. Staged here on branch `claude/funny-cerf-wJD7w` ahead of the
Stage-5 repo cut (CB-RESTRUCTURE-HANDOFF.md §5.5).

## Status: full observability surface ported + verified

The complete extraction. Every louder SOD view runs standalone here, decoupled
onto `cb:` with a configurable data root. Booted on `127.0.0.1:4001`, all routes
serve real data and every Elixir source compiles `--warnings-as-errors` clean.
An adversarial per-file audit (each ported file diffed against its louder
original) returned 21/21 clean, no regressions.

**Routes** (`CBDashboard.Router`): `/` landing · `/plans` + `/plans/:basename` ·
`/position` + `/position/:basename` · `/runs` · `/dag` + `/dag/:id` ·
`/dag/proposals` + `/dag/proposals/:slug` · `/policy` ·
`/transcripts/:session_id`. Plus 5 raw-file static mounts
(`/plans/files`, `/position/files`, `/runs/files`, `/dag/proposals/files`,
`/transcripts/files`) whose `from:` resolves at runtime via `CBDashboard.Paths`
MFA tuples.

**Belief layer** is the framework's own (`CB.Belief.{Store,Graph,Mutation}` +
`CB.JSON`) - verified 1:1 API parity with the host's. **Live updates** come from
`CBDashboard.Watcher` (5 topics: plans/positions/runs/assertions/proposals);
the host's touring-data `:org` source and legacy SSE back-compat were dropped.

**Write path** (`/dag/proposals/:slug` apply: mutates the graph + git-commits) is
the only mutating route and is **gated off by default** - set
`config :cb_dashboard, :enable_mutations, true` to enable it.

## Running

```sh
mix deps.get          # phoenix/bandit/esbuild/... (needs hex access)
cd assets && npm install && cd ..   # d3, for the graph hook
mix assets.build      # bundle assets/js/app.js -> priv/static/assets
CB_DASHBOARD_DATA_ROOT=/path/to/dev-data mix phx.server   # http://127.0.0.1:4001
```

> **macOS hex note**: if `mix deps.get` dies reading
> `/etc/ssl/certs/ca-certificates.crt` (a Linux path), your env has a stale
> `HEX_CACERTS_PATH`. Override with the macOS bundle:
> `HEX_CACERTS_PATH=/etc/ssl/cert.pem mix deps.get`.

`CB_DASHBOARD_DATA_ROOT` defaults to the cwd; point it at the dev-workflow repo
that holds `ops/plans`, `ops/position`, `org/agents/runs`, `ops/dag-proposals`.

## Configurable data dir

Everything resolves at runtime (no compile-time `Louder.repo_root()` joins):

| Surface | Config / env | Default |
|---|---|---|
| belief graph | `config :cb, :beliefs_path` / `CB_BELIEFS` | cb: framework's own graph |
| data root (`ops/*`, `org/*`) | `config :cb_dashboard, :data_root` / `CB_DASHBOARD_DATA_ROOT` | cwd |
| transcripts dir | `config :cb_dashboard, :transcripts_root` / `CB_DASHBOARD_TRANSCRIPTS_ROOT` | derived from `data_root` (Claude's `~/.claude/projects/<encoded>`) |
| HTTP port | `CB_DASHBOARD_PORT` | 4001 |
| write path (proposal apply) | `config :cb_dashboard, :enable_mutations` | `false` (read-only) |

`CBDashboard.Paths` derives `plans_dir`/`positions_dir`/`runs_dir`/`proposals_dir`
from `data_root`; the same helpers feed the source modules, the `Watcher` globs,
and the static mounts so all three always agree on where each kind of file lives.

## Depends on

`{:cb, path: "../composable-beliefs"}` for the belief layer; otherwise the
standard Phoenix stack (bandit, phoenix, phoenix_live_view, phoenix_html, plug,
esbuild, mdex, jason). No coupling to `louder`.
