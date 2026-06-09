defmodule CBDashboard.Router do
  @moduledoc """
  Routes for the Composable Beliefs dashboard — the graph viewer.

  Surface: landing, the belief DAG, DAG proposals (mutations), and policies.
  `/dag/proposals` and `/dag/proposals/:slug` are declared before `/dag/:id` so
  the literal proposal routes win over the `:id` wildcard. The planning surfaces
  (plans/positions/runs/transcripts) live in the separate plan-app.
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
    live "/dag", DagLive, :index
    live "/dag/proposals", DagProposalsLive, :index
    live "/dag/proposals/:slug", DagProposalLive, :show
    live "/dag/:id", DagLive, :show
    # Namespaced (collection-scoped) DAG. `:namespace` is a collection name or
    # the reserved "all" (the global union). Declared after the literal
    # `/dag/...` routes so those win; `/c/...` can't collide with them.
    live "/c/:namespace/dag", DagLive, :index
    live "/c/:namespace/dag/:id", DagLive, :show
    live "/policy", PolicyLive, :index
  end
end
