import Config

config :esbuild,
  version: "0.21.5",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" =>
        Path.expand("../deps", __DIR__) <> ":" <> Path.expand("../assets/node_modules", __DIR__)
    }
  ]

config :cb_dashboard, CBDashboard.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: CBDashboard.ErrorHTML], layout: false],
  pubsub_server: CBDashboard.PubSub,
  live_view: [signing_salt: "cb_dashboard_lv_salt"],
  secret_key_base:
    "dev-only-cb-dashboard-secret-key-base-that-is-at-least-sixty-four-bytes-long-ok"

config :phoenix, :json_library, Jason

# Map the `.jsonl` extension (Claude Code session transcripts) to text/plain so
# the `/transcripts/files` static mount renders them inline in the browser
# instead of forcing a download. `txt` is preserved alongside the default.
config :mime, :types, %{"text/plain" => ["txt", "jsonl"]}

import_config "#{config_env()}.exs"
