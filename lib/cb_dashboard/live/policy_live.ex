defmodule CBDashboard.PolicyLive do
  @moduledoc """
  Placeholder for the deferred `/policy` view (SOD plan step 6).

  The real view is blocked on DAG-side policy categorization work tracked in
  `ops/plans/2026-05-15-dag-policy-categorization.md`. Replace this module
  when that plan ships.
  """

  use Phoenix.LiveView

  import CBUI.Components

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
        Prerequisite plan:
        <a href="/plans/2026-05-15-dag-policy-categorization" style="font-family: ui-monospace, SFMono-Regular, monospace;">
          2026-05-15-dag-policy-categorization.md
        </a>
      </div>

      <p style="font-size: 12px; color: var(--text-muted); margin-top: 16px;">
        The deferral is recorded in the SOD plan's status block and in
        <a href="/plans/2026-05-16-system-observability-dashboard">the SOD plan</a> (recap appended).
      </p>
    </div>
    """
  end
end
