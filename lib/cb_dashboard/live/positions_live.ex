defmodule CBDashboard.PositionsLive do
  @moduledoc """
  Position board — declared normative positions whose realization is
  queryable against the belief DAG per claim.

  Reads from `ops/position/*.md` via `Sources.Positions`. Renders one
  row per artifact with title, status, authored date, and a per-claim
  flag tally (e.g. `7 not-represented / 1 partial`). The full per-claim
  detail view + live-DAG join lands as part of
  `ops/plans/2026-05-17-position-mechanics.md`; this is the initial
  list-only surface so the heading exists in the dashboard.

  Subscribes to `"positions:changes"` on `CBDashboard.PubSub`.
  """

  use Phoenix.LiveView

  import CBDashboard.Components.UI

  alias CBDashboard.Sources.Positions

  @topic "positions:changes"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(CBDashboard.PubSub, @topic)
    {:ok, assign_positions(socket)}
  end

  @impl true
  def handle_info(:positions_changed, socket), do: {:noreply, assign_positions(socket)}

  defp assign_positions(socket) do
    %{active: active, superseded: superseded, abandoned: abandoned} = Positions.list()

    socket
    |> assign(:active, active)
    |> assign(:superseded, superseded)
    |> assign(:abandoned, abandoned)
    |> assign(:active_count, length(active))
    |> assign(:superseded_count, length(superseded))
    |> assign(:abandoned_count, length(abandoned))
    |> assign(:claim_tally, Positions.claim_tally(active))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: var(--maxw-list);">
      <.page_header title="Position">
        <:meta>
          <.count_chip count={@active_count} label="active" />
          <.count_chip :if={@superseded_count > 0} count={@superseded_count} label="superseded" />
          <.count_chip :if={@abandoned_count > 0} count={@abandoned_count} label="abandoned" />
        </:meta>
      </.page_header>

      <p style="font-size: 12px; color: var(--text-muted); margin: -4px 0 16px;">
        Declared normative positions. Each artifact's claims map to DAG beliefs;
        the per-claim flags below are <em>declared</em> values from the markdown
        (no live join yet — see <a href="/plans/2026-05-17-position-mechanics">2026-05-17-position-mechanics</a>).
      </p>

      <.bucket_section
        :if={@active_count > 0}
        label="Active"
        count={@active_count}
        accent="var(--accent-green)"
        open
      >
        <.position_list positions={@active} />
      </.bucket_section>

      <.bucket_section
        :if={@superseded_count > 0}
        label="Superseded"
        count={@superseded_count}
        accent="var(--text-muted)"
      >
        <.position_list positions={@superseded} />
      </.bucket_section>

      <.bucket_section
        :if={@abandoned_count > 0}
        label="Abandoned"
        count={@abandoned_count}
        accent="var(--text-muted)"
      >
        <.position_list positions={@abandoned} />
      </.bucket_section>

      <p :if={@active_count == 0 and @superseded_count == 0 and @abandoned_count == 0} style="color: var(--text-muted); font-size: 13px;">
        No position artifacts yet.
      </p>
    </div>
    """
  end

  # --- Function components ---

  attr :positions, :list, required: true

  defp position_list(assigns) do
    ~H"""
    <ul style="list-style: none; padding: 0;">
      <li
        :for={pos <- @positions}
        style="display: flex; gap: 12px; align-items: baseline; padding: 10px 0; border-top: 1px solid var(--border); flex-wrap: wrap;"
      >
        <a href={"/position/#{pos.basename}"} style="flex: 1; min-width: 320px; font-weight: 500; text-decoration: none;">
          {pos.title}
        </a>
        <span style="display: flex; gap: 8px; align-items: center; font-size: 12px; color: var(--text-muted); flex-wrap: wrap;">
          <time :if={pos.authored}>{Date.to_iso8601(pos.authored)}</time>
          <span style="font-size: 11px;">{length(pos.claims)} claims</span>
          <.claim_flags claims={pos.claims} />
          <a href={"/position/files/#{pos.basename}.md"} style="font-size: 11px; color: var(--text-muted);">raw</a>
        </span>
      </li>
    </ul>
    """
  end

  attr :claims, :list, required: true

  defp claim_flags(assigns) do
    tally = Enum.frequencies_by(assigns.claims, &(&1.declared_status || "unmarked"))

    assigns = assign(assigns, :tally, tally)

    ~H"""
    <span style="display: inline-flex; gap: 4px;">
      <.badge :for={{status, n} <- @tally} tone={status_tone(status)} label={"#{n} #{status}"} />
    </span>
    """
  end

  # Map status flag → badge tone. Keep in sync with the spec at
  # `ops/position/CLAUDE.md` § Status vocabulary.
  defp status_tone("represented"), do: :green
  defp status_tone("partial"), do: :orange
  defp status_tone("aspirational"), do: :purple
  defp status_tone("not-represented"), do: :red
  defp status_tone("superseded"), do: :neutral
  defp status_tone("contradicted"), do: :red
  defp status_tone(_), do: :neutral
end
