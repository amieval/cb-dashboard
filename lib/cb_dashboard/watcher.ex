defmodule CBDashboard.Watcher do
  @moduledoc """
  Watches the dashboard's filesystem sources for changes and broadcasts on
  `CBDashboard.PubSub` so the LiveViews can live-update.

  Polls every second using filesystem fingerprinting (mtime + size). Each source
  is fingerprinted independently so a change in one only wakes its own
  subscribers.

  ## Topics

  | Topic                  | Message                | Source                                   |
  |------------------------|------------------------|------------------------------------------|
  | `"plans:changes"`      | `:plans_changed`       | `Paths.plans_dir/*.md`                   |
  | `"positions:changes"`  | `:positions_changed`   | `Paths.positions_dir/*.md`               |
  | `"runs:changes"`       | `:runs_changed`        | `Paths.runs_dir/*.json`                  |
  | `"assertions:changes"` | `:assertions_changed`  | `CB.Config.beliefs_path()`               |
  | `"proposals:changes"`  | `:proposals_changed`   | `Paths.proposals_dir/*.json`             |

  Decoupled from the host: the host's `:org`/`inbox:changes` touring-data source
  and the legacy SSE `:refresh` back-compat (which served the old client-facing
  surface) are dropped — no dashboard view consumes them.
  """

  use GenServer

  alias CBDashboard.Paths

  @poll_interval 1_000

  # Source -> {topic, message_atom}. Glob/path is resolved per-source in
  # `resolve_globs/1` so every read goes through the configurable data root.
  @sources %{
    plans: {"plans:changes", :plans_changed},
    positions: {"positions:changes", :positions_changed},
    runs: {"runs:changes", :runs_changed},
    assertions: {"assertions:changes", :assertions_changed},
    proposals: {"proposals:changes", :proposals_changed}
  }

  # --- Public API ---

  @doc "Start the watcher GenServer as a linked process."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    fingerprints = Map.new(@sources, fn {source, _} -> {source, scan(source)} end)
    schedule_poll()
    {:ok, %{fingerprints: fingerprints}}
  end

  @impl true
  def handle_info(:poll, state) do
    {new_fps, changed} =
      Enum.reduce(@sources, {%{}, []}, fn {source, _spec}, {fps, changed} ->
        new_fp = scan(source)

        if new_fp != Map.get(state.fingerprints, source) do
          {Map.put(fps, source, new_fp), [source | changed]}
        else
          {Map.put(fps, source, Map.get(state.fingerprints, source)), changed}
        end
      end)

    Enum.each(changed, &broadcast/1)

    schedule_poll()
    {:noreply, %{state | fingerprints: new_fps}}
  end

  # --- Private ---

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp broadcast(source) do
    {topic, message} = Map.fetch!(@sources, source)
    Phoenix.PubSub.broadcast(CBDashboard.PubSub, topic, message)
  end

  # --- Scanning ---

  defp scan(source) do
    source
    |> resolve_globs()
    |> Enum.map(&stat/1)
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_globs(:plans) do
    Paths.plans_dir() |> Path.join("*.md") |> Path.wildcard()
  end

  defp resolve_globs(:positions) do
    Paths.positions_dir() |> Path.join("*.md") |> Path.wildcard()
  end

  defp resolve_globs(:runs) do
    Paths.runs_dir() |> Path.join("*.json") |> Path.wildcard()
  end

  defp resolve_globs(:assertions) do
    # Fingerprint every registered collection's beliefs.json plus the single
    # default graph, so an edit to any collection wakes the DAG view.
    [CB.Config.beliefs_path() | CBDashboard.Sources.Collections.belief_paths()]
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
  end

  defp resolve_globs(:proposals) do
    Paths.proposals_dir() |> Path.join("*.json") |> Path.wildcard()
  end

  defp stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {path, mtime, size}
      _ -> nil
    end
  end
end
