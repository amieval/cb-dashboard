defmodule CBDashboard.PlansLive do
  @moduledoc """
  Plans board — one collapsible section per bucket: paused, pending,
  evaluate, shipped (grouped by month inside its section), superseded,
  deprecated.

  Bucket membership is derived from each plan's `**Status:**` header; the
  filesystem is flat under `ops/plans/`. Subscribes to `"plans:changes"` on
  `CBDashboard.PubSub`; the watcher broadcasts `:plans_changed` on any add /
  modify / delete under that directory.
  """

  use Phoenix.LiveView

  import CBDashboard.Components.UI

  alias CBDashboard.Sources.Plans

  @topic "plans:changes"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(CBDashboard.PubSub, @topic)
    {:ok, assign_plans(socket)}
  end

  @impl true
  def handle_info(:plans_changed, socket), do: {:noreply, assign_plans(socket)}

  defp assign_plans(socket) do
    %{
      in_progress: in_progress,
      pending: pending,
      paused: paused,
      shipped: shipped,
      superseded: superseded,
      deprecated: deprecated,
      evaluate: evaluate
    } = Plans.list()

    recap_count = Enum.count(shipped, & &1.has_recap?)

    socket
    |> assign(:in_progress, in_progress)
    |> assign(:pending, pending)
    |> assign(:paused, paused)
    |> assign(:shipped, shipped)
    |> assign(:shipped_by_month, Plans.by_month(shipped))
    |> assign(:superseded, superseded)
    |> assign(:deprecated, deprecated)
    |> assign(:evaluate, evaluate)
    |> assign(:in_progress_count, length(in_progress))
    |> assign(:pending_count, length(pending))
    |> assign(:paused_count, length(paused))
    |> assign(:shipped_count, length(shipped))
    |> assign(:superseded_count, length(superseded))
    |> assign(:deprecated_count, length(deprecated))
    |> assign(:evaluate_count, length(evaluate))
    |> assign(:recap_count, recap_count)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: var(--maxw-list);">
      <.page_header title="Plans">
        <:meta>
          <.count_chip count={@in_progress_count} label="in progress" />
          <.count_chip count={@paused_count} label="paused" />
          <.count_chip count={@pending_count} label="pending" />
          <.count_chip count={@shipped_count} label="done" />
          <.count_chip count={@recap_count} label="with recaps" />
          <.count_chip count={@evaluate_count} label="evaluate" />
          <.count_chip count={@superseded_count} label="superseded" />
          <.count_chip count={@deprecated_count} label="deprecated" />
        </:meta>
      </.page_header>

      <.bucket_section
        :if={@in_progress_count > 0}
        label="In progress"
        count={@in_progress_count}
        accent="var(--accent-green)"
        open
      >
        <.flat_list plans={@in_progress} />
      </.bucket_section>

      <.bucket_section
        :if={@paused_count > 0}
        label="Paused"
        count={@paused_count}
        accent="var(--accent-red)"
        open
      >
        <.flat_list plans={@paused} />
      </.bucket_section>

      <.bucket_section
        :if={@pending_count > 0}
        label="Pending"
        count={@pending_count}
        accent="var(--accent-orange)"
        open
      >
        <.flat_list plans={@pending} />
      </.bucket_section>

      <.bucket_section
        :if={@evaluate_count > 0}
        label="Evaluate"
        count={@evaluate_count}
        accent="var(--accent-purple)"
      >
        <.flat_list plans={@evaluate} />
      </.bucket_section>

      <.bucket_section
        label="Done"
        count={@shipped_count}
        accent="var(--text-muted)"
      >
        <div :for={{bucket, items} <- @shipped_by_month} style="margin-bottom: 12px;">
          <h4 style="font-size: 11px; color: var(--text-muted); margin: 12px 0 6px; font-family: ui-monospace, SFMono-Regular, monospace;">
            {bucket}
          </h4>
          <ul style="list-style: none; padding: 0; border: 1px solid var(--border); border-radius: 6px; background: var(--bg-secondary);">
            <li :for={plan <- items} style="display: flex; gap: 12px; align-items: baseline; padding: 8px 14px; border-bottom: 1px solid var(--border); flex-wrap: wrap;">
              <a href={"/plans/#{plan.basename}"} style="flex: 1; min-width: 320px; font-weight: 500; text-decoration: none;">
                {plan.title}
              </a>
              <span style="display: flex; gap: 8px; align-items: center; font-size: 12px; color: var(--text-muted);">
                <time>{date_label(plan)}</time>
                <.effort_marker effort={plan.effort} />
                <.tag_marker :if={plan.tag} tag={plan.tag} />
                <.recap_marker plan={plan} />
                <a href={"/plans/files/#{plan.basename}.md"} style="font-size: 11px; color: var(--text-muted);">raw</a>
              </span>
            </li>
          </ul>
        </div>
      </.bucket_section>

      <.bucket_section
        :if={@superseded_count > 0}
        label="Superseded"
        count={@superseded_count}
        accent="var(--text-muted)"
      >
        <.flat_list plans={@superseded} />
      </.bucket_section>

      <.bucket_section
        :if={@deprecated_count > 0}
        label="Deprecated"
        count={@deprecated_count}
        accent="var(--text-muted)"
      >
        <.flat_list plans={@deprecated} />
      </.bucket_section>
    </div>
    """
  end

  # --- Flat list (used for non-shipped buckets) ---

  attr :plans, :list, required: true

  defp flat_list(assigns) do
    ~H"""
    <ul style="list-style: none; padding: 0;">
      <li
        :for={plan <- @plans}
        style="display: flex; gap: 12px; align-items: baseline; padding: 8px 0; border-top: 1px solid var(--border); flex-wrap: wrap;"
      >
        <a href={"/plans/#{plan.basename}"} style="flex: 1; min-width: 320px; font-weight: 500; text-decoration: none;">
          {plan.title}
        </a>
        <span style="display: flex; gap: 8px; align-items: center; font-size: 12px; color: var(--text-muted);">
          <time>{date_label(plan)}</time>
          <.effort_marker effort={plan.effort} />
          <.tag_marker :if={plan.tag} tag={plan.tag} />
          <a href={"/plans/files/#{plan.basename}.md"} style="font-size: 11px; color: var(--text-muted);">raw</a>
        </span>
      </li>
    </ul>
    """
  end

  # --- Function components ---

  defp effort_marker(%{effort: nil} = assigns), do: ~H""

  defp effort_marker(assigns) do
    tone =
      case effort_class(assigns.effort) do
        :small -> :green
        :medium -> :orange
        :large -> :red
        :other -> :neutral
      end

    assigns = assign(assigns, :tone, tone)

    ~H'<.badge tone={@tone} label={@effort} />'
  end

  defp tag_marker(assigns) do
    ~H'<.badge tone={:blue} label={@tag} />'
  end

  defp recap_marker(%{plan: %{has_recap?: false}} = assigns) do
    ~H'<span style="font-size: 10px; color: var(--text-muted); font-style: italic;">no recap</span>'
  end

  defp recap_marker(assigns) do
    ~H'<span style="font-size: 10px; color: var(--accent-green); font-weight: 600;">recap</span>'
  end

  # --- Helpers ---

  defp date_label(%{date: %Date{} = d}), do: Date.to_iso8601(d)
  defp date_label(_), do: "undated"

  defp effort_class(nil), do: :other

  defp effort_class(effort) do
    cond do
      effort =~ ~r/small/i -> :small
      effort =~ ~r/medium/i -> :medium
      effort =~ ~r/large/i -> :large
      true -> :other
    end
  end
end
