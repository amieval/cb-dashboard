defmodule CBDashboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :cb_dashboard,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # Phoenix 1.8 routes code-reload notifications through the Mix listener
      # system; without this the dev server warns on every recompile.
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {CBDashboard.Application, []}
    ]
  end

  defp aliases do
    [
      "assets.build": ["esbuild default"],
      "assets.deploy": ["esbuild default --minify"]
    ]
  end

  defp deps do
    [
      # The framework provides the belief layer (CB.Belief.*) + CB.JSON / CB.Config.
      {:cb, path: "../composable-beliefs"},
      # Shared UI kit: design tokens (CBUI.Theme) + function components
      # (CBUI.Components). Path dep so the design system can't drift across apps.
      {:cb_ui, path: "../cb_ui"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.0"},
      {:mdex, "~> 0.11"},
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev}
    ]
  end
end
