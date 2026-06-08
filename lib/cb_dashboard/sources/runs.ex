defmodule CBDashboard.Sources.Runs do
  @moduledoc """
  Walks `org/agents/runs/*.json` and returns parsed agent-run records.

  Per-run JSON shape (subset used here):

      {
        "id": "2026-05-15-001",
        "agent": "show-check",
        "status": "completed" | "needs-review" | "running" | "failed",
        "started": "2026-05-15T10:00:00Z",
        "finished": "2026-05-15T10:00:01.612Z" | null,
        "steps": [...],
        "alerts": [...]
      }

  A sibling `<id>.html` file (when present) is the per-run detail page served
  via the static plug.
  """

  defstruct [
    :id,
    :path,
    :agent,
    :status,
    :started,
    :finished,
    :duration_s,
    :step_count,
    :alert_count,
    :detail_relpath
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          agent: String.t() | nil,
          status: String.t() | nil,
          started: DateTime.t() | nil,
          finished: DateTime.t() | nil,
          duration_s: float() | nil,
          step_count: non_neg_integer(),
          alert_count: non_neg_integer(),
          detail_relpath: String.t() | nil
        }

  @doc "Return all runs, newest-first by `started`."
  @spec list() :: [t()]
  def list do
    CBDashboard.Paths.runs_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&parse/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&sort_key/1, :desc)
  end

  # Sort by started timestamp; runs missing one fall back to id (which embeds
  # the date). Tuple comparison keeps undated runs last but stable.
  defp sort_key(%__MODULE__{started: %DateTime{} = dt}), do: {1, DateTime.to_unix(dt, :microsecond), ""}
  defp sort_key(%__MODULE__{id: id}), do: {0, 0, id}

  @doc "Status counts across the list (totals + each status)."
  @spec status_counts([t()]) :: map()
  def status_counts(runs) do
    base = %{
      :total => length(runs),
      "completed" => 0,
      "needs-review" => 0,
      "running" => 0,
      "failed" => 0
    }

    Enum.reduce(runs, base, fn run, acc ->
      Map.update(acc, run.status || "unknown", 1, &(&1 + 1))
    end)
  end

  @doc "Group runs by their started-date (YYYY-MM-DD), newest day first."
  @spec by_day([t()]) :: [{String.t(), [t()]}]
  def by_day(runs) do
    runs
    |> Enum.group_by(&day_key/1)
    |> Enum.sort_by(fn {key, _} -> key end, :desc)
  end

  # --- Parsing ---

  defp parse(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      started = parse_dt(json["started"])
      finished = parse_dt(json["finished"])
      duration = duration_seconds(started, finished)

      basename = Path.basename(path, ".json")
      detail = if File.regular?(Path.rootname(path) <> ".html"), do: "#{basename}.html", else: nil

      %__MODULE__{
        id: json["id"] || basename,
        path: path,
        agent: json["agent"],
        status: json["status"],
        started: started,
        finished: finished,
        duration_s: duration,
        step_count: length(json["steps"] || []),
        alert_count: length(json["alerts"] || []),
        detail_relpath: detail
      }
    else
      _ -> nil
    end
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  defp duration_seconds(%DateTime{} = a, %DateTime{} = b),
    do: DateTime.diff(b, a, :millisecond) / 1000.0

  defp duration_seconds(_, _), do: nil

  defp day_key(%__MODULE__{started: %DateTime{} = dt}) do
    dt |> DateTime.to_date() |> Date.to_iso8601()
  end

  defp day_key(_), do: "undated"
end
