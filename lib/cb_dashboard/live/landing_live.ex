defmodule CBDashboard.LandingLive do
  @moduledoc """
  Trivial hardcoded landing for step 2 of the SOD build. Will be replaced in a
  later step with section cards showing live counts.
  """

  use Phoenix.LiveView

  import CBUI.Components

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
      <p style="margin-top: 24px; font-size: 12px; color: var(--text-muted);">
        Step 2 of the SOD build — endpoint is up, routes are stubs.
      </p>
    </section>
    """
  end

  defp sections do
    [
      %{path: "/plans", title: "Plans", note: "ops/plans — active and shipped (step 3)"},
      %{
        path: "/position",
        title: "Position",
        note: "ops/position — normative positions, per-claim DAG status"
      },
      %{path: "/runs", title: "Agent runs", note: "org/agents/runs (step 4)"},
      %{path: "/dag", title: "Belief DAG", note: "org/assertions (step 5)"},
      %{path: "/policy", title: "Policy", note: "derived from belief tags (step 6)"}
    ]
  end
end
