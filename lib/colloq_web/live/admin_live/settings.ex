defmodule ColloqWeb.AdminLive.Settings do
  use ColloqWeb, :live_view

  alias Colloq.SiteSettings

  @groups [
    %{id: "general", label: "General"},
    %{id: "forum", label: "Forum"},
    %{id: "security", label: "Security"},
    %{id: "integrations", label: "Integrations"},
    %{id: "match_day", label: "Match Day"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Settings"))
      |> assign(:groups, @groups)
      |> assign(:active_group, "general")
      |> load_group("general")

    {:ok, socket}
  end

  @impl true
  def handle_event("switch-tab", %{"group" => group}, socket) do
    {:noreply, socket |> assign(:active_group, group) |> load_group(group)}
  end

  def handle_event("save", %{"key" => key, "group" => group, "type" => type, "value" => value}, socket) do
    case SiteSettings.put(key, value, type: type, group: group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_group(group)
         |> put_flash(:info, gettext("Setting '%{key}' saved.", key: key))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save '%{key}'.", key: key))}
    end
  end

  defp load_group(socket, group) do
    settings = SiteSettings.list_by_group(group)
    assign(socket, :settings, settings)
  end
end
