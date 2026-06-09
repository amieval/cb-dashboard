defmodule CBDashboard.DagProposalLive do
  @moduledoc """
  Per-proposal review surface at `/dag/proposals/:slug`.

  Renders the manifest as a vertical list of mutation rows. Each row uses
  `BeliefContext.belief_card/1` to render the target belief with full
  context (deps + citers), plus the mutation diff overlay that highlights
  what's being proposed and the inline rationale.

  Subscribes to two topics:

  - `"proposals:changes"` — re-reads the manifest from disk on any edit
    under `ops/dag-proposals/`.
  - `"assertions:changes"` — re-reads `org/assertions/assertions.json`
    so dep/citer context stays current as upstream beliefs change.

  Phase 1 is read-only: the user reviews here and responds in chat. No
  in-browser approve/reject controls.
  """

  use Phoenix.LiveView

  import CBUI.Components

  alias CB.Belief.{Store, Graph}
  alias CBDashboard.Components.BeliefContext
  alias CBDashboard.Sources.Proposals

  @proposals_topic "proposals:changes"
  @assertions_topic "assertions:changes"

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CBDashboard.PubSub, @proposals_topic)
      Phoenix.PubSub.subscribe(CBDashboard.PubSub, @assertions_topic)
    end

    {:ok, load(socket, slug)}
  end

  @impl true
  def handle_info(:proposals_changed, socket),
    do: {:noreply, load(socket, socket.assigns.slug)}

  def handle_info(:assertions_changed, socket),
    do: {:noreply, load(socket, socket.assigns.slug)}

  @impl true
  def handle_event("set_status", %{"mutation-id" => id, "status" => status}, socket) do
    case Proposals.update_mutation_status(socket.assigns.slug, id, status) do
      {:ok, _manifest} ->
        # PubSub broadcast triggers handle_info(:proposals_changed) which
        # re-loads. No direct assign here — single source of truth for
        # re-render. Clear any prior error.
        {:noreply, assign(socket, :update_error, nil)}

      {:error, reason} ->
        # Surface inline via a transient assign (the root layout doesn't
        # render :flash). Most-likely reason is `:stale` — re-loading is
        # the recovery path, which the PubSub will trigger on the next
        # external write.
        {:noreply,
         assign(socket, :update_error, "Could not update #{id}: #{format_error(reason)}")}
    end
  end

  def handle_event("open_edit", %{"mutation-id" => id}, socket) do
    {:noreply, assign(socket, :editing_mutation_id, id)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing_mutation_id, nil)}
  end

  def handle_event("save_alternative", %{"mutation-id" => id, "value" => value}, socket) do
    mutation = Enum.find(socket.assigns.manifest.mutations, &(&1.id == id))

    cond do
      is_nil(mutation) ->
        {:noreply, assign(socket, :update_error, "Mutation #{id} not found")}

      not editable?(mutation) ->
        {:noreply,
         assign(
           socket,
           :update_error,
           "Mutation #{id} type=#{mutation.type} doesn't accept inline edits"
         )}

      true ->
        save_alternative(socket, mutation, String.trim(value))
    end
  end

  def handle_event("apply_approved", _params, socket) do
    case run_apply(socket.assigns.slug) do
      {:ok, %{count: n, commit: commit, namespace: ns}} ->
        {:noreply,
         socket
         |> assign(:update_error, nil)
         |> assign(
           :apply_note,
           "Applied #{n} mutation#{plural(n)}#{ns_suffix(ns)} — #{commit_note(commit)}"
         )}

      {:error, :nothing_to_apply} ->
        {:noreply,
         assign(
           socket,
           :update_error,
           "Nothing to apply — queue is empty (status=applied + applied_at=null)."
         )}

      {:error, :mutations_disabled} ->
        {:noreply,
         assign(
           socket,
           :update_error,
           "Mutations are disabled (dashboard is read-only). " <>
             "Set `config :cb_dashboard, :enable_mutations, true` to enable the apply path."
         )}

      {:error, {:apply_failed, {id, reason}}} ->
        {:noreply,
         assign(
           socket,
           :update_error,
           "Apply pipeline halted at #{id}: #{format_error(reason)}. " <>
             "No assertions written, no commit."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :update_error, "Apply failed: #{format_error(reason)}")}
    end
  end

  # --- Swap-to-alternative save (Step 6) ---

  defp save_alternative(socket, mutation, value) do
    field = editable_field_name(mutation)

    case Proposals.update_mutation_after_field(socket.assigns.slug, mutation.id, field, value) do
      {:ok, _manifest} ->
        {:noreply,
         socket
         |> assign(:editing_mutation_id, nil)
         |> assign(:update_error, nil)}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :update_error,
           "Save failed for #{mutation.id}: #{format_error(reason)}"
         )}
    end
  end

  # --- Apply-approved pipeline ---

  # Read-only gate lives here; the pipeline itself is CBDashboard.ProposalApply.
  defp run_apply(slug) do
    if CBDashboard.Paths.mutations_enabled?() do
      CBDashboard.ProposalApply.apply_approved(slug)
    else
      {:error, :mutations_disabled}
    end
  end

  defp commit_note(:ok), do: "committed"
  defp commit_note(:skipped), do: "files written (commit skipped)"

  defp commit_note({:error, reason}),
    do: "commit failed (#{inspect(reason)}); files written, commit manually"

  defp ns_suffix(nil), do: ""
  defp ns_suffix(ns), do: " to #{ns}:"

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp load(socket, slug) do
    case Proposals.get(slug) do
      :not_found ->
        socket
        |> assign(:slug, slug)
        |> assign(:found?, false)
        |> assign_new(:update_error, fn -> nil end)

      {:ok, manifest} ->
        # Belief context comes from the manifest's target collection (its
        # dependency-closure union) so cross-namespace deps/citers resolve; a
        # manifest without a namespace uses the single default graph.
        assertions = load_context(manifest)
        index = Graph.index(assertions)

        socket
        |> assign(:slug, slug)
        |> assign(:found?, true)
        |> assign(:manifest, manifest)
        |> assign(:assertions, assertions)
        |> assign(:index, index)
        |> assign(:counts, mutation_counts(manifest.mutations))
        |> assign(:queued_count, CBDashboard.ProposalApply.queued_count(manifest.mutations))
        |> assign_new(:update_error, fn -> nil end)
        |> assign_new(:apply_note, fn -> nil end)
        |> assign_new(:editing_mutation_id, fn -> nil end)
    end
  end

  defp load_context(%{namespace: ns}) when is_binary(ns) and ns != "" do
    case CBDashboard.Sources.Graphs.load(ns) do
      {:ok, union} -> union
      {:error, _} -> single_graph()
    end
  end

  defp load_context(_manifest), do: single_graph()

  defp single_graph do
    case Store.read() do
      {:ok, all} -> all
      _ -> []
    end
  end

  # --- Inline-edit helpers (swap-to-alternative affordance) ---

  defp editable?(%{type: "set-name"}), do: true
  defp editable?(%{type: "reclassify-kind"}), do: true
  defp editable?(_), do: false

  defp editable_field_name(%{type: "set-name"}), do: "name"
  defp editable_field_name(%{type: "reclassify-kind"}), do: "kind"
  defp editable_field_name(_), do: nil

  defp editable_value(%{after: nil}), do: ""

  defp editable_value(mutation) do
    case editable_field_name(mutation) do
      nil -> ""
      field -> Map.get(mutation.after, field) || ""
    end
  end

  defp format_error(:stale),
    do: "manifest changed underfoot — refresh and try again"

  defp format_error({:mutation_not_found, id}),
    do: "mutation #{id} not found in manifest"

  defp format_error({:invalid_status, status}),
    do: "#{inspect(status)} is not a valid per-item status"

  defp format_error(reason), do: inspect(reason)

  @impl true
  def render(%{found?: false} = assigns) do
    ~H"""
    <div style="max-width: var(--maxw-narrow);">
      <div style="font-size: 12px; color: var(--text-muted); margin-bottom: 16px;">
        <a href="/dag/proposals" style="color: var(--text-muted);">← all proposals</a>
      </div>
      <.page_header title="Manifest not found" />
      <p style="font-size: 13px; color: var(--text-secondary);">
        No <code>{@slug}.json</code> in <code>ops/dag-proposals/</code>.
      </p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div style="max-width: var(--maxw-prose);">
      <div style="font-size: 12px; color: var(--text-muted); margin-bottom: 12px; display: flex; gap: 12px; align-items: baseline; flex-wrap: wrap;">
        <a href="/dag/proposals" style="color: var(--text-muted);">← all proposals</a>
        <span>·</span>
        <span style="font-family: ui-monospace, SFMono-Regular, monospace;">{@slug}</span>
        <span>·</span>
        <a href={"/dag/proposals/files/#{@slug}.json"} style="font-size: 11px;">view raw json</a>
      </div>

      <.page_header title={@manifest.title || @slug}>
        <:meta>
          <.badge tone={tone_for_proposal_status(@manifest.status)} label={@manifest.status} />
          <%= if @manifest.namespace do %>
            <a
              href={"/c/#{@manifest.namespace}/dag"}
              title="Target collection — apply writes this collection's beliefs.json"
              style="font-family: ui-monospace, SFMono-Regular, monospace; color: var(--accent-blue);"
            >{@manifest.namespace}:</a>
            <span>·</span>
          <% end %>
          <span>created {date_label(@manifest.created)}</span>
          <%= if @manifest.author do %>
            <span>·</span>
            <span>author: <strong>{@manifest.author}</strong></span>
          <% end %>
          <%= if @manifest.source_plan do %>
            <span>·</span>
            <span>source plan:
              <a
                href={source_plan_link(@manifest.source_plan)}
                style="font-family: ui-monospace, SFMono-Regular, monospace; color: var(--accent-blue);"
              >{@manifest.source_plan}</a>
            </span>
          <% end %>
        </:meta>
      </.page_header>
      <div style="display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 20px; align-items: center;">
        <span style="font-size: 11px; color: var(--text-muted);">{length(@manifest.mutations)} mutations:</span>
        <.numeric_chip :if={(@counts["pending"] || 0) > 0} tone={:orange} count={@counts["pending"]} label="pending" />
        <.numeric_chip :if={(@counts["applied"] || 0) > 0} tone={:green} count={@counts["applied"]} label="applied" />
        <.numeric_chip :if={(@counts["rejected"] || 0) > 0} tone={:red} count={@counts["rejected"]} label="rejected" />
        <.numeric_chip :if={(@counts["discuss"] || 0) > 0} tone={:blue} count={@counts["discuss"]} label="discuss" />
        <%= if @queued_count > 0 do %>
          <button
            phx-click="apply_approved"
            data-confirm={"Apply #{@queued_count} approved mutation#{if @queued_count == 1, do: "", else: "s"} to assertions.json and commit?"}
            style="margin-left: auto; font-size: 12px; padding: 4px 12px; border-radius: 4px; border: 1px solid var(--accent-green); background: var(--badge-bg-green); color: var(--accent-green); cursor: pointer; font-weight: 600;"
          >
            Apply approved ({@queued_count})
          </button>
        <% end %>
      </div>

      <%= if @apply_note do %>
        <div
          role="status"
          style="margin-bottom: 16px; padding: 10px 14px; border: 1px solid var(--accent-green); border-radius: 6px; background: var(--badge-bg-green); color: var(--text-primary); font-size: 13px;"
        >
          {@apply_note}
        </div>
      <% end %>

      <%= if @manifest.errors != [] do %>
        <.errors_block errors={@manifest.errors} />
      <% end %>

      <%= if @update_error do %>
        <div
          role="alert"
          style="margin-bottom: 16px; padding: 10px 14px; border: 1px solid var(--accent-red); border-radius: 6px; background: var(--badge-bg-red); color: var(--text-primary); font-size: 13px;"
        >
          {@update_error}
        </div>
      <% end %>

      <%= if @manifest.rationale do %>
        <section style="margin-bottom: 24px; padding: 14px 16px; background: var(--bg-secondary); border: 1px solid var(--border); border-left: 3px solid var(--accent-blue); border-radius: 6px;">
          <div style="margin-bottom: 6px;"><.section_label>Batch rationale</.section_label></div>
          <p style="font-size: 13.5px; line-height: 1.6; color: var(--text-primary); white-space: pre-wrap;"><.linkify_belief_ids text={@manifest.rationale} /></p>
        </section>
      <% end %>

      <%= if @manifest.mutations == [] do %>
        <.empty_state tone={:note}>
          No mutations in this manifest.
        </.empty_state>
      <% else %>
        <section>
          <%= for {mutation, idx} <- Enum.with_index(@manifest.mutations) do %>
            <.mutation_row
              mutation={mutation}
              idx={idx}
              index={@index}
              assertions={@assertions}
              editing?={@editing_mutation_id == mutation.id}
            />
          <% end %>
        </section>
      <% end %>
    </div>
    """
  end

  # --- Function components ---

  attr :mutation, :map, required: true
  attr :idx, :integer, required: true
  attr :index, :map, required: true
  attr :assertions, :list, required: true
  attr :editing?, :boolean, default: false

  defp mutation_row(assigns) do
    belief = Map.get(assigns.index, assigns.mutation.belief_id)

    assigns =
      assign(assigns,
        belief: belief,
        context?: assigns.mutation.type == "context",
        applied?: assigns.mutation.status == "applied"
      )

    ~H"""
    <div id={"m-#{@mutation.id}"} style="margin-bottom: 20px;">
      <div style="display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; margin-bottom: 6px;">
        <a
          href={"#m-#{@mutation.id}"}
          style="font-family: ui-monospace, SFMono-Regular, monospace; font-size: 12px; font-weight: 600; color: var(--text-muted); text-decoration: none;"
        >{@mutation.id}</a>
        <span style={"font-size: 11px; padding: 2px 8px; border-radius: 10px; background: var(--bg-tertiary); color: #{if @context?, do: "var(--accent-blue)", else: "var(--text-primary)"}; font-family: ui-monospace, SFMono-Regular, monospace;"}>
          {@mutation.type}
        </span>
        <span style="font-size: 12px; color: var(--text-muted);">
          {if @context?, do: "referencing", else: "on"} <a
            href={"/dag/#{@mutation.belief_id}"}
            style="font-family: ui-monospace, SFMono-Regular, monospace; color: var(--accent-blue);"
          >{@mutation.belief_id}</a>
        </span>
        <.badge tone={tone_for_mutation_status(@mutation.status)} label={@mutation.status} />
        <.status_controls mutation={@mutation} applied?={@applied?} editing?={@editing?} />
      </div>

      <BeliefContext.belief_card
        belief={@belief}
        belief_id={@mutation.belief_id}
        index={@index}
        all_beliefs={@assertions}
        mutation={if @context?, do: nil, else: @mutation}
        anchor={"belief-#{@mutation.id}"}
      />

      <%= if @context? and @mutation.rationale do %>
        <div style="margin-top: -8px; margin-bottom: 14px; padding: 10px 14px; background: var(--bg-tertiary); border: 1px solid var(--border); border-left: 3px solid var(--accent-blue); border-radius: 6px;">
          <div style="margin-bottom: 4px;"><.section_label>Context note</.section_label></div>
          <p style="font-size: 12.5px; line-height: 1.55; color: var(--text-primary); white-space: pre-wrap;"><.linkify_belief_ids text={@mutation.rationale} /></p>
        </div>
      <% end %>
    </div>
    """
  end

  attr :mutation, :map, required: true
  attr :applied?, :boolean, required: true
  attr :editing?, :boolean, default: false

  defp status_controls(assigns) do
    assigns = assign(assigns, editable?: editable?(assigns.mutation))

    ~H"""
    <%= cond do %>
      <% @applied? -> %>
        <span style="font-size: 11px; color: var(--text-muted); font-style: italic;">
          applied{if @mutation.applied_at, do: " #{@mutation.applied_at}"} — author an inverse mutation to undo
        </span>

      <% @editing? -> %>
        <form
          phx-submit="save_alternative"
          style="display: inline-flex; gap: 4px; align-items: center; flex-wrap: wrap;"
        >
          <input type="hidden" name="mutation-id" value={@mutation.id} />
          <span style="font-size: 11px; color: var(--text-muted); font-family: ui-monospace, SFMono-Regular, monospace;">
            after.{editable_field_name(@mutation)} =
          </span>
          <input
            type="text"
            name="value"
            value={editable_value(@mutation)}
            autofocus
            phx-key="Escape"
            phx-keyup="cancel_edit"
            style="font-size: 12px; padding: 2px 6px; border-radius: 4px; border: 1px solid var(--accent-blue); background: var(--bg-tertiary); color: var(--text-primary); font-family: ui-monospace, SFMono-Regular, monospace; min-width: 240px;"
          />
          <button
            type="submit"
            style="font-size: 11px; padding: 2px 8px; border-radius: 10px; border: 1px solid var(--accent-green); background: transparent; color: var(--accent-green); cursor: pointer; font-family: ui-monospace, SFMono-Regular, monospace;"
          >
            Save
          </button>
          <button
            type="button"
            phx-click="cancel_edit"
            style="font-size: 11px; padding: 2px 8px; border-radius: 10px; border: 1px solid var(--text-muted); background: transparent; color: var(--text-muted); cursor: pointer; font-family: ui-monospace, SFMono-Regular, monospace;"
          >
            Cancel
          </button>
        </form>

      <% true -> %>
        <span style="display: inline-flex; gap: 4px;">
          <.status_button
            mutation_id={@mutation.id}
            to_status="applied"
            label="Approve"
            tone="green"
            current={@mutation.status}
          />
          <.status_button
            mutation_id={@mutation.id}
            to_status="rejected"
            label="Reject"
            tone="red"
            current={@mutation.status}
          />
          <.status_button
            mutation_id={@mutation.id}
            to_status="discuss"
            label="Discuss"
            tone="blue"
            current={@mutation.status}
          />
          <%= if @editable? do %>
            <button
              type="button"
              phx-click="open_edit"
              phx-value-mutation-id={@mutation.id}
              title={"Swap after.#{editable_field_name(@mutation)} to an alternative"}
              aria-label={"Edit alternative for #{@mutation.id}"}
              style="font-size: 11px; padding: 2px 8px; border-radius: 10px; border: 1px solid var(--border); background: transparent; color: var(--text-muted); cursor: pointer; font-family: ui-monospace, SFMono-Regular, monospace;"
            >
              ✎
            </button>
          <% end %>
        </span>
    <% end %>
    """
  end

  attr :mutation_id, :string, required: true
  attr :to_status, :string, required: true
  attr :label, :string, required: true
  attr :tone, :string, required: true, values: ~w(green red blue)
  attr :current, :string, required: true

  defp status_button(assigns) do
    assigns = assign(assigns, active?: assigns.current == assigns.to_status)

    ~H"""
    <button
      phx-click="set_status"
      phx-value-mutation-id={@mutation_id}
      phx-value-status={@to_status}
      disabled={@active?}
      aria-pressed={to_string(@active?)}
      style={"font-size: 11px; padding: 2px 8px; border-radius: 10px; border: 1px solid var(--accent-#{@tone}); background: #{if @active?, do: "var(--badge-bg-#{@tone})", else: "transparent"}; color: var(--accent-#{@tone}); cursor: #{if @active?, do: "default", else: "pointer"}; font-family: ui-monospace, SFMono-Regular, monospace; opacity: #{if @active?, do: "0.5", else: "1"};"}
    >
      {@label}
    </button>
    """
  end

  attr :errors, :list, required: true

  defp errors_block(assigns) do
    ~H"""
    <section style="margin-bottom: 24px; padding: 14px 16px; border: 1px solid var(--accent-red); border-radius: 6px; background: var(--badge-bg-red);">
      <div style="margin-bottom: 8px;">
        <.section_label>Manifest validation errors ({length(@errors)})</.section_label>
      </div>
      <ul style="font-size: 13px; color: var(--text-primary); padding-left: 18px; line-height: 1.7;">
        <li :for={err <- @errors}>{err}</li>
      </ul>
      <p style="font-size: 12px; color: var(--text-secondary); margin-top: 10px;">
        Rendering may be partial or incorrect until these are resolved. See <a href="/dag/proposals/files/SCHEMA.md" style="color: var(--accent-blue);">SCHEMA.md</a> for the contract.
      </p>
    </section>
    """
  end

  # Tone mappings for status badges. Two distinct tables because the
  # manifest-level and per-mutation status enums diverge ("partial" only
  # appears at manifest level; "discuss" only at mutation level).
  defp tone_for_proposal_status("pending"), do: :orange
  defp tone_for_proposal_status("partial"), do: :blue
  defp tone_for_proposal_status("applied"), do: :green
  defp tone_for_proposal_status("rejected"), do: :red
  defp tone_for_proposal_status(_), do: :neutral

  defp tone_for_mutation_status("pending"), do: :orange
  defp tone_for_mutation_status("applied"), do: :green
  defp tone_for_mutation_status("rejected"), do: :red
  defp tone_for_mutation_status("discuss"), do: :blue
  defp tone_for_mutation_status(_), do: :neutral

  defp mutation_counts(mutations) do
    Enum.frequencies_by(mutations, fn m -> m.status || "pending" end)
  end

  defp date_label(%Date{} = d), do: Date.to_iso8601(d)
  defp date_label(_), do: "undated"

  defp source_plan_link(rel) when is_binary(rel) do
    basename =
      rel
      |> Path.basename()
      |> Path.rootname()

    "/plans/#{basename}"
  end
end
