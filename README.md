# cb_dashboard

A standalone Phoenix LiveView dashboard for **Composable Beliefs** (`cb:`) — a
read-only observability surface over the on-disk artifacts a `cb:` workspace
produces: the belief graph, the plans and positions that reason about it, agent
run records, proposed graph mutations, and the Claude Code session transcripts
behind them.

The dashboard reads these artifacts straight from the filesystem, renders them
as linked, live-updating views, and (behind an explicit opt-in) can apply an
approved batch of graph mutations back to disk. It has no database and no
build-time coupling to any host application — point it at a data root and run.

## What it shows

Composable Beliefs models a body of knowledge as a graph of **assertions**
(`org/assertions/assertions.json`): typed belief nodes with dependencies and
citations. Around that graph sit the working artifacts a `cb:` workspace
accumulates. Each gets a view:

| Route | Surface | Backed by |
|---|---|---|
| `/` | Landing — section index | — |
| `/plans` · `/plans/:basename` | Plans: status-bucketed work items, each with a body and optional session recap | `ops/plans/*.md` |
| `/position` · `/position/:basename` | Positions: normative stances broken into per-claim assertions with DAG status | `ops/position/*.md` |
| `/runs` | Agent runs: status, timing, steps, and alerts for automated checks | `org/agents/runs/*.json` |
| `/dag` · `/dag/:id` | The belief graph itself — a navigable DAG with a d3 force layout, dependency/citer context per node | `CB.Config.beliefs_path()` |
| `/dag/proposals` · `/dag/proposals/:slug` | DAG proposals: batches of proposed mutations to the graph, reviewable per-mutation | `ops/dag-proposals/*.json` |
| `/policy` | Policy view (deferred — pending upstream DAG policy categorization) | derived |
| `/transcripts/:session_id` | Claude Code session transcripts rendered as a dialog trail | `~/.claude/projects/<encoded>/*.jsonl` |

Each section also has a raw-file static mount (`/plans/files`, `/position/files`,
`/runs/files`, `/dag/proposals/files`, `/transcripts/files`) that serves the
underlying source files directly, so any rendered view links through to its
exact on-disk source.

## How it fits together

The codebase is small (~6.5k LOC) and layered so that each concern lives in one
place:

- **`CBDashboard.Paths`** — the single source of truth for *where* data lives.
  Every directory (`plans_dir`, `positions_dir`, `runs_dir`, `proposals_dir`,
  `transcripts_root`) is resolved at runtime from config → env → default, so the
  same binary can point at any workspace. There are no compile-time path
  literals anywhere else.

- **`CBDashboard.Sources.{Plans,Positions,Runs,Proposals,Transcripts}`** — pure
  modules that read and validate one kind of artifact off disk and return
  structured records. They hold no process state and re-read on every call;
  at these volumes (hundreds of files at most) that keeps the cache-invalidation
  question from ever arising. Malformed inputs are returned *with* their
  validation errors rather than dropped, so a view can render an honest error
  state instead of silently omitting data.

- **`CBDashboard.Watcher`** — one GenServer that polls each source once a second,
  fingerprints it by file mtime + size, and broadcasts a per-source message on
  `CBDashboard.PubSub` (`plans:changes`, `positions:changes`, `runs:changes`,
  `assertions:changes`, `proposals:changes`) when it changes. Each LiveView
  subscribes only to the topics it depends on, so editing a plan on disk
  re-renders the plans views and nothing else.

- **`CBDashboard.Live.*`** — the LiveViews. They mount a source, subscribe to its
  topic(s), and re-load on the matching PubSub message. No view talks to the
  filesystem directly; it goes through a source.

- **`CBDashboard.Components.*`** — shared HEEx function components, most notably
  `BeliefContext.belief_card/1`, which renders any belief with its dependency
  and citer context and is reused across the DAG and proposal views.

The belief layer itself — `CB.Belief.{Store,Graph,Mutation}` and `CB.JSON` —
comes from the `cb` framework, so reading and mutating the graph uses the same
code the rest of the `cb:` toolchain does.

## The write path

The dashboard is read-only by default. Its one mutating operation lives on the
proposal review page (`/dag/proposals/:slug`): **Apply approved** takes the
mutations a reviewer has marked `applied`, runs them through
`CB.Belief.Mutation.apply_batch/3` into `assertions.json`, marks them applied in
the manifest, and git-commits both files together.

This path is gated off unless a host opts in:

```elixir
config :cb_dashboard, :enable_mutations, true
```

Reviewing proposals — approving, rejecting, flagging for discussion, or swapping
in an alternative value for an editable mutation — writes only to the proposal
manifest under `ops/dag-proposals/` and is always available. Manifest edits use
order-preserving JSON writes (so on-disk diffs stay minimal) and an optional
mtime check that returns `:stale` if the file changed underfoot.

## Running

```sh
mix deps.get          # phoenix/bandit/esbuild/mdex/...
cd assets && npm install && cd ..   # d3, for the graph hook
mix assets.build      # bundle assets/js/app.js -> priv/static/assets
CB_DASHBOARD_DATA_ROOT=/path/to/workspace mix phx.server   # http://127.0.0.1:4001
```

`CB_DASHBOARD_DATA_ROOT` should point at the workspace that holds `ops/plans`,
`ops/position`, `org/agents/runs`, and `ops/dag-proposals`. It defaults to the
current working directory, so views render empty if you start the server
somewhere without those directories.

The endpoint binds to `127.0.0.1:4001` only. It ships a dev secret and
`check_origin: false`; it is a local tool and is not meant to be exposed beyond
localhost.

> **macOS hex note**: if `mix deps.get` dies reading
> `/etc/ssl/certs/ca-certificates.crt` (a Linux path), your environment has a
> stale `HEX_CACERTS_PATH`. Override with the macOS bundle:
> `HEX_CACERTS_PATH=/etc/ssl/cert.pem mix deps.get`.

## Configuration

Everything resolves at runtime; nothing is baked in at compile time.

| Surface | Config / env | Default |
|---|---|---|
| belief graph | `config :cb, :beliefs_path` / `CB_BELIEFS` | the `cb:` framework's own graph |
| data root (`ops/*`, `org/*`) | `config :cb_dashboard, :data_root` / `CB_DASHBOARD_DATA_ROOT` | cwd |
| transcripts dir | `config :cb_dashboard, :transcripts_root` / `CB_DASHBOARD_TRANSCRIPTS_ROOT` | derived from `data_root` (Claude's `~/.claude/projects/<encoded>`) |
| HTTP port | `CB_DASHBOARD_PORT` | 4001 |
| write path (proposal apply) | `config :cb_dashboard, :enable_mutations` | `false` (read-only) |

The transcripts directory is derived from the data root by default: Claude Code
stores each project's transcripts under `~/.claude/projects/<encoded>`, where
`<encoded>` is the absolute project path with `/` and `.` replaced by `-`. So
transcripts resolve out of the box for the configured data root with no extra
configuration.

## Dependencies

The belief layer comes from `{:cb, path: "../composable-beliefs"}`. Everything
else is the standard Phoenix stack — bandit, phoenix, phoenix_live_view,
phoenix_html, plug, esbuild, mdex, jason — plus d3 (via npm) for the DAG graph
hook. There is no coupling to any host application.
