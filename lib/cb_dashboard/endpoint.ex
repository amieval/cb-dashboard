defmodule CBDashboard.Endpoint do
  @moduledoc """
  Phoenix endpoint for the Composable Beliefs dashboard. Localhost-only, port 4001.

  Serves bundled JS at `/assets`, the LiveView socket, and the proposals
  raw-file static mount. That mount resolves its `from:` at runtime via a
  `CBDashboard.Paths` MFA tuple (`Plug.Static` applies `{mod, fun, args}` per
  request) rather than a compile-time repo-root join, so it honors the
  configurable data root.
  """

  use Phoenix.Endpoint, otp_app: :cb_dashboard

  @session_options [
    store: :cookie,
    key: "_cb_dashboard_key",
    signing_salt: "cb_dashboard_nav_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/assets",
    from: {:cb_dashboard, "priv/static/assets"},
    gzip: false

  # Raw proposal manifests. `from:` is a {module, function, args} MFA tuple,
  # which Plug.Static resolves at request time — so the path tracks the runtime
  # data root rather than a compile-time literal.
  plug Plug.Static,
    at: "/dag/proposals/files",
    from: {CBDashboard.Paths, :proposals_dir, []},
    gzip: false

  # Phoenix.CodeReloader must be plugged for `code_reloader: true` (config/dev.exs)
  # to take effect.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.Session, @session_options
  plug CBDashboard.Router
end
