defmodule CBDashboard.Layouts do
  @moduledoc """
  Root layout for the Composable Beliefs dashboard. Dark-theme palette inlined.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Composable Beliefs — Dashboard</title>
        <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>📊</text></svg>" />
        <script defer phx-track-static src="/assets/app.js"></script>
        <%!-- Design tokens (:root vars) + base reset live in the shared
              cb_ui kit so the theme can't drift across apps. App-specific
              chrome stays in the <style> block below. --%>
        <CBUI.Theme.tokens />
        <style>
          .sod-header {
            padding: 14px 24px;
            border-bottom: 1px solid var(--border);
            background: var(--bg-secondary);
            display: flex;
            align-items: baseline;
            gap: 12px;
          }
          .sod-header h1 { font-size: 14px; font-weight: 600; }
          .sod-header h1 a { color: var(--text-primary); text-decoration: none; }
          .sod-header .tagline { font-size: 12px; color: var(--text-muted); }
          .sod-nav {
            display: flex;
            gap: 4px;
            margin-left: 16px;
          }
          .sod-nav-link {
            font-size: 13px;
            color: var(--text-secondary);
            text-decoration: none;
            padding: 14px 10px;
            margin-bottom: -15px;
            border-bottom: 2px solid transparent;
            line-height: 1;
          }
          .sod-nav-link:hover { color: var(--text-primary); }
          .sod-nav-link.is-active {
            color: var(--text-primary);
            border-bottom-color: var(--accent-blue);
          }
          .sod-main { padding: 24px; }

          /* Position-artifact additions to the .state palette and the
             new .flag palette for per-claim DAG-status pills. Labels are
             upcased at render time so this CSS doesn't need
             text-transform. Keep the .flag map in sync with the spec at
             ops/position/CLAUDE.md § Status vocabulary and with
             PositionsLive.status_tone/1. */
          /* `.state` base styles formerly lived inline in plan_live's
             <style> block, which meant non-plan views (position) saw
             the span without sizing/padding. Promoted here so any view
             that emits `<span class="state state--…">` gets a pill. */
          .state, .effort {
            font-size: 11px;
            font-weight: 600;
            letter-spacing: 0.06em;
            padding: 2px 8px;
            border-radius: 10px;
            font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          }
          .state--active     { background: var(--banner-bg-success); color: var(--accent-green); }
          .state--abandoned  { background: var(--bg-tertiary); color: var(--text-secondary); }
          .flag {
            font-size: 11px;
            font-weight: 600;
            letter-spacing: 0.06em;
            padding: 2px 8px;
            border-radius: 10px;
            font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          }
          .flag--represented     { background: var(--badge-bg-green); color: var(--accent-green); }
          .flag--partial         { background: var(--badge-bg-orange); color: var(--accent-orange); }
          .flag--aspirational    { background: var(--badge-bg-purple); color: var(--accent-purple); }
          .flag--not-represented { background: var(--badge-bg-red); color: var(--accent-red); }
          .flag--contradicted    { background: var(--badge-bg-red); color: var(--accent-red); }
          .flag--superseded      { background: var(--bg-tertiary); color: var(--text-secondary); }

          /* `.plan-prose` is the shared compiled-markdown container for
             plan + position views (and any future SOD document view
             that runs markdown through MDEx). Formerly defined inline
             in plan_live's <style>, which meant PositionLive's article
             tagged `class="plan-prose"` got no styling — body fell back
             to browser defaults (smaller font, tighter line-height) and
             read as cramped next to the plan view. Promoted here so
             every SOD prose view shares the same rhythm. Plan-specific
             chrome (tabs, status-banner, thread/session/turn) stays in
             plan_live. Effort sub-pills moved here alongside .state so
             prose docs that emit Effort badges work uniformly. */
          .plan-prose { font-size: 14.5px; line-height: 1.65; color: var(--text-primary); }
          .plan-prose h1 { font-size: 24px; font-weight: 600; margin: 0 0 16px; }
          .plan-prose h2 { font-size: 18px; font-weight: 600; margin: 28px 0 10px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }
          .plan-prose h3 { font-size: 15px; font-weight: 600; margin: 20px 0 8px; }
          .plan-prose h4 { font-size: 14px; font-weight: 600; margin: 16px 0 6px; color: var(--text-secondary); }
          .plan-prose p, .plan-prose ul, .plan-prose ol { margin: 0 0 14px; }
          .plan-prose ul, .plan-prose ol { padding-left: 26px; }
          .plan-prose li { margin: 4px 0; }
          .plan-prose blockquote { border-left: 3px solid var(--accent-blue); padding: 6px 14px; margin: 12px 0; color: var(--text-secondary); background: var(--bg-secondary); }
          .plan-prose code { background: var(--bg-tertiary); padding: 1px 6px; border-radius: 3px; font-size: 13px; }
          .plan-prose pre { background: var(--bg-secondary); border: 1px solid var(--border); border-radius: 6px; padding: 14px; overflow-x: auto; margin: 12px 0; }
          .plan-prose pre code { background: transparent; padding: 0; }
          .plan-prose table { border-collapse: collapse; margin: 12px 0; font-size: 13px; }
          .plan-prose th, .plan-prose td { border: 1px solid var(--border); padding: 6px 12px; text-align: left; }
          .plan-prose th { background: var(--bg-tertiary); }
          .plan-prose a { color: var(--accent-blue); }
          .plan-prose strong { color: var(--text-primary); font-weight: 600; }
          .plan-prose hr { border: none; border-top: 1px solid var(--border); margin: 24px 0; }
          .plan-prose .plan-link { text-decoration: none; }
          .plan-prose .plan-link code { color: var(--accent-blue); background: var(--overlay-blue-08); }
          .plan-prose .plan-link:hover code { background: var(--overlay-blue-18); }
          .effort--small  { background: var(--badge-bg-green); color: var(--accent-green); }
          .effort--medium { background: var(--badge-bg-orange); color: var(--accent-orange); }
          .effort--large  { background: var(--badge-bg-red); color: var(--accent-red); }
          .state--done       { background: var(--bg-tertiary); color: var(--text-secondary); }
          .state--pending    { background: var(--badge-bg-orange); color: var(--accent-orange); }
          .state--in-progress{ background: var(--banner-bg-success); color: var(--accent-green); }
          .state--paused     { background: var(--banner-bg-error); color: var(--accent-red); }
          .state--evaluate   { background: var(--badge-bg-purple); color: var(--accent-purple); }
          .state--evaluation { background: var(--badge-bg-purple); color: var(--accent-purple); }
          .state--superseded { background: var(--bg-tertiary); color: var(--text-secondary); }
          .state--deprecated { background: var(--bg-tertiary); color: var(--text-secondary); }

          /* Tab nav + Thread tab styling. Shared between PlanLive and
             PositionLive (and any future SOD doc view with a Thread tab).
             Formerly lived inline in plan_live's <style>; promoted here
             when PositionLive grew a Thread tab so both views could use
             the same component (CBDashboard.Components.Thread)
             without duplicating CSS. Class names retain the `.plan-tab`
             prefix for historical compatibility; functionally shared. */
          .plan-tabs { display: flex; gap: 0; border-bottom: 1px solid var(--border); margin-bottom: 18px; }
          .plan-tab { padding: 10px 16px; font-size: 13px; color: var(--text-secondary); text-decoration: none; border-bottom: 2px solid transparent; margin-bottom: -1px; }
          .plan-tab:hover { color: var(--text-primary); }
          .plan-tab.is-active { color: var(--text-primary); border-bottom-color: var(--accent-blue); }

          .thread-pane { display: flex; flex-direction: column; gap: 28px; }
          .thread-session { display: flex; flex-direction: column; gap: 12px; }
          .thread-session-head { font-size: 12px; color: var(--text-muted); display: flex; gap: 12px; align-items: baseline; flex-wrap: wrap; padding-bottom: 8px; border-bottom: 1px solid var(--border); }
          .thread-session-head .sid { font-family: ui-monospace, SFMono-Regular, monospace; color: var(--text-primary); font-size: 13px; }
          .thread-session-head .meta { font-variant-numeric: tabular-nums; }
          .thread-session-missing { padding: 12px 16px; border: 1px dashed var(--border); border-radius: 6px; color: var(--text-muted); font-size: 13px; }

          .thread-back { font-size: 12px; color: var(--text-muted); text-decoration: none; display: inline-block; margin-bottom: 16px; }
          .thread-back:hover { color: var(--text-primary); }
          .thread-back::before { content: "← "; }

          .session-picker { list-style: none; padding: 0; margin: 0; border: 1px solid var(--border); border-radius: 6px; background: var(--bg-secondary); overflow: hidden; }
          .session-picker li { border-bottom: 1px solid var(--border); }
          .session-picker li:last-child { border-bottom: none; }
          .session-picker a { display: flex; gap: 14px; align-items: baseline; padding: 12px 16px; text-decoration: none; color: var(--text-primary); flex-wrap: wrap; font-size: 13px; }
          .session-picker a:hover { background: var(--bg-tertiary); }
          .session-picker .sid { font-family: ui-monospace, SFMono-Regular, monospace; color: var(--text-primary); }
          .session-picker .date { font-variant-numeric: tabular-nums; color: var(--text-muted); font-size: 12px; min-width: 88px; }
          .session-picker .counts { color: var(--text-secondary); font-size: 12px; flex: 1; }
          .session-picker .arrow { color: var(--text-muted); font-size: 12px; }
          .session-picker a:hover .arrow { color: var(--accent-blue); }

          .turn { padding: 12px 16px; border-radius: 6px; border: 1px solid var(--border); background: var(--bg-secondary); }
          .turn--user { border-left: 3px solid var(--accent-blue); }
          .turn--assistant { border-left: 3px solid var(--accent-green); background: var(--bg-primary); }
          .turn-head { display: flex; gap: 12px; align-items: baseline; margin-bottom: 8px; font-size: 11px; }
          /* .turn-role: role_label returns an already-upcased string,
             so this class doesn't carry text-transform. */
          .turn-role { letter-spacing: 0.08em; font-weight: 600; color: var(--text-secondary); }
          .turn--user .turn-role { color: var(--accent-blue); }
          .turn--assistant .turn-role { color: var(--accent-green); }
          .turn-ts { color: var(--text-muted); font-family: ui-monospace, SFMono-Regular, monospace; }
          .turn-body { font-size: 13.5px; line-height: 1.6; color: var(--text-primary); }
          .turn-body > :first-child { margin-top: 0; }
          .turn-body > :last-child { margin-bottom: 0; }
          .turn-body p { margin: 0 0 10px; }
          .turn-body code { background: var(--bg-tertiary); padding: 1px 6px; border-radius: 3px; font-size: 12.5px; }
          .turn-body pre { background: var(--bg-tertiary); border: 1px solid var(--border); border-radius: 4px; padding: 10px 12px; overflow-x: auto; margin: 8px 0; font-size: 12.5px; }
          .turn-body pre code { background: transparent; padding: 0; }
          .turn-body blockquote { border-left: 3px solid var(--border); padding: 4px 12px; margin: 8px 0; color: var(--text-secondary); }
          .turn-body a { color: var(--accent-blue); }
          .turn-body .plan-link { text-decoration: none; }
          .turn-body .plan-link code { color: var(--accent-blue); background: var(--overlay-blue-08); }

          /* Hover-preview popup used by BeliefContext dep/citer cards and
             DagLive sidebar entries. Parent must be position:relative. */
          .bc-hover-parent { position: relative; }
          .bc-hover-popup {
            position: absolute;
            top: calc(100% + 4px);
            left: 0;
            min-width: 320px;
            max-width: 420px;
            width: max-content;
            padding: 10px 12px;
            background: var(--bg-primary);
            border: 1px solid var(--border);
            border-radius: 6px;
            box-shadow: 0 6px 18px rgba(0, 0, 0, 0.5);
            color: var(--text-primary);
            font-size: 12px;
            line-height: 1.45;
            opacity: 0;
            visibility: hidden;
            transition: opacity 100ms 200ms, visibility 0s 300ms;
            z-index: 100;
            pointer-events: none;
            text-align: left;
            white-space: normal;
          }
          .bc-hover-parent:hover .bc-hover-popup,
          .bc-hover-parent:focus-within .bc-hover-popup {
            opacity: 1;
            visibility: visible;
            transition: opacity 100ms 100ms, visibility 0s 100ms;
          }
          /* Sidebar variant: pop up to the LEFT of the dep card so the
             popup stays inside the viewport when the sidebar sits at the
             right edge. */
          .bc-hover-popup--left {
            left: auto;
            right: calc(100% + 6px);
            top: 0;
          }
          .bc-popup-row {
            display: flex;
            gap: 6px;
            align-items: center;
            flex-wrap: wrap;
            margin-bottom: 6px;
          }
          /* .bc-popup-badge removed — popup_card now renders each badge
             via <.badge>. */
          .bc-popup-claim {
            color: var(--text-secondary);
            margin-bottom: 6px;
          }
          .bc-popup-meta {
            font-size: 11px;
            color: var(--text-muted);
            display: flex;
            gap: 8px;
            flex-wrap: wrap;
            font-family: ui-monospace, SFMono-Regular, monospace;
          }
        </style>
      </head>
      <body>
        <header class="sod-header">
          <h1><a href="/">Beliefs</a></h1>
          <span class="tagline">Composable Beliefs Dashboard · DEV</span>
          <nav class="sod-nav">
            <%= for item <- nav_items() do %>
              <a
                href={item.path}
                class={"sod-nav-link" <> if(active?(@conn, item), do: " is-active", else: "")}
              >{item.label}</a>
            <% end %>
          </nav>
        </header>
        <main class="sod-main">{@inner_content}</main>
      </body>
    </html>
    """
  end

  defp nav_items do
    [
      %{label: "Plans", path: "/plans", prefix: "/plans"},
      %{label: "Positions", path: "/position", prefix: "/position"},
      %{label: "Runs", path: "/runs", prefix: "/runs"},
      %{label: "Beliefs", path: "/dag", prefix: "/dag", exclude_prefixes: ["/dag/proposals"]},
      %{label: "Mutations", path: "/dag/proposals", prefix: "/dag/proposals"},
      %{label: "Policies", path: "/policy", prefix: "/policy"}
    ]
  end

  defp active?(%{request_path: path}, %{prefix: prefix} = item) do
    excluded =
      item
      |> Map.get(:exclude_prefixes, [])
      |> Enum.any?(fn ex -> path == ex or String.starts_with?(path, ex <> "/") end)

    not excluded and (path == prefix or String.starts_with?(path, prefix <> "/"))
  end

  defp active?(_, _), do: false
end
