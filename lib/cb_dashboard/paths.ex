defmodule CBDashboard.Paths do
  @moduledoc """
  Configurable data roots for the dashboard, resolved at runtime (config -> env -> default).

  This replaces the upstream app's compile-time repo-root joins. The belief
  graph itself is read through `CB.Config.beliefs_path/0` (config `:cb, :beliefs_path`
  or `CB_BELIEFS`), which already defaults to the cb: framework's own graph - so the
  belief-DAG view needs no path config. The viewer's only `data_root`-relative
  source now is the proposals dir; the planning sources moved to plan-app.
  """

  @doc """
  Base dir for repo-relative dashboard data. Now backs only `proposals_dir/0`
  (the planning sources moved to plan-app).
  Config `:cb_dashboard, :data_root`, else `CB_DASHBOARD_DATA_ROOT`, else cwd.
  """
  def data_root do
    Application.get_env(:cb_dashboard, :data_root) ||
      System.get_env("CB_DASHBOARD_DATA_ROOT") ||
      File.cwd!()
  end

  @doc """
  Path to the user's graph **sources file** — the registries and standalone
  belief graphs the dashboard should load (see `CBDashboard.Sources.Graphs`).
  Config `:cb_dashboard, :sources_file`, else `CB_DASHBOARD_SOURCES`, else the
  repo-local `config/sources.local.json` (gitignored).

  The viewer ships with **no default path into anyone's data**: if this file is
  absent and no `CB_COLLECTIONS`/`CB_BELIEFS` env override is set, no graphs
  load until the user adds a source. `config/sources.example.json` documents the
  format.
  """
  def sources_file do
    Application.get_env(:cb_dashboard, :sources_file) ||
      System.get_env("CB_DASHBOARD_SOURCES") ||
      Path.expand("../../config/sources.local.json", __DIR__)
  end

  @doc "Directory holding DAG proposal manifests (`*.json`)."
  def proposals_dir, do: Path.join(data_root(), "ops/dag-proposals")

  @doc """
  Whether the dashboard's single write path (applying an approved DAG proposal:
  mutates the belief graph + git-commits) is enabled. Defaults to `false` so the
  dashboard is read-only unless a host explicitly opts in via
  `config :cb_dashboard, :enable_mutations, true`.
  """
  def mutations_enabled?, do: Application.get_env(:cb_dashboard, :enable_mutations, false)
end
