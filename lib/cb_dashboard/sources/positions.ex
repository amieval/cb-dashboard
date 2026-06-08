defmodule CBDashboard.Sources.Positions do
  @moduledoc """
  Pure module that walks position artifacts and returns structured records.

  Positions live flat under `ops/position/*.md`. Format spec is in
  `ops/position/CLAUDE.md`. Each artifact has a header block with `Type:
  position`, `Status:`, `Authored:`, and a body of `### Claim:` sections,
  each with a `**DAG status:**` line and optional `**Belief:**` line.

  This module parses the header and enumerates claims with their declared
  status — no live DAG join yet. The render-time join that derives computed
  status from `org/assertions/assertions.json` is tracked in
  `ops/plans/2026-05-17-position-mechanics.md`.

  Reads from disk on every call — cheap at our volumes (single-digit files).
  The PositionsLive calls `list/0` on mount and on each `:positions_changed`
  PubSub message.
  """

  defstruct [
    :basename,
    :path,
    :title,
    :status,
    :bucket,
    :authored,
    :origin,
    :companion_plans,
    :mtime,
    :claims
  ]

  defmodule Claim do
    @moduledoc false
    defstruct [:index, :text, :declared_status, :belief_ids, :domain]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            text: String.t(),
            declared_status: String.t() | nil,
            belief_ids: [String.t()],
            domain: String.t() | nil
          }
  end

  @type bucket :: :active | :superseded | :abandoned

  @type t :: %__MODULE__{
          basename: String.t(),
          path: String.t(),
          title: String.t(),
          status: String.t() | nil,
          bucket: bucket(),
          authored: Date.t() | nil,
          origin: String.t() | nil,
          companion_plans: [String.t()],
          mtime: integer() | nil,
          claims: [Claim.t()]
        }

  @doc "Return position artifacts grouped by bucket (active / superseded / abandoned)."
  @spec list() :: %{active: [t()], superseded: [t()], abandoned: [t()]}
  def list do
    all =
      CBDashboard.Paths.positions_dir()
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&parse/1)
      |> Enum.reject(&is_nil/1)

    by_bucket = Enum.group_by(all, & &1.bucket)

    %{
      active: Map.get(by_bucket, :active, []) |> Enum.sort_by(& &1.basename, :desc),
      superseded: Map.get(by_bucket, :superseded, []) |> Enum.sort_by(& &1.basename, :desc),
      abandoned: Map.get(by_bucket, :abandoned, []) |> Enum.sort_by(& &1.basename, :desc)
    }
  end

  @doc "Tally claims by their declared status across all positions in the input list."
  @spec claim_tally([t()]) :: %{String.t() => non_neg_integer()}
  def claim_tally(positions) do
    positions
    |> Enum.flat_map(& &1.claims)
    |> Enum.frequencies_by(&(&1.declared_status || "unmarked"))
  end

  # --- Parsing ---

  defp parse(path) do
    basename = Path.basename(path, ".md")

    if basename == "CLAUDE" do
      nil
    else
      case File.read(path) do
        {:ok, body} ->
          header = body |> String.split("\n") |> Enum.take(40) |> Enum.join("\n")
          status = extract_field(header, "Status")

          %__MODULE__{
            basename: basename,
            path: path,
            title: extract_title(header) || basename,
            status: status,
            bucket: classify(status),
            authored: parse_authored(header),
            origin: extract_field(header, "Origin"),
            companion_plans: extract_list(header, "Companion plans"),
            mtime: file_mtime(path),
            claims: parse_claims(body)
          }

        _ ->
          nil
      end
    end
  rescue
    _ -> nil
  end

  defp classify(nil), do: :active

  defp classify(value) do
    cond do
      String.match?(value, ~r/^active\b/i) -> :active
      String.match?(value, ~r/^superseded\b/i) -> :superseded
      String.match?(value, ~r/^abandoned\b/i) -> :abandoned
      true -> :active
    end
  end

  defp extract_title(header) do
    case Regex.run(~r/^#\s*Position:\s*(.+?)\s*$/m, header) do
      [_, title] ->
        title

      _ ->
        case Regex.run(~r/^#\s*(.+?)\s*$/m, header) do
          [_, title] -> title
          _ -> nil
        end
    end
  end

  defp extract_field(header, name) do
    case Regex.run(~r/^\*\*#{Regex.escape(name)}:\*\*\s*(.+?)\s*$/m, header) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp extract_list(header, name) do
    case extract_field(header, name) do
      nil -> []
      raw -> raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end
  end

  defp parse_authored(header) do
    case extract_field(header, "Authored") do
      nil ->
        nil

      raw ->
        case Regex.run(~r/(\d{4}-\d{2}-\d{2})/, raw) do
          [_, date_str] ->
            case Date.from_iso8601(date_str) do
              {:ok, d} -> d
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  # Split the body on `### Claim:` headings and parse each block.
  defp parse_claims(body) do
    body
    |> String.split(~r/^### Claim:\s*/m, trim: true)
    # The first chunk is everything before the first `### Claim:`.
    |> Enum.drop(1)
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, index} -> parse_claim(chunk, index) end)
  end

  defp parse_claim(chunk, index) do
    [first_line | rest] = String.split(chunk, "\n", parts: 2)
    rest_body = List.first(rest) || ""

    %Claim{
      index: index,
      text: String.trim(first_line),
      declared_status: extract_field(rest_body, "DAG status"),
      belief_ids: extract_belief_ids(rest_body),
      domain: extract_field(rest_body, "Domain")
    }
  end

  # Pull `[[aNNN]]` style refs from the `**Belief:**` line.
  defp extract_belief_ids(body) do
    case extract_field(body, "Belief") do
      nil ->
        []

      raw ->
        Regex.scan(~r/\[\[([a-z]\d+)\]\]/i, raw)
        |> Enum.map(fn [_, id] -> id end)
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: m}} -> m
      _ -> nil
    end
  end
end
