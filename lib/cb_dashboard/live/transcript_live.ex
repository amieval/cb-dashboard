defmodule CBDashboard.TranscriptLive do
  @moduledoc """
  Single-session transcript view at `/transcripts/:session_id`.

  Reads `~/.claude/projects/<encoded>/<session_id>.jsonl`, decodes the
  user/assistant text stream (filtering out tool-use blocks, command wrappers,
  and system reminders), and renders each turn with MDEx so the assistant's
  markdown responses display as prose.

  A link in the header points at the raw JSONL served via Plug.Static at
  `/transcripts/files/<session_id>.jsonl`.
  """

  use Phoenix.LiveView

  import CBDashboard.Components.UI

  alias CBDashboard.Sources.Transcripts

  @impl true
  def mount(%{"session_id" => session_id}, _session, socket) do
    {:ok, load(socket, session_id)}
  end

  defp load(socket, session_id) do
    case Transcripts.rendered(session_id) do
      {:ok, turns, summary} ->
        socket
        |> assign(:session_id, session_id)
        |> assign(:found?, true)
        |> assign(:turns, turns)
        |> assign(:summary, summary)
        |> assign(:size_label, format_size(file_size(session_id)))

      {:error, _reason} ->
        socket
        |> assign(:session_id, session_id)
        |> assign(:found?, false)
    end
  end

  defp file_size(session_id) do
    case File.stat(Transcripts.path(session_id)) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  defp format_size(bytes) when bytes >= 1_048_576 do
    :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MB"
  end

  defp format_size(bytes) when bytes >= 1024 do
    :erlang.float_to_binary(bytes / 1024, decimals: 1) <> " KB"
  end

  defp format_size(bytes), do: "#{bytes} B"

  defp short_session(session_id), do: String.slice(session_id, 0, 8)

  defp format_ts(nil), do: "—"

  defp format_ts(%DateTime{} = dt) do
    dt |> DateTime.to_iso8601() |> String.replace("T", " ") |> String.slice(0, 19)
  end

  @impl true
  def render(%{found?: false} = assigns) do
    ~H"""
    <div style="max-width: var(--maxw-narrow);">
      <.page_header title="Transcript not found" />
      <p style="font-size: 13px; color: var(--text-secondary);">
        No JSONL for session <code>{@session_id}</code> under
        <code>~/.claude/projects/-Users-mark-dev-repos-mine-DIRTWIRE-bandlab-data-dirtwire/</code>.
      </p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div style="max-width: var(--maxw-prose);">
      <div style="font-size: 12px; color: var(--text-muted); margin-bottom: 16px; display: flex; gap: 12px; align-items: baseline; flex-wrap: wrap;">
        <span style="font-family: ui-monospace, SFMono-Regular, monospace;">{short_session(@session_id)}…</span>
        <span>·</span>
        <span><strong>{@summary.user_turns}</strong> user · <strong>{@summary.assistant_turns}</strong> assistant · <strong>{@summary.skipped_meta}</strong> meta</span>
        <span>·</span>
        <span>{@size_label}</span>
        <span>·</span>
        <a href={"/transcripts/files/#{@session_id}.jsonl"} style="font-size: 11px;">view raw jsonl</a>
      </div>

      <div class="transcript-stream">
        <div :for={turn <- @turns} class={"turn turn--" <> Atom.to_string(turn.role)}>
          <div class="turn-head">
            <span class="turn-role">{turn_role_label(turn.role)}</span>
            <time class="turn-ts">{format_ts(turn.timestamp)}</time>
          </div>
          <div class="turn-body">{Phoenix.HTML.raw(turn.html)}</div>
        </div>
      </div>
    </div>

    <style>
      .transcript-stream { display: flex; flex-direction: column; gap: 14px; }
      .turn { padding: 12px 16px; border-radius: 6px; border: 1px solid var(--border); background: var(--bg-secondary); }
      .turn--user { border-left: 3px solid var(--accent-blue); }
      .turn--assistant { border-left: 3px solid var(--accent-green); background: var(--bg-primary); }

      .turn-head { display: flex; gap: 12px; align-items: baseline; margin-bottom: 8px; font-size: 11px; }
      /* .turn-role: turn_role_label returns an already-upcased string,
         so this class doesn't carry text-transform. */
      .turn-role { letter-spacing: 0.08em; font-weight: 600; color: var(--text-secondary); }
      .turn--user .turn-role { color: var(--accent-blue); }
      .turn--assistant .turn-role { color: var(--accent-green); }
      .turn-ts { color: var(--text-muted); font-family: ui-monospace, SFMono-Regular, monospace; }

      .turn-body { font-size: 13.5px; line-height: 1.6; color: var(--text-primary); }
      .turn-body > :first-child { margin-top: 0; }
      .turn-body > :last-child { margin-bottom: 0; }
      .turn-body h1, .turn-body h2, .turn-body h3, .turn-body h4 { font-weight: 600; margin: 14px 0 6px; }
      .turn-body h1 { font-size: 24px; }
      .turn-body h2 { font-size: 18px; }
      .turn-body h3 { font-size: 15px; }
      .turn-body h4 { font-size: 14px; color: var(--text-secondary); }
      .turn-body p { margin: 0 0 10px; }
      .turn-body ul, .turn-body ol { margin: 0 0 10px; padding-left: 24px; }
      .turn-body li { margin: 3px 0; }
      .turn-body code { background: var(--bg-tertiary); padding: 1px 6px; border-radius: 3px; font-size: 12.5px; }
      .turn-body pre { background: var(--bg-tertiary); border: 1px solid var(--border); border-radius: 4px; padding: 10px 12px; overflow-x: auto; margin: 8px 0; font-size: 12.5px; }
      .turn-body pre code { background: transparent; padding: 0; }
      .turn-body blockquote { border-left: 3px solid var(--border); padding: 4px 12px; margin: 8px 0; color: var(--text-secondary); }
      .turn-body table { border-collapse: collapse; margin: 8px 0; font-size: 12.5px; }
      .turn-body th, .turn-body td { border: 1px solid var(--border); padding: 4px 10px; text-align: left; }
      .turn-body th { background: var(--bg-tertiary); }
      .turn-body a { color: var(--accent-blue); }
      .turn-body .plan-link { text-decoration: none; }
      .turn-body .plan-link code { color: var(--accent-blue); background: var(--overlay-blue-08); }
      .turn-body .plan-link:hover code { background: var(--overlay-blue-18); }
    </style>
    """
  end

  # Returned strings are already upcased so .turn-role can omit
  # `text-transform: uppercase` and still match the inline-styled
  # uppercase labels rendered via `<.section_label>` elsewhere.
  defp turn_role_label(:user), do: "USER"
  defp turn_role_label(:assistant), do: "CLAUDE"
end
