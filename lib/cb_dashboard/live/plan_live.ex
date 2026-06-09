defmodule CBDashboard.PlanLive do
  @moduledoc """
  Single-plan view at `/plans/:basename`, organized as three tabs:

  - **Plan** — the plan body (everything before `## Recap`). Always shown.
  - **Recap** — the appended recap section. Shown only when `## Recap`
    exists in the markdown.
  - **Thread** — compiled transcripts for sessions cited in `**Sessions:**`
    blocks in either the plan body (authoring sessions, creation-time)
    or the recap (execution sessions, completion-time). Shown only when at
    least one session is parseable.

  Active tab is driven by the `?tab=plan|recap|thread` query param via
  `handle_params/3` so deep links and back-button navigation work.

  Plans live flat under `ops/plans/<basename>.md`; the body is rendered to
  HTML by MDEx with PlanLinks post-processing so plan-path references are
  hot-linked to their basename-only URLs.

  Subscribes to `"plans:changes"` so a live edit re-renders without refresh.
  """

  use Phoenix.LiveView

  import CBUI.Components

  alias CB.Belief
  alias CB.Belief.Store
  alias CBDashboard.Components.Thread
  alias CBDashboard.Sources.Proposals

  @topic "plans:changes"
  @assertions_topic "assertions:changes"
  @proposals_topic "proposals:changes"

  @impl true
  def mount(%{"basename" => basename}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CBDashboard.PubSub, @topic)
      Phoenix.PubSub.subscribe(CBDashboard.PubSub, @assertions_topic)
      Phoenix.PubSub.subscribe(CBDashboard.PubSub, @proposals_topic)
    end

    {:ok, socket |> assign(:basename, basename) |> load(basename)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:active_tab, normalize_tab(params["tab"], socket.assigns))
     |> assign(:selected_session, normalize_session_param(params["session"], socket.assigns))}
  end

  defp normalize_session_param(nil, _), do: nil

  defp normalize_session_param(sid, assigns) do
    if sid in (assigns[:session_ids] || []) do
      sid
    else
      nil
    end
  end

  @impl true
  def handle_info(:plans_changed, socket) do
    {:noreply, load(socket, socket.assigns.basename)}
  end

  def handle_info(:assertions_changed, socket) do
    {:noreply, load(socket, socket.assigns.basename)}
  end

  def handle_info(:proposals_changed, socket) do
    {:noreply, load(socket, socket.assigns.basename)}
  end

  # --- Load + parse ---

  defp load(socket, basename) do
    case path_for(basename) do
      {:ok, path} ->
        case File.read(path) do
          {:ok, markdown} ->
            markdown = inject_children_block(markdown, basename)
            {plan_md, recap_md} = split_at_recap(markdown)
            session_ids = Thread.parse_session_ids((plan_md || "") <> "\n" <> (recap_md || ""))
            self_plan = CBDashboard.Sources.Plans.all() |> Enum.find(&(&1.basename == basename))
            {assertions, belief_index} = load_assertions()
            dag_beliefs = beliefs_for_session(assertions, basename)
            dag_proposals = proposals_for_plan(basename)
            dag_mutated = group_mutations_by_belief(dag_proposals, belief_index)

            socket
            |> assign(:found?, true)
            |> assign(:plan_html, render_md(plan_md))
            |> assign(:recap_html, render_md(recap_md))
            |> assign(:has_recap?, not is_nil(recap_md))
            |> assign(:session_ids, session_ids)
            |> assign(:has_thread?, session_ids != [])
            |> assign(:sessions, Thread.load_sessions(session_ids))
            |> assign(:status_banner, status_banner_for(self_plan))
            |> assign(:dag_beliefs, dag_beliefs)
            |> assign(:dag_proposals, dag_proposals)
            |> assign(:dag_mutated, dag_mutated)
            |> assign(:has_dag?, dag_beliefs != [] or dag_proposals != [] or dag_mutated != [])

          {:error, _} ->
            assign_missing(socket, basename)
        end

      :not_found ->
        assign_missing(socket, basename)
    end
  end

  # Beliefs whose `artifact` field is `session:<basename>` were authored
  # in the session corresponding to this plan. Session ids in this
  # project correspond to plan basenames; per a436 schema migrations and
  # ordinary belief authoring both set this field at write time. Returns
  # beliefs sorted by id for stable display.
  defp beliefs_for_session(assertions, basename) do
    target = "session:#{basename}"

    assertions
    |> Enum.filter(&(&1.artifact == target))
    |> Enum.sort_by(& &1.id)
  end

  defp load_assertions do
    case Store.read() do
      {:ok, assertions} -> {assertions, Map.new(assertions, &{&1.id, &1})}
      _ -> {[], %{}}
    end
  end

  # Walk every mutation across proposals authored under this plan and
  # group by `belief_id` so the DAG tab can render "all beliefs touched
  # by this plan's proposals" as a flat list. Each grouped entry
  # carries the current belief (resolved from the index, may be nil
  # for new-belief targets that haven't been applied yet) plus a list
  # of {proposal_slug, mutation} pairs so each row can deep-link to
  # the mutation's anchor on the proposal page.
  defp group_mutations_by_belief(proposals, belief_index) do
    proposals
    |> Enum.flat_map(fn p -> Enum.map(p.mutations, &{p.slug, &1}) end)
    |> Enum.group_by(fn {_slug, m} -> m.belief_id end)
    |> Enum.map(fn {belief_id, pairs} ->
      %{
        belief_id: belief_id,
        belief: Map.get(belief_index, belief_id),
        mutations: pairs
      }
    end)
    |> Enum.sort_by(& &1.belief_id)
  end

  # Proposals whose `source_plan` field references this plan basename.
  # Field shape varies (some manifests carry old bucket-prefixed paths
  # like "done/<basename>.md", others the new flat "<basename>.md"); we
  # compare basenames only so both shapes match.
  defp proposals_for_plan(basename) do
    Proposals.list()
    |> Enum.filter(fn p ->
      case p.source_plan do
        nil -> false
        path -> Path.basename(path, ".md") == basename
      end
    end)
  end

  # Compute the blocker callout for paused plans. Blocking is parent←child
  # only (a parent is blocked by its children; a child unblocks its parent
  # when it ships) — there is no external-blocker concept.
  #
  # Returns one of:
  #   nil                              — not paused, no banner
  #   {:waiting_active, [children]}    — paused, at least one child still in flight
  #   {:resolved, [shipped_children]}  — paused, all children shipped; ready to resume
  #   :ready_to_run                    — paused with no children; queued for pick-up
  defp status_banner_for(nil), do: nil

  defp status_banner_for(%{bucket: :paused} = plan) do
    children = CBDashboard.Sources.Plans.children_of(plan.basename)
    active = Enum.reject(children, &(&1.bucket == :shipped))
    shipped = Enum.filter(children, &(&1.bucket == :shipped))

    cond do
      active != [] -> {:waiting_active, active}
      shipped != [] -> {:resolved, shipped}
      true -> :ready_to_run
    end
  end

  defp status_banner_for(_), do: nil

  defp assign_missing(socket, basename) do
    socket
    |> assign(:basename, basename)
    |> assign(:found?, false)
  end

  defp path_for(basename) do
    path = Path.join(CBDashboard.Paths.plans_dir(), "#{basename}.md")
    if File.regular?(path), do: {:ok, path}, else: :not_found
  end

  # Children are derived from any plan whose Parent: field matches this
  # basename. Inject the block as a header field so it runs through the
  # same metadata-reorder / linkify pipeline as everything else and picks
  # up the status badge per child for free.
  defp inject_children_block(markdown, basename) do
    case CBDashboard.Sources.Plans.children_of(basename) do
      [] ->
        markdown

      children ->
        label = if length(children) == 1, do: "Child", else: "Children"

        line =
          "**#{label}:** " <>
            Enum.map_join(children, ", ", fn child -> "`#{child.basename}.md`" end)

        insert_after_metadata_block(markdown, line)
    end
  end

  # Insert `line` at the end of the top metadata block — the consecutive
  # `**Field:**` lines following the title. Stops at the first `##`
  # heading or `---` separator so in-body field-like lines (e.g. the
  # `**Resume signal:**` line inside a Paused note) don't get matched.
  defp insert_after_metadata_block(markdown, line) do
    lines = String.split(markdown, "\n", trim: false)
    {head_end_idx, last_meta_idx} = scan_header_block(lines)

    cond do
      last_meta_idx != nil ->
        Enum.join(List.insert_at(lines, last_meta_idx + 1, line), "\n")

      head_end_idx != nil ->
        Enum.join(List.insert_at(lines, head_end_idx, line), "\n")

      true ->
        line <> "\n" <> markdown
    end
  end

  # Walk the lines after the title until we hit the first `##` heading or
  # `---` separator. Within that window, record the index of the last
  # `**Field:**` line. Returns {header_end_idx, last_meta_idx} where
  # either may be nil if no header exists.
  defp scan_header_block(lines) do
    title_idx = Enum.find_index(lines, &String.starts_with?(&1, "# "))
    start_idx = if title_idx, do: title_idx + 1, else: 0

    Enum.reduce_while(
      Enum.with_index(Enum.drop(lines, start_idx)),
      {nil, nil},
      fn {line, i}, {_head_end, last_meta} ->
        abs_idx = start_idx + i

        cond do
          String.starts_with?(line, "## ") or String.trim(line) == "---" ->
            {:halt, {abs_idx, last_meta}}

          String.match?(line, ~r/^\*\*[A-Za-z][A-Za-z -]*:\*\*\s+\S/) ->
            {:cont, {nil, abs_idx}}

          true ->
            {:cont, {nil, last_meta}}
        end
      end
    )
  end

  # Split the plan markdown at the first `## Recap` heading. Strips the
  # `---` separator that conventionally precedes it so the recap tab
  # doesn't lead with a stray horizontal rule.
  defp split_at_recap(markdown) do
    case Regex.run(~r/\A(.*?)(?:\n---\s*\n+)?(## Recap\b.*)\z/s, markdown,
           capture: :all_but_first
         ) do
      [plan, recap] -> {String.trim_trailing(plan), recap}
      _ -> {markdown, nil}
    end
  end

  defp render_md(nil), do: nil

  defp render_md(md) do
    md
    |> strip_sessions_block()
    |> reorder_metadata_fields()
    |> wrap_status_value()
    |> wrap_effort_value()
    |> expand_multi_value_fields()
    |> MDEx.to_html!(
      extension: [table: true, autolink: true, strikethrough: true, tasklist: true],
      render: [unsafe_: true, hardbreaks: true],
      syntax_highlight: [formatter: {:html_inline, theme: "github_dark"}]
    )
    |> CBDashboard.PlanLinks.linkify_html()
    |> CBDashboard.PlanLinks.linkify_belief_ids()
  end

  # Remove the `**Sessions:** … bullets` block from the recap so it doesn't
  # render in the Recap tab. The Thread tab is the canonical view of
  # session info — each session there has its own header with compiled /
  # raw links, so the inline list is just duplicate metadata.
  # parse_session_ids/1 still reads the raw recap markdown (pre-strip) to
  # populate the Thread tab, so this only affects rendering.
  defp strip_sessions_block(md) do
    Regex.replace(~r/^\*\*Sessions:\*\*\n(?:[ \t]*- [^\n]*\n)+/m, md, "")
  end

  # --- Metadata reorder ---

  # Preferred display order for metadata fields at the top of a plan body.
  # Fields not in this list keep their original relative position at the end.
  @field_order [
    "Status",
    "Tags",
    "Series",
    "Parent",
    "Child",
    "Children",
    "Dependencies",
    "Superseded-by",
    "Related",
    "Effort",
    "Commits",
    "Sessions"
  ]

  # Re-emit the top metadata block in the preferred field order. The block
  # is "consecutive single-line `**Field:**` lines following the first
  # `# ` heading (or the very top if no heading)". Multi-line fields like
  # `**Sessions:**` with bullets below are left in place — they only appear
  # in the recap block where ordering is already canonical.
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

  # Consume contiguous single-line `**Field:** value` lines (allowing blank
  # lines between as the convention may put one). Stop at any other content.
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

  # --- Status / Effort value wrappers ---

  # Wrap the Status keyword in a colored badge. Source: `**Status:** done (date)`
  # becomes `**Status:** <span class="state state--done">DONE</span> (date)`.
  # Label is upcased here in Elixir so the CSS class doesn't need a
  # `text-transform: uppercase` declaration (the Phase 2 acceptance check
  # bans uppercase outside `components/ui.ex`).
  defp wrap_status_value(md) do
    Regex.replace(
      ~r/^(\*\*Status:\*\*\s+)([a-z]+)/m,
      md,
      fn _whole, prefix, keyword ->
        normalized = state_class(keyword)
        prefix <> ~s(<span class="state state--#{normalized}">#{String.upcase(keyword)}</span>)
      end
    )
  end

  # Same shape for Effort.
  defp wrap_effort_value(md) do
    Regex.replace(
      ~r/^(\*\*Effort:\*\*\s+)([a-z]+)/m,
      md,
      fn _whole, prefix, keyword ->
        prefix <> ~s(<span class="effort effort--#{keyword}">#{String.upcase(keyword)}</span>)
      end
    )
  end

  # Status header keyword → CSS-class slug. Maps `evaluation` → `evaluate`
  # so the `Status: evaluation needed` form picks up the same yellow as the
  # bucket label.
  defp state_class("evaluation"), do: "evaluate"
  defp state_class(keyword), do: keyword |> String.split() |> List.first()

  # --- Multi-value field expansion ---

  # Pre-process markdown so a multi-value metadata line like
  #
  #     **Related:** `foo.md` (parent), `bar.md` (the prereq), `baz.md` (...)
  #
  # renders as a bulleted list under the field name instead of cramming
  # everything onto one wrapped line. Splits on commas only where the next
  # item starts with a backtick, so commas inside an item's description
  # (e.g. "the prereq sweep, now done") don't split the entry.
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
          # Trailing blank line ends the bullet list so a subsequent
          # `**Field:**` line on the next row doesn't get absorbed as a
          # bullet continuation.
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

  # --- Tab normalization ---

  defp normalize_tab(nil, _), do: "plan"

  defp normalize_tab(tab, assigns) when tab in ["plan", "recap", "thread", "dag"] do
    cond do
      tab == "recap" and not assigns[:has_recap?] -> "plan"
      tab == "thread" and not assigns[:has_thread?] -> "plan"
      tab == "dag" and not assigns[:has_dag?] -> "plan"
      true -> tab
    end
  end

  defp normalize_tab(_, _), do: "plan"

  # --- Render ---

  @impl true
  def render(%{found?: false} = assigns) do
    ~H"""
    <div style="max-width: var(--maxw-narrow);">
      <h2 style="font-size: 16px; margin: 0 0 8px 0; font-weight: 600;">Plan not found</h2>
      <p style="font-size: 13px; color: var(--text-secondary);">
        No <code>{@basename}.md</code> in <code>ops/plans/</code>.
        <a href="/plans">← back to plans</a>
      </p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div style="max-width: var(--maxw-prose);">
      <div style="font-size: 12px; color: var(--text-muted); margin-bottom: 12px; display: flex; gap: 12px; align-items: baseline; flex-wrap: wrap;">
        <a href="/plans" style="color: var(--text-muted);">← all plans</a>
        <span style="color: var(--text-muted);">·</span>
        <span style="font-family: ui-monospace, SFMono-Regular, monospace;">{@basename}</span>
        <span style="color: var(--text-muted);">·</span>
        <a href={"/plans/files/#{@basename}.md"} style="font-size: 11px;">view raw markdown</a>
      </div>

      <.status_banner banner={@status_banner} />

      <nav class="plan-tabs">
        <Thread.tab_link patch={"/plans/#{@basename}?tab=plan"} active={@active_tab == "plan"}>Plan</Thread.tab_link>
        <Thread.tab_link :if={@has_recap?} patch={"/plans/#{@basename}?tab=recap"} active={@active_tab == "recap"}>Recap</Thread.tab_link>
        <Thread.tab_link :if={@has_thread?} patch={"/plans/#{@basename}?tab=thread"} active={@active_tab == "thread"}>Thread</Thread.tab_link>
        <Thread.tab_link :if={@has_dag?} patch={"/plans/#{@basename}?tab=dag"} active={@active_tab == "dag"}>DAG</Thread.tab_link>
      </nav>

      <article :if={@active_tab == "plan"} class="plan-prose">
        {Phoenix.HTML.raw(@plan_html)}
      </article>

      <article :if={@active_tab == "recap"} class="plan-prose">
        {Phoenix.HTML.raw(@recap_html)}
      </article>

      <div :if={@active_tab == "thread"} class="thread-pane">
        <Thread.thread_view sessions={@sessions} selected={@selected_session} base_path="/plans" basename={@basename} />
      </div>

      <div :if={@active_tab == "dag"} class="plan-dag-pane">
        <.dag_pane beliefs={@dag_beliefs} proposals={@dag_proposals} mutated={@dag_mutated} />
      </div>
    </div>

    <style>
      /* Tab nav + Thread tab styles moved to layouts.ex (shared with
         PositionLive). Plan-prose, state/effort base + sub-pills also
         live in layouts.ex. Plan-specific chrome (status-banner) stays
         here. */

      .status-banner {
        display: flex;
        flex-direction: column;
        gap: 6px;
        padding: 12px 16px;
        margin-bottom: 18px;
        border-radius: 6px;
        background: var(--bg-secondary);
        border-left: 4px solid var(--accent-red);
        font-size: 13px;
        color: var(--text-secondary);
      }
      .status-banner.resolved { border-left-color: var(--accent-green); }
      .status-banner-head {
        /* Label content is upcased in the template (status_banner
           clauses) so this class can omit text-transform. */
        font-size: 12px;
        font-weight: 600;
        letter-spacing: 0.08em;
        color: var(--accent-red);
      }
      .status-banner.resolved .status-banner-head { color: var(--accent-green); }
      .status-banner ul { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 4px; }
      .status-banner li { display: flex; gap: 8px; align-items: baseline; }
      .status-banner a.plan-link { text-decoration: none; }
      .status-banner a.plan-link code { background: var(--bg-tertiary); color: var(--text-primary); padding: 1px 6px; border-radius: 3px; font-size: 12.5px; }
    </style>
    """
  end

  # --- DAG tab (beliefs + proposals authored under this plan) ---

  attr :beliefs, :list, required: true
  attr :proposals, :list, required: true
  attr :mutated, :list, required: true

  defp dag_pane(assigns) do
    assigns =
      assigns
      |> assign(:grouped, group_by_type(assigns.beliefs))

    ~H"""
    <div style="display: flex; flex-direction: column; gap: 24px;">
      <p style="font-size: 12px; color: var(--text-muted); margin: 0;">
        DAG nodes touched by this plan: beliefs <em>authored</em> here (artifact = session:{}), beliefs <em>mutated</em> by proposals authored under this plan, and the proposal manifests themselves. Beliefs only cited in prose aren't surfaced — use the auto-linked belief ids in the Plan tab for those.
      </p>

      <section :if={@beliefs != []}>
        <h3 style="font-size: 14px; font-weight: 600; margin: 0 0 8px 0; color: var(--text-primary);">
          Beliefs authored ({length(@beliefs)})
        </h3>
        <div :for={{type, items} <- @grouped} style="margin-bottom: 16px;">
          <div style="margin-bottom: 6px;">
            <.section_label>{type} ({length(items)})</.section_label>
          </div>
          <ul style="list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 6px;">
            <li :for={belief <- items} style="padding: 8px 10px; background: var(--bg-secondary); border-left: 3px solid var(--accent-blue); border-radius: 4px;">
              <div style="display: flex; gap: 8px; align-items: baseline; flex-wrap: wrap; margin-bottom: 4px;">
                <a href={"/dag/#{belief.id}"} style="font-family: ui-monospace, SFMono-Regular, monospace; font-weight: 700; font-size: 13px; color: var(--text-primary); text-decoration: none;">
                  {belief.id}
                </a>
                <span :if={belief.kind} style="font-size: 10px; padding: 1px 6px; border-radius: 8px; background: var(--bg-tertiary); color: var(--text-secondary); font-family: ui-monospace, SFMono-Regular, monospace;">
                  {belief.kind}
                </span>
                <span :if={Belief.contract?(belief)} style="font-size: 10px; padding: 1px 6px; border-radius: 8px; background: var(--badge-bg-purple); color: var(--accent-purple); font-weight: 600;">
                  CONTRACT
                </span>
                <span :if={belief.name} style="font-size: 11px; padding: 1px 6px; border-radius: 8px; background: var(--badge-bg-blue); color: var(--accent-blue); font-family: ui-monospace, SFMono-Regular, monospace;">
                  {belief.name}
                </span>
                <span :if={belief.status != "active"} style="font-size: 10px; padding: 1px 6px; border-radius: 8px; background: var(--bg-tertiary); color: var(--text-muted); text-transform: uppercase;">
                  {belief.status}
                </span>
              </div>
              <div style="font-size: 12px; line-height: 1.4; color: var(--text-secondary);">
                {claim_preview(belief.claim)}
              </div>
            </li>
          </ul>
        </div>
      </section>

      <section :if={@mutated != []}>
        <h3 style="font-size: 14px; font-weight: 600; margin: 0 0 8px 0; color: var(--text-primary);">
          Beliefs touched by proposals ({length(@mutated)})
        </h3>
        <ul style="list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 6px;">
          <li :for={entry <- @mutated} style="padding: 8px 10px; background: var(--bg-secondary); border-left: 3px solid var(--accent-purple); border-radius: 4px;">
            <div style="display: flex; gap: 8px; align-items: baseline; flex-wrap: wrap; margin-bottom: 4px;">
              <a href={"/dag/#{entry.belief_id}"} style="font-family: ui-monospace, SFMono-Regular, monospace; font-weight: 700; font-size: 13px; color: var(--text-primary); text-decoration: none;">
                {entry.belief_id}
              </a>
              <span :if={entry.belief && entry.belief.kind} style="font-size: 10px; padding: 1px 6px; border-radius: 8px; background: var(--bg-tertiary); color: var(--text-secondary); font-family: ui-monospace, SFMono-Regular, monospace;">
                {entry.belief.kind}
              </span>
              <span :if={entry.belief && entry.belief.name} style="font-size: 11px; padding: 1px 6px; border-radius: 8px; background: var(--badge-bg-blue); color: var(--accent-blue); font-family: ui-monospace, SFMono-Regular, monospace;">
                {entry.belief.name}
              </span>
              <span :if={is_nil(entry.belief)} style="font-size: 10px; padding: 1px 6px; border-radius: 8px; background: var(--badge-bg-green); color: var(--accent-green); font-weight: 600;">
                NEW
              </span>
            </div>
            <div style="display: flex; gap: 6px; flex-wrap: wrap; font-size: 11px;">
              <a :for={{slug, m} <- entry.mutations}
                href={"/dag/proposals/#{slug}#m-#{m.id}"}
                style="display: inline-flex; gap: 4px; align-items: center; padding: 2px 6px; background: var(--bg-tertiary); border-radius: 4px; text-decoration: none; color: var(--text-secondary); font-family: ui-monospace, SFMono-Regular, monospace;"
                title={"#{slug} · #{m.id}"}>
                <span>{m.type}</span>
                <.badge tone={tone_for_mutation_status(m.status)} label={m.status || "pending"} />
              </a>
            </div>
            <div :if={entry.belief && entry.belief.claim} style="font-size: 12px; line-height: 1.4; color: var(--text-secondary); margin-top: 6px;">
              {claim_preview(entry.belief.claim)}
            </div>
          </li>
        </ul>
      </section>

      <section :if={@proposals != []}>
        <h3 style="font-size: 14px; font-weight: 600; margin: 0 0 8px 0; color: var(--text-primary);">
          Proposal manifests ({length(@proposals)})
        </h3>
        <ul style="list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 6px;">
          <li :for={proposal <- @proposals} style="padding: 8px 10px; background: var(--bg-secondary); border-left: 3px solid var(--accent-orange); border-radius: 4px;">
            <div style="display: flex; gap: 8px; align-items: baseline; flex-wrap: wrap; margin-bottom: 4px;">
              <a href={"/dag/proposals/#{proposal.slug}"} style="font-family: ui-monospace, SFMono-Regular, monospace; font-weight: 700; font-size: 13px; color: var(--text-primary); text-decoration: none;">
                {proposal.slug}
              </a>
              <.badge tone={tone_for_proposal_status(proposal.status)} label={proposal.status || "pending"} />
              <span style="font-size: 11px; color: var(--text-muted);">
                {length(proposal.mutations)} mutations
              </span>
            </div>
            <div :if={proposal.title} style="font-size: 12px; line-height: 1.4; color: var(--text-secondary);">
              {proposal.title}
            </div>
          </li>
        </ul>
      </section>

      <div :if={@beliefs == [] and @proposals == [] and @mutated == []} style="padding: 14px 16px; background: var(--bg-tertiary); border-radius: 6px; font-size: 13px; color: var(--text-muted);">
        No DAG content authored or touched under this plan.
      </div>
    </div>
    """
  end

  defp group_by_type(beliefs) do
    beliefs
    |> Enum.group_by(& &1.type)
    |> Enum.sort_by(fn {type, _} -> type_order(type) end)
  end

  defp type_order("primitive"), do: 0
  defp type_order("compound"), do: 1
  defp type_order("implication"), do: 2
  defp type_order(_), do: 99

  defp claim_preview(nil), do: ""

  defp claim_preview(claim) when is_binary(claim) do
    case String.length(claim) do
      n when n > 200 -> String.slice(claim, 0, 200) <> "…"
      _ -> claim
    end
  end

  defp tone_for_proposal_status("pending"), do: :orange
  defp tone_for_proposal_status("partial"), do: :blue
  defp tone_for_proposal_status("applied"), do: :green
  defp tone_for_proposal_status("rejected"), do: :red
  defp tone_for_proposal_status(_), do: :neutral

  defp tone_for_mutation_status("pending"), do: :orange
  defp tone_for_mutation_status("applied"), do: :green
  defp tone_for_mutation_status("rejected"), do: :red
  defp tone_for_mutation_status("discuss"), do: :blue
  defp tone_for_mutation_status(_), do: :neutral

  # --- Status banner (paused-plan blocker callout) ---

  attr :banner, :any, required: true

  defp status_banner(%{banner: nil} = assigns), do: ~H""

  defp status_banner(%{banner: {:waiting_active, plans}} = assigns) do
    assigns = assign(assigns, :plans, plans)

    ~H"""
    <div class="status-banner">
      <span class="status-banner-head">PAUSED — WAITING ON</span>
      <ul>
        <li :for={p <- @plans}>
          <a href={"/plans/#{p.basename}"} class="plan-link"><code>{p.basename}</code></a>
          <span class={"state state--" <> bucket_class(p.bucket)}>{String.upcase(state_label(p.bucket))}</span>
        </li>
      </ul>
    </div>
    """
  end

  defp status_banner(%{banner: {:resolved, plans}} = assigns) do
    label =
      if length(plans) == 1,
        do: "Child plan complete — ready to resume",
        else: "Child plans complete — ready to resume"

    assigns = assign(assigns, plans: plans, label: label)

    ~H"""
    <div class="status-banner resolved">
      <span class="status-banner-head">{String.upcase(@label)}</span>
      <ul>
        <li :for={p <- @plans}>
          <a href={"/plans/#{p.basename}"} class="plan-link"><code>{p.basename}</code></a>
          <span class="state state--done">DONE</span>
        </li>
      </ul>
    </div>
    """
  end

  defp status_banner(%{banner: :ready_to_run} = assigns) do
    ~H"""
    <div class="status-banner resolved">
      <span class="status-banner-head">READY TO RESUME</span>
    </div>
    """
  end

  defp bucket_class(:shipped), do: "done"
  defp bucket_class(:in_progress), do: "in-progress"
  defp bucket_class(bucket), do: Atom.to_string(bucket)

  defp state_label(:shipped), do: "Done"
  defp state_label(:in_progress), do: "In-progress"
  defp state_label(b), do: b |> Atom.to_string() |> String.capitalize()
end
