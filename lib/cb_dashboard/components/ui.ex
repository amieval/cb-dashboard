defmodule CBDashboard.Components.UI do
  @moduledoc """
  Shared presentation primitives — the design-system function components.

  These render through CSS-variable design tokens so each visual pattern is
  described once. Token names (`--badge-bg-*`, `--accent-*`, `--text-*`, …)
  are defined by the `:root` block in `CBDashboard.Layouts` (the root layout),
  rendered once in the page `<head>`; without it these components paint
  unstyled. This module is intentionally app-local, not a shared dependency —
  cb-dashboard is distributed standalone, so each app keeps its own copy.
  """

  use Phoenix.Component

  # --- Badge ---------------------------------------------------------------

  @badge_tones [:green, :orange, :red, :purple, :blue, :neutral]
  @badge_sizes [:sm, :md]

  @doc """
  Uppercase-label pill. The single primitive every type/status/effort/tag
  pill across the dashboard reduces to.
  """
  attr :tone, :atom, default: :neutral, values: @badge_tones
  attr :size, :atom, default: :sm, values: @badge_sizes
  attr :label, :string, default: nil
  slot :inner_block

  def badge(assigns) do
    {fs, pad} =
      case assigns.size do
        :sm -> {"10px", "2px 6px"}
        :md -> {"11px", "2px 8px"}
      end

    assigns =
      assigns
      |> assign(:bg, "var(--badge-bg-#{assigns.tone})")
      |> assign(:fg, badge_fg(assigns.tone))
      |> assign(:fs, fs)
      |> assign(:pad, pad)

    ~H"""
    <span style={"display: inline-block; font-size: #{@fs}; padding: #{@pad}; border-radius: 10px; background: #{@bg}; color: #{@fg}; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; line-height: 1.4;"}>
      <%= if @label, do: @label, else: render_slot(@inner_block) %>
    </span>
    """
  end

  defp badge_fg(:neutral), do: "var(--text-secondary)"
  defp badge_fg(tone), do: "var(--accent-#{tone})"

  # --- Count chip ----------------------------------------------------------

  @doc """
  Numeric count + label pair (e.g. "3 pending"). Plain text variant for
  `<.page_header>` meta strips and §G aggregate rows.
  """
  attr :count, :integer, required: true
  attr :label, :string, required: true

  def count_chip(assigns) do
    ~H"""
    <span style="font-size: 12px; color: var(--text-muted);">
      <strong style="color: var(--text-primary);">{@count}</strong> {@label}
    </span>
    """
  end

  @doc """
  Numeric count + label rendered as a small tonal chip (e.g.
  "3 pending" on a neutral pill with orange accent text). Use when the
  count needs visual weight inside a meta row, otherwise prefer
  `<.count_chip>`.
  """
  attr :count, :integer, required: true
  attr :label, :string, required: true
  attr :tone, :atom, default: :neutral, values: @badge_tones

  def numeric_chip(assigns) do
    assigns = assign(assigns, :fg, badge_fg(assigns.tone))

    ~H"""
    <span style={"display: inline-block; font-size: 10px; padding: 2px 6px; border-radius: 8px; background: var(--bg-tertiary); color: #{@fg};"}>
      {@count} {@label}
    </span>
    """
  end

  # --- Linkify belief ids --------------------------------------------------

  @belief_id_pattern ~r/\b([ac]\d{3,})\b/

  @doc """
  Render text with belief-id mentions (`a299`, `c038`, ...) wrapped as
  anchor links to `/dag/<id>`. Used everywhere rationale prose may
  reference DAG nodes — the surface exists so the user doesn't have to
  copy ids out to navigate.

  Plain text segments are emitted as-is (no HTML escaping needed in
  HEEx text interpolation). Whitespace and pre-wrap behavior are
  preserved by the caller's container.
  """
  attr :text, :any, required: true

  def linkify_belief_ids(%{text: nil} = assigns), do: ~H""
  def linkify_belief_ids(%{text: ""} = assigns), do: ~H""

  def linkify_belief_ids(assigns) do
    parts = belief_id_parts(assigns.text)
    assigns = assign(assigns, :parts, parts)

    ~H"""
    <%= for part <- @parts do %><.linkify_part part={part} /><% end %>
    """
  end

  attr :part, :any, required: true

  defp linkify_part(%{part: {:link, _id}} = assigns) do
    assigns = assign(assigns, :id, elem(assigns.part, 1))

    ~H"""
    <a href={"/dag/#{@id}"} style="font-family: ui-monospace, SFMono-Regular, monospace; color: var(--accent-blue);">{@id}</a>
    """
  end

  defp linkify_part(%{part: {:text, _text}} = assigns) do
    assigns = assign(assigns, :text, elem(assigns.part, 1))

    ~H"{@text}"
  end

  defp belief_id_parts(text) when is_binary(text) do
    Regex.split(@belief_id_pattern, text, include_captures: true)
    |> Enum.map(fn part ->
      if Regex.match?(~r/^[ac]\d{3,}$/, part), do: {:link, part}, else: {:text, part}
    end)
  end

  defp belief_id_parts(_), do: []

  # --- Artifact link -------------------------------------------------------

  @doc """
  Render a belief's `artifact` URI as a link when the scheme resolves to
  something we can navigate to in-app. Falls back to a plain blue
  monospace span for unrecognized schemes.

  Recognized schemes (per c040):

  - `https:<rest>` → external `https:<rest>` URL.

  Other schemes (session, gmail, user, document, source) render as plain
  text. The viewer doesn't host the planning surfaces, so `session:` plan
  references aren't linked here; `gmail:` would need a thread URL builder,
  and `document:`/`source:` need filesystem viewers the viewer doesn't have.
  """
  attr :artifact, :string, required: true

  attr :style, :string,
    default:
      "font-size: 12px; color: var(--accent-blue); font-family: ui-monospace, SFMono-Regular, monospace; word-break: break-all;"

  def artifact_link(%{artifact: nil} = assigns), do: ~H""
  def artifact_link(%{artifact: ""} = assigns), do: ~H""

  def artifact_link(assigns) do
    case parse_artifact(assigns.artifact) do
      {:link, href} ->
        assigns = assign(assigns, :href, href)
        ~H'<a href={@href} style={@style}>{@artifact}</a>'

      :plain ->
        ~H'<span style={@style}>{@artifact}</span>'
    end
  end

  defp parse_artifact("https:" <> _ = url), do: {:link, url}
  defp parse_artifact(_), do: :plain

  # --- Section label -------------------------------------------------------

  @doc """
  Small uppercase label used as a section sub-header or eyebrow.
  Replaces every inline `text-transform: uppercase` span.
  """
  slot :inner_block, required: true

  def section_label(assigns) do
    ~H"""
    <span style="font-size: 11px; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.05em; font-weight: 600;">
      {render_slot(@inner_block)}
    </span>
    """
  end

  # --- Page header ---------------------------------------------------------

  @doc """
  Page-level `<h2>` title + optional meta strip (counts, pills).
  """
  attr :title, :string, required: true
  slot :meta

  def page_header(assigns) do
    ~H"""
    <h2 style="font-size: 16px; margin: 0 0 8px 0; font-weight: 600; color: var(--text-primary);">
      {@title}
    </h2>
    <%= if @meta != [] do %>
      <div style="display: flex; gap: 12px; align-items: center; flex-wrap: wrap; font-size: 12px; color: var(--text-muted); margin-bottom: 14px;">
        {render_slot(@meta)}
      </div>
    <% end %>
    """
  end

  # --- Empty state ---------------------------------------------------------

  @empty_tones [:not_found, :deferred, :note]

  @doc """
  Unified empty-state placeholder. `tone` switches the accent:

    - `:not_found` — dashed neutral border (default visual)
    - `:deferred` — orange-tinted border + overlay background
    - `:note` — plain dashed neutral border
  """
  attr :tone, :atom, default: :note, values: @empty_tones
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def empty_state(assigns) do
    {border, bg} =
      case assigns.tone do
        :deferred -> {"var(--accent-orange)", "var(--overlay-orange-08)"}
        _ -> {"var(--border)", "var(--bg-secondary)"}
      end

    assigns = assign(assigns, border: border, bg: bg)

    ~H"""
    <div style={"padding: 16px; border: 1px dashed #{@border}; border-radius: 6px; background: #{@bg};"}>
      <%= if @title do %>
        <div style="margin-bottom: 6px;">
          <.section_label>{@title}</.section_label>
        </div>
      <% end %>
      <div style="font-size: 13px; color: var(--text-secondary); line-height: 1.5;">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # --- Data list -----------------------------------------------------------

  @list_variants [:bordered, :flat]

  @doc """
  List wrapper. `:bordered` renders an outer border + rounded corners;
  `:flat` has no outer border. Both separate items with a top border on
  every row after the first.
  """
  attr :variant, :atom, default: :bordered, values: @list_variants

  slot :row, required: true do
    attr :id, :string
  end

  def data_list(assigns) do
    container_style =
      case assigns.variant do
        :bordered ->
          "list-style: none; padding: 0; margin: 0; border: 1px solid var(--border); border-radius: 6px; background: var(--bg-secondary);"

        :flat ->
          "list-style: none; padding: 0; margin: 0;"
      end

    assigns = assign(assigns, :container_style, container_style)

    ~H"""
    <ul style={@container_style}>
      <li
        :for={{row, idx} <- Enum.with_index(@row)}
        id={Map.get(row, :id)}
        style={"padding: 8px 14px; #{if idx > 0, do: "border-top: 1px solid var(--border);"}"}
      >
        {render_slot(row)}
      </li>
    </ul>
    """
  end
end
