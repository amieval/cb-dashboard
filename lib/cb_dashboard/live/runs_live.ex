defmodule CBDashboard.RunsLive do
  @moduledoc """
  Agent runs board — grouped by day, newest first.

  Subscribes to `"runs:changes"` on `CBDashboard.PubSub`. The watcher broadcasts
  `:runs_changed` on any add/modify/delete under `org/agents/runs/`.
  """

  use Phoenix.LiveView

  import CBUI.Components

  alias CBDashboard.Sources.Runs

  @topic "runs:changes"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(CBDashboard.PubSub, @topic)
    {:ok, assign_runs(socket)}
  end

  @impl true
  def handle_info(:runs_changed, socket), do: {:noreply, assign_runs(socket)}

  defp assign_runs(socket) do
    runs = Runs.list()

    socket
    |> assign(:runs_by_day, Runs.by_day(runs))
    |> assign(:counts, Runs.status_counts(runs))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: var(--maxw-list);">
      <.page_header title="Agent runs">
        <:meta>
          <.count_chip count={@counts.total} label="runs" />
          <.run_status :if={(@counts["needs-review"] || 0) > 0} status="needs-review" count={@counts["needs-review"]} />
          <.run_status :if={(@counts["running"] || 0) > 0} status="running" count={@counts["running"]} />
          <.run_status :if={(@counts["failed"] || 0) > 0} status="failed" count={@counts["failed"]} />
        </:meta>
      </.page_header>
      <p style="font-size: 12px; color: var(--text-muted); margin-bottom: 16px;">
        A run exists when an agent touches the outside world. Click a row to open the per-run detail HTML.
      </p>

      <div :for={{day, items} <- @runs_by_day} style="margin-bottom: 16px;">
        <h3 style="font-size: 11px; color: var(--text-muted); margin: 12px 0 6px; font-family: ui-monospace, SFMono-Regular, monospace;">
          {day}
        </h3>
        <.data_list variant={:bordered}>
          <:row :for={run <- items}>
            <div style="display: flex; gap: 12px; align-items: baseline; flex-wrap: wrap;">
              <.run_link run={run} />
              <span style="display: flex; gap: 8px; align-items: center; font-size: 12px; color: var(--text-muted);">
                <span style="background: var(--bg-tertiary); padding: 2px 8px; border-radius: 10px; font-size: 11px;">
                  {run.agent || "unknown"}
                </span>
                <time>{duration_label(run.duration_s)}</time>
                <.run_status :if={run.status} status={run.status} />
                <span :if={run.alert_count > 0} style="font-size: 11px; color: var(--accent-orange); font-weight: 600;">
                  {run.alert_count} alert{if run.alert_count != 1, do: "s"}
                </span>
                <a href={"/runs/files/#{run.id}.json"} style="font-size: 11px; color: var(--text-muted);">json</a>
              </span>
            </div>
          </:row>
        </.data_list>
      </div>
    </div>
    """
  end

  # --- Function components ---

  defp run_link(%{run: %{detail_relpath: nil, id: id}} = assigns) do
    assigns = assign(assigns, id: id)

    ~H"""
    <span style="flex: 1; min-width: 280px; font-family: ui-monospace, SFMono-Regular, monospace; font-weight: 500;">
      {@id}
    </span>
    """
  end

  defp run_link(%{run: %{id: id, detail_relpath: rel}} = assigns) do
    assigns = assign(assigns, id: id, rel: rel)

    ~H"""
    <a href={"/runs/files/#{@rel}"} style="flex: 1; min-width: 280px; font-family: ui-monospace, SFMono-Regular, monospace; font-weight: 500; text-decoration: none;">
      {@id}
    </a>
    """
  end

  attr :status, :string, required: true
  attr :count, :integer, default: nil

  defp run_status(%{status: nil} = assigns), do: ~H""

  defp run_status(assigns) do
    label =
      case assigns.count do
        nil -> assigns.status
        0 -> nil
        n -> "#{n} #{assigns.status}"
      end

    assigns =
      assign(assigns,
        tone: tone_for_run_status(assigns.status),
        label: label
      )

    ~H'<.badge :if={@label} tone={@tone} size={:md} label={@label} />'
  end

  defp tone_for_run_status("completed"), do: :green
  defp tone_for_run_status("needs-review"), do: :orange
  defp tone_for_run_status("running"), do: :blue
  defp tone_for_run_status("failed"), do: :red
  defp tone_for_run_status(_), do: :neutral

  # --- Helpers ---

  defp duration_label(nil), do: "—"

  defp duration_label(seconds) when is_float(seconds) do
    cond do
      seconds < 60 -> "#{:erlang.float_to_binary(seconds, decimals: 1)}s"
      seconds < 3600 -> "#{Float.round(seconds / 60, 1)}m"
      true -> "#{Float.round(seconds / 3600, 1)}h"
    end
  end
end
