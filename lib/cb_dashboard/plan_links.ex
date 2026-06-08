defmodule CBDashboard.PlanLinks do
  @moduledoc """
  Post-process MDEx-rendered HTML so plan-path references become hot links.

  Plan paths in prose are conventionally written in backticks, which MDEx
  renders as `<code>...</code>`. This module finds those code spans whose
  content is a plan path, wraps them in `<a href="/plans/<basename>">`, and
  rewrites the visible text to just the basename (stripping any bucket
  prefix and `.md` extension).

  All plans live flat under `ops/plans/<basename>.md`, so the URL is
  exactly `/plans/<basename>` — bucket subdirectories no longer exist.
  Older prose still mentions paths like `done/<basename>.md` or
  `non-sequential/<basename>.md`; the linkifier recognizes those legacy
  forms too and resolves them to the same URL.

  Supported path shapes (all link to `/plans/<basename>` and display as
  `<basename>`):

      ops/plans/<basename>.md
      ops/plans/done/<basename>.md             (legacy; same target)
      ops/plans/non-sequential/<basename>.md   (legacy; same target)
      done/<basename>.md                       (legacy; same target)
      non-sequential/<basename>.md             (legacy; same target)
      <basename>.md                            (bare basename, dated)
  """

  # Fresh `<code>` span whose body is a plan-path reference.
  @plan_code_re Regex.compile!(
                  "<code>(?:ops/plans/)?(?:done/|paused/|superseded/|deprecated/|evaluate/|non-sequential/)?(\\d{4}-\\d{2}-\\d{2}-[a-z0-9_-]+)\\.md</code>"
                )

  # Already-linkified plan anchor — captures basename so re-runs reconcile
  # any stale href against the current URL scheme. Optionally consumes a
  # trailing status badge so refresh doesn't double-stamp it.
  @linked_re Regex.compile!(
               "<a href=\"[^\"]*\" class=\"plan-link\"><code>(\\d{4}-\\d{2}-\\d{2}-[a-z0-9_-]+)</code></a>(?:\\s*<span class=\"state state--[a-z]+\">[^<]*</span>)?"
             )

  @doc """
  Wrap plan-path `<code>` spans in `<a>` links and replace their visible
  text with the bare basename. Idempotent and refresh-safe:

  - Fresh `<code>plan/path.md</code>` spans get wrapped.
  - Already-linkified `<a class="plan-link"><code>basename</code></a>`
    spans have their href re-resolved against the current URL scheme.
  """
  @spec linkify_html(String.t()) :: String.t()
  def linkify_html(html) when is_binary(html) do
    html
    |> wrap_fresh()
    |> refresh_existing()
  end

  defp wrap_fresh(html) do
    Regex.replace(@plan_code_re, html, fn _match, basename -> anchor(basename) end)
  end

  defp refresh_existing(html) do
    Regex.replace(@linked_re, html, fn _match, basename -> anchor(basename) end)
  end

  defp anchor(basename) do
    link = ~s(<a href="/plans/#{basename}" class="plan-link"><code>#{basename}</code></a>)
    link <> status_badge(basename)
  end

  # Inline status badge appended after a plan link, so cross-references
  # carry the current state of the referenced plan ("Paused", "Done",
  # etc.) without having to click through. Reads the target plan's
  # **Status:** field on each render — cheap at the file counts we have.
  defp status_badge(basename) do
    case CBDashboard.Sources.Plans.status_meta(basename) do
      %{bucket: bucket, label: label} ->
        cls = bucket_class(bucket)
        # Label is upcased here so the .state CSS class can drop
        # `text-transform: uppercase` (Phase 2 acceptance restricts
        # uppercase declarations to `components/ui.ex`).
        ~s( <span class="state state--#{cls}">#{String.upcase(label)}</span>)

      _ ->
        ""
    end
  end

  defp bucket_class(:shipped), do: "done"
  defp bucket_class(:in_progress), do: "in-progress"
  defp bucket_class(bucket), do: Atom.to_string(bucket)

  # --- Belief-id linkification --------------------------------------------

  @belief_id_re Regex.compile!("\\b([ac]\\d{3,})\\b")

  @doc """
  Wrap belief-id mentions (`a299`, `c038`, ...) in rendered HTML as
  anchor links to `/dag/<id>`. Walks the HTML at tag granularity so
  text inside existing `<a>` anchors is left alone (no nested links).
  Text inside other tags — including `<code>` — gets linkified, which
  is what we want: a `<code>c039</code>` span becomes
  `<code><a href="/dag/c039">c039</a></code>`, monospace and clickable.

  Safe to run on already-linkified plan paths because the belief-id
  regex requires `[ac]` + digits and plan basenames start with
  `YYYY-MM-DD-`.
  """
  @spec linkify_belief_ids(String.t()) :: String.t()
  def linkify_belief_ids(html) when is_binary(html) do
    {parts, _in_anchor} =
      Regex.split(~r/(<[^>]+>)/, html, include_captures: true)
      |> Enum.reduce({[], false}, fn part, {acc, in_anchor?} ->
        cond do
          not in_anchor? and Regex.match?(~r/^<a\b/i, part) ->
            {[part | acc], true}

          in_anchor? and Regex.match?(~r/^<\/a>/i, part) ->
            {[part | acc], false}

          String.starts_with?(part, "<") ->
            {[part | acc], in_anchor?}

          in_anchor? ->
            {[part | acc], in_anchor?}

          true ->
            {[linkify_belief_text(part) | acc], in_anchor?}
        end
      end)

    parts |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp linkify_belief_text(text) do
    Regex.replace(@belief_id_re, text, fn _, id ->
      ~s(<a href="/dag/#{id}" class="dag-link">#{id}</a>)
    end)
  end
end
