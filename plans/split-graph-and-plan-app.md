# Split the Graph Viewer and Planning into Two Apps

**Status:** in progress — Phase 0 done; **start at Phase 1**
**Repos:** cb-dashboard, plan-app (new, its own repo), cb_ui, composable-beliefs
**Effort:** large

> **Update (2026-06):** `planning-data` was emptied — its plans were homed into
> `composable-beliefs/plans/` and `cb-dashboard/plans/`. The plan-app this
> plan proposes aggregates plans from *those* repos, not `planning-data`.

## Execution brief — read this first (for a fresh-context agent)

This section is the self-contained launch pad: everything decided and done so
far, so you can execute without prior conversation history. Then read the rest
of this plan + the two it links: `federated-planning-dashboard.md` (the
plan-app's native federated model) and `multi-graph-belief-viewer.md` (the
viewer work, **already shipped — do not redo**).

**Settled decisions:**
- **plan-app is its own sibling git repo** at `amieval/plan-app` (alongside
  `cb-dashboard`, `cb_ui`, `composable-beliefs`) — *not* a subdir.
- Proposals stay with the graph viewer (they mutate the graph); transcripts +
  the `Thread` component go to plan-app.
- `cb_ui` is the shared design system, already extracted.

**Phase 0 is DONE** (committed, not pushed):
- **`cb_ui` repo** created (commit `7e9a002`, its own git repo, **no remote**):
  `CBUI.Components` (the function components) + `CBUI.Theme` (a `tokens/1`
  component rendering the `:root` CSS design tokens + base reset). Has its own
  `mix.exs`, `.formatter.exs`, `.gitignore`.
- **cb-dashboard repointed** (commit `e101597` on `main`): path-deps
  `{:cb_ui, path: "../cb_ui"}`; old `lib/cb_dashboard/components/ui.ex` is
  **deleted**; every call site does `import CBUI.Components`; `layouts.ex`
  renders `<CBUI.Theme.tokens />`.
- **`cb-dashboard/lib/cb_dashboard/layouts.ex` STAYED in cb-dashboard** — it
  holds app chrome (`<html>/<head>`, the `.sod-*` header/nav markup + CSS,
  thread/belief-card/plan styles). Only the theme *tokens* moved to cb_ui. So:
  you edit `layouts.ex` in cb-dashboard (Phase 3), and you author a *fresh*
  layout for plan-app that also renders `<CBUI.Theme.tokens />`.

**Repo conventions (both apps must satisfy):**
- `mix compile --warnings-as-errors` clean, `mix test` green,
  `mix format --check-formatted` clean. The repos use **paren-less** Phoenix DSL
  (`live "..."`, `attr :x, :map`), so each Mix project needs a `.formatter.exs`
  with `import_deps: [:phoenix, :phoenix_live_view]` (note: `:phoenix_live_view`
  alone re-parenthesizes `attr`/`slot` — you need `:phoenix` too).
- plan-app path-deps **both** `{:cb_ui, path: "../cb_ui"}` and
  `{:cb, path: "../composable-beliefs"}`.

**Guardrails:**
- **Phase-gate hard.** After each phase: `mix compile --warnings-as-errors` +
  boot (`mix phx.server`) both apps, then **stop and summarize for review**
  before the next phase. This is large and multi-repo; review between phases.
- Two apps, two ports, two configs. Cross-app links become **absolute deep
  links** via `graph_viewer_url` (plan-app → viewer); belief IDs stay namespaced
  (`cb:a098`).
- **Remotes / push:** cb-dashboard, composable-beliefs, belief-collections have
  `amieval/*` GitHub remotes; **cb_ui and plan-app do not.** Do **NOT push** any
  repo — the user controls pushes and remote creation.
- **Commits:** end each with
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Concurrency:** a separate thread may run the residue scrub on cb-dashboard
  `main` (no branches in play). Before editing shared files (README, provenance
  refs), confirm it has landed or work on a branch — avoid concurrent edits to
  the same files.
- **Plan housekeeping:** when this plan completes, move it into the existing
  convention — `plans/previous/` or `plans/deprecated/` (no `done/` subdir).

**Phase 3 also does the Tier-2 provenance scrub** (Tier 1 is already done; see
`dashboard-residue-scrub.md`). That plan's Tier-2 file list is **stale** (it
predates Phase 0, which deleted `ui.ex`). The **current** `louder`/`SOD`/
`LouderWeb` surface to *neutralize, not delete*:
- **cb-dashboard:** `lib/cb_dashboard/paths.ex`, `error_html.ex`, `layouts.ex`
  (incl. `.sod-header` / `.sod-nav` / `.sod-main` — these are **live CSS class
  names**, so renaming them is real code, not a comment edit),
  `components/thread.ex`, `sources/transcripts.ex`, `live/policy_live.ex`,
  `live/landing_live.ex`, `config/dev.exs`.
- **cb_ui:** `lib/cb_ui/components.ex` (a `SOD` ref carried over from old `ui.ex`).

`cb-dashboard` today bundles two unrelated activities behind one endpoint:
**viewing/mutating a Composable Beliefs graph** (`/dag`, proposals, policy) and
**planning workflow** (`/plans`, `/position`, `/runs`, `/transcripts`). Split
them into two independent internal tools — `cb-dashboard` (the general
CB-graph viewer) and a new `plan-app` — sharing only a thin UI kernel and
the `cb` framework library. Proposals stay with the graph viewer (they *are*
graph mutations); transcripts go with planning (they back the plan/position
views).

> Supersedes the "one app, two surfaces" recommendation in
> [[federated-planning-dashboard]] — but **adopts that plan wholesale as the
> plan-app's native model**. The plan-app *is* the federated planning
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

| | **cb-dashboard** (graph viewer) | **plan-app** (new) |
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
   - *Resolution:* plan-app keeps `{:cb, ...}` and reads the graph directly
     (read-only) for belief context. For proposals it may still **read** the
     manifest files (to show "N proposals reference this plan"), but the review
     and apply UI lives in the viewer — the link becomes a deep link out
     (see #2), not an in-process call into `DagProposalLive`.

2. **Belief-ID and proposal links cross apps.** `UI.linkify_belief_ids` and
   plan/position views link to `/dag/:id` and `/dag/proposals/:slug` — now a
   different app on a different port.
   - *Resolution:* add `config :plan_app, :graph_viewer_url` (default
     `http://127.0.0.1:4001`). plan-app renders absolute deep links into the
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
   plan-app; the viewer drops them.

## Config after the split

Each app owns its own `Paths`/endpoint/router/supervisor:

- **cb-dashboard:** the graph **sources file** (`config :cb_dashboard,
  :sources_file`, already implemented — registries + standalone graphs) + a
  proposals dir. No `data_root` for plans/positions/runs anymore.
- **plan-app:** the federated `plan_sources` registry from
  [[federated-planning-dashboard]] (config → `PLAN_APP_PLAN_SOURCES` env),
  plus `positions_dir` / `runs_dir` / `transcripts_root`, plus
  `graph_viewer_url` for deep links.

Two ports, two `mix phx.server` invocations, two configs — the accepted cost of
two deployables, justified because the activities are genuinely separate and the
viewer is meant to be pointed at *any* CB graph independent of planning data.

## Phasing

- **Phase 0 — shared kernel.** ✅ **Done** (`cb_ui` `7e9a002`, cb-dashboard
  `e101597`). Extracted `cb_ui` (components + theme **tokens**; layouts stayed in
  cb-dashboard) as a path-dep library; repointed cb-dashboard, behavior
  unchanged. See the Execution brief above for exact state.
- **Phase 1 — scaffold plan-app.** New Phoenix app **in its own sibling repo
  `amieval/plan-app`** (`git init`, like `cb_ui` — no remote): endpoint, router,
  application/supervisor, esbuild pipeline, its own `.formatter.exs` +
  `config/test.exs`, depending on `{:cb_ui, path: "../cb_ui"}` and
  `{:cb, path: "../composable-beliefs"}`. Its layout renders
  `<CBUI.Theme.tokens />`. Boots empty on its own port (pick one ≠ 4001, e.g.
  4002). Settle the `graph_viewer_url` config shape here.
- **Phase 2 — move planning surfaces, federated from the start.** Relocate
  `Positions`/`Runs`/`Transcripts` sources, their LiveViews, and `Thread` into
  plan-app on a single `data_root`. Build the **plans** surface directly
  against the federated `plan_sources` registry from
  [[federated-planning-dashboard]] — multi-dir walk, `:source`/`:repos` on the
  `%Plans{}` struct (default `[source]`), Watcher fan-out across registered
  dirs, repo selector in `PlansLive`. The plan-app's plans surface is
  multi-repo on day one; there is no single-root interim. Convert belief-ID and
  proposal references to deep links via `graph_viewer_url`.
- **Phase 3 — strip the viewer.** Remove planning routes, LiveViews, sources,
  `Thread`, and the now-dead `data_root`/`ops/plans` plumbing from cb-dashboard;
  trim its landing and Watcher to `assertions` + `proposals`. Update its README
  to "graph viewer only." **While rewriting these files, fold in Tier 2 of
  [[dashboard-residue-scrub]] — neutralize the remaining `louder`/`SOD`/`LouderWeb`
  provenance refs; this is the deferred-to-re-cut moment that plan names.**
- **Phase 4 — migrate plans to their home repos.** Now that the plan-app
  aggregates across a registry, move plans physically into the repo each is
  *about* (`cb-dashboard/plans/`, `composable-beliefs/plans/`, …), backfill
  `**Repos:**` only on cross-cutting plans, and resolve cross-repo link identity
  (`(source, basename)`, not basename alone) per [[federated-planning-dashboard]]
  §Migration. This is data movement, not code — the durable end state where every
  plan lives beside the code it describes.

## Open questions

- **Where does plan-app live?** ✅ **Resolved:** its own sibling repo
  `amieval/plan-app` (alongside `cb-dashboard`/`cb_ui`), per "the tool is not the
  data."
- **`cb_ui` granularity.** ✅ **Resolved (Phase 0):** components + theme tokens
  only; app chrome/layouts stayed in cb-dashboard. Promote more only if
  duplication bites.
- **Proposal `source_plan` back-reference.** Proposals point at a plan basename;
  cross-app this is a link from the viewer *into* plan-app. Decide whether
  the viewer also needs a `plan_app_url` for that reverse link, or whether
  the reference stays one-directional (planning → viewer only).
- **Shared `cb` version skew.** Both apps path-dep `composable-beliefs`. Fine
  while co-located; revisit if either is ever released independently.
