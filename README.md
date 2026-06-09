# cb_dashboard

A standalone Phoenix LiveView dashboard for **Composable Beliefs** (`cb:`) — a
graph viewer over the on-disk artifacts a `cb:` workspace produces: the belief
graph itself and the proposed mutations to it.

The dashboard reads these artifacts straight from the filesystem, renders them
as linked, live-updating views, and (behind an explicit opt-in) can apply an
approved batch of graph mutations back to disk. It has no database and no
build-time coupling to any upstream application — point it at a graph and run.

> The planning surfaces (plans, positions, runs, transcripts) live in the
> separate **plan-app**; this app is the graph viewer only.

## What it shows

Composable Beliefs models a body of knowledge as a graph of **assertions**
(`org/assertions/assertions.json`): typed belief nodes with dependencies and
citations. Each gets a view:

| Route | Surface | Backed by |
|---|---|---|
| `/` | Landing — section index | — |
| `/dag` · `/dag/:id` | The belief graph itself — a navigable DAG with a d3 force layout, dependency/citer context per node | `CB.Config.beliefs_path()` |
| `/c/:namespace/dag` · `/c/:namespace/dag/:id` | The same DAG scoped to a single collection (or the `all` union) | the collection's graph |
| `/dag/proposals` · `/dag/proposals/:slug` | DAG proposals: batches of proposed mutations to the graph, reviewable per-mutation | `ops/dag-proposals/*.json` |
| `/policy` | Policy view (deferred — pending upstream DAG policy categorization) | derived |

The proposals view has a raw-file static mount (`/dag/proposals/files`) that
serves the underlying manifests directly, so any rendered view links through to
its exact on-disk source.

## How it fits together

The codebase is small and layered so that each concern lives in one place:

- **`CBDashboard.Paths`** — the single source of truth for *where* data lives.
  The proposals dir (`proposals_dir`) and the graph **sources file**
  (`sources_file`) are resolved at runtime from config → env → default, so the
  same binary can point at any workspace. The belief graph itself is read
  through `CB.Config.beliefs_path/0`. There are no compile-time path literals.

- **`CBDashboard.Sources.{Graphs,Proposals}`** — pure modules that read and
  validate one kind of artifact off disk and return structured records. They
  hold no process state and re-read on every call. Malformed inputs are returned
  *with* their validation errors rather than dropped, so a view can render an
  honest error state instead of silently omitting data.

- **`CBDashboard.Watcher`** — one GenServer that polls each source once a second,
  fingerprints it by file mtime + size, and broadcasts a per-source message on
  `CBDashboard.PubSub` (`assertions:changes`, `proposals:changes`) when it
  changes. Each LiveView subscribes only to the topics it depends on.

- **`CBDashboard.{DagLive,DagProposalsLive,DagProposalLive,PolicyLive,LandingLive}`**
  — the LiveViews. They mount a source, subscribe to its topic(s), and re-load
  on the matching PubSub message. No view talks to the filesystem directly; it
  goes through a source.

- **`CBDashboard.Components.*`** — shared HEEx function components, most notably
  `BeliefContext.belief_card/1`, which renders any belief with its dependency
  and citer context and is reused across the DAG and proposal views, plus the
  `UI` design-system primitives.

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
mix phx.server        # http://127.0.0.1:4001
```

Point the DAG view at a graph via the sources file (below). `CB_DASHBOARD_DATA_ROOT`
backs only the proposals dir (`ops/dag-proposals`) and defaults to the current
working directory, so the proposals view renders empty if you start the server
somewhere without it.

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
| graph sources (the DAG view) | `config :cb_dashboard, :sources_file` / `CB_DASHBOARD_SOURCES` | `config/sources.local.json` (gitignored) |
| proposals data root | `config :cb_dashboard, :data_root` / `CB_DASHBOARD_DATA_ROOT` | cwd |
| HTTP port | `CB_DASHBOARD_PORT` | 4001 |
| write path (proposal apply) | `config :cb_dashboard, :enable_mutations` | `false` (read-only) |

### Graph sources

The DAG view is a general belief-graph viewer — it owns **no path to anyone's
data**. The graphs it loads come from a user-supplied sources file; until you
configure one, no graphs load. Copy the committed example to activate:

```sh
cp config/sources.example.json config/sources.local.json   # then edit the paths
```

```jsonc
// config/sources.local.json  (gitignored)
{
  "registries": [ "/path/to/belief-collections/collections.json" ],  // namespaced collections (depends_on closures)
  "graphs":     [ { "label": "my-project", "path": "/path/to/beliefs.json" } ]  // standalone single graphs
}
```

Paths may be absolute or relative to the sources file. Each registry namespace
and each standalone graph becomes a selectable entry in the DAG view's source
picker (plus an `all` union). Env shortcuts append to the file: `CB_COLLECTIONS`
adds a registry, `CB_BELIEFS` adds one graph.

## Dependencies

The belief layer comes from `{:cb, path: "../composable-beliefs"}`. Everything
else is the standard Phoenix stack — bandit, phoenix, phoenix_live_view,
phoenix_html, plug, esbuild, mdex, jason — plus d3 (via npm) for the DAG graph
hook. There is no coupling to any upstream application.
