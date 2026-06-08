defmodule CBDashboard.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: CBDashboard.PubSub},
      # Live-update poller: fingerprints the data sources and broadcasts on
      # CBDashboard.PubSub. Started before the endpoint so subscribers' first
      # render already reflects the current fingerprint baseline.
      CBDashboard.Watcher,
      CBDashboard.Endpoint
    ]

    opts = [strategy: :one_for_one, name: CBDashboard.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
