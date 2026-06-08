defmodule CBDashboard.DagLive do
  use Phoenix.LiveView

  import CBDashboard.Components.UI

  alias CB.Belief
  alias CB.Belief.{Store, Graph}
  alias CBDashboard.Components.BeliefContext

  @topic "assertions:changes"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CBDashboard.PubSub, @topic)
    end

    assertions = load_data()
    index = Graph.index(assertions)
    stats = Graph.stats(assertions)

    socket =
      socket
      |> assign(:assertions, assertions)
      |> assign(:index, index)
      |> assign(:stats, stats)
      |> assign(:selected, nil)
      |> assign(:selected_deps, [])
      |> assign(:selected_dependents, [])
      |> assign(:filters, %{type: nil, kind: nil, contract: nil, status: "active"})
      |> assign(:search, "")
      |> assign(:available_kinds, compute_kinds(assertions))
      |> assign(:view_mode, :graph)

    socket =
      if connected?(socket) do
        filtered = apply_filters(assertions, socket.assigns.filters, "")
        push_graph_data(socket, filtered)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Map.get(socket.assigns.index, id) do
      nil -> {:noreply, socket}
      assertion -> {:noreply, select_node(socket, assertion)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_node", %{"id" => id}, socket) do
    case Map.get(socket.assigns.index, id) do
      nil -> {:noreply, socket}
      assertion -> {:noreply, select_node(socket, assertion)}
    end
  end

  def handle_event("deselect", _, socket) do
    {:noreply,
     socket
     |> assign(:selected, nil)
     |> assign(:selected_deps, [])
     |> assign(:selected_dependents, [])
     |> push_event("highlight", %{deps: [], dependents: [], selected: nil})}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    type = if type == "", do: nil, else: type
    filters = %{socket.assigns.filters | type: type}
    filtered = apply_filters(socket.assigns.assertions, filters, socket.assigns.search)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> push_graph_data(filtered)}
  end

  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    kind = if kind == "", do: nil, else: kind
    filters = %{socket.assigns.filters | kind: kind}
    filtered = apply_filters(socket.assigns.assertions, filters, socket.assigns.search)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> push_graph_data(filtered)}
  end

  def handle_event("filter_contract", %{"contract" => contract}, socket) do
    contract = if contract == "", do: nil, else: contract
    filters = %{socket.assigns.filters | contract: contract}
    filtered = apply_filters(socket.assigns.assertions, filters, socket.assigns.search)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> push_graph_data(filtered)}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    status = if status == "all", do: nil, else: status
    filters = %{socket.assigns.filters | status: status}
    filtered = apply_filters(socket.assigns.assertions, filters, socket.assigns.search)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> push_graph_data(filtered)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    filtered = apply_filters(socket.assigns.assertions, socket.assigns.filters, query)

    {:noreply,
     socket
     |> assign(:search, query)
     |> push_graph_data(filtered)}
  end

  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    mode = String.to_existing_atom(mode)
    {:noreply, assign(socket, :view_mode, mode)}
  end

  @impl true
  def handle_info(:assertions_changed, socket) do
    assertions = load_data()
    index = Graph.index(assertions)
    stats = Graph.stats(assertions)
    filtered = apply_filters(assertions, socket.assigns.filters, socket.assigns.search)

    {:noreply,
     socket
     |> assign(:assertions, assertions)
     |> assign(:index, index)
     |> assign(:stats, stats)
     |> assign(:available_kinds, compute_kinds(assertions))
     |> push_graph_data(filtered)}
  end

  # --- Private ---

  defp load_data do
    case Store.read() do
      {:ok, all} -> all
      _ -> []
    end
  end

  defp select_node(socket, assertion) do
    deps = Graph.resolve_deps(assertion, socket.assigns.index)
    dependents = Graph.dependents(assertion.id, socket.assigns.assertions)
    dep_ids = Enum.map(deps, & &1.id)
    dependent_ids = Enum.map(dependents, & &1.id)

    socket
    |> assign(:selected, assertion)
    |> assign(:selected_deps, deps)
    |> assign(:selected_dependents, dependents)
    |> push_event("highlight", %{
      deps: dep_ids,
      dependents: dependent_ids,
      selected: assertion.id
    })
  end

  defp apply_filters(all, filters, search) do
    all
    |> maybe_filter_type(filters.type)
    |> maybe_filter_kind(filters.kind)
    |> maybe_filter_contract(filters.contract)
    |> maybe_filter_status(filters.status)
    |> maybe_filter_search(search)
  end

  defp maybe_filter_type(items, nil), do: items
  defp maybe_filter_type(items, type), do: Enum.filter(items, &(&1.type == type))

  defp maybe_filter_kind(items, nil), do: items
  defp maybe_filter_kind(items, kind), do: Enum.filter(items, &(&1.kind == kind))

  defp maybe_filter_contract(items, nil), do: items
  defp maybe_filter_contract(items, "yes"), do: Enum.filter(items, &Belief.contract?/1)
  defp maybe_filter_contract(items, "no"), do: Enum.reject(items, &Belief.contract?/1)
  defp maybe_filter_contract(items, _), do: items

  defp maybe_filter_status(assertions, nil), do: assertions
  defp maybe_filter_status(assertions, status), do: Enum.filter(assertions, &(&1.status == status))

  defp maybe_filter_search(items, ""), do: items
  defp maybe_filter_search(items, nil), do: items
  defp maybe_filter_search(items, query) do
    q = String.downcase(query)
    Enum.filter(items, fn item ->
      (item.id && String.contains?(String.downcase(item.id), q)) ||
        (item.claim && String.contains?(String.downcase(item.claim), q))
    end)
  end

  defp compute_kinds(assertions) do
    assertions
    |> Enum.map(& &1.kind)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp push_graph_data(socket, assertions) do
    nodes =
      Enum.map(assertions, fn a ->
        %{
          id: a.id,
          type: a.type,
          kind: a.kind,
          contract: Belief.contract?(a),
          claim: a.claim,
          status: a.status,
          deps: a.deps || [],
          artifact: a.artifact,
          created: a.created,
          subjects: a.subjects || [],
          materialized: a.materialized != nil
        }
      end)

    edges =
      assertions
      |> Enum.flat_map(fn a ->
        (a.deps || [])
        |> Enum.map(fn dep -> %{source: dep, target: a.id} end)
      end)

    push_event(socket, "graph_data", %{nodes: nodes, edges: edges})
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- dag_live: full-viewport graph canvas; no max-width tier applies. --%>
    <div style="display: flex; height: 100vh; width: 100vw;">
      <%!-- Left sidebar: filters + stats --%>
      <div style="width: 260px; min-width: 260px; background: var(--bg-secondary); border-right: 1px solid var(--border); display: flex; flex-direction: column; overflow-y: auto;">
        <div style="padding: 16px; border-bottom: 1px solid var(--border);">
          <h1 style="font-size: 16px; font-weight: 600; margin-bottom: 4px;">DAG Navigator</h1>
          <span style="font-size: 12px; color: var(--text-secondary);">
            {@stats.total} beliefs
          </span>
        </div>

        <%!-- Search --%>
        <div style="padding: 12px 16px;">
          <form phx-change="search" phx-submit="search">
            <input
              type="text"
              name="query"
              aria-label="Search claims"
              placeholder="Search claims..."
              value={@search}
              phx-debounce="300"
              style="width: 100%; padding: 6px 10px; background: var(--bg-tertiary); border: 1px solid var(--border); border-radius: 6px; color: var(--text-primary); font-size: 13px; outline: none;"
            />
          </form>
        </div>

        <%!-- Filters --%>
        <div style="padding: 0 16px 12px;">
          <div style="margin-bottom: 8px;"><.section_label>Type</.section_label></div>
          <div style="display: flex; flex-wrap: wrap; gap: 4px;">
            <.filter_button active={@filters.type == nil} click="filter_type" value="" label="All" />
            <.filter_button active={@filters.type == "primitive"} click="filter_type" value="primitive" label="Primitive" color="var(--kind-primitive)" />
            <.filter_button active={@filters.type == "compound"} click="filter_type" value="compound" label="Compound" color="var(--kind-compound)" />
            <.filter_button active={@filters.type == "implication"} click="filter_type" value="implication" label="Implication" color="var(--kind-implication)" />
          </div>
        </div>

        <div style="padding: 0 16px 12px;">
          <div style="margin-bottom: 8px;"><.section_label>Contract</.section_label></div>
          <div style="display: flex; flex-wrap: wrap; gap: 4px;">
            <.filter_button active={@filters.contract == nil} click="filter_contract" value="" label="All" />
            <.filter_button active={@filters.contract == "yes"} click="filter_contract" value="yes" label="Contracts" color="var(--kind-contract)" />
            <.filter_button active={@filters.contract == "no"} click="filter_contract" value="no" label="Non-contract" color="var(--accent-blue)" />
          </div>
        </div>

        <div style="padding: 0 16px 12px;">
          <div style="margin-bottom: 8px;"><.section_label>Kind</.section_label></div>
          <form phx-change="filter_kind">
            <select
              name="kind"
              aria-label="Filter by kind"
              style="width: 100%; padding: 5px 8px; background: var(--bg-tertiary); border: 1px solid var(--border); border-radius: 6px; color: var(--text-primary); font-size: 12px; outline: none; cursor: pointer;"
            >
              <option value="" selected={@filters.kind == nil}>All kinds</option>
              <option :for={k <- @available_kinds} value={k} selected={@filters.kind == k}>
                <%= k %>
              </option>
            </select>
          </form>
        </div>

        <div style="padding: 0 16px 12px;">
          <div style="margin-bottom: 8px;"><.section_label>Status</.section_label></div>
          <div style="display: flex; flex-wrap: wrap; gap: 4px;">
            <.filter_button active={@filters.status == "active"} click="filter_status" value="active" label="Active" />
            <.filter_button active={@filters.status == nil} click="filter_status" value="all" label="All" />
            <.filter_button active={@filters.status == "superseded"} click="filter_status" value="superseded" label="Superseded" />
            <.filter_button active={@filters.status == "retracted"} click="filter_status" value="retracted" label="Retracted" />
          </div>
        </div>

        <%!-- Stats --%>
        <div style="padding: 12px 16px; border-top: 1px solid var(--border); margin-top: auto;">
          <div style="margin-bottom: 8px;"><.section_label>Graph Stats</.section_label></div>
          <div style="font-size: 12px; color: var(--text-secondary); line-height: 1.8;">
            <div style="display: flex; justify-content: space-between;">
              <span>Primitives</span>
              <span style="color: var(--kind-primitive);"><%= @stats.by_type["primitive"] || 0 %></span>
            </div>
            <div style="display: flex; justify-content: space-between;">
              <span>Compounds</span>
              <span style="color: var(--kind-compound);"><%= @stats.by_type["compound"] || 0 %></span>
            </div>
            <div style="display: flex; justify-content: space-between;">
              <span>Implications</span>
              <span style="color: var(--kind-implication);"><%= @stats.by_type["implication"] || 0 %></span>
            </div>
            <div style="display: flex; justify-content: space-between; border-top: 1px solid var(--border); padding-top: 4px; margin-top: 4px;">
              <span>Stale</span>
              <span style="color: var(--accent-red);"><%= @stats.stale_count %></span>
            </div>
            <div style="display: flex; justify-content: space-between;">
              <span>Unlinked</span>
              <span style="color: var(--accent-orange);"><%= @stats.unlinked_implications %></span>
            </div>
          </div>
        </div>
      </div>

      <%!-- Center: graph canvas --%>
      <div style="flex: 1; position: relative; overflow: hidden;">
        <div id="graph-container" phx-hook="AssertionGraph" phx-update="ignore" style="width: 100%; height: 100%;"></div>
      </div>

      <%!-- Right panel: detail --%>
      <div :if={@selected} style="width: 520px; min-width: 520px; background: var(--bg-secondary); border-left: 1px solid var(--border); overflow-y: auto; padding: 16px;">
        <div style="display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 12px;">
          <div>
            <span style={"display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; background: #{type_color(@selected.type)}22; color: #{type_color(@selected.type)};"}>
              <%= @selected.type %>
            </span>
            <span :if={@selected.kind} style="display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; background: var(--bg-tertiary); color: var(--text-secondary); margin-left: 4px;">
              <%= @selected.kind %>
            </span>
          </div>
          <button phx-click="deselect" aria-label="Close detail pane" style="background: none; border: none; color: var(--text-muted); cursor: pointer; font-size: 18px; line-height: 1;">&times;</button>
        </div>

        <h2 style="font-size: 14px; font-weight: 600; margin-bottom: 4px; color: var(--text-primary);">
          <%= @selected.id %>
        </h2>
        <p style="font-size: 13px; line-height: 1.5; color: var(--text-secondary); margin-bottom: 16px;">
          <%= @selected.claim %>
        </p>

        <%!-- Rules (contract-grade implications: c038/c039/c040/c041/c013 etc.) --%>
        <BeliefContext.rules_block belief={@selected} compact={true} />

        <%!-- Invariants --%>
        <BeliefContext.invariants_block belief={@selected} compact={true} />

        <%!-- Status --%>
        <div style="margin-bottom: 16px;">
          <div style="margin-bottom: 4px;"><.section_label>Status</.section_label></div>
          <span style={"font-size: 13px; color: #{status_color(@selected.status)};"}><%= @selected.status %></span>
          <span :if={@selected.superseded_by} style="font-size: 12px; color: var(--text-muted);"> -> <%= @selected.superseded_by %></span>
        </div>

        <%!-- Artifact --%>
        <div :if={@selected.artifact} style="margin-bottom: 16px;">
          <div style="margin-bottom: 4px;"><.section_label>Artifact</.section_label></div>
          <.artifact_link artifact={@selected.artifact} />
        </div>

        <%!-- Materialized --%>
        <div :if={@selected.materialized} style="margin-bottom: 16px;">
          <div style="margin-bottom: 4px;"><.section_label>Materialized</.section_label></div>
          <div style="font-size: 12px; color: var(--accent-green);">
            <%= @selected.materialized["date"] %>
            <div :for={todo <- @selected.materialized["todos"] || []} style="margin-top: 4px; padding: 4px 8px; background: var(--bg-tertiary); border-radius: 4px; font-size: 11px; color: var(--text-secondary);">
              <strong><%= todo["object"] %></strong>: <%= todo["action"] %>
            </div>
          </div>
        </div>

        <%!-- Subjects --%>
        <div :if={@selected.subjects != []} style="margin-bottom: 16px;">
          <div style="margin-bottom: 4px;"><.section_label>Subjects</.section_label></div>
          <div :for={s <- @selected.subjects} style="font-size: 12px; margin-bottom: 2px;">
            <span style="color: var(--accent-blue); font-family: monospace;"><%= s["ref"] %></span>
            <span style="color: var(--text-muted); margin-left: 4px;">(<%= s["type"] %>)</span>
          </div>
        </div>

        <%!-- Evidence --%>
        <div :if={@selected.evidence != []} style="margin-bottom: 16px;">
          <div style="margin-bottom: 4px;"><.section_label>Evidence (<%= length(@selected.evidence) %>)</.section_label></div>
          <div :for={e <- @selected.evidence} style="font-size: 11px; padding: 6px 8px; background: var(--bg-tertiary); border-radius: 4px; margin-bottom: 4px;">
            <div style="color: var(--text-muted);"><%= e["date"] %></div>
            <div style="color: var(--text-secondary); margin-top: 2px;"><%= e["detail"] %></div>
          </div>
        </div>

        <%!-- Dependencies --%>
        <div :if={@selected_deps != []} style="margin-bottom: 16px;">
          <div style="margin-bottom: 4px;"><.section_label>Dependencies (<%= length(@selected_deps) %>)</.section_label></div>
          <div :for={d <- @selected_deps} style="margin-bottom: 4px;">
            <button
              phx-click="select_node"
              phx-value-id={d.id}
              class="bc-hover-parent"
              style={"display: block; width: 100%; text-align: left; padding: 6px 8px; background: var(--bg-tertiary); border: 1px solid var(--border); border-left: 3px solid #{type_color(d.type)}; border-radius: 4px; cursor: pointer; color: var(--text-primary);"}
            >
              <span style="font-size: 12px; font-weight: 600;"><%= d.id %></span>
              <div style="font-size: 11px; color: var(--text-secondary); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;"><%= d.claim %></div>
              <BeliefContext.popup_card belief={d} placement={:left} />
            </button>
          </div>
        </div>

        <%!-- Dependents --%>
        <div :if={@selected_dependents != []} style="margin-bottom: 16px;">
          <div style="margin-bottom: 4px;"><.section_label>Dependents (<%= length(@selected_dependents) %>)</.section_label></div>
          <div :for={d <- @selected_dependents} style="margin-bottom: 4px;">
            <button
              phx-click="select_node"
              phx-value-id={d.id}
              class="bc-hover-parent"
              style={"display: block; width: 100%; text-align: left; padding: 6px 8px; background: var(--bg-tertiary); border: 1px solid var(--border); border-left: 3px solid #{type_color(d.type)}; border-radius: 4px; cursor: pointer; color: var(--text-primary);"}
            >
              <span style="font-size: 12px; font-weight: 600;"><%= d.id %></span>
              <div style="font-size: 11px; color: var(--text-secondary); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;"><%= d.claim %></div>
              <BeliefContext.popup_card belief={d} placement={:left} />
            </button>
          </div>
        </div>

        <%!-- Created --%>
        <div style="font-size: 11px; color: var(--text-muted); margin-top: 16px;">
          Created: <%= @selected.created %>
        </div>
      </div>
    </div>
    """
  end

  # --- Components ---

  defp filter_button(assigns) do
    assigns = assign_new(assigns, :color, fn -> nil end)

    ~H"""
    <button
      phx-click={@click}
      phx-value-type={if @click == "filter_type", do: @value}
      phx-value-kind={if @click == "filter_kind", do: @value}
      phx-value-contract={if @click == "filter_contract", do: @value}
      phx-value-status={if @click == "filter_status", do: @value}
      aria-pressed={to_string(@active)}
      style={"padding: 3px 10px; border-radius: 12px; font-size: 11px; cursor: pointer; border: 1px solid #{if @active, do: @color || "var(--accent-blue)", else: "var(--border)"}; background: #{if @active, do: (@color || "var(--accent-blue)") <> "22", else: "transparent"}; color: #{if @active, do: @color || "var(--accent-blue)", else: "var(--text-secondary)"};"}
    >
      <%= @label %>
    </button>
    """
  end

  # --- Helpers ---

  defp type_color("primitive"), do: "var(--kind-primitive)"
  defp type_color("compound"), do: "var(--kind-compound)"
  defp type_color("implication"), do: "var(--kind-implication)"
  defp type_color(_), do: "var(--text-secondary)"

  defp status_color("active"), do: "var(--accent-green)"
  defp status_color("superseded"), do: "var(--accent-orange)"
  defp status_color("retracted"), do: "var(--accent-red)"
  defp status_color(_), do: "var(--text-secondary)"
end
