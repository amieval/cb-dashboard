# Multi-Graph Belief Viewer

**Status:** done — Phases 0–3 shipped; monorepo kept, no further phases
**Repos:** cb-dashboard, belief-collections, composable-beliefs
**Effort:** medium

Generalize the viewer's `/dag` surface from **one** belief graph to **many**.
The world it serves is a set of namespaced collections (`cb:`, `lib:`,
`agent-behavior:`, `paradigm:`, `sdl:`), each its own `beliefs.json`, some
depending on others — plus standalone graphs a user points at. The viewer
discovers what the user registers, lets you pick one, loads its dependency
closure, and renders the union — with a selector to switch between sources.

> **Implemented design note.** The original plan below assumed a single
> `:collections_registry` defaulting to `../belief-collections`. That was
> revised during Phase 1: a general viewer must own **no path to anyone's
> data**, so resolution now goes through a user-supplied **sources file**
> (registries + standalone graphs) with no baked-in default. The phase log and
> Design §1–2 below reflect the shipped design.

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

1. **Sources, not a baked-in registry** *(shipped form)*. The viewer owns no
   path to anyone's data. Graphs come from a user-supplied **sources file**
   (`config :cb_dashboard, :sources_file` → `CB_DASHBOARD_SOURCES` →
   repo-local `config/sources.local.json`, gitignored) listing **registries**
   (`collections.json` → namespaced collections) and **standalone graphs** (any
   `beliefs.json` at any path). No sources configured → nothing loads, with an
   "add a source" hint; `config/sources.example.json` documents the format; env
   shortcuts `CB_COLLECTIONS`/`CB_BELIEFS` append. The framework `CB.Collection`
   API stays the resolution seam, so `collections.json` stays swappable without
   touching the viewer. (`collections.json` is still a staging-era map; the
   durable contract is each `manifest.json`'s `depends_on`.)

2. **Discovery.** `CBDashboard.Sources.Graphs` reads the sources file and
   produces unified selectable entries: one per registry namespace
   (`kind: :collection`, with `description` via `CB.Collection`) and one per
   standalone graph (`kind: :graph`, label slug). `registry_for/1` maps a
   namespace back to its registry for the apply write path.

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
| `CBDashboard.Paths` / config | `beliefs_path` (single) | `sources_file/0` — user sources file, no default into real data |
| `Sources.Graphs` (new) | — | multi-registry + standalone graphs; unified entries; `all` union; `registry_for/1` |
| `DagLive` | `Store.read()` → one graph | load selected namespace's union; add collection selector; namespace in assigns/route |
| `BeliefContext` / graph render | one flat graph | mark dependency-namespace beliefs as context vs primary |
| `DagProposalLive` apply | one `Store` + one commit | target the proposal's declared collection; write its `beliefs.json`; commit in its repo |
| `Watcher` | one `assertions` fingerprint | fan out across all collection `beliefs.json` |

Volumes are small (a handful of collections, low-thousands of beliefs); the
sources already read from disk per call, so union loading per request stays
cheap.

## Phasing

- **Phase 0 — framework API.** ✅ `dc3118e`. `CB.Collection.{registry,closure,load_union}`
  extracted from the mix task; `cb.verify.collection` delegates, output
  byte-identical across all five collections; unit-tested.
- **Phase 1 — sources + selector.** ✅ `c831736`, `d3d8daf`. Source picker in
  `DagLive`; Watcher fan-out. **Revised from the original spec**: instead of a
  single `:collections_registry` defaulting to one collection, a user-owned
  sources file (registries + standalone graphs) with *no default into anyone's
  data* — the viewer is general, and shows an "add a source" state when nothing
  is configured.
- **Phase 2 — namespaced routing + context rendering.** ✅ `7aed8f0`.
  `/c/:namespace/dag(/:id)` (+ `?c=` back-compat); dependency-namespace beliefs
  rendered as dashed/dimmed context; `all` global-union view.
- **Phase 3 — collection-aware proposals.** ✅ `ee9857f`. Manifest `namespace`;
  apply writes the target collection's `beliefs.json` and commits each touched
  file in its own repo. Pipeline extracted to `CBDashboard.ProposalApply` +
  integration tests.
**Not a planned phase — no lock-in note.** The `belief-collections` monorepo
stays. The viewer is already indifferent to where graphs live (the sources file
abstracts locations behind the `CB.Collection` API), so *if* collections were
ever split into separate repos, it would only mean rehoming `collections.json`
paths to sibling checkouts — no viewer change. There is deliberately no
collection-split plan; it isn't scheduled work.

## Open questions

- **Registry vs manifest as SSOT.** `collections.json` says it's temporary and
  `depends_on` is durable. Keep the framework API the seam so the viewer is
  indifferent to which backs it. Confirm the API shape with the framework owner.
- **Route style.** ✅ Resolved (Phase 2): path segment `/c/:namespace/dag`, with
  `?c=` honored for back-compat.
- **"All" view scale + cycles.** Unioning every collection is fine at current
  size; the resolver is already cycle-safe. Revisit only if the global union
  grows large enough to need lazy/streamed loading.
- **Proposal target for cross-namespace mutations.** A proposal that touches
  beliefs in more than one collection — disallow (one collection per manifest) or
  support multi-target apply? Start single-target.
