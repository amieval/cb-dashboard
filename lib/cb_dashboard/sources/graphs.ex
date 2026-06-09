defmodule CBDashboard.Sources.Graphs do
  @moduledoc """
  Resolves the belief graphs a user has registered with the dashboard.

  The dashboard is a general viewer: it owns no path to anyone's data. The
  graphs to show come from a user-supplied **sources file**
  (`CBDashboard.Paths.sources_file/0`, default `config/sources.local.json`,
  gitignored) — there is no baked-in default pointing at real data. Absent a
  sources file (and the env overrides below), the viewer shows nothing until the
  user adds a source. `config/sources.example.json` documents the format.

  Two kinds of source:

  - **registries** — `collections.json` files mapping namespaces to
    `beliefs.json`, resolved through `CB.Collection` (namespaced collections with
    `depends_on` dependency closures). Each namespace becomes a selectable entry.
  - **graphs** — standalone `beliefs.json` files at any path, each a single
    selectable entry with no closure.

  Env overrides append to the file: `CB_COLLECTIONS` adds a registry,
  `CB_BELIEFS` adds a single graph labelled `default`. Relative paths in the
  sources file resolve against the file's own directory.

  An entry is `%{key, label, kind, description, path}` where `kind` is
  `:collection` or `:graph` and `key` is the URL-safe selector/route id (a
  collection's namespace, or a graph label slug).
  """

  alias CB.{Belief, Collection, JSON}
  alias CBDashboard.Paths

  @typedoc "A selectable graph source."
  @type entry :: %{
          key: String.t(),
          label: String.t(),
          kind: :collection | :graph,
          description: String.t() | nil,
          path: String.t() | nil
        }

  # --- configuration ---

  @doc "Parsed sources: registry paths + standalone graph specs (file + env)."
  @spec config() :: %{registries: [String.t()], graphs: [%{label: String.t(), path: String.t()}]}
  def config do
    path = Paths.sources_file()
    file = read_sources_file(path)

    %{
      registries: file.registries ++ env_registries(),
      graphs: file.graphs ++ env_graphs()
    }
  end

  defp read_sources_file(path) do
    with true <- is_binary(path) and File.exists?(path),
         {:ok, %{} = m} <- JSON.read(path) do
      dir = Path.dirname(path)

      %{
        registries: m["registries"] |> list_of_strings() |> Enum.map(&Path.expand(&1, dir)),
        graphs:
          m["graphs"]
          |> parse_graphs()
          |> Enum.map(fn g -> %{g | path: Path.expand(g.path, dir)} end)
      }
    else
      _ -> %{registries: [], graphs: []}
    end
  end

  defp env_registries do
    case System.get_env("CB_COLLECTIONS") do
      p when is_binary(p) and p != "" -> [Path.expand(p)]
      _ -> []
    end
  end

  defp env_graphs do
    case System.get_env("CB_BELIEFS") do
      p when is_binary(p) and p != "" -> [%{label: "default", path: Path.expand(p)}]
      _ -> []
    end
  end

  defp list_of_strings(l) when is_list(l), do: Enum.filter(l, &is_binary/1)
  defp list_of_strings(_), do: []

  defp parse_graphs(l) when is_list(l) do
    for g <- l, is_map(g), is_binary(g["path"]) do
      %{label: g["label"] || Path.basename(Path.dirname(g["path"])), path: g["path"]}
    end
  end

  defp parse_graphs(_), do: []

  # --- entries (for the selector) ---

  @doc "All selectable sources, registry collections first then standalone graphs, keys unique."
  @spec entries() :: [entry()]
  def entries do
    cfg = config()

    registry_entries = Enum.flat_map(cfg.registries, &registry_entries/1)
    graph_entries = Enum.map(cfg.graphs, &graph_entry/1)

    Enum.uniq_by(registry_entries ++ graph_entries, & &1.key)
  end

  defp registry_entries(path) do
    case Collection.registry(path) do
      {:ok, reg} ->
        Enum.map(Collection.namespaces(reg), fn ns ->
          %{key: ns, label: ns, kind: :collection, description: description(ns, reg), path: nil}
        end)

      {:error, _} ->
        []
    end
  end

  defp graph_entry(%{label: label, path: path}) do
    %{key: slug(label), label: label, kind: :graph, description: path, path: path}
  end

  @doc "Default source to show when none is selected: `cb` if present, else the first, else `nil`."
  @spec default_key() :: String.t() | nil
  def default_key do
    case entries() do
      [] -> nil
      list -> if Enum.any?(list, &(&1.key == "cb")), do: "cb", else: hd(list).key
    end
  end

  # --- loading ---

  @doc """
  Beliefs for a source key. A `:collection` resolves to its dependency-closure
  union; a `:graph` to that file's beliefs; `"all"` to the global union across
  every source (de-duped by id).
  """
  @spec load(String.t()) :: {:ok, [Belief.t()]} | {:error, term()}
  def load("all"), do: load_all()

  def load(key) do
    case Enum.find(entries(), &(&1.key == key)) do
      %{kind: :collection, key: ns} -> load_collection(ns)
      %{kind: :graph, path: path} -> load_graph(path)
      nil -> {:error, :unknown_source}
    end
  end

  defp load_collection(ns) do
    with {:ok, reg} <- registry_for(ns),
         {:ok, %{union: union}} <- Collection.load_union(ns, reg) do
      {:ok, union}
    end
  end

  defp load_graph(path) do
    if File.exists?(path) do
      with {:ok, data} <- JSON.read(path) do
        if is_list(data),
          do: {:ok, Enum.map(data, &Belief.from_map/1)},
          else: {:error, {:not_an_array, path}}
      end
    else
      {:error, {:missing, path}}
    end
  end

  # Global union: each collection's own beliefs (read once, not via closures) plus
  # every standalone graph, de-duped by id.
  defp load_all do
    cfg = config()

    from_registries =
      Enum.flat_map(cfg.registries, fn path ->
        case Collection.registry(path) do
          {:ok, reg} ->
            reg
            |> Collection.namespaces()
            |> Enum.flat_map(fn ns ->
              case Collection.load(ns, reg) do
                {:ok, bs} -> bs
                _ -> []
              end
            end)

          _ ->
            []
        end
      end)

    from_graphs =
      Enum.flat_map(cfg.graphs, fn g ->
        case load_graph(g.path) do
          {:ok, bs} -> bs
          _ -> []
        end
      end)

    {:ok, Enum.uniq_by(from_registries ++ from_graphs, & &1.id)}
  end

  # --- helpers for other modules ---

  @doc """
  The registry that contains `namespace`, for callers that need to resolve a
  specific collection's `beliefs.json` (e.g. the proposal-apply write path).
  """
  @spec registry_for(String.t()) :: {:ok, Collection.Registry.t()} | {:error, :unknown_source}
  def registry_for(namespace) do
    config().registries
    |> Enum.find_value({:error, :unknown_source}, fn path ->
      case Collection.registry(path) do
        {:ok, reg} -> if Map.has_key?(reg.collections, namespace), do: {:ok, reg}, else: false
        _ -> false
      end
    end)
  end

  @doc "Every on-disk graph file across all sources, for the Watcher to fingerprint."
  @spec belief_paths() :: [String.t()]
  def belief_paths do
    cfg = config()

    registry_paths =
      Enum.flat_map(cfg.registries, fn path ->
        case Collection.registry(path) do
          {:ok, reg} ->
            reg
            |> Collection.namespaces()
            |> Enum.flat_map(fn ns ->
              case Collection.collection_path(ns, reg) do
                {:ok, p} -> [p]
                _ -> []
              end
            end)

          _ ->
            []
        end
      end)

    Enum.uniq(registry_paths ++ Enum.map(cfg.graphs, & &1.path))
  end

  # --- internal ---

  defp description(ns, reg) do
    with {:ok, path} <- Collection.collection_path(ns, reg),
         manifest = path |> Path.dirname() |> Path.join("manifest.json"),
         {:ok, %{"description" => d}} when is_binary(d) <- JSON.read(manifest) do
      d
    else
      _ -> nil
    end
  end

  defp slug(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end
end
