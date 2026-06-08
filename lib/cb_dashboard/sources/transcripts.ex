defmodule CBDashboard.Sources.Transcripts do
  @moduledoc """
  Reads Claude Code session transcripts from `~/.claude/projects/<encoded>/`.

  The Claude CLI writes one JSONL file per session. Each line is a JSON object
  whose `type` field discriminates the kind of record (`user`, `assistant`,
  `system`, `attachment`, `file-history-snapshot`, ...).

  This source compiles a JSONL into the user/assistant text stream that drives
  the recap dialog trail — same filter the `/recap` skill prescribes.

  Records are read from disk on every call; transcripts grow append-only and
  Phoenix LiveView re-mounts cheaply enough that a 5MB scan per request is fine
  for the localhost-only SOD.
  """

  # The transcripts directory is resolved at runtime through the configurable
  # data-root surface (`CB_DASHBOARD_TRANSCRIPTS_ROOT` / config, default
  # `~/.claude/projects`) rather than the host's compile-time literal.
  defmodule Turn do
    @moduledoc false
    defstruct [:role, :text, :timestamp, :uuid, :has_attachment?]

    @type t :: %__MODULE__{
            role: :user | :assistant,
            text: String.t(),
            timestamp: DateTime.t() | nil,
            uuid: String.t() | nil,
            has_attachment?: boolean()
          }
  end

  @doc "Absolute path for a session id. Does not check existence."
  @spec path(String.t()) :: String.t()
  def path(session_id), do: Path.join(CBDashboard.Paths.transcripts_root(), "#{session_id}.jsonl")

  @doc "Directory that holds all transcripts (the project-encoded path)."
  @spec projects_root() :: String.t()
  def projects_root, do: CBDashboard.Paths.transcripts_root()

  @doc """
  Parse a session JSONL into a flat list of `%Turn{}` records.

  Filters: drops command/system wrappers and tool-call blocks. Strips embedded
  `<system-reminder>`/`<command-*>` tags from text content. Records with empty
  text after filtering are dropped.

  Returns `{:ok, [Turn.t()], summary}` or `{:error, reason}` where summary is a
  map of counts useful for the header strip.
  """
  @spec parse(String.t()) :: {:ok, [Turn.t()], map()} | {:error, term()}
  def parse(session_id) do
    case File.read(path(session_id)) do
      {:ok, body} ->
        {turns, summary} = body |> String.split("\n", trim: true) |> walk()
        {:ok, Enum.reverse(turns), summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Convenience for view layers: parse the session, then render each turn's
  text through MDEx + PlanLinks. Returns a list of maps with `:role`,
  `:html`, `:timestamp`, `:uuid` fields.

  Reused by both `TranscriptLive` (the standalone `/transcripts/:id` route)
  and `PlanLive`'s Thread tab so the rendering pipeline lives in one place.
  """
  @spec rendered(String.t()) :: {:ok, [map()], map()} | {:error, term()}
  def rendered(session_id) do
    case parse(session_id) do
      {:ok, turns, summary} ->
        {:ok, Enum.map(turns, &render_turn/1), summary}

      err ->
        err
    end
  end

  defp render_turn(%Turn{role: role, text: text, timestamp: ts, uuid: uuid}) do
    html =
      text
      |> MDEx.to_html!(
        extension: [
          table: true,
          autolink: true,
          strikethrough: true,
          tasklist: true
        ],
        render: [unsafe_: false]
      )
      |> CBDashboard.PlanLinks.linkify_html()

    %{role: role, html: html, timestamp: ts, uuid: uuid}
  end

  @doc """
  Lightweight metadata for the session list — line counts, first/last timestamps,
  file size. No per-line decoding beyond the first/last lines.
  """
  @spec metadata(String.t()) :: {:ok, map()} | {:error, term()}
  def metadata(session_id) do
    p = path(session_id)

    with {:ok, stat} <- File.stat(p, time: :posix),
         {:ok, body} <- File.read(p) do
      lines = body |> String.split("\n", trim: true)

      {first, last} = bookend_timestamps(lines)

      {:ok,
       %{
         size: stat.size,
         line_count: length(lines),
         first_timestamp: first,
         last_timestamp: last
       }}
    end
  end

  @doc """
  List all session ids in the project's transcript directory, sorted by mtime
  desc. Each entry: `{session_id, mtime_posix}`.
  """
  @spec list() :: [{String.t(), integer()}]
  def list do
    CBDashboard.Paths.transcripts_root()
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.map(fn p ->
      sid = Path.basename(p, ".jsonl")
      mtime =
        case File.stat(p, time: :posix) do
          {:ok, %{mtime: m}} -> m
          _ -> 0
        end

      {sid, mtime}
    end)
    |> Enum.sort_by(fn {_sid, mtime} -> mtime end, :desc)
  end

  # --- Private ---

  defp walk(lines) do
    init_summary = %{
      total_lines: length(lines),
      user_turns: 0,
      assistant_turns: 0,
      attachments: 0,
      skipped_meta: 0,
      decode_errors: 0
    }

    Enum.reduce(lines, {[], init_summary}, fn line, {acc, sum} ->
      case Jason.decode(line) do
        {:ok, obj} -> classify(obj, acc, sum)
        {:error, _} -> {acc, Map.update!(sum, :decode_errors, &(&1 + 1))}
      end
    end)
  end

  # Attachments — surface only as a marker on the next user turn (counted here).
  defp classify(%{"type" => "attachment"}, acc, sum) do
    {acc, Map.update!(sum, :attachments, &(&1 + 1))}
  end

  defp classify(%{"type" => "user", "message" => %{"content" => content}} = obj, acc, sum) do
    text = extract_text(content) |> sanitize() |> String.trim()

    cond do
      text == "" ->
        {acc, Map.update!(sum, :skipped_meta, &(&1 + 1))}

      command_wrapper?(text) ->
        {acc, Map.update!(sum, :skipped_meta, &(&1 + 1))}

      true ->
        turn = %Turn{
          role: :user,
          text: text,
          timestamp: parse_dt(obj["timestamp"]),
          uuid: obj["uuid"],
          has_attachment?: false
        }

        {[turn | acc], Map.update!(sum, :user_turns, &(&1 + 1))}
    end
  end

  defp classify(%{"type" => "assistant", "message" => %{"content" => content}} = obj, acc, sum) do
    text = extract_text(content) |> sanitize() |> String.trim()

    if text == "" do
      {acc, sum}
    else
      turn = %Turn{
        role: :assistant,
        text: text,
        timestamp: parse_dt(obj["timestamp"]),
        uuid: obj["uuid"],
        has_attachment?: false
      }

      {[turn | acc], Map.update!(sum, :assistant_turns, &(&1 + 1))}
    end
  end

  defp classify(_other, acc, sum), do: {acc, sum}

  # Pull text out of either a string `content` or an array of typed blocks.
  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map(& &1["text"])
    |> Enum.join("\n")
  end

  defp extract_text(_), do: ""

  # Strip embedded harness tags so the prose reads cleanly. The full record
  # remains visible in the raw view; this is for the compiled stream only.
  defp sanitize(text) do
    text
    |> String.replace(~r/<system-reminder>.*?<\/system-reminder>/s, "")
    |> String.replace(~r/<local-command-caveat>.*?<\/local-command-caveat>/s, "")
    |> String.replace(~r/<local-command-stdout>.*?<\/local-command-stdout>/s, "")
  end

  # A user turn that is *entirely* a `<command-name>` / `<command-message>` /
  # `<command-args>` block is the slash-command echo, not a real prompt.
  defp command_wrapper?(text) do
    Regex.match?(~r/\A\s*<command-name>/, text)
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  defp bookend_timestamps([]), do: {nil, nil}

  defp bookend_timestamps(lines) do
    first = first_ts(lines)
    last = first_ts(Enum.reverse(lines))
    {first, last}
  end

  defp first_ts([line | rest]) do
    case Jason.decode(line) do
      {:ok, %{"timestamp" => ts}} -> parse_dt(ts) || first_ts(rest)
      _ -> first_ts(rest)
    end
  end

  defp first_ts([]), do: nil
end
