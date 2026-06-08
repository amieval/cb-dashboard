import Config

# Don't bind the HTTP listener or start asset watchers during tests; the suite
# exercises modules directly, not the running server.
config :cb_dashboard, CBDashboard.Endpoint, server: false
