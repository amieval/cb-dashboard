# Dashboard Extraction Residue — Scrub

> **Status (2026-06): Tier 1 done.** Three first-party domain leaks neutralized:
> the `README.md` line (already resolved by the standalone-README rewrite), the
> `watcher.ex` moduledoc comment, and the `**Tag:**` example in
> `sources/plans.ex` (was `advancing | flights | lodging` — literal tour-
> management vocabulary, the residue [[federated-planning-dashboard]] flagged).
> No `touring` / `:org` / `inbox:changes` / tour-tag residue remains in
> first-party code.
>
> **Out of scope — not a domain leak:** the `ops/*` data root (`ops/plans`,
> `ops/position`) is a generic host *layout convention*, not a touring leak;
> changing it is architectural and is owned by [[split-graph-and-plan-app]], not
> this scrub.
>
> **Status (2026-06): Tier 2 done too.** Folded into [[split-graph-and-plan-app]]
> Phase 3 (the viewer re-cut) per its plan. All `louder`/`SOD`/`LouderWeb`
> provenance neutralized in first-party `lib/` + `config/`: the `.sod-*` CSS
> class names renamed to `.app-*` (real code, not just comments), and the
> doc/comment refs in `paths.ex`, `error_html.ex`, `endpoint.ex`, `ui.ex`,
> `layouts.ex`, `landing_live.ex`, `policy_live.ex`, `config/dev.exs` replaced
> with neutral phrasing ("the upstream app"). `grep -rniE "louder|\bsod\b|sod-|LouderWeb" lib/ config/`
> is now empty.

`cb-dashboard` was extracted from a frozen host app (`louder`, an "SOD" observability
surface). The code decoupled cleanly (see `dashboard-extraction.md`), but **prose
breadcrumbs of the host survived the cut** — in particular a reference to the host's
*touring-data* domain, which leaks what the host product is. This plan inventories the
residue, separates a **domain leak** (scrub) from **extraction provenance** (a keep/drop
decision), and gives exact edits.

> Scope note: only **first-party** files. The `deps/` tree (Phoenix, Plug, mdex, …)
> contains unrelated `:org`/`host`/`SSE` substrings in third-party docs — out of scope,
> never edit.

## Tier 1 — domain leak (scrub; this is what "was supposed to be scrubbed")

Two comments name the host's **touring-data `:org` source** — they reveal the host
product's domain (tour/event management). Nothing in `cb-dashboard` consumes these; the
comments only explain what was *dropped*. Remove the domain specifics; keep the (useful)
statement that an upstream source and legacy SSE path were dropped, stated generically.

| File:line | Current | Proposed |
|---|---|---|
| `cb-dashboard/README.md:27` | "the host's touring-data `:org` source and legacy SSE back-compat were dropped." | "an upstream domain-data source and legacy SSE back-compat were dropped." |
| `cb-dashboard/lib/cb_dashboard/watcher.ex:20-22` | "Decoupled from the host: the host's `:org`/`inbox:changes` touring-data source and the legacy SSE `:refresh` back-compat (which served the old client-facing surface) are dropped — no dashboard view consumes them." | "Decoupled from the upstream app: an upstream domain-data source and the legacy SSE `:refresh` back-compat (which served the old client-facing surface) are dropped — no dashboard view consumes them." |

Both are comment/markdown edits, zero code impact. After the edit, re-grep to confirm
`touring` and `:org` (first-party) are gone:

```sh
grep -rinE "touring|inbox:changes" cb-dashboard --include="*.ex" --include="*.exs" --include="*.md"   # expect: no matches
grep -rinE "\b:org\b" cb-dashboard --include="*.ex" --include="*.exs" --include="*.md"                  # expect: deps/ only
```

## Tier 2 — host-app provenance (decision: keep or scrub)

A second layer names the host app itself (`louder` / `SOD` / `LouderWeb`). Unlike Tier 1
this is *engineering provenance*, not a domain leak — and `dashboard-extraction.md`
deliberately documents the `louder` → `cb` port, so internally these refs are expected.
The question is whether the **public** dashboard cut should carry them.

| File:line | Reference |
|---|---|
| `cb-dashboard/README.md:4` | "host `louder` app's observability surface (the \"SOD\")" |
| `cb-dashboard/README.md:10` | "Every louder SOD view runs standalone here" |
| `cb-dashboard/README.md:13` | "diffed against its louder …" (per-file audit) |
| `cb-dashboard/README.md:25` | "verified 1:1 API parity with the host's" |
| `cb-dashboard/README.md:52` | "no compile-time `Louder.repo_root()` joins" |
| `cb-dashboard/README.md:70` | "No coupling to `louder`." |
| `cb-dashboard/config/dev.exs:5` | "run beside the still-live louder SOD during the cutover" |
| `cb-dashboard/lib/cb_dashboard/paths.ex:5` | "replaces the host app's compile-time `Louder.repo_root()` joins" |
| `cb-dashboard/lib/cb_dashboard/error_html.ex:3` | "replaces the borrowed `LouderWeb.ErrorHTML`" |
| `cb-dashboard/lib/cb_dashboard/endpoint.ex:8` | "instead of the host's compile-time …" |
| `cb-dashboard/lib/cb_dashboard/components/ui.ex:5` | "Every LiveView in `lib/louder/observability/live/`" |
| `cb-dashboard/lib/cb_dashboard/sources/transcripts.ex:19` | "rather than the host's compile-time literal" |

**Recommendation:** scrub Tier 1 now (unambiguous leak). Defer Tier 2 to whenever the
public re-cut of `cb-dashboard` happens (the Stage-5 cut tracked in
`dashboard-extraction.md` §6 / the restructure handoff) — and at that point replace
`louder`/`SOD`/`LouderWeb`/`Louder.repo_root()` with neutral phrasing ("the upstream
app", "the upstream observability surface", "a compile-time repo-root join") rather than
deleting the provenance outright. Doing Tier 2 piecemeal now risks missing some and
leaving a half-scrubbed README.

## Sequence

1. Apply the two Tier-1 edits.
2. Run the two greps above; confirm `touring`/`inbox:changes` gone and `:org` is `deps/`-only.
3. (Optional, deferred) Tier-2 neutralization as part of the public re-cut.

## Risks and non-goals

- **Half-scrub** — fixing Tier 1 but advertising "fully scrubbed" while Tier 2 remains. Mitigated by naming the two tiers explicitly here; Tier 2 is a *known, deferred* item, not an oversight.
- **Over-scrub** — deleting useful extraction provenance. Tier 2 is *neutralized*, not deleted, and only at re-cut time.
- **Non-goal:** touching `deps/`. Third-party; out of scope.
- **Non-goal:** code changes. Every edit here is comment/markdown only; no behavior moves.

## Open questions

1. Tier-2 timing: fold into this scrub now, or strictly defer to the public re-cut?
2. Neutral phrasing for the upstream app in public docs — "the upstream app", "the source application", or drop the framing entirely and state only the current behavior?
