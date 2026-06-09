defmodule CBDashboard.DagProposalsLive do
  @moduledoc """
  DAG proposal manifest list at `/dag/proposals`.

  Lists every manifest under `ops/dag-proposals/*.json`, sorted by `created`
  desc. Each row links to the per-proposal review at `/dag/proposals/:slug`
  and surfaces a status pill plus a per-status mutation count.

  Subscribes to `"proposals:changes"` so additions/edits re-render without
  a refresh.
  """

  use Phoenix.LiveView

  import CBUI.Components

  alias CBDashboard.Sources.Proposals

  @topic "proposals:changes"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(CBDashboard.PubSub, @topic)
    {:ok, assign_manifests(socket)}
  end

  @impl true
  def handle_info(:proposals_changed, socket), do: {:noreply, assign_manifests(socket)}

  defp assign_manifests(socket) do
    manifests = Proposals.list()

    assign(socket,
      manifests: manifests,
      total: length(manifests),
      error_count: Enum.count(manifests, &(&1.errors != []))
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: var(--maxw-list);">
      <.page_header title="DAG proposals">
        <:meta>
          <.count_chip count={@total} label="manifests" />
          <.badge :if={@error_count > 0} tone={:red} size={:md} label={"#{@error_count} malformed"} />
          <a href="/dag/proposals/files/SCHEMA.md" style="font-size: 11px;">schema</a>
        </:meta>
      </.page_header>

      <%= if @total == 0 do %>
        <.empty_state tone={:note}>
          No proposals yet. Manifests live under <code>ops/dag-proposals/*.json</code>.
        </.empty_state>
      <% else %>
        <.data_list variant={:bordered}>
          <:row :for={m <- @manifests}>
            <.manifest_row manifest={m} />
          </:row>
        </.data_list>
      <% end %>
    </div>
    """
  end

  # --- Function components ---

  attr :manifest, :map, required: true

  defp manifest_row(assigns) do
    counts = mutation_counts(assigns.manifest.mutations)
    has_errors? = assigns.manifest.errors != []
    assigns = assign(assigns, counts: counts, has_errors?: has_errors?)

    ~H"""
    <div style="display: flex; gap: 12px; align-items: baseline; flex-wrap: wrap;">
      <a
        href={"/dag/proposals/#{@manifest.slug}"}
        style="flex: 1; min-width: 320px; font-weight: 600; font-size: 14px; text-decoration: none; color: var(--text-primary);"
      >
        <%= @manifest.title || @manifest.slug %>
      </a>
      <span style="display: flex; gap: 8px; align-items: center; font-size: 12px; color: var(--text-muted); flex-wrap: wrap;">
        <.badge :if={@has_errors?} tone={:red} label={"#{length(@manifest.errors)} errors"} />
        <.badge tone={tone_for_proposal_status(@manifest.status)} label={@manifest.status} />
        <span style="font-family: ui-monospace, SFMono-Regular, monospace;">{date_label(@manifest.created)}</span>
        <span style="color: var(--text-muted);">·</span>
        <span title="total mutations">{length(@manifest.mutations)} mutations</span>
        <.numeric_chip :if={(@counts["pending"] || 0) > 0} tone={:orange} count={@counts["pending"]} label="pending" />
        <.numeric_chip :if={(@counts["applied"] || 0) > 0} tone={:green} count={@counts["applied"]} label="applied" />
        <.numeric_chip :if={(@counts["rejected"] || 0) > 0} tone={:red} count={@counts["rejected"]} label="rejected" />
        <.numeric_chip :if={(@counts["discuss"] || 0) > 0} tone={:blue} count={@counts["discuss"]} label="discuss" />
        <a href={"/dag/proposals/files/#{@manifest.slug}.json"} style="font-size: 11px; color: var(--text-muted);">json</a>
      </span>
    </div>
    """
  end

  defp tone_for_proposal_status("pending"), do: :orange
  defp tone_for_proposal_status("partial"), do: :blue
  defp tone_for_proposal_status("applied"), do: :green
  defp tone_for_proposal_status("rejected"), do: :red
  defp tone_for_proposal_status(_), do: :neutral

  defp mutation_counts(mutations) do
    Enum.frequencies_by(mutations, fn m -> m.status || "pending" end)
  end

  defp date_label(%Date{} = d), do: Date.to_iso8601(d)
  defp date_label(_), do: "undated"
end
