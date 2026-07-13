defmodule ColloqWeb.AdminLive.XFeedSettings do
  use ColloqWeb, :live_view

  alias Colloq.SiteSettings

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("X Feed Settings"))
      |> load_form()

    {:ok, socket}
  end

  @impl true
  def handle_event("save", %{
    "nitter_url" => nitter_url,
    "accounts" => accounts,
    "keywords" => keywords,
    "target_topic_id" => target_topic_id
  }, socket) do
    results = [
      SiteSettings.put("x_feed_nitter_url", nitter_url, group: "integrations"),
      SiteSettings.put("x_feed_accounts", accounts, group: "integrations"),
      SiteSettings.put("x_feed_keywords", keywords, group: "integrations"),
      SiteSettings.put("x_feed_target_topic_id", target_topic_id, group: "integrations")
    ]

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {:noreply, socket |> load_form() |> put_flash(:info, gettext("X Feed settings saved."))}
    else
      {:noreply, put_flash(socket, :error, gettext("Error saving settings."))}
    end
  end

  defp load_form(socket) do
    assign(socket, :form, %{
      nitter_url: setting_value("x_feed_nitter_url", "https://nitter.net"),
      accounts: setting_value("x_feed_accounts", ""),
      keywords: setting_value("x_feed_keywords", ""),
      target_topic_id: setting_value("x_feed_target_topic_id", "")
    })
  end

  defp setting_value(key, default) do
    case SiteSettings.get(key) do
      nil -> default
      val when is_binary(val) -> val
      val -> to_string(val)
    end
  end
end
