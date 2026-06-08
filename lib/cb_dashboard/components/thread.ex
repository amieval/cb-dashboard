defmodule CBDashboard.Components.Thread do
  @moduledoc """
  Shared Thread-tab infrastructure for SOD document views (PlanLive,
  PositionLive, and any future view that surfaces session transcripts
  alongside a markdown artifact).

  Provides:

  - `parse_session_ids/1` — scan markdown for `/transcripts/<uuid>` URLs.
    Used to populate the Thread tab's session list. Called against the
    full artifact (plan body + recap, or position body) so authoring-
    session (creation-time) and execution-session (completion-time)
    references both surface.
  - `load_sessions/1` — given a list of session UUIDs, hydrate them
    via `CBDashboard.Sources.Transcripts.rendered/1`.
  - `thread_view/1` (function component) — three render modes:
      * selected session id in URL → just that session + back link
      * exactly one session → render inline (no picker)
      * 2+ sessions → compact list (click expands one)
  - `session/1` (function component) — full transcript render for one
    session, including head metadata and turn list.

  CSS for the thread/turn/session-picker rules lives in
  `CBDashboard.Layouts` so any view using the components gets
  the styling without duplicating the rules.

  Parameterization: the components take `base_path` (e.g. `"/plans"`
  or `"/position"`) so per-session deep-link URLs route back to the
  parent view's `?tab=thread&session=...` patch.
  """

  use Phoenix.Component

  alias CBDashboard.Sources.Transcripts

  # --- Public functions ---

  @doc """
  Scan markdown for `/transcripts/<uuid>` URLs and return the deduped
  list of session UUIDs found. Designed to be called against the
  combined plan body + recap (or any markdown that may contain session
  references in either authoring or execution context).
  """
  def parse_session_ids(md) when is_binary(md) do
    Regex.compile!("/transcripts/([0-9a-f-]{36})")
    |> Regex.scan(md)
    |> Enum.map(fn [_, sid] -> sid end)
    |> Enum.uniq()
  end

  def parse_session_ids(_), do: []

  @doc """
  Hydrate session UUIDs into rendered transcripts.

  Returns a list of maps: `%{id: sid, found?: true, turns: [...], summary: %{...}}`
  for hits; `%{id: sid, found?: false}` for misses (transcript file pruned
  or session id wrong).
  """
  def load_sessions(ids) when is_list(ids) do
    Enum.map(ids, fn sid ->
      case Transcripts.rendered(sid) do
        {:ok, turns, summary} ->
          %{id: sid, found?: true, turns: turns, summary: summary}

        {:error, _} ->
          %{id: sid, found?: false}
      end
    end)
  end

  # --- Tab normalization helper (shared between PlanLive/PositionLive) ---

  @doc """
  Normalize the `?tab=` query param into a valid tab key, with a sane
  default when the selected tab's data is empty.

  `tab` is the incoming param (nil or a string); `default` is the tab
  to fall back to; `available` is a map `%{tab_name => has_data?}` for
  the tabs other than `default`. If the requested tab is unavailable,
  falls back to `default`.
  """
  def normalize_tab(nil, default, _available), do: default

  def normalize_tab(tab, default, available) when is_binary(tab) do
    cond do
      tab == default -> tab
      Map.get(available, tab) == true -> tab
      true -> default
    end
  end

  def normalize_tab(_, default, _), do: default

  @doc """
  Normalize the `?session=` query param against the known session-id list.
  Returns the sid if it's in the list, nil otherwise.
  """
  def normalize_session_param(nil, _), do: nil

  def normalize_session_param(sid, ids) when is_binary(sid) and is_list(ids) do
    if sid in ids, do: sid, else: nil
  end

  def normalize_session_param(_, _), do: nil

  # --- Thread tab dispatch (function component) ---

  attr :sessions, :list, required: true
  attr :selected, :string, default: nil
  attr :base_path, :string, required: true
  attr :basename, :string, required: true

  @doc """
  Render the Thread tab in one of three modes (see module doc).
  """
  def thread_view(%{selected: sid} = assigns) when not is_nil(sid) do
    found = Enum.find(assigns.sessions, fn s -> s.id == sid end)
    assigns = assign(assigns, :found, found)

    ~H"""
    <.link patch={"#{@base_path}/#{@basename}?tab=thread"} class="thread-back">back to threads</.link>
    <%= if @found do %>
      <.session session={@found} />
    <% else %>
      <p style="color: var(--text-muted); font-size: 13px;">Session not found.</p>
    <% end %>
    """
  end

  def thread_view(%{sessions: [single]} = assigns) do
    assigns = assign(assigns, :single, single)

    ~H"""
    <.session session={@single} />
    """
  end

  def thread_view(assigns) do
    ~H"""
    <ul class="session-picker">
      <li :for={s <- @sessions}>
        <.link patch={"#{@base_path}/#{@basename}?tab=thread&session=#{s.id}"}>
          <span class="sid">{short(s.id)}…</span>
          <span class="date">{format_date(s)}</span>
          <span class="counts">
            <%= if s.found? do %>
              <strong>{s.summary.user_turns}</strong> user ·
              <strong>{s.summary.assistant_turns}</strong> claude
            <% else %>
              transcript not found
            <% end %>
          </span>
          <span class="arrow">→</span>
        </.link>
      </li>
    </ul>
    """
  end

  # --- Single-session render (expanded view) ---

  attr :session, :map, required: true

  def session(%{session: %{found?: false}} = assigns) do
    ~H"""
    <div class="thread-session">
      <div class="thread-session-head">
        <span class="sid">{short(@session.id)}…</span>
        <span class="meta">transcript file not found</span>
      </div>
      <p class="thread-session-missing">
        No JSONL at <code>~/.claude/projects/.../{@session.id}.jsonl</code> — the session
        file may have been pruned or the id is wrong.
      </p>
    </div>
    """
  end

  def session(assigns) do
    ~H"""
    <div class="thread-session">
      <div class="thread-session-head">
        <span class="sid">{short(@session.id)}…</span>
        <span class="meta">
          <strong>{@session.summary.user_turns}</strong> user ·
          <strong>{@session.summary.assistant_turns}</strong> claude
        </span>
        <a href={"/transcripts/#{@session.id}"} style="font-size: 11px;">open standalone</a>
        <span>·</span>
        <a href={"/transcripts/files/#{@session.id}.jsonl"} style="font-size: 11px;">raw jsonl</a>
      </div>
      <div :for={turn <- @session.turns} class={"turn turn--" <> Atom.to_string(turn.role)}>
        <div class="turn-head">
          <span class="turn-role">{role_label(turn.role)}</span>
          <time class="turn-ts">{format_ts(turn.timestamp)}</time>
        </div>
        <div class="turn-body">{Phoenix.HTML.raw(turn.html)}</div>
      </div>
    </div>
    """
  end

  # --- Tab link function component ---

  attr :patch, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  @doc """
  Tab link used in the tab nav row. Adds `.is-active` when selected.
  """
  def tab_link(assigns) do
    ~H"""
    <.link patch={@patch} class={"plan-tab" <> if(@active, do: " is-active", else: "")}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # --- Helpers ---

  defp short(id), do: String.slice(id, 0, 8)

  # Pre-upcased so .turn-role can drop `text-transform: uppercase`.
  defp role_label(:user), do: "USER"
  defp role_label(:assistant), do: "CLAUDE"

  defp format_ts(nil), do: "—"

  defp format_ts(%DateTime{} = dt) do
    dt |> DateTime.to_iso8601() |> String.replace("T", " ") |> String.slice(0, 19)
  end

  defp format_date(%{found?: true, turns: [%{timestamp: %DateTime{} = dt} | _]}) do
    dt |> DateTime.to_date() |> Date.to_iso8601()
  end

  defp format_date(_), do: ""
end
