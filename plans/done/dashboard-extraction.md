# Dashboard Extraction — Blueprint for the Local Agent

Extract the SOD observability dashboard from the frozen `louder` app into the
standalone `cb_dashboard` (at `dashboard-staging/`), decoupled onto the `cb:`
framework with a configurable data dir. The belief-DAG **vertical slice is
already built**; this is the blueprint to boot it and finish the bulk-move.

> Why local: this work needs hex access (to boot Phoenix), the real dev-workflow
> data the dashboard displays (`ops/plans`, `ops/position`, `org/agents/runs`,
> `ops/dag-proposals`, `~/.claude` transcripts), and a live compiler/REPL. The
> remote web sandbox has none of those — it produced the slice as syntax-verified,
> parity-verified code but never compiled or booted it.

## 0. First step — boot the slice, validate the stack

Before porting anything else, prove the architecture end-to-end:

```sh
cd dashboard-staging
mix deps.get
(cd assets && npm install)        # d3
mix assets.build                  # bundle js/app.js -> priv/static/assets
mix phx.server                    # http://127.0.0.1:4001
```

Expect `/dag` to render the cb: graph (the framework's own ~107-belief
self-describing graph, via `CB.Config.beliefs_path`). The ported Elixir
syntax-parses clean and the belief API is 1:1, but it was **never run against a
compiler** — fix any compile/boot issues here first (they validate the whole
pattern cheaply before it's replicated across 10 more views). To point at a
richer graph, set `CB_BELIEFS=/path/to/graph.json`.

## 1. What is already done (the slice)

`dashboard-staging/` — standalone Phoenix app, `app: :cb_dashboard`, modules
`CBDashboard.*`, dep `{:cb, path: "../composable-beliefs-public"}`. No `louder`
coupling.

| Built | File |
|---|---|
| Mix project, config (esbuild, endpoint :4001), dev config | `mix.exs`, `config/{config,dev}.exs` |
| Supervision (own PubSub + endpoint) | `lib/cb_dashboard/application.ex` |
| Endpoint (trimmed: `/assets` + `/live` + router only) | `lib/cb_dashboard/endpoint.ex` |
| Router (`/`, `/dag`, `/dag/:id`) | `lib/cb_dashboard/router.ex` |
| Own error view (replaces borrowed `LouderWeb.ErrorHTML`) | `lib/cb_dashboard/error_html.ex` |
| Configurable data-root surface | `lib/cb_dashboard/paths.ex` |
| Root layout (rebranded, nav trimmed to Beliefs) | `lib/cb_dashboard/layouts.ex` |
| Belief-DAG view + components | `live/dag_live.ex`, `components/{belief_context,ui}.ex` |
| D3 hook + socket wiring (dead `confidence` code removed) | `assets/js/{assertion_graph,app}.js`, `assets/package.json` |

## 2. Coupling map (the blueprint)

### 2.1 Belief layer — FULL 1:1 parity (no work)
`CB.Belief.{Store,Graph,Mutation}` satisfies every call the dashboard makes;
`%CB.Belief{}` struct fields are **byte-identical** to `Louder.Belief`; and
`Louder.JSON` has an API-identical `CB.JSON` twin. The only delta is the read
source: `CB.Belief.Store` reads `CB.Config.beliefs_path()` (configurable:
`config :cb, :beliefs_path` / `CB_BELIEFS` / default), vs louder's hardcoded
`org/assertions/assertions.json`. Functions used: `Store.read/0`, `Store.write/1`,
`Graph.{index,stats,resolve_deps}/_`, `Graph.dependents/2`,
`Mutation.{apply_batch/3,summary/1}`, `Belief.contract?/1`.

### 2.2 Remaining files to port (from `lib/louder/observability/`)

| File (lines) | Role | Notes for port |
|---|---|---|
| `live/landing_live.ex` (45) | landing placeholder | trivial |
| `live/plans_live.ex` (235) | plans board (buckets) | reads `sources/plans` |
| `live/plan_live.ex` (790) | single plan, 3 tabs (Plan/Thread/DAG) | uses `thread.ex`, `plan_links.ex`, MDEx; `Store.read` for DAG tab |
| `live/positions_live.ex` (147) | positions board | reads `sources/positions` |
| `live/position_live.ex` (322) | single position, 2 tabs | uses `thread.ex`, `plan_links.ex` |
| `live/runs_live.ex` (149) | agent-runs board by day | reads `sources/runs` |
| `live/transcript_live.ex` (149) | single transcript (JSONL) | reads `sources/transcripts` |
| `live/dag_proposals_live.ex` (112) | proposal manifest list | reads `sources/proposals` |
| `live/dag_proposal_live.ex` (612) | per-proposal review; **applies mutations** | `Store.read/write` + `Mutation.apply_batch` + `git` cmd (see 2.3) |
| `live/policy_live.ex` (49) | placeholder | trivial |
| `components/thread.ex` (240) | Thread-tab infra | used by plan/position views |
| `components/plan_links.ex` (137) | MDEx HTML post-process → links | used by plan/position views |
| `sources/plans.ex` (321) | `ops/plans/*.md` → records | repoint path → `CBDashboard.Paths.plans_dir` |
| `sources/positions.ex` (218) | `ops/position/*.md` | → `Paths.positions_dir` |
| `sources/runs.ex` (137) | `org/agents/runs/*.json` | → `Paths.runs_dir` |
| `sources/proposals.ex` (657) | `ops/dag-proposals/*.json` (read+write); `Louder.JSON` | → `Paths.proposals_dir`; `Louder.JSON` → `CB.JSON` |
| `sources/transcripts.ex` (268) | `~/.claude/.../*.jsonl` | `@projects_root` literal → `Paths.transcripts_root` (see 2.4) |

### 2.3 The Watcher (outside `observability/`, must be ported)
`Louder.Dashboard.Watcher` (`lib/louder/dashboard/watcher.ex`, 207 ln) is the
change-detection poller the LiveViews subscribe to for live updates. Port it as
`CBDashboard.Watcher`, add to the supervision tree, repoint its globs at
`CBDashboard.Paths.*` + the belief graph at `CB.Config.beliefs_path`, broadcast
on `CBDashboard.PubSub`. **Drop** the legacy SSE `:refresh` back-compat (that
served the old `LouderWeb` surface). Topics consumed: `plans:changes`,
`positions:changes`, `runs:changes`, `assertions:changes`, `proposals:changes`.

### 2.4 Data paths → `CBDashboard.Paths` (the bulk of the real work)
Every louder read derives from `Louder.repo_root()` (a Mix build-time call) or a
hardcoded literal. `CBDashboard.Paths` already defines the runtime surface
(`config :cb_dashboard, :data_root` / `CB_DASHBOARD_DATA_ROOT`; `transcripts_root`
/ `CB_DASHBOARD_TRANSCRIPTS_ROOT`). Wire each consumer to it:

| Data | Louder source | Standalone |
|---|---|---|
| belief graph | `Config.assertions_path` (`org/assertions/assertions.json`) | `CB.Config.beliefs_path` (done) |
| plans | `repo_root/ops/plans` (+ bucket subdirs) | `Paths.plans_dir` |
| positions | `repo_root/ops/position` | `Paths.positions_dir` |
| runs | `repo_root/org/agents/runs` | `Paths.runs_dir` |
| proposals | `repo_root/ops/dag-proposals` (read+write) | `Paths.proposals_dir` |
| transcripts | `~/.claude/projects/-Users-mark-.../*.jsonl` **literal** | `Paths.transcripts_root` |
| git revert/commit on proposal apply | `System.cmd("git", …, cd: repo_root)` | `cd: Paths.data_root` |

The endpoint's **5 raw-file `Plug.Static` mounts** (`/plans/files`,
`/position/files`, `/runs/files`, `/dag/proposals/files`, `/transcripts/files`)
were dropped from the slice endpoint — restore them, but resolve `from:` at
**runtime** via `Paths.*` (not the compile-time module attributes louder used;
`Plug.Static` `from:` can take a function or be set in an `init` that reads
config).

## 3. Rename cheat-sheet (mechanical, per ported file)
```
Louder.Observability.Components.BeliefContext -> CBDashboard.Components.BeliefContext
Louder.Observability.Components.UI            -> CBDashboard.Components.UI
Louder.Observability.Components.Thread        -> CBDashboard.Components.Thread
Louder.Observability.Layouts                  -> CBDashboard.Layouts
Louder.Observability.<X>Live                  -> CBDashboard.<X>Live
Louder.Belief                                 -> CB.Belief
Louder.JSON                                   -> CB.JSON
Louder.PubSub                                 -> CBDashboard.PubSub
Louder.repo_root()/Louder.Config paths        -> CBDashboard.Paths.* / CB.Config.beliefs_path
```
(The slice was ported with exactly these via `cp` + `sed`; reuse that approach,
then hand-fix path/config + any `~/.claude` literal.)

## 4. Suggested sequence
1. Boot the slice (§0); fix any compile/boot issues.
2. Port the 5 sources, repointing paths → `CBDashboard.Paths` + `CB.JSON`.
3. Port + wire the Watcher (§2.3); confirm one view live-updates.
4. Port the remaining views + `thread.ex` + `plan_links.ex`; restore full nav in `layouts.ex`.
5. Restore the 5 static mounts (runtime `Paths.*`).
6. Compile + boot + click through every route against real local data.

## 5. Gotchas
- All templates are inline `~H` (no `.heex`) — moves stay simple.
- esbuild bundles `js/app.js` with `NODE_PATH=../deps:../assets/node_modules` —
  `phoenix` + `phoenix_live_view` JS ship inside their hex packages (in `deps/`),
  `d3` from `assets/node_modules` (`npm install`).
- Phoenix 1.8 needs `listeners: [Phoenix.CodeReloader]` (already in `mix.exs`).
- `dag_proposal_live` mutates the graph + runs `git` — gate behind config; it is
  the only write path in the dashboard.

## 6. After the dashboard
The other Stage-5 cuts (`planning-data`, `amieval/evals`, the `belief-collections`
repos, and the refreshed public re-cut/flip of `composable-beliefs`) are tracked
in `CB-RESTRUCTURE-HANDOFF.md` §9.
