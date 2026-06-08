# Multi-Graph Belief Viewer

**Status:** planned
**Repos:** cb-dashboard, belief-collections, composable-beliefs
**Effort:** medium

Generalize the viewer's `/dag` surface from **one** belief graph to **many**.
Today `DagLive` reads a single `beliefs.json` via `CB.Config.beliefs_path()`. The
world it should serve is a set of namespaced collections (`cb:`, `lib:`,
`agent-behavior:`, `paradigm:`, `sdl:`), each its own `beliefs.json`, some
depending on others. The viewer should discover them, let you pick one, load its
dependency closure, and render the union — with a selector to switch between
collections.

> This plan lives in `cb-dashboard/plans/` because it is cb-dashboard's own
> roadmap (home is physical, per [[federated-planning-dashboard]]). It concerns
> only the viewer half left behind by [[split-graph-and-planning-apps]]; the
> planning surfaces are out of scope here.

## Why

The viewer is meant to inspect *any* Composable Beliefs graph, but it's wired to
exactly one file. The actual data is already multi-collection: `belief-collections/`
holds four collections plus the framework's own `cb:` graph, related to it
through `collections.json` (namespace → `beliefs.json`) and per-collection
`manifest.json` (`namespace`, `depends_on`, `description`). A collection is **not
standalone** — e.g. `agent-behavior:` beliefs reference `cb:` and `paradigm:`
beliefs — so "view a collection" means "load it plus its transitive dependency
closure as one union."

## The mechanism already exists — reuse it

`composable-beliefs` already resolves and loads collection unions for
verification: `mix cb.verify.collection <ns>` reads `collections.json`, walks the
target's transitive cycle-safe `depends_on` closure (`resolve_closure/3`,
target-first), loads each collection's `beliefs.json` (`load_collection/2`), and
flat-maps them into one union over which the schema checks run. Belief IDs are
namespaced (`cb:a110`, `lib:a001`), so the union is unambiguous and
cross-namespace deps resolve cleanly.

**Do not reimplement this in the viewer.** The right move is to lift the resolver
out of the mix task into a public framework API — e.g. `CB.Collection.registry/1`,
`CB.Collection.closure/2`, `CB.Collection.load_union/2` — that both
`cb.verify.collection` and the viewer call. The viewer then never parses
`collections.json` or `depends_on` itself; it asks the framework for a namespace's
union and renders it.

## Design

1. **Registry config.** `config :cb_dashboard, :collections_registry` pointing at
   `collections.json` (config → `CB_COLLECTIONS` env → default
   `../belief-collections/collections.json`), mirroring the existing `Paths`
   resolution pattern. `collections.json` is explicitly a staging-era resolution
   map; the durable contract is each `manifest.json`'s `depends_on`, so keep the
   framework API the seam and treat the registry file as swappable.

2. **Discovery.** A new `CBDashboard.Sources.Collections` (thin wrapper over the
   framework API) lists available namespaces with their `description` and
   `depends_on`, for the selector.

3. **Selection + closure load.** Selecting namespace `N` loads
   `CB.Collection.load_union(N)` — `N` plus its dependency closure — instead of
   `Store.read()` of a single file. An **"all"** option unions every registered
   collection (the global graph).

4. **Rendering.** `DagLive` builds `Graph.index/1` over the union, as now.
   Beliefs from *dependency* namespaces are context, not the focus: render them
   visually distinct (dimmed / "from `cb:`" tag), reusing the muted treatment the
   proposal view already uses for `context`-type entries. The active namespace's
   own beliefs are primary.

5. **Routing.** Carry the namespace in the route so a view is shareable and
   `/dag/:id` resolves within the right union. Options: `/dag?c=lib` (query,
   smallest change) or `/c/:namespace/dag` + `/c/:namespace/dag/:id` (cleaner,
   bigger router change). Belief-ID links already exist; they now resolve against
   the loaded union, and namespaced IDs make cross-collection links work without
   ambiguity.

6. **Proposals become collection-aware.** A proposal manifest must declare which
   collection it mutates (a `namespace` / `target_collection` field). The apply
   pipeline (`DagProposalLive.do_apply_approved/1`) currently reads/writes one
   `Store` and git-commits one `assertions.json`; generalize it to read/write
   that collection's `beliefs.json` and commit in the owning repo.

7. **Watcher fan-out.** `Watcher` currently fingerprints one `assertions` path.
   Watch every registered collection's `beliefs.json` so any collection's edits
   live-update the viewer (one topic, or per-namespace topics if selectivity
   matters).

## What changes in the code

| Area | Today | Change |
|---|---|---|
| framework (`composable-beliefs`) | closure/union logic buried in `cb.verify.collection` | extract to public `CB.Collection.*`; mix task calls it |
| `CBDashboard.Paths` / config | `beliefs_path` (single) | + `collections_registry` resolution |
| `Sources.Collections` (new) | — | list namespaces + metadata; load a namespace's union via `CB.Collection` |
| `DagLive` | `Store.read()` → one graph | load selected namespace's union; add collection selector; namespace in assigns/route |
| `BeliefContext` / graph render | one flat graph | mark dependency-namespace beliefs as context vs primary |
| `DagProposalLive` apply | one `Store` + one commit | target the proposal's declared collection; write its `beliefs.json`; commit in its repo |
| `Watcher` | one `assertions` fingerprint | fan out across all collection `beliefs.json` |

Volumes are small (a handful of collections, low-thousands of beliefs); the
sources already read from disk per call, so union loading per request stays
cheap.

## Phasing

- **Phase 0 — framework API.** Extract `CB.Collection.{registry,closure,load_union}`
  from the mix task; repoint `cb.verify.collection` at it. No viewer change yet.
- **Phase 1 — registry + selector.** `collections_registry` config +
  `Sources.Collections`; collection selector in `DagLive` loading the selected
  union; Watcher fan-out. Default still resolves to one collection if no registry
  is configured (back-compat).
- **Phase 2 — namespaced routing + context rendering.** Namespace in the route;
  cross-namespace belief links; dependency beliefs rendered as context. Add the
  "all"/global union view.
- **Phase 3 — collection-aware proposals.** Manifest declares target collection;
  apply writes the right `beliefs.json` and commits in the owning repo.
- **Phase 4 — durable resolution.** When the collections split into separate
  repos, swap the `collections.json` registry for `manifest.json`-driven
  resolution behind the same `CB.Collection` API — no viewer change.

## Open questions

- **Registry vs manifest as SSOT.** `collections.json` says it's temporary and
  `depends_on` is durable. Keep the framework API the seam so the viewer is
  indifferent to which backs it. Confirm the API shape with the framework owner.
- **Route style.** Query param (`?c=`) for minimal change vs path segment
  (`/c/:ns/...`) for clean shareable URLs. Lean path segment if multi-graph is
  the long-term default.
- **"All" view scale + cycles.** Unioning every collection is fine at current
  size; the resolver is already cycle-safe. Revisit only if the global union
  grows large enough to need lazy/streamed loading.
- **Proposal target for cross-namespace mutations.** A proposal that touches
  beliefs in more than one collection — disallow (one collection per manifest) or
  support multi-target apply? Start single-target.
