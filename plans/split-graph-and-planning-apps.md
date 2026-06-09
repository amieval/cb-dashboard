# Split the Graph Viewer and Planning into Two Apps

**Status:** planned
**Repos:** cb-dashboard, planning-app (new), composable-beliefs
**Effort:** large

> **Update (2026-06):** `planning-data` was emptied — its plans were homed into
> `composable-beliefs/plans/` and `cb-dashboard/plans/`. The planning-app this
> plan proposes aggregates plans from *those* repos, not `planning-data`.

> **Current state of cb-dashboard (ground truth for a cold start).** The
> multi-graph viewer work (Phases 0–3 of [[multi-graph-belief-viewer]]) is
> shipped. So the *graph-viewer* half is already mature: `Sources.Graphs`
> (user-owned sources file — registries + standalone graphs, no hardcoded data
> path), `CBDashboard.ProposalApply` (collection-aware apply, extracted from the
> LiveView), namespaced `/c/:namespace/dag` routes, and a test harness
> (`config/test.exs`, `test/`, `.formatter.exs`). This plan's job is to carve the
> **planning** half out from under it. Nothing in the planning surfaces changed.

`cb-dashboard` today bundles two unrelated activities behind one endpoint:
**viewing/mutating a Composable Beliefs graph** (`/dag`, proposals, policy) and
**planning workflow** (`/plans`, `/position`, `/runs`, `/transcripts`). Split
them into two independent internal tools — `cb-dashboard` (the general
CB-graph viewer) and a new `planning-app` — sharing only a thin UI kernel and
the `cb` framework library. Proposals stay with the graph viewer (they *are*
graph mutations); transcripts go with planning (they back the plan/position
views).

> Supersedes the "one app, two surfaces" recommendation in
> [[federated-planning-dashboard]] — but **adopts that plan wholesale as the
> planning-app's native model**. The planning-app *is* the federated planning
> dashboard: from inception it reads plans from many repos (config → registry →
> aggregate), per the `**Repos:**` header format that plan specifies. It is not
> a single-root tool that later grows federation; federation is why it exists.
> cb-dashboard, for its part, keeps a parallel roadmap in its **own** repo
> ([[multi-graph-belief-viewer]]) to grow from one belief collection to many.

## Why

The `ops/*` data root is louder touring residue. Pointed at any of the actual
`cb:` repos (`composable-beliefs`, `belief-collections`), the planning tabs
render empty because nothing there uses `ops/plans` / `org/agents/runs`. The two
halves have **no shared domain**: one is about a belief graph, the other about
work items. They share a design system and a framework dependency, nothing more.
Fusing them means every planning change boots the graph machinery and vice
versa, and the "general CB-graph viewer" goal is muddied by workflow surfaces
that don't generalize.

## What moves where

Grounded in the current modules (`lib/cb_dashboard/`):

| | **cb-dashboard** (graph viewer) | **planning-app** (new) |
|---|---|---|
| Routes | `/`, `/dag`, `/dag/:id`, `/dag/proposals`(+`/:slug`), `/policy` | `/`, `/plans`(+`/:basename`), `/position`(+`/:basename`), `/runs`, `/transcripts/:session_id` |
| LiveViews | `DagLive`, `DagProposalsLive`, `DagProposalLive`, `PolicyLive`, graph `LandingLive` | `PlansLive`, `PlanLive`, `PositionsLive`, `PositionLive`, `RunsLive`, `TranscriptLive`, planning `LandingLive` |
| Sources / modules | `Proposals`, `Graphs`, `ProposalApply` | `Plans`, `Positions`, `Runs`, `Transcripts` |
| Components | `BeliefContext` | `Thread` |
| Assets | `assertion_graph.js`, belief-card popup JS | — (markdown only) |
| Watcher topics | `assertions`, `proposals` | `plans`, `positions`, `runs` |
| Framework use | `CB.Belief.{Store,Graph,Mutation}`, `CB.JSON` | `CB.Belief.{Store,Graph}` (read-only), `CB.JSON` |

## Coupling to cut

Four cross-references currently bind the halves; each needs an explicit seam:

1. **`PlanLive` reads the belief graph and proposals.** It aliases
   `CB.Belief.Store` and `Sources.Proposals` (a plan shows belief context and
   the proposals spawned from it via the proposal `source_plan` field).
   - *Resolution:* planning-app keeps `{:cb, ...}` and reads the graph directly
     (read-only) for belief context. For proposals it may still **read** the
     manifest files (to show "N proposals reference this plan"), but the review
     and apply UI lives in the viewer — the link becomes a deep link out
     (see #2), not an in-process call into `DagProposalLive`.

2. **Belief-ID and proposal links cross apps.** `UI.linkify_belief_ids` and
   plan/position views link to `/dag/:id` and `/dag/proposals/:slug` — now a
   different app on a different port.
   - *Resolution:* add `config :planning_app, :graph_viewer_url` (default
     `http://127.0.0.1:4001`). Planning-app renders absolute deep links into the
     viewer. Belief IDs are namespaced (`cb:a098`, `lib:a001`), so links stay
     unambiguous across collections.

3. **`Components.UI` is the shared design system** (~320 lines of function
   components + the CSS-variable theme + layouts), imported by nearly every
   LiveView in both halves.
   - *Resolution (recommended):* extract it to a small shared library `cb_ui`
     (path dep), so the theme and primitives don't drift between two apps.
     *Lightweight fallback:* copy `UI` + layouts into each app and accept drift —
     acceptable only if `cb_ui` proves over-engineered for two consumers.

4. **`Thread` + `Transcripts`** are used by `PlanLive` and `PositionLive` and by
   the standalone `/transcripts` route — all planning. They move wholesale to
   planning-app; the viewer drops them.

## Config after the split

Each app owns its own `Paths`/endpoint/router/supervisor:

- **cb-dashboard:** the graph **sources file** (`config :cb_dashboard,
  :sources_file`, already implemented — registries + standalone graphs) + a
  proposals dir. No `data_root` for plans/positions/runs anymore.
- **planning-app:** the federated `plan_sources` registry from
  [[federated-planning-dashboard]] (config → `PLANNING_APP_PLAN_SOURCES` env),
  plus `positions_dir` / `runs_dir` / `transcripts_root`, plus
  `graph_viewer_url` for deep links.

Two ports, two `mix phx.server` invocations, two configs — the accepted cost of
two deployables, justified because the activities are genuinely separate and the
viewer is meant to be pointed at *any* CB graph independent of planning data.

## Phasing

- **Phase 0 — shared kernel.** Extract `cb_ui` (UI components, theme, layouts)
  as a path-dep library; repoint cb-dashboard at it with no behavior change.
  Decide cross-app deep-link config shape.
- **Phase 1 — scaffold planning-app.** New Phoenix app (endpoint, router,
  application/supervisor, esbuild pipeline), depending on `cb_ui` and `cb`.
  Boots empty on its own port.
- **Phase 2 — move planning surfaces, federated from the start.** Relocate
  `Positions`/`Runs`/`Transcripts` sources, their LiveViews, and `Thread` into
  planning-app on a single `data_root`. Build the **plans** surface directly
  against the federated `plan_sources` registry from
  [[federated-planning-dashboard]] — multi-dir walk, `:source`/`:repos` on the
  `%Plans{}` struct (default `[source]`), Watcher fan-out across registered
  dirs, repo selector in `PlansLive`. The planning-app's plans surface is
  multi-repo on day one; there is no single-root interim. Convert belief-ID and
  proposal references to deep links via `graph_viewer_url`.
- **Phase 3 — strip the viewer.** Remove planning routes, LiveViews, sources,
  `Thread`, and the now-dead `data_root`/`ops/plans` plumbing from cb-dashboard;
  trim its landing and Watcher to `assertions` + `proposals`. Update its README
  to "graph viewer only."
- **Phase 4 — migrate plans to their home repos.** Now that the planning-app
  aggregates across a registry, move plans physically into the repo each is
  *about* (`cb-dashboard/plans/`, `composable-beliefs/plans/`, …), backfill
  `**Repos:**` only on cross-cutting plans, and resolve cross-repo link identity
  (`(source, basename)`, not basename alone) per [[federated-planning-dashboard]]
  §Migration. This is data movement, not code — the durable end state where every
  plan lives beside the code it describes.

## Open questions

- **Where does planning-app live?** Its own sibling repo (`planning-app/`)
  alongside `cb-dashboard`, per the established "the tool is not the data"
  principle. Confirm before scaffolding.
- **`cb_ui` granularity.** Just primitives + theme, or also shared endpoint/
  layout boilerplate? Start minimal (components + theme); promote more only if
  duplication bites.
- **Proposal `source_plan` back-reference.** Proposals point at a plan basename;
  cross-app this is a link from the viewer *into* planning-app. Decide whether
  the viewer also needs a `planning_app_url` for that reverse link, or whether
  the reference stays one-directional (planning → viewer only).
- **Shared `cb` version skew.** Both apps path-dep `composable-beliefs`. Fine
  while co-located; revisit if either is ever released independently.
