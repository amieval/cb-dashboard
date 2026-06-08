defmodule CBDashboard.ErrorHTML do
  @moduledoc """
  Minimal error view (replaces the borrowed `LouderWeb.ErrorHTML`).
  Renders the bare status message - e.g. "Not Found", "Internal Server Error".
  """
  use Phoenix.Component

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
