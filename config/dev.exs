import Config

config :cb_dashboard, CBDashboard.Endpoint,
  # Port defaults to 4001 (the SOD's canonical port); override via CB_DASHBOARD_PORT
  # so the dashboard can run beside the still-live louder SOD during the cutover.
  http: [
    ip: {127, 0, 0, 1},
    port: String.to_integer(System.get_env("CB_DASHBOARD_PORT") || "4001")
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]}
  ]
