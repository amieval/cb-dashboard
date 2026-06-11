defmodule CBDashboard.Components.BeliefContext do
  @moduledoc """
  Reusable function component that renders a belief with full review context.

  Given a belief id, renders:

  - Header — id, type/kind/status/contract badges, optional name
  - Claim prose
  - Compact metadata — artifact, tags, subjects, materialized, evidence count
  - Deps section — each upstream dep as a small card (id + claim), with
    stale deps (`superseded`/`retracted`) marked explicitly. Dep cards link
    to `/dag/<id>` (graph view with that node pre-selected) and surface a
    hover popup with the dep's claim + key schema fields so the user can
    skim without leaving the page.
  - Citers section — each incoming `deps` reference as a small card; contract
    citers get an explicit badge so the three-layer chain per a409 is visible.
    Same hover popup affordance as deps.
  - (Optional) Mutation diff overlay — when a `mutation` assign is supplied,
    fields touched by the proposed mutation render with the current value
    struck through and the proposed value highlighted; the per-mutation
    rationale renders inline beneath the diff.

  Used by `DagLive` (in flat mode) and `DagProposalLive` (one card per
  mutation row).
  """

  use Phoenix.Component

  import CBDashboard.Components.UI

  alias CB.Belief
  alias CB.Belief.Graph

  attr :belief, :any,
    required: true,
    doc: "Belief struct or proposed-payload map. `nil` when belief doesn't exist (new-belief)."

  attr :belief_id, :string,
    required: true,
    doc: "Target belief id, used for citers + missing-state."

  attr :index, :map, required: true, doc: "id => belief map (for dep resolution)."
  attr :all_beliefs, :list, required: true, doc: "Full belief list (for citer lookup)."

  attr :mutation, :any,
    default: nil,
    doc:
      "Optional mutation diff overlay. Shape: %{type, before, after, rationale, status, ...}. " <>
        "When present, changed fields are highlighted and the rationale renders inline."

  attr :show_deps, :boolean, default: true
  attr :show_citers, :boolean, default: true
  attr :anchor, :string, default: nil, doc: "Optional DOM id for in-page linking."

  def belief_card(assigns) do
    assigns =
      assigns
      |> assign_new(:resolved_deps, fn -> resolve_deps(assigns.belief, assigns.index) end)
      |> assign_new(:citers, fn -> resolve_citers(assigns.belief_id, assigns.all_beliefs) end)
      |> assign_new(:changed_fields, fn -> changed_fields(assigns.mutation) end)
      |> assign_new(:proposed_belief, fn -> proposed_belief(assigns.belief, assigns.mutation) end)

    ~H"""
    <article
      id={@anchor}
      style="border: 1px solid var(--border); border-radius: 8px; background: var(--bg-secondary); padding: 16px 18px; margin-bottom: 14px;"
    >
      <%= if is_nil(@belief) and is_new_belief?(@mutation) do %>
        <.new_belief_header belief_id={@belief_id} mutation={@mutation} />
        <.claim_block belief={@proposed_belief} changed_fields={@changed_fields} proposed?={true} />
        <.metadata_block belief={@proposed_belief} changed_fields={@changed_fields} proposed?={true} />
        <.rules_block belief={@proposed_belief} />
        <.invariants_block belief={@proposed_belief} />
        <.mutation_overlay mutation={@mutation} />
      <% else %>
        <%= if is_nil(@belief) do %>
          <.missing_belief belief_id={@belief_id} />
        <% else %>
          <.header_block
            belief={@belief}
            changed_fields={@changed_fields}
          />
          <.claim_block belief={@belief} changed_fields={@changed_fields} proposed?={false} />
          <.metadata_block belief={@belief} changed_fields={@changed_fields} proposed?={false} />
          <.rules_block belief={@belief} />
          <.invariants_block belief={@belief} />

          <%= if @show_deps and @resolved_deps != [] do %>
            <.deps_block deps={@resolved_deps} changed_fields={@changed_fields} mutation={@mutation} />
          <% end %>

          <%= if @show_citers and @citers != [] do %>
            <.citers_block citers={@citers} />
          <% end %>

          <.mutation_overlay mutation={@mutation} />
        <% end %>
      <% end %>
    </article>
    """
  end

  # --- Internal rendering blocks ---

  attr :belief, :any, required: true
  attr :changed_fields, :list, required: true

  defp header_block(assigns) do
    ~H"""
    <header style="display: flex; align-items: flex-start; gap: 10px; flex-wrap: wrap; margin-bottom: 10px;">
      <span style="font-family: ui-monospace, SFMono-Regular, monospace; font-weight: 700; font-size: 14px; color: var(--text-primary);">
        <a href={"/dag/#{@belief.id}"} style="color: var(--text-primary); text-decoration: none;">
          {@belief.id}
        </a>
      </span>
      <.type_badge type={@belief.type} />
      <.kind_badge kind={@belief.kind} highlighted={:kind in @changed_fields} />
      <%= if Belief.contract?(@belief) do %>
        <.badge tone={:purple} label="contract" />
      <% end %>
      <.status_badge status={@belief.status} highlighted={:status in @changed_fields} />
      <%= if @belief.name do %>
        <span style={"font-size: 12px; padding: 2px 8px; border-radius: 10px; background: var(--badge-bg-blue); color: var(--accent-blue); font-family: ui-monospace, SFMono-Regular, monospace; #{if :name in @changed_fields, do: "outline: 2px solid var(--accent-orange);"}"}>
          {@belief.name}
        </span>
      <% end %>
      <span style="margin-left: auto; font-size: 11px; color: var(--text-muted);">
        {@belief.created}
      </span>
    </header>
    """
  end

  attr :belief_id, :string, required: true
  attr :mutation, :any, required: true

  defp new_belief_header(assigns) do
    ~H"""
    <header style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-bottom: 10px;">
      <span style="font-family: ui-monospace, SFMono-Regular, monospace; font-weight: 700; font-size: 14px; color: var(--accent-green);">
        {@belief_id}
      </span>
      <.badge tone={:green} label="NEW BELIEF" />
    </header>
    <p style="font-size: 12px; color: var(--text-muted); margin-bottom: 12px;">
      Proposed insertion — no current state to compare against.
    </p>
    """
  end

  attr :belief_id, :string, required: true

  defp missing_belief(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 10px 0;">
      <span style="font-family: ui-monospace, SFMono-Regular, monospace; font-weight: 700; font-size: 14px; color: var(--accent-red);">
        {@belief_id}
      </span>
      <.badge tone={:red} label="NOT FOUND" />
      <span style="font-size: 12px; color: var(--text-secondary);">
        no belief with this id in <code>the belief graph</code>
      </span>
    </div>
    """
  end

  attr :belief, :any, required: true
  attr :changed_fields, :list, required: true
  attr :proposed?, :boolean, required: true

  defp claim_block(assigns) do
    ~H"""
    <p style={"font-size: 14px; line-height: 1.55; color: var(--text-primary); margin-bottom: 12px; #{if :claim in @changed_fields, do: "background: var(--overlay-orange-12); padding: 8px 10px; border-radius: 6px; border-left: 3px solid var(--accent-orange);"}"}>
      <%= Map.get(@belief, :claim) || "(no claim)" %>
    </p>
    """
  end

  attr :belief, :any, required: true
  attr :changed_fields, :list, required: true
  attr :proposed?, :boolean, required: true

  defp metadata_block(assigns) do
    artifact = Map.get(assigns.belief, :artifact)
    tags = Map.get(assigns.belief, :tags) || []
    subjects = Map.get(assigns.belief, :subjects) || []
    materialized = Map.get(assigns.belief, :materialized)
    evidence = Map.get(assigns.belief, :evidence) || []
    domain = Map.get(assigns.belief, :domain)
    superseded_by = Map.get(assigns.belief, :superseded_by)
    retracted_reason = Map.get(assigns.belief, :retracted_reason)
    retracted_on = Map.get(assigns.belief, :retracted_on)

    assigns =
      assign(assigns, %{
        artifact: artifact,
        tags: tags,
        subjects: subjects,
        materialized: materialized,
        evidence: evidence,
        domain: domain,
        superseded_by: superseded_by,
        retracted_reason: retracted_reason,
        retracted_on: retracted_on
      })

    ~H"""
    <dl style="display: grid; grid-template-columns: 100px 1fr; gap: 4px 12px; font-size: 12px; color: var(--text-secondary); margin-bottom: 12px;">
      <%= if @domain do %>
        <dt style="color: var(--text-muted);">domain</dt>
        <dd style="font-family: ui-monospace, SFMono-Regular, monospace;">{@domain}</dd>
      <% end %>
      <%= if @artifact do %>
        <dt style="color: var(--text-muted);">artifact</dt>
        <dd><.artifact_link artifact={@artifact} /></dd>
      <% end %>
      <%= if @tags != [] do %>
        <dt style="color: var(--text-muted);">tags</dt>
        <dd>
          <span :for={tag <- @tags} style="display: inline-block; font-size: 10px; padding: 1px 6px; margin-right: 4px; border-radius: 8px; background: var(--bg-tertiary); color: var(--text-secondary); font-family: ui-monospace, SFMono-Regular, monospace;">
            {tag}
          </span>
        </dd>
      <% end %>
      <%= if @subjects != [] do %>
        <dt style="color: var(--text-muted);">subjects</dt>
        <dd>
          <div :for={s <- @subjects} style="margin-bottom: 2px;">
            <span style="color: var(--accent-blue); font-family: ui-monospace, SFMono-Regular, monospace;">{Map.get(s, "ref") || Map.get(s, :ref)}</span>
            <span style="color: var(--text-muted); margin-left: 4px;">({Map.get(s, "type") || Map.get(s, :type)})</span>
          </div>
        </dd>
      <% end %>
      <%= if @superseded_by do %>
        <dt style="color: var(--text-muted);">superseded by</dt>
        <dd>
          <a href={"/dag/#{@superseded_by}"} style="font-family: ui-monospace, SFMono-Regular, monospace; color: var(--accent-orange);">{@superseded_by}</a>
        </dd>
      <% end %>
      <%= if @retracted_on do %>
        <dt style="color: var(--text-muted);">retracted</dt>
        <dd>{@retracted_on}{if @retracted_reason, do: " — #{@retracted_reason}"}</dd>
      <% end %>
      <%= if @evidence != [] do %>
        <dt style="color: var(--text-muted);">evidence</dt>
        <dd>{length(@evidence)} entries</dd>
      <% end %>
      <%= if @materialized do %>
        <dt style="color: var(--text-muted);">materialized</dt>
        <dd style="color: var(--accent-green);">
          <%= Map.get(@materialized, "date") || Map.get(@materialized, :date) %>
          ({length(Map.get(@materialized, "todos") || Map.get(@materialized, :todos) || [])} todos)
        </dd>
      <% end %>
    </dl>
    """
  end

  @doc """
  Render a belief's `rules` array as a numbered list. Used by belief_card
  (between metadata and deps) and by DagLive's sidebar so any view that
  surfaces a contract-grade implication shows its actual rule payload.
  Each rule runs through `linkify_belief_ids` so cross-references inside
  rule text stay traversable.
  """
  attr :belief, :any, required: true
  attr :compact, :boolean, default: false, doc: "Smaller fonts/padding for sidebar use."

  def rules_block(assigns) do
    rules =
      case assigns.belief do
        nil -> []
        belief -> Map.get(belief, :rules) || []
      end

    assigns = assign(assigns, :rules, rules)

    ~H"""
    <%= if @rules != [] do %>
      <section style={"margin-top: #{if @compact, do: "0", else: "14px"}; #{if @compact, do: "margin-bottom: 16px;"}"}>
        <h4 style="margin-bottom: 6px;">
          <.section_label>Rules ({length(@rules)})</.section_label>
        </h4>
        <ol style={"font-size: #{if @compact, do: "11px", else: "12px"}; line-height: 1.5; padding-left: 22px; margin: 0;"}>
          <li :for={rule <- @rules} style="font-family: ui-monospace, SFMono-Regular, monospace; color: var(--text-primary); margin-bottom: 4px; word-break: break-word;">
            <.rule_or_invariant value={rule} />
          </li>
        </ol>
      </section>
    <% end %>
    """
  end

  @doc """
  Render a belief's `invariants` array as a numbered list. Parallel to
  `rules_block/1` — separate function so the two sections render with
  their own headers when both are present.
  """
  attr :belief, :any, required: true
  attr :compact, :boolean, default: false

  def invariants_block(assigns) do
    invariants =
      case assigns.belief do
        nil -> []
        belief -> Map.get(belief, :invariants) || []
      end

    assigns = assign(assigns, :invariants, invariants)

    ~H"""
    <%= if @invariants != [] do %>
      <section style={"margin-top: #{if @compact, do: "0", else: "14px"}; #{if @compact, do: "margin-bottom: 16px;"}"}>
        <h4 style="margin-bottom: 6px;">
          <.section_label>Invariants ({length(@invariants)})</.section_label>
        </h4>
        <ol style={"font-size: #{if @compact, do: "11px", else: "12px"}; line-height: 1.5; padding-left: 22px; margin: 0;"}>
          <li :for={inv <- @invariants} style="font-family: ui-monospace, SFMono-Regular, monospace; color: var(--text-primary); margin-bottom: 4px; word-break: break-word;">
            <.rule_or_invariant value={inv} />
          </li>
        </ol>
      </section>
    <% end %>
    """
  end

  attr :value, :any, required: true

  defp rule_or_invariant(%{value: v} = assigns) when is_binary(v) do
    case split_enum_prefix(v) do
      {prefix, rest} ->
        assigns = assigns |> assign(:prefix, prefix) |> assign(:rest, rest)

        ~H"""
        <span style="color: var(--accent-blue); font-weight: 600;">{@prefix}</span>
        <span style="color: var(--text-muted);"> — </span>
        <.linkify_belief_ids text={@rest} />
        """

      nil ->
        ~H"<.linkify_belief_ids text={@value} />"
    end
  end

  defp rule_or_invariant(%{value: v} = assigns) when is_map(v) do
    assigns = assign(assigns, :pretty, Jason.encode!(v, pretty: true))

    ~H"""
    <pre style="font-size: 11.5px; background: var(--bg-tertiary); padding: 6px 8px; border-radius: 4px; margin: 0; white-space: pre-wrap;">{@pretty}</pre>
    """
  end

  defp rule_or_invariant(assigns) do
    assigns = assign(assigns, :text, inspect(assigns.value))
    ~H"{@text}"
  end

  # c039, c040, c041 and other domain-enums render their entries as
  # "slug:value — prose" strings. Splitting out the prefix lets the
  # surface colorize the enum key the same way kind/type badges are
  # colored elsewhere, making the enum visually scannable instead of
  # a wall of monospace text.
  @enum_prefix_pattern ~r/^([a-z][a-z0-9-]*:[a-zA-Z][a-zA-Z0-9-]*)\s+—\s+(.*)$/s

  defp split_enum_prefix(text) when is_binary(text) do
    case Regex.run(@enum_prefix_pattern, text) do
      [_, prefix, rest] -> {prefix, rest}
      _ -> nil
    end
  end

  defp split_enum_prefix(_), do: nil

  attr :deps, :list, required: true
  attr :changed_fields, :list, required: true
  attr :mutation, :any, required: true

  defp deps_block(assigns) do
    assigns =
      assign(
        assigns,
        :deps_highlighted?,
        :deps in assigns.changed_fields
      )

    ~H"""
    <section style={"margin-top: 14px; #{if @deps_highlighted?, do: "padding: 6px 8px; border-radius: 6px; background: var(--overlay-orange-08);"}"}>
      <h4 style="margin-bottom: 6px;">
        <.section_label>Deps ({length(@deps)})</.section_label>
      </h4>
      <div style="display: grid; gap: 4px;">
        <.dep_card :for={dep <- @deps} dep={dep} mutation={@mutation} />
      </div>
    </section>
    """
  end

  attr :dep, :any, required: true
  attr :mutation, :any, required: true

  defp dep_card(assigns) do
    stale? = assigns.dep.status in ["superseded", "retracted"]

    dropped? =
      case assigns.mutation do
        %{type: "drop-dep", dep: dep_id} -> dep_id == assigns.dep.id
        %{"type" => "drop-dep", "dep" => dep_id} -> dep_id == assigns.dep.id
        _ -> false
      end

    added? =
      case assigns.mutation do
        %{type: "add-dep", dep: dep_id} -> dep_id == assigns.dep.id
        %{"type" => "add-dep", "dep" => dep_id} -> dep_id == assigns.dep.id
        _ -> false
      end

    border_color =
      cond do
        added? -> "var(--accent-green)"
        dropped? -> "var(--accent-red)"
        stale? -> "var(--accent-orange)"
        true -> type_color(assigns.dep.type)
      end

    assigns =
      assign(assigns,
        stale?: stale?,
        dropped?: dropped?,
        added?: added?,
        border_color: border_color
      )

    ~H"""
    <a
      href={"/dag/#{@dep.id}"}
      class="bc-hover-parent"
      style={"display: flex; gap: 10px; align-items: baseline; padding: 6px 10px; background: var(--bg-tertiary); border-radius: 4px; border-left: 3px solid #{@border_color}; text-decoration: none; color: var(--text-primary); #{if @dropped?, do: "opacity: 0.55; text-decoration: line-through;"}"}
    >
      <span style="font-family: ui-monospace, SFMono-Regular, monospace; font-size: 11px; font-weight: 600; min-width: 48px;">
        {@dep.id}
      </span>
      <.badge :if={@added?} tone={:green} label="ADD" />
      <.badge :if={@dropped?} tone={:red} label="DROP" />
      <.badge :if={@stale?} tone={:orange} label={String.upcase(@dep.status)} />
      <span style="font-size: 12px; color: var(--text-secondary); flex: 1; line-height: 1.4;">{@dep.claim}</span>
      <.popup_card belief={@dep} />
    </a>
    """
  end

  attr :citers, :list, required: true

  defp citers_block(assigns) do
    ~H"""
    <section style="margin-top: 14px;">
      <h4 style="margin-bottom: 6px;">
        <.section_label>Citers ({length(@citers)})</.section_label>
      </h4>
      <div style="display: grid; gap: 4px;">
        <.citer_card :for={citer <- @citers} citer={citer} />
      </div>
    </section>
    """
  end

  attr :citer, :any, required: true

  defp citer_card(assigns) do
    stale? = assigns.citer.status in ["superseded", "retracted"]
    contract? = Belief.contract?(assigns.citer)
    relationship = citer_relationship(assigns.citer)
    assigns = assign(assigns, stale?: stale?, contract?: contract?, relationship: relationship)

    ~H"""
    <a
      href={"/dag/#{@citer.id}"}
      class="bc-hover-parent"
      style={"display: flex; gap: 10px; align-items: baseline; padding: 6px 10px; background: var(--bg-tertiary); border-radius: 4px; border-left: 3px solid #{type_color(@citer.type)}; text-decoration: none; color: var(--text-primary);"}
    >
      <span style="font-family: ui-monospace, SFMono-Regular, monospace; font-size: 11px; font-weight: 600; min-width: 48px;">
        {@citer.id}
      </span>
      <.badge :if={@contract?} tone={:purple} label="CONTRACT" />
      <.badge :if={@stale?} tone={:orange} label={String.upcase(@citer.status)} />
      <span style="font-size: 10px; padding: 1px 5px; border-radius: 8px; background: var(--bg-secondary); color: var(--text-muted);">{@relationship}</span>
      <span style="font-size: 12px; color: var(--text-secondary); flex: 1; line-height: 1.4;">{@citer.claim}</span>
      <.popup_card belief={@citer} />
    </a>
    """
  end

  attr :mutation, :any, required: true

  defp mutation_overlay(%{mutation: nil} = assigns), do: ~H""

  defp mutation_overlay(assigns) do
    rationale = mutation_field(assigns.mutation, :rationale)
    type = mutation_field(assigns.mutation, :type)
    before = mutation_field(assigns.mutation, :before) || %{}
    after_ = mutation_field(assigns.mutation, :after) || %{}
    keys = changed_keys(before, after_)

    assigns =
      assign(assigns,
        rationale: rationale,
        mutation_type: type,
        before: before,
        after_: after_,
        keys: keys
      )

    ~H"""
    <div style="margin-top: 14px; border-top: 1px solid var(--border); padding-top: 12px;">
      <div style="margin-bottom: 8px;">
        <.section_label>Proposed mutation · <span style="color: var(--accent-orange);">{@mutation_type}</span></.section_label>
      </div>

      <%= if @keys != [] do %>
        <table style="width: 100%; font-size: 12px; border-collapse: collapse; margin-bottom: 10px;">
          <thead>
            <tr style="text-align: left; color: var(--text-muted);">
              <th style="padding: 4px 8px; font-weight: 400; width: 90px;">field</th>
              <th style="padding: 4px 8px; font-weight: 400;">before</th>
              <th style="padding: 4px 8px; font-weight: 400;">after</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={key <- @keys} style="border-top: 1px solid var(--border);">
              <td style="padding: 6px 8px; font-family: ui-monospace, SFMono-Regular, monospace; color: var(--text-secondary);">
                {to_string(key)}
              </td>
              <td style="padding: 6px 8px; font-family: ui-monospace, SFMono-Regular, monospace; color: var(--accent-red); background: var(--overlay-red-08); word-break: break-word;">
                {format_value(Map.get(@before, key) || Map.get(@before, to_string(key)))}
              </td>
              <td style="padding: 6px 8px; font-family: ui-monospace, SFMono-Regular, monospace; color: var(--accent-green); background: var(--overlay-green-08); word-break: break-word;">
                {format_value(Map.get(@after_, key) || Map.get(@after_, to_string(key)))}
              </td>
            </tr>
          </tbody>
        </table>
      <% end %>

      <%= if @rationale do %>
        <div style="font-size: 12.5px; color: var(--text-primary); line-height: 1.55; background: var(--bg-tertiary); padding: 10px 12px; border-radius: 6px; border-left: 3px solid var(--accent-blue);">
          <div style="display: block; margin-bottom: 4px;"><.section_label>Rationale</.section_label></div>
          <.linkify_belief_ids text={@rationale} />
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Compact belief preview rendered as a hover popup.

  Caller must place this inside a positioned ancestor with the
  `bc-hover-parent` class. The popup shows the belief's claim plus key
  schema fields (type/kind/status badges, name, artifact, dep count).
  CSS in `Layouts.root/1` handles the show/hide on `:hover` /
  `:focus-within` — no JS required.

  Pass `placement: :left` to anchor the popup on the right edge of its
  parent (used in the DagLive sidebar so the popup doesn't extend
  off-screen).
  """
  attr :belief, :any, required: true
  attr :placement, :atom, default: :below, doc: ":below (default) or :left"

  def popup_card(%{belief: nil} = assigns), do: ~H""

  def popup_card(assigns) do
    placement_class = if assigns.placement == :left, do: " bc-hover-popup--left", else: ""

    assigns =
      assigns
      |> assign(:placement_class, placement_class)
      |> assign(:contract?, Belief.contract?(assigns.belief))
      |> assign(:dep_count, length(Map.get(assigns.belief, :deps) || []))

    ~H"""
    <div class={"bc-hover-popup" <> @placement_class}>
      <div class="bc-popup-row">
        <.badge tone={tone_for_type(@belief.type)} label={@belief.type} />
        <.badge :if={@belief.kind} tone={:neutral} label={to_string(@belief.kind)} />
        <.badge :if={@contract?} tone={:purple} label="contract" />
        <.badge tone={tone_for_status(@belief.status)} label={@belief.status} />
        <.badge :if={@belief.name} tone={:blue} label={@belief.name} />
      </div>
      <div class="bc-popup-claim">{Map.get(@belief, :claim) || "(no claim)"}</div>
      <div class="bc-popup-meta">
        <span style="color: var(--text-secondary);">{@belief.id}</span>
        <%= if @belief.artifact do %>
          <span>·</span>
          <span style="color: var(--accent-blue);">{@belief.artifact}</span>
        <% end %>
        <%= if @dep_count > 0 do %>
          <span>·</span>
          <span>{@dep_count} deps</span>
        <% end %>
        <%= if @belief.created do %>
          <span>·</span>
          <span>{@belief.created}</span>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Small badge components ---
  #
  # These three wrappers preserve the original public surface
  # (type_badge / kind_badge / status_badge) so external callers
  # don't break, but their bodies are now thin shells around
  # `<.badge>` from `CBDashboard.Components.UI`.

  attr :type, :string, required: true

  defp type_badge(assigns) do
    ~H'<.badge tone={tone_for_type(@type)} size={:sm} label={@type} />'
  end

  attr :kind, :any, required: true
  attr :highlighted, :boolean, default: false

  defp kind_badge(%{kind: nil} = assigns), do: ~H""

  defp kind_badge(assigns) do
    ~H'<.badge tone={:neutral} size={:sm} label={to_string(@kind)} />'
  end

  attr :status, :string, required: true
  attr :highlighted, :boolean, default: false

  defp status_badge(assigns) do
    ~H'<.badge tone={tone_for_status(@status)} size={:sm} label={@status} />'
  end

  # --- Helpers ---

  def type_color("primitive"), do: "var(--accent-blue)"
  def type_color("compound"), do: "var(--accent-green)"
  def type_color("inference"), do: "var(--kind-inference)"
  def type_color("directive"), do: "var(--accent-orange)"
  def type_color(_), do: "var(--text-secondary)"

  def status_color("active"), do: "var(--accent-green)"
  def status_color("superseded"), do: "var(--accent-orange)"
  def status_color("retracted"), do: "var(--accent-red)"
  def status_color("retired"), do: "var(--text-secondary)"
  def status_color(_), do: "var(--text-secondary)"

  # Tone mapping used by the type_badge / status_badge wrappers.
  defp tone_for_type("primitive"), do: :blue
  defp tone_for_type("compound"), do: :green
  defp tone_for_type("inference"), do: :blue
  defp tone_for_type("directive"), do: :orange
  defp tone_for_type(_), do: :neutral

  defp tone_for_status("active"), do: :green
  defp tone_for_status("superseded"), do: :orange
  defp tone_for_status("retracted"), do: :red
  defp tone_for_status(_), do: :neutral

  defp resolve_deps(nil, _index), do: []

  defp resolve_deps(belief, index) do
    dep_ids = Map.get(belief, :deps) || Map.get(belief, "deps") || []

    dep_ids
    |> Enum.map(&Map.get(index, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_citers(belief_id, all_beliefs) do
    Graph.dependents(belief_id, all_beliefs)
  end

  defp citer_relationship(%{contract: true}), do: "derivation"
  defp citer_relationship(%{type: "compound"}), do: "composition"
  defp citer_relationship(%{type: "inference"}), do: "derivation"
  defp citer_relationship(%{type: "directive"}), do: "action-derivation"
  defp citer_relationship(_), do: "deps"

  defp changed_fields(nil), do: []

  defp changed_fields(mutation) do
    after_ = mutation_field(mutation, :after) || %{}
    before = mutation_field(mutation, :before) || %{}

    changed_keys(before, after_)
    |> Enum.map(&to_atom_field/1)
  end

  defp changed_keys(before, after_) do
    before_keys = before |> Map.keys() |> Enum.map(&to_string/1)
    after_keys = after_ |> Map.keys() |> Enum.map(&to_string/1)

    (before_keys ++ after_keys) |> Enum.uniq()
  end

  defp to_atom_field(k) when is_binary(k) do
    try do
      String.to_existing_atom(k)
    rescue
      _ -> nil
    end
  end

  defp to_atom_field(k) when is_atom(k), do: k
  defp to_atom_field(_), do: nil

  defp mutation_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp is_new_belief?(nil), do: false
  defp is_new_belief?(%{type: "new-belief"}), do: true
  defp is_new_belief?(%{"type" => "new-belief"}), do: true
  defp is_new_belief?(_), do: false

  defp proposed_belief(_belief, %{type: "new-belief", after: payload}) when is_map(payload),
    do: normalize_payload(payload)

  defp proposed_belief(_belief, %{"type" => "new-belief", "after" => payload})
       when is_map(payload),
       do: normalize_payload(payload)

  defp proposed_belief(belief, _), do: belief

  defp normalize_payload(payload) when is_map(payload) do
    %{
      id: get(payload, :id),
      type: get(payload, :type),
      kind: get(payload, :kind),
      domain: get(payload, :domain),
      tags: get(payload, :tags) || [],
      name: get(payload, :name),
      claim: get(payload, :claim),
      artifact: get(payload, :artifact),
      subjects: get(payload, :subjects) || [],
      evidence: get(payload, :evidence) || [],
      deps: get(payload, :deps) || [],
      materialized: get(payload, :materialized),
      status: get(payload, :status) || "active",
      created: get(payload, :created),
      superseded_by: get(payload, :superseded_by),
      retracted_on: get(payload, :retracted_on),
      retracted_reason: get(payload, :retracted_reason),
      contract: get(payload, :contract),
      rules: get(payload, :rules) || [],
      invariants: get(payload, :invariants) || []
    }
  end

  defp get(map, key) when is_atom(key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp format_value(nil), do: "—"
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(value) when is_boolean(value), do: to_string(value)

  defp format_value(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &format_value/1) <> "]"

  defp format_value(value) when is_map(value), do: Jason.encode!(value)
  defp format_value(value), do: inspect(value)
end
