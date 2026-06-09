import Config

config :cb_dashboard, CBDashboard.Endpoint,
  # Port defaults to 4001; override via CB_DASHBOARD_PORT (e.g. to run beside
  # plan-app on 4002).
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
