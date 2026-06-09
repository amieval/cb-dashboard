defmodule CBDashboard.PolicyLive do
  @moduledoc """
  Placeholder for the deferred `/policy` view.

  The real view is blocked on DAG-side policy categorization work (the
  `dag-policy-categorization` plan). Replace this module when that ships.
  """

  use Phoenix.LiveView

  import CBDashboard.Components.UI

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: var(--maxw-narrow);">
      <.page_header title="Policy — deferred" />
      <p style="font-size: 14px; color: var(--text-secondary); margin-bottom: 16px;">
        The <code>/policy</code> LiveView is blocked on a prerequisite: the DAG's policy
        categorization needs to be made consistent before any view can render it honestly.
      </p>

      <.empty_state tone={:deferred} title="What's missing">
        <ul style="font-size: 13px; line-height: 1.7; padding-left: 18px; color: var(--text-primary);">
          <li><code>kind: "policy"</code> is applied to 18 beliefs without a defined inclusion principle.</li>
          <li>The <code>implication:</code> field leaks onto 43 <code>type: "compound"</code> nodes — schema contamination.</li>
          <li>The <code>*-policy</code> tag convention is used on only 2 nodes — half-formed.</li>
        </ul>
      </.empty_state>

      <div style="margin-top: 16px; font-size: 13px; color: var(--text-secondary);">
        Prerequisite: the <code style="font-family: ui-monospace, SFMono-Regular, monospace;">dag-policy-categorization</code>
        plan (tracked in plan-app).
      </div>
    </div>
    """
  end
end
