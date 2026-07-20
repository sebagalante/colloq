defmodule ColloqWeb.Components.Lucide do
  @moduledoc """
  Lucide icon components for Colloq.

  Renders inline SVG icons from the Lucide icon set.
  Icons are rendered as function components for use in HEEx templates.

  Usage in templates:
      <Lucide.icon name="bookmark" />
      <Lucide.icon name="flag" class="w-4 h-4 text-red-400" />
      <Lucide.icon name="share-2" size={16} />

  Available icon names match the Lucide library:
  https://lucide.dev/icons/
  """
  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]

  @doc """
  Renders a Lucide icon by name.

  ## Attributes
    - `name` — Icon name (atom or string), e.g. `:bookmark`, `"flag"`
    - `class` — CSS classes (default: "w-4 h-4")
    - `size` — Icon size in pixels (default: 24, overridden by class)
  """
  attr :name, :any, required: true
  attr :class, :string, default: "w-4 h-4"
  attr :rest, :global

  def icon(assigns) do
    name = to_string(assigns.name)
    paths = icon_paths(name)

    assigns =
      assigns
      |> assign(:paths, paths)
      |> assign(:icon_name, name)

    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      {@rest}
    >
      <%= for path <- @paths do %>
        <%= raw(path) %>
      <% end %>
    </svg>
    """
  end

  # Icon path definitions — each returns a list of SVG inner elements
  # To add a new icon, visit https://lucide.dev/icons/ and copy the inner SVG content

  defp icon_paths("bookmark"), do: [
    ~s(<path d="m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v16z"/>)
  ]

  defp icon_paths("bookmark-filled"), do: [
    ~s(<path d="m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z" fill="currentColor"/>)
  ]

  defp icon_paths("flag"), do: [
    ~s(<path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/>),
    ~s(<line x1="4" x2="4" y1="22" y2="15"/>)
  ]

  defp icon_paths("shield"), do: [
    ~s(<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>)
  ]

  defp icon_paths("lock"), do: [
    ~s(<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/>),
    ~s(<path d="M7 11V7a5 5 0 0 1 10 0v4"/>)
  ]

  defp icon_paths("lock-open"), do: [
    ~s(<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/>),
    ~s(<path d="M7 11V7a5 5 0 0 1 9.9-1"/>)
  ]

  defp icon_paths("megaphone"), do: [
    ~s(<path d="m3 11 18-5v12L3 14v-3z"/>),
    ~s(<path d="M11.6 16.8a3 3 0 1 1-5.8-1.6"/>)
  ]

  defp icon_paths("ban"), do: [
    ~s(<circle cx="12" cy="12" r="10"/>),
    ~s(<path d="m4.9 4.9 14.2 14.2"/>)
  ]

  defp icon_paths("share-2"), do: [
    ~s(<circle cx="18" cy="5" r="3"/>),
    ~s(<circle cx="6" cy="12" r="3"/>),
    ~s(<circle cx="18" cy="19" r="3"/>),
    ~s(<line x1="8.59" x2="15.42" y1="13.51" y2="17.49"/>),
    ~s(<line x1="15.41" x2="8.59" y1="6.51" y2="10.49"/>)
  ]

  defp icon_paths("reply"), do: [
    ~s(<polyline points="9 17 4 12 9 7"/>),
    ~s(<path d="M20 18v-2a4 4 0 0 0-4-4H4"/>)
  ]

  defp icon_paths("message-circle"), do: [
    ~s(<path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/>)
  ]

  defp icon_paths("thumbs-up"), do: [
    ~s(<path d="M7 10v12"/>),
    ~s(<path d="M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z"/>)
  ]

  defp icon_paths("heart"), do: [
    ~s(<path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"/>)
  ]

  defp icon_paths("search"), do: [
    ~s(<circle cx="11" cy="11" r="8"/>),
    ~s(<path d="m21 21-4.3-4.3"/>)
  ]

  defp icon_paths("menu"), do: [
    ~s(<line x1="4" x2="20" y1="12" y2="12"/>),
    ~s(<line x1="4" x2="20" y1="6" y2="6"/>),
    ~s(<line x1="4" x2="20" y1="18" y2="18"/>)
  ]

  defp icon_paths("x"), do: [
    ~s(<path d="M18 6 6 18"/>),
    ~s(<path d="m6 6 12 12"/>)
  ]

  defp icon_paths("plus"), do: [
    ~s(<path d="M5 12h14"/>),
    ~s(<path d="M12 5v14"/>)
  ]

  defp icon_paths("settings"), do: [
    ~s(<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/>),
    ~s(<circle cx="12" cy="12" r="3"/>)
  ]

  defp icon_paths("user"), do: [
    ~s(<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/>),
    ~s(<circle cx="12" cy="7" r="4"/>)
  ]

  defp icon_paths("users"), do: [
    ~s(<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/>),
    ~s(<circle cx="9" cy="7" r="4"/>),
    ~s(<path d="M22 21v-2a4 4 0 0 0-3-3.87"/>),
    ~s(<path d="M16 3.13a4 4 0 0 1 0 7.75"/>)
  ]

  defp icon_paths("log-in"), do: [
    ~s(<path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"/>),
    ~s(<polyline points="10 17 15 12 10 7"/>),
    ~s(<line x1="15" x2="3" y1="12" y2="12"/>)
  ]

  defp icon_paths("log-out"), do: [
    ~s(<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/>),
    ~s(<polyline points="16 17 21 12 16 7"/>),
    ~s(<line x1="21" x2="9" y1="12" y2="12"/>)
  ]

  defp icon_paths("chevron-right"), do: [
    ~s(<path d="m9 18 6-6-6-6"/>)
  ]

  defp icon_paths("flame"), do: [
    ~s(<path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.072-2.143-.224-4.054 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.153.433-2.294 1-3a2.5 2.5 0 0 0 2.5 2.5z"/>)
  ]

  defp icon_paths("archive"), do: [
    ~s(<rect width="20" height="5" x="2" y="3" rx="1"/>),
    ~s(<path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/>),
    ~s(<path d="M10 12h4"/>)
  ]

  defp icon_paths("inbox"), do: [
    ~s(<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/>),
    ~s(<path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>)
  ]

  defp icon_paths("bell"), do: [
    ~s(<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/>),
    ~s(<path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>)
  ]

  defp icon_paths("bell-ring"), do: [
    ~s(<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/>),
    ~s(<path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>),
    ~s(<path d="M4 2C2.8 3.7 2 5.7 2 8"/>),
    ~s(<path d="M22 8c0-2.3-.8-4.3-2-6"/>)
  ]

  defp icon_paths("bell-off"), do: [
    ~s(<path d="M8.7 3A6 6 0 0 1 18 8a21.3 21.3 0 0 0 .6 5"/>),
    ~s(<path d="M17 17H3s3-2 3-9a4.67 4.67 0 0 1 .3-1.7"/>),
    ~s(<path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>),
    ~s(<path d="m2 2 20 20"/>)
  ]

  defp icon_paths("home"), do: [
    ~s(<path d="M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"/>),
    ~s(<path d="M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>)
  ]

  defp icon_paths("bar-chart-3"), do: [
    ~s(<path d="M3 3v18h18"/>),
    ~s(<path d="M18 17V9"/>),
    ~s(<path d="M13 17V5"/>),
    ~s(<path d="M8 17v-3"/>)
  ]

  defp icon_paths("trending-up"), do: [
    ~s(<polyline points="22 7 13.5 15.5 8.5 10.5 2 17"/>),
    ~s(<polyline points="16 7 22 7 22 13"/>)
  ]

  defp icon_paths("clock"), do: [
    ~s(<circle cx="12" cy="12" r="10"/>),
    ~s(<polyline points="12 6 12 12 16 14"/>)
  ]

  defp icon_paths("calendar"), do: [
    ~s(<path d="M8 2v4"/>),
    ~s(<path d="M16 2v4"/>),
    ~s(<rect width="18" height="18" x="3" y="4" rx="2"/>),
    ~s(<path d="M3 10h18"/>)
  ]

  defp icon_paths("pin"), do: [
    ~s(<line x1="12" x2="12" y1="17" y2="22"/>),
    ~s(<path d="M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1v4.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24Z"/>)
  ]

  defp icon_paths("mic"), do: [
    ~s(<path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/>),
    ~s(<path d="M19 10v2a7 7 0 0 1-14 0v-2"/>),
    ~s(<line x1="12" x2="12" y1="19" y2="22"/>)
  ]

  defp icon_paths("mic-off"), do: [
    ~s(<line x1="2" x2="22" y1="2" y2="22"/>),
    ~s(<path d="M18.89 13.23A7.12 7.12 0 0 0 19 12v-2"/>),
    ~s(<path d="M5 10v2a7 7 0 0 0 12 5"/>),
    ~s(<path d="M15 9.34V5a3 3 0 0 0-5.68-1.33"/>),
    ~s(<path d="M9 9v3a3 3 0 0 0 5.12 2.12"/>),
    ~s(<line x1="12" x2="12" y1="19" y2="22"/>)
  ]

  defp icon_paths("copy"), do: [
    ~s(<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/>),
    ~s(<path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>)
  ]

  defp icon_paths("external-link"), do: [
    ~s(<path d="M15 3h6v6"/>),
    ~s(<path d="M10 14 21 3"/>),
    ~s(<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>)
  ]

  defp icon_paths("trash-2"), do: [
    ~s(<path d="M3 6h18"/>),
    ~s(<path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/>),
    ~s(<path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/>),
    ~s(<line x1="10" x2="10" y1="11" y2="17"/>),
    ~s(<line x1="14" x2="14" y1="11" y2="17"/>)
  ]

  defp icon_paths("edit"), do: [
    ~s(<path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/>),
    ~s(<path d="M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4Z"/>)
  ]

  defp icon_paths("eye"), do: [
    ~s(<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/>),
    ~s(<circle cx="12" cy="12" r="3"/>)
  ]

  defp icon_paths("eye-off"), do: [
    ~s(<path d="M9.88 9.88a3 3 0 1 0 4.24 4.24"/>),
    ~s(<path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68"/>),
    ~s(<path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61"/>),
    ~s(<line x1="2" x2="22" y1="2" y2="22"/>)
  ]

  defp icon_paths("check"), do: [
    ~s(<polyline points="20 6 9 17 4 12"/>)
  ]

  defp icon_paths("alert-triangle"), do: [
    ~s(<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/>),
    ~s(<path d="M12 9v4"/>),
    ~s(<path d="M12 17h.01"/>)
  ]

  defp icon_paths("info"), do: [
    ~s(<circle cx="12" cy="12" r="10"/>),
    ~s(<path d="M12 16v-4"/>),
    ~s(<path d="M12 8h.01"/>)
  ]

  defp icon_paths("help-circle"), do: [
    ~s(<circle cx="12" cy="12" r="10"/>),
    ~s(<path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/>),
    ~s(<path d="M12 17h.01"/>)
  ]

  defp icon_paths("refresh-cw"), do: [
    ~s(<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/>),
    ~s(<path d="M21 3v5h-5"/>),
    ~s(<path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/>),
    ~s(<path d="M8 16H3v5"/>)
  ]

  defp icon_paths("zap"), do: [
    ~s(<polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/>)
  ]

  defp icon_paths("star"), do: [
    ~s(<polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/>)
  ]

  defp icon_paths("layers"), do: [
    ~s(<polygon points="12 2 2 7 12 12 22 7 12 2"/>),
    ~s(<polyline points="2 17 12 22 22 17"/>),
    ~s(<polyline points="2 12 12 17 22 12"/>)
  ]

  defp icon_paths("smile"), do: [
    ~s(<circle cx="12" cy="12" r="10"/>),
    ~s(<path d="M8 14s1.5 2 4 2 4-2 4-2"/>),
    ~s(<line x1="9" x2="9.01" y1="9" y2="9"/>),
    ~s(<line x1="15" x2="15.01" y1="9" y2="9"/>)
  ]

  defp icon_paths("hash"), do: [
    ~s(<line x1="4" x2="20" y1="9" y2="9"/>),
    ~s(<line x1="4" x2="20" y1="15" y2="15"/>),
    ~s(<line x1="10" x2="8" y1="3" y2="21"/>),
    ~s(<line x1="16" x2="14" y1="3" y2="21"/>)
  ]

  defp icon_paths("image"), do: [
    ~s(<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/>),
    ~s(<circle cx="9" cy="9" r="2"/>),
    ~s(<path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>)
  ]

  defp icon_paths("link"), do: [
    ~s(<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/>),
    ~s(<path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>)
  ]

  defp icon_paths("sparkles"), do: [
    ~s(<path d="M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z"/>),
    ~s(<path d="M20 3v4"/>),
    ~s(<path d="M22 5h-4"/>),
    ~s(<path d="M4 17v2"/>),
    ~s(<path d="M5 18H3"/>)
  ]

  defp icon_paths("file-text"), do: [
    ~s(<path d="M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5L14.5 2z"/>),
    ~s(<polyline points="14 2 14 8 20 8"/>),
    ~s(<line x1="16" x2="8" y1="13" y2="13"/>),
    ~s(<line x1="16" x2="8" y1="17" y2="17"/>),
    ~s(<line x1="10" x2="8" y1="9" y2="9"/>)
  ]

  defp icon_paths("globe"), do: [
    ~s(<circle cx="12" cy="12" r="10"/>),
    ~s(<path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/>),
    ~s(<path d="M2 12h20"/>)
  ]

  defp icon_paths("mail"), do: [
    ~s(<rect width="20" height="16" x="2" y="4" rx="2"/>),
    ~s(<path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7"/>)
  ]

  defp icon_paths("send"), do: [
    ~s(<path d="m22 2-7 20-4-9-9-4Z"/>),
    ~s(<path d="M22 2 11 13"/>)
  ]

  defp icon_paths("award"), do: [
    ~s(<path d="m15.477 12.89 1.515 8.526a.5.5 0 0 1-.81.47l-3.58-2.687a1 1 0 0 0-1.197 0l-3.586 2.686a.5.5 0 0 1-.81-.469l1.514-8.526"/>),
    ~s(<circle cx="12" cy="8" r="6"/>)
  ]

  defp icon_paths("more-horizontal"), do: [
    ~s(<circle cx="12" cy="12" r="1"/>),
    ~s(<circle cx="19" cy="12" r="1"/>),
    ~s(<circle cx="5" cy="12" r="1"/>)
  ]

  defp icon_paths("chevron-up"), do: [~s(<path d="m18 15-6-6-6 6"/>)]
  defp icon_paths("chevron-down"), do: [~s(<path d="m6 9 6 6 6-6"/>)]

  defp icon_paths("quote"), do: [
    ~s(<path d="M3 21c3 0 7-1 7-8V5c0-1.25-.756-2.017-2-2H4c-1.25 0-2 .75-2 1.972V11c0 1.25.75 2 2 2 1 0 1 0 1 1v1c0 1-1 2-2 2s-1 .008-1 1.031V20c0 1 0 1 1 1z"/>),
    ~s(<path d="M15 21c3 0 7-1 7-8V5c0-1.25-.757-2.017-2-2h-4c-1.25 0-2 .75-2 1.972V11c0 1.25.75 2 2 2h.75c0 2.25.25 4-2.75 4v3c0 1 0 1 1 1z"/>)
  ]

  defp icon_paths("map-pin"), do: [
    ~s(<path d="M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0"/>),
    ~s(<circle cx="12" cy="10" r="3"/>)
  ]

  defp icon_paths("activity"), do: [
    ~s(<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2"/>)
  ]

  defp icon_paths("at-sign"), do: [
    ~s(<circle cx="12" cy="12" r="4"/>),
    ~s(<path d="M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-4 8"/>)
  ]

  defp icon_paths("paperclip"), do: [
    ~s(<path d="M13.234 20.252 21 12.3a4 4 0 0 0-5.658-5.657l-8.485 8.485a6 6 0 0 0 8.485 8.485l7.071-7.07"/>),
    ~s(<path d="m2.196 12.657 8.485-8.485"/>)
  ]

  defp icon_paths("download"), do: [
    ~s(<path d="M12 15V3"/>),
    ~s(<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>),
    ~s(<path d="m7 10 5 5 5-5"/>)
  ]

  defp icon_paths("file"), do: [
    ~s(<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/>),
    ~s(<path d="M14 2v4a2 2 0 0 0 2 2h4"/>)
  ]

  defp icon_paths("cpu"), do: [
    ~s(<rect width="16" height="16" x="4" y="4" rx="2"/>),
    ~s(<rect width="6" height="6" x="9" y="9" rx="1"/>),
    ~s(<path d="M15 2v2"/>), ~s(<path d="M15 20v2"/>), ~s(<path d="M2 15h2"/>),
    ~s(<path d="M2 9h2"/>), ~s(<path d="M20 15h2"/>), ~s(<path d="M20 9h2"/>),
    ~s(<path d="M9 2v2"/>), ~s(<path d="M9 20v2"/>)
  ]

  defp icon_paths("tag"), do: [
    ~s(<path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z"/>),
    ~s(<circle cx="7.5" cy="7.5" r=".5" fill="currentColor"/>)
  ]

  defp icon_paths("sticker"), do: [
    ~s(<path d="M15.5 3H5a2 2 0 0 0-2 2v14c0 1.1.9 2 2 2h14a2 2 0 0 0 2-2V8.5L15.5 3Z"/>),
    ~s(<path d="M15 3v6h6"/>),
    ~s(<path d="M10 14a3.5 3.5 0 0 0 4 0"/>),
    ~s(<path d="M9 12h.01"/>),
    ~s(<path d="M15 12h.01"/>)
  ]

  # Fallback for unknown icon names
  defp icon_paths(_name), do: [
    ~s(<circle cx="12" cy="12" r="10"/>),
    ~s(<path d="M12 16v-4"/>),
    ~s(<path d="M12 8h.01"/>)
  ]
end
