defmodule CBDashboard.PositionLive do
  @moduledoc """
  Single-position view at `/position/:basename`, organized as two tabs:

  - **Position** — the position body (always shown).
  - **Thread** — compiled transcripts for sessions cited in `**Sessions:**`
    or `**Authoring-session:**` blocks (any `/transcripts/<uuid>` URL in
    the body). Shown only when at least one session is parseable.

  Active tab is driven by the `?tab=position|thread` query param.
  Mirrors `PlanLive`'s compiled-markdown pipeline (metadata reorder →
  status wrap → multi-value expand → MDEx → PlanLinks) so position
  artifacts read with the same affordances as plans. Adds a per-claim
  flag-wrapper that turns each `**DAG status:** <value>` line into a
  colored `.flag` pill (palette in `CBDashboard.Layouts`'s
  inline CSS, kept in sync with the spec at
  `ops/position/CLAUDE.md` § Status vocabulary).

  Subscribes to `"positions:changes"` so a live edit re-renders without
  refresh. The live-DAG join that converts declared flags into computed
  flags is tracked in `ops/plans/2026-05-17-position-mechanics.md`
  (items 1-3); this view currently renders declared flags as-authored.

  Thread infrastructure (parse_session_ids, load_sessions, thread_view,
  session components, helpers) lives in
  `CBDashboard.Components.Thread` — shared with PlanLive.
  Tab/thread CSS lives in layouts.ex.

  Several helpers (`reorder_metadata_fields`, `wrap_status_value`,
  `expand_multi_value_fields`) intentionally parallel the same-named
  helpers in `PlanLive` — they are similar enough that an extraction
  into a shared `MarkdownRender` module is on the table once the
  mechanics plan adds the live-DAG join (which is the right moment to
  decide on the shared abstraction surface).
  """

  use Phoenix.LiveView

  alias CBDashboard.Components.Thread

  @topic "positions:changes"

  # Field display order at the top of the rendered body. Anything not
  # listed keeps its original relative position at the end.
  @field_order [
    "Type",
    "Status",
    "Authored",
    "Superseded-by",
    "Origin",
    "Companion plans"
  ]

  @impl true
  def mount(%{"basename" => basename}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(CBDashboard.PubSub, @topic)
    {:ok, socket |> assign(:basename, basename) |> load(basename)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:active_tab, normalize_tab(params["tab"], socket.assigns))
     |> assign(:selected_session, normalize_session_param(params["session"], socket.assigns))}
  end

  defp normalize_tab(nil, _), do: "position"

  defp normalize_tab(tab, assigns) when tab in ["position", "thread"] do
    cond do
      tab == "thread" and not assigns[:has_thread?] -> "position"
      true -> tab
    end
  end

  defp normalize_tab(_, _), do: "position"

  defp normalize_session_param(nil, _), do: nil

  defp normalize_session_param(sid, assigns) do
    if sid in (assigns[:session_ids] || []) do
      sid
    else
      nil
    end
  end

  @impl true
  def handle_info(:positions_changed, socket) do
    {:noreply, load(socket, socket.assigns.basename)}
  end

  # --- Load + parse ---

  defp load(socket, basename) do
    case path_for(basename) do
      {:ok, path} ->
        case File.read(path) do
          {:ok, markdown} ->
            session_ids = Thread.parse_session_ids(markdown)

            socket
            |> assign(:found?, true)
            |> assign(:body_html, render_md(markdown))
            |> assign(:session_ids, session_ids)
            |> assign(:has_thread?, session_ids != [])
            |> assign(:sessions, Thread.load_sessions(session_ids))

          {:error, _} ->
            assign_missing(socket, basename)
        end

      :not_found ->
        assign_missing(socket, basename)
    end
  end

  defp assign_missing(socket, basename) do
    socket
    |> assign(:basename, basename)
    |> assign(:found?, false)
  end

  defp path_for(basename) do
    path = Path.join(CBDashboard.Paths.positions_dir(), "#{basename}.md")
    if File.regular?(path), do: {:ok, path}, else: :not_found
  end

  defp render_md(md) do
    md
    |> strip_type_field()
    |> reorder_metadata_fields()
    |> wrap_status_value()
    |> wrap_dag_status_value()
    |> expand_multi_value_fields()
    |> MDEx.to_html!(
      extension: [table: true, autolink: true, strikethrough: true, tasklist: true],
      render: [unsafe_: true, hardbreaks: true],
      syntax_highlight: [formatter: {:html_inline, theme: "github_dark"}]
    )
    |> CBDashboard.PlanLinks.linkify_html()
    |> CBDashboard.PlanLinks.linkify_belief_ids()
  end

  # `**Type:** position` is the format's enum-stamp, useful in the raw
  # markdown for tooling and out-of-context discovery. On the `/position`
  # detail view itself the field is redundant noise — the route already
  # establishes the type. Strip it before any other markdown massaging
  # runs so the metadata reorder doesn't have to know about it.
  defp strip_type_field(md) do
    Regex.replace(~r/^\*\*Type:\*\*\s+\S.*\n/m, md, "")
  end

  # --- Metadata reorder (parallels PlanLive.reorder_metadata_fields/1) ---

  defp reorder_metadata_fields(markdown) do
    lines = String.split(markdown, "\n", trim: false)
    {prelude, rest} = split_at_metadata_start(lines)
    {meta_lines, tail} = take_single_line_meta(rest)

    if length(meta_lines) <= 1 do
      markdown
    else
      sorted = sort_meta_lines(meta_lines)
      Enum.join(prelude ++ sorted ++ tail, "\n")
    end
  end

  defp split_at_metadata_start(lines) do
    case Enum.find_index(lines, &String.match?(&1, ~r/^\*\*[A-Za-z][A-Za-z -]*:\*\*\s/)) do
      nil -> {lines, []}
      i -> {Enum.take(lines, i), Enum.drop(lines, i)}
    end
  end

  defp take_single_line_meta(lines, acc \\ [])
  defp take_single_line_meta([], acc), do: {Enum.reverse(acc), []}

  defp take_single_line_meta([line | rest] = all, acc) do
    cond do
      String.match?(line, ~r/^\*\*[A-Za-z][A-Za-z -]*:\*\*\s+\S.*$/) ->
        take_single_line_meta(rest, [line | acc])

      line == "" and acc != [] and rest != [] and
          String.match?(hd(rest), ~r/^\*\*[A-Za-z][A-Za-z -]*:\*\*\s/) ->
        take_single_line_meta(rest, acc)

      true ->
        {Enum.reverse(acc), all}
    end
  end

  defp sort_meta_lines(lines) do
    indexed =
      Enum.map(lines, fn line ->
        field = field_name_of(line)
        rank = Enum.find_index(@field_order, &(&1 == field)) || length(@field_order)
        {rank, line}
      end)

    indexed
    |> Enum.sort_by(fn {rank, _} -> rank end)
    |> Enum.map(fn {_, line} -> line end)
  end

  defp field_name_of(line) do
    case Regex.run(~r/^\*\*([A-Za-z][A-Za-z -]*):\*\*/, line) do
      [_, name] -> name
      _ -> ""
    end
  end

  # --- Status / DAG-status value wrappers ---

  # Wrap the position's top-level `**Status:** active|superseded|abandoned`
  # keyword in a `.state` pill. Mirrors PlanLive.wrap_status_value/1; the
  # state classes for active/abandoned were added to layouts.ex.
  defp wrap_status_value(md) do
    Regex.replace(
      ~r/^(\*\*Status:\*\*\s+)([a-z]+)/m,
      md,
      fn _whole, prefix, keyword ->
        prefix <>
          ~s(<span class="state state--#{keyword}">#{String.upcase(keyword)}</span>)
      end
    )
  end

  # Wrap each claim's `**DAG status:** <flag>` line in a `.flag--<flag>`
  # pill. Flag values are kebab-case (e.g. `not-represented`) so the
  # regex captures `[a-z-]+`. Unknown values fall through to a plain
  # `.flag` pill with default tone.
  defp wrap_dag_status_value(md) do
    Regex.replace(
      ~r/^(\*\*DAG status:\*\*\s+)([a-z][a-z-]*)/m,
      md,
      fn _whole, prefix, keyword ->
        prefix <>
          ~s(<span class="flag flag--#{keyword}">#{String.upcase(keyword)}</span>)
      end
    )
  end

  # --- Multi-value field expansion (parallels PlanLive) ---

  defp expand_multi_value_fields(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.map(&maybe_expand_field/1)
    |> Enum.join("\n")
  end

  defp maybe_expand_field(line) do
    case Regex.run(~r/^(\*\*[A-Za-z][A-Za-z -]*:\*\*)\s+(.+)$/, line) do
      [_, prefix, value] ->
        items = split_backticked_items(value)

        if length(items) >= 2 do
          bullets = Enum.map_join(items, "\n", fn item -> "- " <> String.trim(item) end)
          prefix <> "\n" <> bullets <> "\n"
        else
          line
        end

      _ ->
        line
    end
  end

  defp split_backticked_items(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, "`") do
      Regex.split(~r/,\s*(?=`)/, trimmed)
    else
      [value]
    end
  end

  # --- Render ---

  @impl true
  def render(%{found?: false} = assigns) do
    ~H"""
    <div style="max-width: var(--maxw-narrow);">
      <h2 style="font-size: 16px; margin: 0 0 8px 0; font-weight: 600;">Position not found</h2>
      <p style="font-size: 13px; color: var(--text-secondary);">
        No <code>{@basename}.md</code> in <code>ops/position/</code>.
        <a href="/position">← back to position</a>
      </p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div style="max-width: var(--maxw-prose);">
      <div style="font-size: 12px; color: var(--text-muted); margin-bottom: 12px; display: flex; gap: 12px; align-items: baseline; flex-wrap: wrap;">
        <a href="/position" style="color: var(--text-muted);">← all positions</a>
        <span style="color: var(--text-muted);">·</span>
        <span style="font-family: ui-monospace, SFMono-Regular, monospace;">{@basename}</span>
        <span style="color: var(--text-muted);">·</span>
        <a href={"/position/files/#{@basename}.md"} style="font-size: 11px;">view raw markdown</a>
      </div>

      <nav :if={@has_thread?} class="plan-tabs">
        <Thread.tab_link patch={"/position/#{@basename}?tab=position"} active={@active_tab == "position"}>Position</Thread.tab_link>
        <Thread.tab_link patch={"/position/#{@basename}?tab=thread"} active={@active_tab == "thread"}>Thread</Thread.tab_link>
      </nav>

      <article :if={@active_tab == "position"} class="plan-prose">
        {Phoenix.HTML.raw(@body_html)}
      </article>

      <div :if={@active_tab == "thread"} class="thread-pane">
        <Thread.thread_view sessions={@sessions} selected={@selected_session} base_path="/position" basename={@basename} />
      </div>
    </div>
    """
  end
end
