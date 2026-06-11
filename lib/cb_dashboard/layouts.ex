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
        <%!-- Design tokens (:root vars) + base reset, inlined. Kept app-local
              (no shared UI dependency) so cb-dashboard distributes standalone.
              App-specific chrome stays in the <style> block below. --%>
        <style>
          :root {
            /* Base palette. */
            --bg-primary: #0d1117;
            --bg-secondary: #161b22;
            --bg-tertiary: #21262d;
            --border: #30363d;
            --text-primary: #e6edf3;
            --text-secondary: #8b949e;
            --text-muted: #6e7681;
            --accent-blue: #58a6ff;
            --accent-green: #3fb950;
            --accent-orange: #d29922;
            --accent-red: #f85149;
            --accent-purple: #bc8cff;
            --badge-bg-green: #1b2e22;
            --badge-bg-orange: #2e2818;
            --badge-bg-red: #2e1818;
            --badge-bg-purple: #2a1f33;
            --badge-bg-blue: #1c2734;
            --badge-bg-neutral: var(--bg-tertiary);
            --banner-bg-success: #0f2417;
            --banner-bg-error: #2a1414;
            --overlay-orange-08: rgba(210, 153, 34, 0.08);
            --overlay-orange-12: rgba(210, 153, 34, 0.12);
            --overlay-blue-08: rgba(88, 166, 255, 0.08);
            --overlay-blue-18: rgba(88, 166, 255, 0.18);
            --overlay-green-08: rgba(63, 185, 80, 0.08);
            --overlay-red-08: rgba(248, 81, 73, 0.08);
            --kind-primitive: var(--accent-blue);
            --kind-compound: var(--accent-purple);
            --kind-inference: #39c5cf;
            --kind-directive: var(--accent-orange);
            --kind-contract: var(--accent-green);
            --kind-default: var(--text-muted);
            --maxw-narrow: 720px;
            --maxw-prose: 880px;
            --maxw-list: 1020px;
          }
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            min-height: 100vh;
          }
          a { color: var(--accent-blue); }
          button:focus-visible,
          a:focus-visible {
            outline: 2px solid var(--accent-blue);
            outline-offset: 2px;
          }
        </style>
        <style>
          .app-header {
            padding: 14px 24px;
            border-bottom: 1px solid var(--border);
            background: var(--bg-secondary);
            display: flex;
            align-items: baseline;
            gap: 12px;
          }
          .app-header h1 { font-size: 14px; font-weight: 600; }
          .app-header h1 a { color: var(--text-primary); text-decoration: none; }
          .app-header .tagline { font-size: 12px; color: var(--text-muted); }
          .app-nav {
            display: flex;
            gap: 4px;
            margin-left: 16px;
          }
          .app-nav-link {
            font-size: 13px;
            color: var(--text-secondary);
            text-decoration: none;
            padding: 14px 10px;
            margin-bottom: -15px;
            border-bottom: 2px solid transparent;
            line-height: 1;
          }
          .app-nav-link:hover { color: var(--text-primary); }
          .app-nav-link.is-active {
            color: var(--text-primary);
            border-bottom-color: var(--accent-blue);
          }
          .app-main { padding: 24px; }

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
        <header class="app-header">
          <h1><a href="/">Beliefs</a></h1>
          <span class="tagline">Composable Beliefs Dashboard · DEV</span>
          <nav class="app-nav">
            <%= for item <- nav_items() do %>
              <a
                href={item.path}
                class={"app-nav-link" <> if(active?(@conn, item), do: " is-active", else: "")}
              >{item.label}</a>
            <% end %>
          </nav>
        </header>
        <main class="app-main">{@inner_content}</main>
      </body>
    </html>
    """
  end

  defp nav_items do
    [
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
