defmodule CBDashboard.Paths do
  @moduledoc """
  Configurable data roots for the dashboard, resolved at runtime (config -> env -> default).

  This replaces the host app's compile-time `Louder.repo_root()` joins. The belief
  graph itself is read through `CB.Config.beliefs_path/0` (config `:cb, :beliefs_path`
  or `CB_BELIEFS`), which already defaults to the cb: framework's own graph - so the
  belief-DAG view needs no path config. The remaining sources (plans, positions, runs,
  proposals, transcripts) read under `data_root/` and `transcripts_root/`; they are
  wired in as those views are ported.
  """

  @doc """
  Base dir for repo-relative dashboard data (`ops/*`, `org/*`).
  Config `:cb_dashboard, :data_root`, else `CB_DASHBOARD_DATA_ROOT`, else cwd.
  """
  def data_root do
    Application.get_env(:cb_dashboard, :data_root) ||
      System.get_env("CB_DASHBOARD_DATA_ROOT") ||
      File.cwd!()
  end

  @doc """
  Directory holding the current project's Claude Code session transcripts
  (`<session-id>.jsonl` files).

  Config `:cb_dashboard, :transcripts_root`, else `CB_DASHBOARD_TRANSCRIPTS_ROOT`,
  else derived from `data_root/0`: Claude Code stores each project's transcripts
  under `~/.claude/projects/<encoded>`, where `<encoded>` is the absolute project
  path with `/` and `.` replaced by `-`. Deriving it means transcripts resolve
  out-of-the-box for the configured data root, with no extra config.
  """
  def transcripts_root do
    Application.get_env(:cb_dashboard, :transcripts_root) ||
      System.get_env("CB_DASHBOARD_TRANSCRIPTS_ROOT") ||
      default_transcripts_root()
  end

  defp default_transcripts_root do
    encoded = data_root() |> Path.expand() |> String.replace(["/", "."], "-")
    Path.expand("~/.claude/projects") |> Path.join(encoded)
  end

  @doc """
  Path to the belief-collections registry (`collections.json`): `namespace ->
  beliefs.json`. Config `:cb_dashboard, :collections_registry`, else
  `CB_COLLECTIONS`, else the `cb` framework's default
  (`CB.Collection.default_registry_path/0`). When the file is absent the DAG view
  falls back to the single graph at `CB.Config.beliefs_path/0`.
  """
  def collections_registry do
    Application.get_env(:cb_dashboard, :collections_registry) ||
      System.get_env("CB_COLLECTIONS") ||
      CB.Collection.default_registry_path()
  end

  def plans_dir, do: Path.join(data_root(), "ops/plans")
  def positions_dir, do: Path.join(data_root(), "ops/position")
  def runs_dir, do: Path.join(data_root(), "org/agents/runs")
  def proposals_dir, do: Path.join(data_root(), "ops/dag-proposals")

  @doc """
  Whether the dashboard's single write path (applying an approved DAG proposal:
  mutates the belief graph + git-commits) is enabled. Defaults to `false` so the
  dashboard is read-only unless a host explicitly opts in via
  `config :cb_dashboard, :enable_mutations, true`.
  """
  def mutations_enabled?, do: Application.get_env(:cb_dashboard, :enable_mutations, false)
end
