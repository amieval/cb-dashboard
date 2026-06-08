defmodule CBDashboard.Sources.Collections do
  @moduledoc """
  Thin dashboard-side wrapper over `CB.Collection` (the framework's collection
  resolver). Resolves the registry from `CBDashboard.Paths.collections_registry/0`
  and exposes just what the DAG view needs: the list of available collections,
  the union of beliefs for a selected one (collection + its dependency closure),
  and the on-disk `beliefs.json` paths the Watcher fingerprints.

  Everything degrades gracefully: when no registry is configured or present,
  `available/0` is `[]` and the view falls back to the single graph at
  `CB.Config.beliefs_path/0`.
  """

  alias CB.Collection

  @doc "Load the configured registry, or `{:error, reason}` if absent/invalid."
  @spec registry() :: {:ok, Collection.Registry.t()} | {:error, term()}
  def registry, do: Collection.registry(CBDashboard.Paths.collections_registry())

  @doc """
  Available collections as `%{namespace: ns, description: str | nil}`, sorted by
  namespace. `[]` when no registry resolves (single-graph mode).
  """
  @spec available() :: [%{namespace: String.t(), description: String.t() | nil}]
  def available do
    case registry() do
      {:ok, reg} ->
        Enum.map(Collection.namespaces(reg), fn ns ->
          %{namespace: ns, description: description(ns, reg)}
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Default namespace to show when none is selected: `cb` if present (the
  framework's own graph), else the first available, else `nil` (single-graph
  fallback).
  """
  @spec default_namespace() :: String.t() | nil
  def default_namespace do
    case available() do
      [] -> nil
      list -> if Enum.any?(list, &(&1.namespace == "cb")), do: "cb", else: hd(list).namespace
    end
  end

  @doc """
  Beliefs for a namespace: the union of the collection and its transitive
  dependency closure. `{:error, reason}` if the namespace or registry is bad.
  """
  @spec load_union(String.t()) :: {:ok, [CB.Belief.t()]} | {:error, term()}
  def load_union(namespace) do
    with {:ok, reg} <- registry(),
         {:ok, %{union: union}} <- Collection.load_union(namespace, reg) do
      {:ok, union}
    end
  end

  @doc """
  Every registered collection's beliefs, concatenated and de-duplicated by id —
  the global union across all namespaces (the "all" view). Each collection file
  is read once (not via closures), so there's no cross-namespace overlap to
  merge; `uniq_by` is just defensive.
  """
  @spec load_all() :: {:ok, [CB.Belief.t()]} | {:error, term()}
  def load_all do
    case registry() do
      {:ok, reg} ->
        beliefs =
          reg
          |> Collection.namespaces()
          |> Enum.flat_map(fn ns ->
            case Collection.load(ns, reg) do
              {:ok, bs} -> bs
              _ -> []
            end
          end)
          |> Enum.uniq_by(& &1.id)

        {:ok, beliefs}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Absolute `beliefs.json` paths for every registered collection, for the Watcher
  to fingerprint. `[]` when no registry resolves.
  """
  @spec belief_paths() :: [String.t()]
  def belief_paths do
    case registry() do
      {:ok, reg} ->
        reg
        |> Collection.namespaces()
        |> Enum.flat_map(fn ns ->
          case Collection.collection_path(ns, reg) do
            {:ok, path} -> [path]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp description(ns, reg) do
    # The manifest carries the human description; reuse the framework's
    # path resolution and read it best-effort.
    with {:ok, path} <- Collection.collection_path(ns, reg),
         manifest = path |> Path.dirname() |> Path.join("manifest.json"),
         {:ok, %{"description" => d}} when is_binary(d) <- CB.JSON.read(manifest) do
      d
    else
      _ -> nil
    end
  end
end
