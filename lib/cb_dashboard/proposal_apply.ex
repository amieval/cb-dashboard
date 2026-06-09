defmodule CBDashboard.ProposalApply do
  @moduledoc """
  Applies an approved DAG proposal to its target belief collection.

  The dashboard's one mutating operation. Given a proposal slug, it:

  1. collects the queued mutations (status `applied`, not yet landed, non-context),
  2. resolves the manifest's **target collection** — its `namespace` field maps,
     through the collections registry, to the `beliefs.json` to edit; a manifest
     without a namespace falls back to the single graph at
     `CB.Config.beliefs_path/0` (back-compat with the pre-collections world),
  3. reads that graph, folds the mutations over it with
     `CB.Belief.Mutation.apply_batch/3`, writes it back atomically,
  4. stamps `applied_at`/`applied_by` on the manifest, and
  5. git-commits the touched files **each in their own repo** — the collection's
     `beliefs.json` and the proposal manifest can live in different repos, so the
     commit is grouped by `git rev-parse --show-toplevel`.

  Extracted from the LiveView so the pipeline is callable and testable in
  isolation. The caller (the LiveView) owns the read-only gate
  (`CBDashboard.Paths.mutations_enabled?/0`); this module assumes it may write.
  """

  alias CB.Belief
  alias CB.Belief.{Mutation, Store}
  alias CBDashboard.Paths
  alias CBDashboard.Sources.{Graphs, Proposals}

  @doc """
  Apply a slug's approved mutations to its target collection.

  Options:
  - `:commit?` (default `true`) — git-commit the touched files. Set `false` in
    tests that don't want to shell out to git.
  - `:broadcast?` — forwarded to `Proposals.mark_mutations_applied/3`.

  Returns `{:ok, %{count, namespace, commit}}` where `commit` is `:ok`,
  `{:error, reason}` (commit failed; files were still written), or `:skipped`
  (when `commit?: false`). Error returns mirror the prior pipeline:
  `{:error, :nothing_to_apply}`, `{:error, {:apply_failed, {id, reason}}}`,
  `{:error, {:unknown_collection, ns, reason}}`, or a raw I/O error.
  """
  @spec apply_approved(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_approved(slug, opts \\ []) do
    with {:ok, manifest} <- Proposals.get(slug),
         to_apply <- queued(manifest.mutations),
         :ok <- ensure_non_empty(to_apply),
         {:ok, target} <- resolve_target(manifest),
         {:ok, beliefs} <- read_target(target),
         {:ok, updated} <- run_apply_batch(to_apply, beliefs, slug),
         {:ok, _path} <- Store.write(updated, target.beliefs_path),
         {:ok, _manifest} <-
           Proposals.mark_mutations_applied(
             slug,
             Enum.map(to_apply, & &1.id),
             Keyword.take(opts, [:broadcast?])
           ) do
      {:ok,
       %{
         count: length(to_apply),
         namespace: target.namespace,
         commit: maybe_commit(slug, to_apply, target, opts)
       }}
    end
  end

  @doc "The mutations a slug's manifest would apply: approved, not yet landed, non-context."
  @spec queued([map()]) :: [map()]
  def queued(mutations), do: Enum.filter(mutations, &queueable?/1)

  @doc "How many mutations are queued for apply."
  @spec queued_count([map()]) :: non_neg_integer()
  def queued_count(mutations), do: Enum.count(mutations, &queueable?/1)

  # A mutation is queued when it's approved (status=applied), hasn't landed yet
  # (applied_at=nil), and actually changes the DAG (type ≠ context).
  defp queueable?(%{type: "context"}), do: false
  defp queueable?(%{status: "applied", applied_at: nil}), do: true
  defp queueable?(_), do: false

  defp ensure_non_empty([]), do: {:error, :nothing_to_apply}
  defp ensure_non_empty(_), do: :ok

  # --- target resolution ---

  # Where this manifest's mutations land. With a namespace, resolve its
  # beliefs.json through the registry; without one, the single default graph.
  defp resolve_target(%{namespace: ns}) when is_binary(ns) and ns != "" do
    with {:ok, reg} <- Graphs.registry_for(ns),
         {:ok, path} <- CB.Collection.collection_path(ns, reg) do
      {:ok, %{namespace: ns, beliefs_path: path}}
    else
      {:error, reason} -> {:error, {:unknown_collection, ns, reason}}
    end
  end

  defp resolve_target(_manifest) do
    {:ok, %{namespace: nil, beliefs_path: CB.Config.beliefs_path()}}
  end

  defp read_target(%{beliefs_path: path}) do
    if File.exists?(path) do
      with {:ok, data} <- CB.JSON.read(path) do
        if is_list(data),
          do: {:ok, Enum.map(data, &Belief.from_map/1)},
          else: {:error, {:not_an_array, path}}
      end
    else
      {:ok, []}
    end
  end

  defp run_apply_batch(to_apply, beliefs, slug) do
    case Mutation.apply_batch(to_apply, beliefs, slug: slug) do
      {:ok, _} = ok -> ok
      {:error, {id, reason}} when is_binary(id) -> {:error, {:apply_failed, {id, reason}}}
      err -> err
    end
  end

  # --- commit (each file in its own repo) ---

  defp maybe_commit(slug, mutations, target, opts) do
    if Keyword.get(opts, :commit?, true) do
      commit(slug, mutations, target)
    else
      :skipped
    end
  end

  defp commit(slug, mutations, target) do
    message = build_commit_message(slug, mutations)
    manifest_path = Path.join(Paths.proposals_dir(), "#{slug}.json")

    [target.beliefs_path, manifest_path]
    |> Enum.map(&Path.expand/1)
    |> Enum.map(&{&1, git_root(&1)})
    |> commit_by_repo(message)
  end

  # Group the touched files by their git toplevel and make one commit per repo,
  # so a beliefs.json and a manifest in different repos each get committed in
  # their own.
  defp commit_by_repo(file_roots, message) do
    case Enum.split_with(file_roots, fn {_f, root} -> match?({:ok, _}, root) end) do
      {oks, []} ->
        oks
        |> Enum.group_by(fn {_f, {:ok, root}} -> root end, fn {f, _} -> f end)
        |> Enum.reduce_while(:ok, fn {root, paths}, :ok ->
          rels = Enum.map(paths, &Path.relative_to(&1, root))

          with :ok <- run_git(root, ["add" | rels]),
               :ok <- run_git(root, ["commit", "-m", message]) do
            {:cont, :ok}
          else
            err -> {:halt, err}
          end
        end)

      {_oks, [{file, _err} | _]} ->
        {:error, {:not_in_git_repo, file}}
    end
  end

  defp git_root(path) do
    case System.cmd("git", ["rev-parse", "--show-toplevel"],
           cd: Path.dirname(path),
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {:git_exit, code, String.trim(out)}}
    end
  end

  defp run_git(cd, args) do
    case System.cmd("git", args, cd: cd, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:git_exit, code, String.trim(out)}}
    end
  end

  defp build_commit_message(slug, mutations) do
    n = length(mutations)
    header = "dag: #{slug} — apply #{n} mutation#{plural(n)}"
    bullets = mutations |> Enum.map(fn m -> "- #{Mutation.summary(m)}" end) |> Enum.join("\n")

    """
    #{header}

    #{bullets}

    Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
    """
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
