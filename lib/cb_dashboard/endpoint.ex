defmodule CBDashboard.Endpoint do
  @moduledoc """
  Phoenix endpoint for the Composable Beliefs dashboard. Localhost-only, port 4001.

  Serves bundled JS at `/assets`, the LiveView socket, and five raw-file static
  mounts (plans/position/runs/proposals/transcripts). The raw-file mounts resolve
  their `from:` at runtime via `CBDashboard.Paths` MFA tuples (`Plug.Static`
  applies `{mod, fun, args}` per request) instead of the host's compile-time
  `repo_root` joins, so they honor the configurable data root.
  """

  use Phoenix.Endpoint, otp_app: :cb_dashboard

  @session_options [
    store: :cookie,
    key: "_cb_dashboard_key",
    signing_salt: "cb_dashboard_nav_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/assets",
    from: {:cb_dashboard, "priv/static/assets"},
    gzip: false

  # Raw-file mounts. `from:` is a {module, function, args} MFA tuple, which
  # Plug.Static resolves at request time — so each path tracks the runtime data
  # root rather than a compile-time literal.
  plug Plug.Static,
    at: "/plans/files",
    from: {CBDashboard.Paths, :plans_dir, []},
    gzip: false

  plug Plug.Static,
    at: "/position/files",
    from: {CBDashboard.Paths, :positions_dir, []},
    gzip: false

  plug Plug.Static,
    at: "/runs/files",
    from: {CBDashboard.Paths, :runs_dir, []},
    gzip: false

  plug Plug.Static,
    at: "/dag/proposals/files",
    from: {CBDashboard.Paths, :proposals_dir, []},
    gzip: false

  # Raw Claude Code session transcripts. The directory lives outside the data
  # root and isn't committed; the plug just exposes the live files. `.jsonl` is
  # mapped to text/plain via `config :mime` (config/config.exs) so the browser
  # renders it inline instead of forcing a download.
  plug Plug.Static,
    at: "/transcripts/files",
    from: {CBDashboard.Paths, :transcripts_root, []},
    gzip: false

  # Phoenix.CodeReloader must be plugged for `code_reloader: true` (config/dev.exs)
  # to take effect.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.Session, @session_options
  plug CBDashboard.Router
end
