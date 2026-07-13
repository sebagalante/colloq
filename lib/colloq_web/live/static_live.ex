defmodule ColloqWeb.StaticLive do
  @moduledoc """
  Simple static content pages (About, Guidelines) shown from the More menu.
  """
  use ColloqWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    page = socket.assigns.live_action

    {:ok,
     socket
     |> assign(:page, page)
     |> assign(:page_title, title(page))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6">
      <h1 class="text-2xl font-bold text-heading mb-4 flex items-center gap-2">
        <.icon name={page_icon(@page)} class="w-6 h-6 text-accent" /><%= title(@page) %>
      </h1>
      <div class="prose max-w-none text-sm text-body space-y-3">
        <%= render_content(assigns) %>
      </div>
    </div>
    """
  end

  defp render_content(%{page: :about} = assigns) do
    ~H"""
    <p><%= gettext("Colloq is the community forum for Racing Club fans — a place to talk matches, players, transfers, and everything about La Academia.") %></p>
    <p><%= gettext("Join the conversation: create topics, reply, react, and follow live match threads.") %></p>
    """
  end

  defp render_content(%{page: :guidelines} = assigns) do
    ~H"""
    <p><%= gettext("A few simple rules keep the community healthy:") %></p>
    <ul class="list-disc pl-5 space-y-1">
      <li><%= gettext("Be respectful — no insults, harassment, or hate speech.") %></li>
      <li><%= gettext("Stay on topic and use the right category.") %></li>
      <li><%= gettext("No spam, self-promotion, or off-topic advertising.") %></li>
      <li><%= gettext("Report content that breaks the rules instead of engaging.") %></li>
    </ul>
    """
  end

  defp title(:about), do: gettext("About")
  defp title(:guidelines), do: gettext("Guidelines")
  defp title(_), do: "Colloq"

  defp page_icon(:about), do: "info"
  defp page_icon(:guidelines), do: "file-text"
  defp page_icon(_), do: "info"
end
