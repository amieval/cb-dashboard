# Federated Planning Dashboard

**Status:** planned
**Repos:** cb-dashboard, composable-beliefs
**Effort:** medium

> **Update (2026-06):** `planning-data` has since been **emptied** — its plans
> were homed into `composable-beliefs/plans/` and `cb-dashboard/plans/`. The
> registry below should point at *those* repos (and a future planning-app), not
> `planning-data`. The cross-repo case this plan solves is now the live
> situation, not a hypothetical.

Make the dashboard's plans surface **multi-repo**: plans live in the repo they
relate to, in an agreed header format, and a single planning app discovers and
aggregates them across a configured set of repos. A selector filters by source
repo; a plan can declare relevance to more than one repo via a `Repos:` tag.
The belief-DAG view stays a **separate surface** — viewing plans and viewing the
DAG are different activities and should not be fused.

> This plan dogfoods its own format: the header above carries the proposed
> `**Repos:**` field.

## Why

The repos split (`cb-dashboard`, `composable-beliefs`, `planning-data`,
`belief-collections`, `evals`, …) but planning didn't. Today every plan lives in
one place and the dashboard reads a single `data_root/ops/plans` dir. As work
spreads across repos, two things are wanted:

1. **Plans belong to a repo.** A plan about `cb-dashboard` should be findable as
   *that repo's* plan, not buried in a global pile.
2. **The tool is not the data.** The dashboard is an internal tool; it should not
   be committed into each subject repo. One app, pointed at many repos.

These reconcile as a **master planning dashboard with a repo selector** — exactly
the shape the dashboard already supports in spirit (config-pointed-at-data, via
`CBDashboard.Paths`), just generalized from one root to many.

## Federated, not centralized

Two architectures were weighed:

| | **Federated** (this plan) | Centralized (`planning-data` only, repo = tag) |
|---|---|---|
| Plan home | each repo's `plans/` dir | one repo |
| Travels with code | ✅ diffable in the same PR | ❌ separate repo/commit |
| Cross-repo plan | lives in one repo, **tagged** into others via `Repos:` | natural (multi-tag) |
| Dashboard reads | N repo dirs (a registry) | one dir, filter by tag |
| Freshness | only as fresh as local checkouts | single source |

Federated is chosen because plans should be diffable alongside the code they
describe, and the dashboard is already a config-pointed-at-data tool. The
cross-repo case is handled by metadata (`Repos:`), not by physical location:
**home is physical, relevance is tags.**

Accepted cost: the dashboard reads N working copies **on disk**, so plans are
only as fresh as local checkouts. Fine for a local internal tool; a non-starter
if this is ever hosted/shared (revisit then).

## The format contract

Plans already carry a structured header (SSOT: `ops/plans/CLAUDE.md`), parsed by
`CBDashboard.Sources.Plans` into `%Plans{status, tag, effort, parents, …}`. The
contract is **one new field on that existing header**, not a new front-matter
system:

```
# Plan: <title>

**Status:** pending | in-progress | paused (YYYY-MM-DD) | done (YYYY-MM-DD)
            | superseded (YYYY-MM-DD) | deprecated (YYYY-MM-DD) | evaluation needed
**Repos:** cb-dashboard, composable-beliefs        # NEW — comma-separated; multi-valued
**Effort:** small | medium | large
```

Notes:
- **`Repos:` is multi-valued** — that is the entire cross-repo story. A plan
  physically in `cb-dashboard/plans/` may list `Repos: cb-dashboard,
  composable-beliefs` and surface under both.
- **Default when omitted:** the plan's *source repo* (the registry name of the
  dir it was found in). So existing plans need no edit to appear correctly under
  their own repo.
- **Reuse the existing parser.** Extending the `**Field:**` header keeps one
  schema and one SSOT doc; avoid introducing a parallel YAML front-matter block.
- **Vocabulary cleanup (related, not blocking):** the current `**Tag:**`
  controlled vocabulary is louder touring residue (`advancing | flights |
  lodging | …`). That is host-domain leak — see [[dashboard-residue-scrub]].
  Resolve it there; this plan only adds `Repos:`.

## The registry — the one piece of config

Replace the single plans root with a list of `(repo-name, plans-dir)` pairs.
Different repos use different layouts (`ops/plans` vs `plans/`), so the path is
explicit per source:

```elixir
config :cb_dashboard, :plan_sources, [
  {"cb-dashboard",       "../cb-dashboard/plans"},
  {"composable-beliefs", "../composable-beliefs/plans"},
  {"planning-data",      "../planning-data/plans"},
]
```

Resolution mirrors the existing `Paths` pattern: config → env
(`CB_DASHBOARD_PLAN_SOURCES`, e.g. `name=path:name=path`) → sensible default.
The selector in the UI = filter the aggregated set by `source` (or by a value in
`Repos:`); an **"all"** view shows everything.

## What changes in the code

Grounded in the current modules:

| Area | Today | Change |
|---|---|---|
| `CBDashboard.Paths` | `plans_dir/0` → `data_root/ops/plans` (single) | add `plan_sources/0` returning `[{name, dir}]`; keep `data_root` for the other sources (positions/runs/proposals) |
| `CBDashboard.Sources.Plans` | walks one dir; `list/0` → buckets | walk every registered dir; add `:source` to the struct; parse `**Repos:**`; default `repos` to `[source]` |
| `%Plans{}` struct | `basename, status, tag, effort, parents, …` | + `:source` (repo name), + `:repos` ([String]) |
| Plans LiveView | mounts, lists buckets, reacts to `:plans_changed` | add a **source/repo selector**; filter buckets by selection; "all" default |
| `CBDashboard.Watcher` | watches one plans dir | watch every registered dir → `:plans_changed` |
| `plan_links.ex` | links between plans | ensure cross-repo links resolve by `(source, basename)`, not basename alone |
| DAG views | own surface (`/dag`) | **unchanged** — kept separate by design; may adopt the same selector later for per-repo `CB_BELIEFS` graphs |

Volumes are low hundreds of files; `Sources.Plans` already reads from disk on
every call (no cache), so fan-out across a handful of repos stays cheap.

## Migration

1. **Add `plan_sources` config** pointing at the sibling repos that have a
   `plans/` dir (initially `planning-data`; add `cb-dashboard/plans` etc. as they
   gain plans).
2. **Move repo-local plans home.** The two dashboard plans currently in
   `planning-data` are *about* `cb-dashboard` →
   [[dashboard-extraction]] and [[dashboard-residue-scrub]] move to
   `cb-dashboard/plans/`. Genuinely cross-cutting design records stay in
   `planning-data` and gain a `Repos:` tag.
3. **Backfill `Repos:`** only where a plan spans repos; single-repo plans rely on
   the source-repo default and need no edit.
4. **Update the schema SSOT** (`ops/plans/CLAUDE.md`, or its successor) to
   document `Repos:`.

## Decisions / open questions

- **One app or two?** Recommendation: **one app, two surfaces** (plans view
  becomes multi-repo; DAG view stays as-is). Splitting into two deployables buys
  nothing for a local tool and doubles the boot/config story. Revisit only if the
  DAG surface grows its own multi-repo needs.
- **Where does the planning app itself live?** It is `cb-dashboard` today. Since
  it is now a cross-repo tool, consider whether it stays in `cb-dashboard` or
  becomes its own sibling repo. Not blocking; deferred.
- **Front-matter vs header field.** This plan picks extending the existing
  `**Field:**` header (one parser, one SSOT). If a richer metadata story emerges
  later, YAML front-matter is the migration target — but not now.
- **Cross-repo plan links.** `plan_links.ex` keys on basename; cross-repo means
  basenames can collide. Decide on `(source, basename)` identity before backfill.

## Phasing

- **Phase 0** — extend the header schema doc with `Repos:`; add `:source`/`:repos`
  to `%Plans{}` with source-default; no behavior change yet (single source still).
- **Phase 1** — `plan_sources/0` registry + multi-dir walk in `Sources.Plans` +
  Watcher fan-out. Dashboard now aggregates across repos.
- **Phase 2** — repo selector in the Plans LiveView (+ "all"); filter by
  `source`/`Repos:`.
- **Phase 3** — migrate plans to their home repos; backfill `Repos:` on
  cross-cutting plans; resolve cross-repo link identity.
