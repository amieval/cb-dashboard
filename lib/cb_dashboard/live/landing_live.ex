defmodule CBDashboard.LandingLive do
  @moduledoc """
  Landing for the graph viewer — a section index of the belief-graph surfaces.
  """

  use Phoenix.LiveView

  import CBDashboard.Components.UI

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :sections, sections())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section style="max-width: var(--maxw-narrow);">
      <div style="margin-bottom: 16px;">
        <.section_label>Sections</.section_label>
      </div>
      <ul style="list-style: none; display: grid; gap: 8px;">
        <li :for={section <- @sections} style="border: 1px solid var(--border); border-radius: 6px; padding: 12px 16px; background: var(--bg-secondary);">
          <a href={section.path} style="font-weight: 600;">{section.title}</a>
          <div style="font-size: 12px; color: var(--text-muted); margin-top: 4px;">{section.note}</div>
        </li>
      </ul>
    </section>
    """
  end

  defp sections do
    [
      %{
        path: "/dag",
        title: "Belief DAG",
        note: "the belief graph — navigable, with per-node context"
      },
      %{
        path: "/dag/proposals",
        title: "Mutations",
        note: "proposed graph mutations, reviewable per-mutation"
      },
      %{path: "/policy", title: "Policy", note: "derived from belief tags (deferred)"}
    ]
  end
end
