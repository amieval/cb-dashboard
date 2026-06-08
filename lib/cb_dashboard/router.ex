defmodule CBDashboard.Router do
  @moduledoc """
  Routes for the Composable Beliefs dashboard.

  Full observability surface: landing, plans, positions, runs, the belief DAG,
  DAG proposals (mutations), policies, and transcripts. `/dag/proposals` and
  `/dag/proposals/:slug` are declared before `/dag/:id` so the literal proposal
  routes win over the `:id` wildcard.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
    # fetch_query_params makes ?tab=... query strings reach LiveView mount /
    # handle_params on the initial HTTP load (tab views rely on it).
    plug :fetch_query_params
    plug :fetch_live_flash
    plug :put_root_layout, html: {CBDashboard.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", CBDashboard do
    pipe_through :browser

    live "/", LandingLive, :index
    live "/plans", PlansLive, :index
    live "/plans/:basename", PlanLive, :show
    live "/position", PositionsLive, :index
    live "/position/:basename", PositionLive, :show
    live "/runs", RunsLive, :index
    live "/dag", DagLive, :index
    live "/dag/proposals", DagProposalsLive, :index
    live "/dag/proposals/:slug", DagProposalLive, :show
    live "/dag/:id", DagLive, :show
    live "/policy", PolicyLive, :index
    live "/transcripts/:session_id", TranscriptLive, :show
  end
end
