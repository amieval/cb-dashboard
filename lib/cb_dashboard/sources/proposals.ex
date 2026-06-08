defmodule CBDashboard.Sources.Proposals do
  @moduledoc """
  Pure module that walks `ops/dag-proposals/*.json` and returns proposal
  manifests as structured records.

  Per `ops/dag-proposals/SCHEMA.md`. Reads from disk on every call —
  cheap at our volumes. Manifests that fail validation are still returned
  (with `errors` populated) so the LiveView can render an inline error
  state rather than silently dropping them.

  ## Closed enums

  - Mutation types: `reclassify-kind`, `set-name`, `rename-name`,
    `supersede`, `retract`, `new-belief`, `add-dep`, `drop-dep`,
    `drop-field`, `context`.
  - Manifest statuses: `pending`, `partial`, `applied`, `rejected`.
  - Per-mutation statuses: `pending`, `applied`, `rejected`, `discuss`.

  ## `context` type

  Non-mutation entry whose purpose is to make a referenced belief
  inline-viewable in the proposal. No `before`/`after` payload; the
  rationale carries the prose explaining why this belief is being
  surfaced (e.g. it's a precondition the batch depends on, a reference
  that motivates other mutations, or a deliberately-not-mutated
  belief). Renders as a normal belief card without the diff overlay.
  """

  alias CB.JSON

  @mutation_types ~w(reclassify-kind set-name rename-name supersede retract new-belief add-dep drop-dep drop-field context)
  @manifest_statuses ~w(pending partial applied rejected)
  @mutation_statuses ~w(pending applied rejected discuss)

  defstruct [
    :slug,
    :path,
    :title,
    :author,
    :created,
    :status,
    :rationale,
    :source_plan,
    :mutations,
    :mtime,
    :raw,
    :errors
  ]

  @type mutation :: %{
          id: String.t(),
          type: String.t(),
          belief_id: String.t(),
          status: String.t(),
          rationale: String.t(),
          before: map() | nil,
          after: map() | nil,
          successor: String.t() | nil,
          dep: String.t() | nil,
          field: String.t() | nil,
          applied_at: String.t() | nil,
          applied_by: String.t() | nil
        }

  @type t :: %__MODULE__{
          slug: String.t(),
          path: String.t(),
          title: String.t() | nil,
          author: String.t() | nil,
          created: Date.t() | nil,
          status: String.t() | nil,
          rationale: String.t() | nil,
          source_plan: String.t() | nil,
          mutations: [mutation()],
          mtime: integer() | nil,
          raw: map(),
          errors: [String.t()]
        }

  @doc "Directory holding proposal manifests."
  def dir do
    CBDashboard.Paths.proposals_dir()
  end

  @doc """
  Closed enum of supported mutation types.
  Surfaced for SCHEMA.md cross-reference + UI vocabulary.
  """
  def mutation_types, do: @mutation_types

  @doc "Closed enum of manifest-level statuses."
  def manifest_statuses, do: @manifest_statuses

  @doc "Closed enum of per-mutation statuses."
  def mutation_statuses, do: @mutation_statuses

  @doc """
  Return all proposal manifests sorted by `created` desc, then slug desc.
  Malformed manifests are included with non-empty `errors`.
  """
  @spec list() :: [t()]
  def list do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.ends_with?(&1, ".json") and not String.starts_with?(&1, ".")))
        |> Enum.map(&Path.join(dir(), &1))
        |> Enum.map(&load/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&sort_key/1, :desc)

      {:error, _} ->
        []
    end
  end

  @doc "Find a single manifest by slug. Returns `{:ok, manifest}` or `:not_found`."
  @spec get(String.t()) :: {:ok, t()} | :not_found
  def get(slug) do
    path = Path.join(dir(), "#{slug}.json")

    if File.regular?(path) do
      {:ok, load(path)}
    else
      :not_found
    end
  end

  @doc """
  Update a single mutation's per-item status field on disk.

  Reads the manifest fresh, locates the mutation by id, replaces the
  `status` field, writes atomically. Returns the re-loaded manifest so
  the caller sees the new state.

  ## Options

  - `:expected_mtime` — caller-provided posix mtime captured at the
    time the caller last observed the file. If set and the current
    mtime differs, returns `{:error, :stale}` so the caller can re-load
    and re-display before re-trying. Without this option the function
    writes regardless of concurrent edits — single-operator UX is the
    norm and the LiveView passes mtime; tests usually omit it.
  - `:broadcast?` — defaults `true`. Broadcasts `:proposals_changed` on
    `"proposals:changes"` after a successful write so any open
    LiveView re-renders without waiting on the file watcher's poll
    interval. Set `false` in tests.

  ## Returns

  - `{:ok, updated_manifest}` — write succeeded
  - `{:error, {:invalid_status, status}}` — `new_status` not in `@mutation_statuses`
  - `{:error, :not_found}` — slug doesn't resolve to a file
  - `{:error, {:mutation_not_found, mutation_id}}` — mutation_id not in this manifest
  - `{:error, :stale}` — `:expected_mtime` set and current mtime differs
  - `{:error, reason}` — file I/O or JSON parse error

  ## Format normalization

  Reads with `Jason.decode(..., objects: :ordered_objects)` to preserve
  key order on write, so status flips produce minimal diffs. Jason's
  pretty-print expands inline single-pair objects like
  `{"name": null}` onto multiple lines — the first write to a manifest
  authored with the compact form lands a one-time format-normalization
  diff. Subsequent writes are clean.
  """
  @spec update_mutation_status(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def update_mutation_status(slug, mutation_id, new_status, opts \\ []) do
    if new_status not in @mutation_statuses do
      {:error, {:invalid_status, new_status}}
    else
      update_manifest(slug, opts, &put_mutation_status(&1, mutation_id, new_status))
    end
  end

  @doc """
  Replace the value of a single key inside a mutation's `after` object
  AND flip the mutation's status back to `pending`.

  Used by the swap-to-alternative affordance: when the user edits the
  proposed value (e.g. `set-name` swapping `"foo"` → `"bar"`), any
  prior approve/reject decision was based on the old proposal, so the
  status resets to `pending` and the row goes back into the queue.

  Only specific types accept edits today (`set-name` swaps `after.name`,
  `reclassify-kind` swaps `after.kind`); the caller is responsible for
  enforcing that contract — this function blindly writes `field → value`
  into `after`.

  Same opts as `update_mutation_status/4`. Returns the same shape.
  """
  @spec update_mutation_after_field(String.t(), String.t(), String.t(), term(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def update_mutation_after_field(slug, mutation_id, field, new_value, opts \\ []) do
    update_manifest(
      slug,
      opts,
      &swap_after_value(&1, mutation_id, field, new_value)
    )
  end

  @doc """
  Bulk-write `applied_at` + `applied_by` on a set of mutations.

  Called by the Apply-approved pipeline after `CB.Belief.Mutation.apply_batch/3`
  successfully lands the mutations in `assertions.json`. Single atomic
  write — all mutations in `mutation_ids` get the same `applied_at`
  timestamp so the batch is recognizable in the manifest.

  ## Options

  - `:applied_at` — ISO date. Defaults to today.
  - `:applied_by` — operator identifier. Defaults to `"user"`.
  - `:expected_mtime`, `:broadcast?` — same semantics as
    `update_mutation_status/4`.

  Mutations not in `mutation_ids` are untouched. Unknown ids are
  silently skipped (the apply pipeline already filtered to known ids;
  defensive behaviour here keeps the call site simple).
  """
  @spec mark_mutations_applied(String.t(), [String.t()], keyword()) ::
          {:ok, t()} | {:error, term()}
  def mark_mutations_applied(slug, mutation_ids, opts \\ []) do
    applied_at = Keyword.get(opts, :applied_at) || Date.utc_today() |> Date.to_iso8601()
    applied_by = Keyword.get(opts, :applied_by, "user")
    id_set = MapSet.new(mutation_ids)

    update_manifest(slug, opts, &mark_applied(&1, id_set, applied_at, applied_by))
  end

  # --- Shared write plumbing for manifest edits ---

  defp update_manifest(slug, opts, mutator) do
    path = Path.join(dir(), "#{slug}.json")

    if not File.regular?(path) do
      {:error, :not_found}
    else
      with {:ok, content} <- File.read(path),
           :ok <- check_expected_mtime(opts[:expected_mtime], file_mtime(path)),
           {:ok, ordered} <- Jason.decode(content, objects: :ordered_objects),
           {:ok, updated} <- mutator.(ordered),
           new_content = Jason.encode!(updated, pretty: true) <> "\n",
           {:ok, _} <- JSON.write_atomic_raw(path, new_content) do
        if Keyword.get(opts, :broadcast?, true), do: broadcast_changed()
        {:ok, load(path)}
      end
    end
  end

  defp check_expected_mtime(nil, _current), do: :ok
  defp check_expected_mtime(expected, current) when expected == current, do: :ok
  defp check_expected_mtime(_, _), do: {:error, :stale}

  # Walk an OrderedObject manifest, locate the mutations array, and replace
  # the `status` field on the matching mutation. Every other key keeps its
  # position so the on-disk diff is bounded to the one line that changed.
  defp put_mutation_status(%Jason.OrderedObject{values: top}, mutation_id, new_status) do
    case Enum.find_index(top, fn {k, _} -> k == "mutations" end) do
      nil ->
        {:error, :no_mutations_field}

      idx ->
        {_, mutations} = Enum.at(top, idx)

        case replace_status_in_list(mutations, mutation_id, new_status) do
          {:ok, updated} ->
            {:ok, %Jason.OrderedObject{values: List.replace_at(top, idx, {"mutations", updated})}}

          err ->
            err
        end
    end
  end

  defp put_mutation_status(_, _, _), do: {:error, :unexpected_manifest_shape}

  defp replace_status_in_list(mutations, mutation_id, new_status) when is_list(mutations) do
    case Enum.find_index(mutations, &mutation_id_matches?(&1, mutation_id)) do
      nil ->
        {:error, {:mutation_not_found, mutation_id}}

      idx ->
        original = Enum.at(mutations, idx)
        updated = replace_ordered_value(original, "status", new_status)
        {:ok, List.replace_at(mutations, idx, updated)}
    end
  end

  defp replace_status_in_list(_, _, _), do: {:error, :unexpected_manifest_shape}

  # Edit a single field inside the matching mutation's `after` object
  # and revert that mutation's status to `pending`. Atomic — both
  # changes land in the same write.
  defp swap_after_value(%Jason.OrderedObject{values: top}, mutation_id, field, new_value) do
    case Enum.find_index(top, fn {k, _} -> k == "mutations" end) do
      nil ->
        {:error, :no_mutations_field}

      idx ->
        {_, mutations} = Enum.at(top, idx)

        case Enum.find_index(mutations, &mutation_id_matches?(&1, mutation_id)) do
          nil ->
            {:error, {:mutation_not_found, mutation_id}}

          m_idx ->
            original = Enum.at(mutations, m_idx)

            updated =
              original
              |> swap_in_after(field, new_value)
              |> replace_ordered_value("status", "pending")

            updated_mutations = List.replace_at(mutations, m_idx, updated)

            {:ok,
             %Jason.OrderedObject{
               values: List.replace_at(top, idx, {"mutations", updated_mutations})
             }}
        end
    end
  end

  defp swap_after_value(_, _, _, _), do: {:error, :unexpected_manifest_shape}

  defp swap_in_after(%Jason.OrderedObject{values: vs} = mutation, field, new_value) do
    case Enum.find_index(vs, fn {k, _} -> k == "after" end) do
      nil ->
        # Defensive: `after` should exist for editable types but if it's
        # absent (e.g. an agent-authored manifest dropped it), create one.
        new_after = %Jason.OrderedObject{values: [{field, new_value}]}
        %{mutation | values: vs ++ [{"after", new_after}]}

      idx ->
        {_, after_obj} = Enum.at(vs, idx)
        new_after = replace_ordered_value(after_obj, field, new_value)
        %{mutation | values: List.replace_at(vs, idx, {"after", new_after})}
    end
  end

  # Iterate every mutation in the manifest; for those whose id appears
  # in `id_set`, write `applied_at` + `applied_by` (replacing any prior
  # values, though normally they're absent). Mutations not in the set
  # are untouched. Returns `{:ok, updated}` always — unknown ids are
  # silently no-ops (defensive; the apply pipeline pre-filters).
  defp mark_applied(%Jason.OrderedObject{values: top}, id_set, applied_at, applied_by) do
    case Enum.find_index(top, fn {k, _} -> k == "mutations" end) do
      nil ->
        {:error, :no_mutations_field}

      idx ->
        {_, mutations} = Enum.at(top, idx)

        updated_mutations =
          Enum.map(mutations, fn
            %Jason.OrderedObject{} = m ->
              if mutation_id_in?(m, id_set) do
                m
                |> replace_ordered_value("applied_at", applied_at)
                |> replace_ordered_value("applied_by", applied_by)
              else
                m
              end

            other ->
              other
          end)

        {:ok,
         %Jason.OrderedObject{values: List.replace_at(top, idx, {"mutations", updated_mutations})}}
    end
  end

  defp mutation_id_matches?(%Jason.OrderedObject{values: vs}, mutation_id) do
    Enum.any?(vs, fn {k, v} -> k == "id" and v == mutation_id end)
  end

  defp mutation_id_matches?(_, _), do: false

  defp mutation_id_in?(%Jason.OrderedObject{values: vs}, id_set) do
    Enum.any?(vs, fn {k, v} -> k == "id" and MapSet.member?(id_set, v) end)
  end

  defp replace_ordered_value(%Jason.OrderedObject{values: vs} = obj, key, new_value) do
    case Enum.find_index(vs, fn {k, _} -> k == key end) do
      nil -> %{obj | values: vs ++ [{key, new_value}]}
      idx -> %{obj | values: List.replace_at(vs, idx, {key, new_value})}
    end
  end

  defp broadcast_changed do
    Phoenix.PubSub.broadcast(CBDashboard.PubSub, "proposals:changes", :proposals_changed)
  end

  defp sort_key(%__MODULE__{created: %Date{} = d, slug: slug}),
    do: {Date.to_iso8601(d), slug}

  defp sort_key(%__MODULE__{slug: slug}), do: {"", slug}

  # --- Loading + validation ---

  defp load(path) do
    slug = Path.basename(path, ".json")
    mtime = file_mtime(path)

    case JSON.read(path) do
      {:ok, raw} when is_map(raw) ->
        build(slug, path, mtime, raw)

      {:ok, _} ->
        %__MODULE__{
          slug: slug,
          path: path,
          mtime: mtime,
          raw: %{},
          mutations: [],
          errors: ["manifest is not a JSON object"]
        }

      {:error, reason} ->
        %__MODULE__{
          slug: slug,
          path: path,
          mtime: mtime,
          raw: %{},
          mutations: [],
          errors: ["could not parse JSON: #{inspect(reason)}"]
        }
    end
  rescue
    e ->
      %__MODULE__{
        slug: Path.basename(path, ".json"),
        path: path,
        mutations: [],
        raw: %{},
        errors: ["exception during load: #{Exception.message(e)}"]
      }
  end

  defp build(slug, path, mtime, raw) do
    {created, created_err} = parse_date(raw["created"])
    {mutations, mutation_errors} = parse_mutations(raw["mutations"])

    errors =
      []
      |> require_field(raw, "slug", "slug missing")
      |> require_match(Map.get(raw, "slug"), slug, "slug field does not match filename (#{slug})")
      |> require_field(raw, "title", "title missing")
      |> require_field(raw, "created", "created missing")
      |> append(created_err)
      |> require_enum(raw["status"], @manifest_statuses, "manifest status invalid")
      |> ensure_mutations(raw["mutations"], mutations)
      |> Enum.concat(mutation_errors)
      |> Enum.reject(&is_nil/1)

    %__MODULE__{
      slug: slug,
      path: path,
      title: raw["title"],
      author: raw["author"],
      created: created,
      status: raw["status"] || "pending",
      rationale: raw["rationale"],
      source_plan: raw["source_plan"],
      mutations: mutations,
      mtime: mtime,
      raw: raw,
      errors: errors
    }
  end

  defp parse_mutations(nil), do: {[], ["mutations field missing"]}

  defp parse_mutations(list) when is_list(list) do
    {mutations, all_errors, _seen_ids} =
      list
      |> Enum.with_index()
      |> Enum.reduce({[], [], MapSet.new()}, fn {raw, idx}, {ms, errs, seen} ->
        {mutation, errs_for_this} = parse_mutation(raw, idx)

        dup_err =
          cond do
            mutation.id == nil -> nil
            MapSet.member?(seen, mutation.id) -> "mutation ##{idx} duplicate id #{mutation.id}"
            true -> nil
          end

        seen = if mutation.id, do: MapSet.put(seen, mutation.id), else: seen
        {ms ++ [mutation], errs ++ errs_for_this ++ List.wrap(dup_err), seen}
      end)

    {mutations, Enum.reject(all_errors, &is_nil/1)}
  end

  defp parse_mutations(_), do: {[], ["mutations must be an array"]}

  defp parse_mutation(raw, idx) when is_map(raw) do
    id = raw["id"]
    type = raw["type"]
    belief_id = raw["belief_id"]
    status = raw["status"]
    rationale = raw["rationale"]
    before = raw["before"]
    after_ = raw["after"]

    base_errors =
      []
      |> require_field(raw, "id", "mutation ##{idx} id missing")
      |> require_field(raw, "type", "mutation #{label(id, idx)} type missing")
      |> require_enum(
        type,
        @mutation_types,
        "mutation #{label(id, idx)} type #{inspect(type)} not in enum"
      )
      |> require_field(raw, "belief_id", "mutation #{label(id, idx)} belief_id missing")
      |> require_field(raw, "status", "mutation #{label(id, idx)} status missing")
      |> require_enum(
        status,
        @mutation_statuses,
        "mutation #{label(id, idx)} status #{inspect(status)} not in enum"
      )
      |> require_field(raw, "rationale", "mutation #{label(id, idx)} rationale missing")
      |> Enum.reject(&is_nil/1)

    type_errors = validate_type_shape(type, raw, label(id, idx))

    mutation = %{
      id: id,
      type: type,
      belief_id: belief_id,
      status: status || "pending",
      rationale: rationale,
      before: before,
      after: after_,
      successor: raw["successor"],
      dep: raw["dep"],
      field: raw["field"],
      applied_at: raw["applied_at"],
      applied_by: raw["applied_by"]
    }

    {mutation, base_errors ++ type_errors}
  end

  defp parse_mutation(_raw, idx) do
    {%{id: nil, type: nil, belief_id: nil, status: nil, rationale: nil},
     ["mutation ##{idx} is not a JSON object"]}
  end

  defp validate_type_shape("new-belief", raw, label) do
    after_ = raw["after"]
    belief_id = raw["belief_id"]

    errs = []

    errs =
      if is_map(after_),
        do: errs,
        else: errs ++ ["mutation #{label} new-belief missing after payload"]

    errs =
      if is_map(after_) && belief_id && Map.get(after_, "id") != belief_id do
        errs ++
          [
            "mutation #{label} new-belief: after.id (#{Map.get(after_, "id")}) ≠ belief_id (#{belief_id})"
          ]
      else
        errs
      end

    errs
  end

  defp validate_type_shape("supersede", raw, label) do
    after_ = raw["after"] || %{}
    successor = raw["successor"]

    errs = []
    errs = if successor, do: errs, else: errs ++ ["mutation #{label} supersede missing successor"]

    errs =
      if successor && Map.get(after_, "superseded_by") &&
           Map.get(after_, "superseded_by") != successor do
        errs ++ ["mutation #{label} supersede: after.superseded_by ≠ successor"]
      else
        errs
      end

    errs
  end

  defp validate_type_shape("retract", raw, label) do
    after_ = raw["after"] || %{}

    if Map.get(after_, "retracted_reason") in [nil, ""] do
      ["mutation #{label} retract missing after.retracted_reason"]
    else
      []
    end
  end

  defp validate_type_shape(type, raw, label) when type in ["add-dep", "drop-dep"] do
    if is_binary(raw["dep"]) do
      []
    else
      ["mutation #{label} #{type} missing dep field"]
    end
  end

  defp validate_type_shape("drop-field", raw, label) do
    if is_binary(raw["field"]) do
      []
    else
      ["mutation #{label} drop-field missing field name"]
    end
  end

  defp validate_type_shape(_, _, _), do: []

  # --- Tiny validation helpers ---

  defp require_field(errors, raw, key, msg) do
    case Map.get(raw, key) do
      nil -> errors ++ [msg]
      "" -> errors ++ [msg]
      _ -> errors
    end
  end

  defp require_match(_errors, value, expected, _) when value == expected, do: []

  defp require_match(errors, _value, _expected, msg) do
    errors ++ [msg]
  end

  defp require_enum(errors, value, _enum, _msg) when value in [nil, ""], do: errors

  defp require_enum(errors, value, enum, msg) do
    if value in enum, do: errors, else: errors ++ [msg]
  end

  defp append(list, nil), do: list
  defp append(list, item), do: list ++ [item]

  defp ensure_mutations(errors, nil, _), do: errors

  defp ensure_mutations(errors, list, []) when is_list(list),
    do: errors ++ ["mutations array is empty"]

  defp ensure_mutations(errors, _list, _parsed), do: errors

  defp label(nil, idx), do: "##{idx}"
  defp label(id, _idx), do: id

  defp parse_date(nil), do: {nil, "created missing"}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {date, nil}
      {:error, _} -> {nil, "created is not a valid YYYY-MM-DD date: #{value}"}
    end
  end

  defp parse_date(_), do: {nil, "created must be a string"}

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: m}} -> m
      _ -> nil
    end
  end
end
