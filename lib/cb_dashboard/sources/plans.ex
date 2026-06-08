defmodule CBDashboard.Sources.Plans do
  @moduledoc """
  Pure module that walks plan files and returns structured records.

  All plans live flat under `ops/plans/*.md`. Bucket membership (pending,
  paused, shipped, superseded, deprecated, evaluate) is derived from the
  `**Status:**` field in each plan's header — there is no parallel
  directory structure. Files never move over a plan's lifecycle; status
  changes are header edits.

  Reads from disk on every call — cheap enough at our volumes (low hundreds
  of files) and avoids any cache-invalidation question. The Plans LiveView
  calls `list/0` on mount and again on each `:plans_changed` PubSub message.

  Source-of-truth for the schema is `ops/plans/CLAUDE.md`:

      # Plan: <title>

      **Status:** pending | in-progress | paused (YYYY-MM-DD)
                  | done (YYYY-MM-DD) | superseded (YYYY-MM-DD)
                  | deprecated (YYYY-MM-DD) | evaluation needed
      **Tag:** advancing | flights | lodging | ... (one of the controlled vocabulary)
      **Effort:** small | medium | large
  """

  defstruct [
    :basename,
    :path,
    :title,
    :status,
    :bucket,
    :shipped?,
    :date,
    :done_date,
    :mtime,
    :effort,
    :tag,
    :parents,
    :has_recap?
  ]

  @type bucket :: :in_progress | :pending | :paused | :shipped | :superseded | :deprecated | :evaluate

  @type t :: %__MODULE__{
          basename: String.t(),
          path: String.t(),
          title: String.t(),
          status: String.t() | nil,
          bucket: bucket(),
          shipped?: boolean(),
          date: Date.t() | nil,
          done_date: Date.t() | nil,
          mtime: integer() | nil,
          effort: String.t() | nil,
          tag: String.t() | nil,
          parents: [String.t()],
          has_recap?: boolean()
        }

  @doc "Return plan lists for every bucket, derived from each plan's Status."
  @spec list() :: %{
          in_progress: [t()],
          pending: [t()],
          paused: [t()],
          shipped: [t()],
          superseded: [t()],
          deprecated: [t()],
          evaluate: [t()]
        }
  def list do
    all =
      CBDashboard.Paths.plans_dir()
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&parse/1)
      |> Enum.reject(&is_nil/1)

    by_bucket = Enum.group_by(all, & &1.bucket)

    %{
      in_progress: Map.get(by_bucket, :in_progress, []) |> Enum.sort_by(& &1.basename, :desc),
      pending: Map.get(by_bucket, :pending, []) |> sort_pending(),
      paused: Map.get(by_bucket, :paused, []) |> Enum.sort_by(& &1.basename, :desc),
      shipped: Map.get(by_bucket, :shipped, []) |> Enum.sort_by(& &1.basename, :desc),
      superseded: Map.get(by_bucket, :superseded, []) |> Enum.sort_by(& &1.basename, :desc),
      deprecated: Map.get(by_bucket, :deprecated, []) |> Enum.sort_by(& &1.basename, :desc),
      evaluate: Map.get(by_bucket, :evaluate, []) |> Enum.sort_by(& &1.basename, :desc)
    }
  end

  @doc """
  Group shipped plans by YYYY-MM bucket (newest first).

  Within a bucket, plans sort by actual ship date (`done_date` parsed from
  the `Status: done (YYYY-MM-DD)` header) descending, with file mtime and
  basename as deterministic tiebreakers.
  """
  @spec by_month([t()]) :: [{String.t(), [t()]}]
  def by_month(shipped) do
    shipped
    |> Enum.group_by(&month_bucket/1)
    |> Enum.sort_by(fn {bucket, _} -> bucket end, :desc)
    |> Enum.map(fn {bucket, items} ->
      {bucket, Enum.sort_by(items, &sort_key/1, :desc)}
    end)
  end

  defp sort_key(%__MODULE__{done_date: %Date{} = d, mtime: m, basename: b}) do
    {Date.to_iso8601(d), m || 0, b}
  end

  defp sort_key(%__MODULE__{date: %Date{} = d, mtime: m, basename: b}) do
    {Date.to_iso8601(d), m || 0, b}
  end

  defp sort_key(%__MODULE__{mtime: m, basename: b}), do: {"", m || 0, b}

  # --- Parsing ---

  defp parse(path) do
    basename = Path.basename(path, ".md")

    if basename == "CLAUDE" do
      nil
    else
      header = read_header(path)
      status = extract_field(header, "Status")
      bucket = classify(status)

      %__MODULE__{
        basename: basename,
        path: path,
        title: extract_title(header) || basename,
        status: status,
        bucket: bucket,
        shipped?: bucket == :shipped,
        date: filename_date(basename),
        done_date: status_done_date(header) || (bucket == :shipped && filename_date(basename)) || nil,
        mtime: file_mtime(path),
        effort: extract_field(header, "Effort"),
        tag: extract_field(header, "Tag"),
        parents: parse_parents(extract_field(header, "Parent")),
        has_recap?: recap_in_body?(path)
      }
    end
  rescue
    _ -> nil
  end

  # Field values for plan refs are often `` `bucket/basename.md` `` —
  # strip wrappers down to the bare basename so children_of/1 can match.
  defp normalize_basename_ref(nil), do: nil

  defp normalize_basename_ref(value) do
    value
    |> String.trim()
    |> String.trim("`")
    |> String.replace_suffix(".md", "")
    |> String.replace(~r{^(?:ops/plans/)?(?:done/|paused/|superseded/|deprecated/|evaluate/)?}, "")
    |> case do
      "" -> nil
      bn -> bn
    end
  end

  # Parent: field is comma-separated; a plan can declare multiple
  # parents when it sits at the intersection of two upstream plans.
  # Returns a list of normalized basenames (empty list when no parent
  # is declared) so callers don't need to handle a nil case.
  defp parse_parents(nil), do: []

  defp parse_parents(value) do
    value
    |> String.split(",")
    |> Enum.map(&normalize_basename_ref/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Return every plan whose `Parent:` field contains the given basename.
  Used by `PlanLive` to render the Children block at view time — keeps
  parent/child as a single source of truth (only Parent stored).
  Handles plans with multiple parents (comma-separated Parent: field).
  """
  @spec children_of(String.t()) :: [t()]
  def children_of(basename) do
    all()
    |> Enum.filter(fn p -> basename in p.parents end)
    |> Enum.sort_by(& &1.basename)
  end

  @doc "All plans, flat. Used by `children_of/1` and other cross-plan queries."
  @spec all() :: [t()]
  def all do
    CBDashboard.Paths.plans_dir()
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&parse/1)
    |> Enum.reject(&is_nil/1)
  end

  # Classify the `Status:` field value into one of the bucket atoms. The
  # value typically looks like "done (2026-05-16)" or "paused (2026-05-15)"
  # or just "pending" / "in-progress" / "evaluation needed".
  defp classify(nil), do: :pending

  defp classify(value) do
    cond do
      String.match?(value, ~r/^done\b/i) -> :shipped
      String.match?(value, ~r/^in[-\s]progress\b/i) -> :in_progress
      String.match?(value, ~r/^paused\b/i) -> :paused
      String.match?(value, ~r/^superseded\b/i) -> :superseded
      String.match?(value, ~r/^deprecated\b/i) -> :deprecated
      String.match?(value, ~r/^evaluation\b/i) -> :evaluate
      true -> :pending
    end
  end

  @doc """
  Quick status lookup for a basename without parsing the whole plan.
  Returns `nil` if the plan doesn't exist or has no Status field.
  Used by `PlanLinks` to render an inline status badge after each link.
  """
  @spec status_meta(String.t()) :: %{bucket: bucket(), label: String.t()} | nil
  def status_meta(basename) do
    path = Path.join(CBDashboard.Paths.plans_dir(), "#{basename}.md")

    with {:ok, body} <- File.read(path),
         header = body |> String.split("\n") |> Enum.take(40) |> Enum.join("\n"),
         [_, raw_status] <- Regex.run(~r/^\*\*Status:\*\*\s*(.+?)\s*$/m, header) do
      %{bucket: classify(raw_status), label: status_label(raw_status)}
    else
      _ -> nil
    end
  end

  # Display label for the badge — the first word of the Status field,
  # capitalized. `done (2026-05-16)` → "Done". `evaluation needed` →
  # "Evaluation". Matches the keyword captured by PlanLive's status badge.
  defp status_label(raw_status) do
    raw_status
    |> String.split()
    |> List.first()
    |> case do
      nil -> ""
      word -> String.capitalize(word)
    end
  end

  # A plan "has a recap" once its body contains a top-level `## Recap`
  # section. Cheap to scan since plans top out at a few hundred lines.
  defp recap_in_body?(path) do
    case File.read(path) do
      {:ok, body} -> Regex.match?(~r/^## Recap\b/m, body)
      _ -> false
    end
  end

  defp read_header(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.split("\n") |> Enum.take(40) |> Enum.join("\n")
      _ -> ""
    end
  end

  defp extract_title(header) do
    case Regex.run(~r/^#\s*Plan:\s*(.+?)\s*$/m, header) do
      [_, title] -> title
      _ ->
        case Regex.run(~r/^#\s*(.+?)\s*$/m, header) do
          [_, title] -> title
          _ -> nil
        end
    end
  end

  defp extract_field(header, name) do
    case Regex.run(~r/^\*\*#{name}:\*\*\s*(.+?)\s*$/m, header) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp status_done_date(header) do
    case Regex.run(~r/Status:\*\*\s*done\s*\((\d{4}-\d{2}-\d{2})\)/, header) do
      [_, date_str] -> Date.from_iso8601!(date_str)
      _ -> nil
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: m}} -> m
      _ -> nil
    end
  end

  defp filename_date(basename) do
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2})/, basename) do
      [_, date_str] -> Date.from_iso8601!(date_str)
      _ -> nil
    end
  end

  # --- Sorting ---

  defp sort_pending(plans) do
    {dated, undated} = Enum.split_with(plans, &(&1.date != nil))

    dated_sorted = Enum.sort_by(dated, & &1.date, {:desc, Date})
    undated_sorted = Enum.sort_by(undated, & &1.basename)

    dated_sorted ++ undated_sorted
  end

  defp month_bucket(%__MODULE__{date: %Date{} = d}) do
    "#{d.year}-#{String.pad_leading("#{d.month}", 2, "0")}"
  end

  defp month_bucket(_), do: "undated"
end
