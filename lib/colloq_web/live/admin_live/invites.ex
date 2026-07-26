defmodule ColloqWeb.AdminLive.Invites do
  @moduledoc """
  Admin screen for invitations: send them, see who accepted, revoke or resend.

  Only does anything while `registration_mode` is `"invite"` — the page says so
  rather than silently sending mail nobody needs, since in `open` mode anyone
  can register without a token.
  """
  use ColloqWeb, :live_view

  alias Colloq.Invites

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Invitations"))
     |> assign(:emails, "")
     |> load()}
  end

  @impl true
  def handle_event("send", %{"emails" => raw}, socket) do
    case Invites.parse_emails(raw) do
      [] ->
        {:noreply, put_flash(socket, :error, gettext("Enter at least one email address."))}

      emails ->
        {sent, failed} = Invites.invite_many(emails, socket.assigns.current_user)

        {:noreply,
         socket
         |> assign(:emails, "")
         |> load()
         |> flash_result(sent, failed)}
    end
  end

  def handle_event("resend", %{"id" => id}, socket) do
    invite = Invites.get_invite!(id)

    case Invites.resend(invite) do
      {:ok, _} ->
        {:noreply,
         put_flash(socket, :info, gettext("Invitation resent to %{email}.", email: invite.email))}

      {:error, :not_pending} ->
        {:noreply,
         put_flash(socket, :error, gettext("That invitation was already used or expired."))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    invite = Invites.get_invite!(id)

    case Invites.delete_invite(invite) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, gettext("Invitation revoked."))}

      {:error, :already_accepted} ->
        {:noreply,
         put_flash(socket, :error, gettext("An accepted invitation can't be revoked."))}
    end
  end

  defp load(socket) do
    socket
    |> assign(:invites, Invites.list_invites())
    |> assign(:mode, Invites.registration_mode())
  end

  defp flash_result(socket, sent, []) do
    put_flash(
      socket,
      :info,
      ngettext("%{count} invitation sent.", "%{count} invitations sent.", length(sent),
        count: length(sent)
      )
    )
  end

  defp flash_result(socket, sent, failed) do
    detail = Enum.map_join(failed, ", ", fn {email, reason} -> "#{email} (#{reason(reason)})" end)

    put_flash(
      socket,
      :error,
      gettext("Sent %{sent}, skipped: %{detail}", sent: length(sent), detail: detail)
    )
  end

  defp reason(:already_registered), do: gettext("already registered")
  defp reason(:already_invited), do: gettext("already invited")
  defp reason(_), do: pgettext("invites", "invalid address")

  defp status(invite) do
    cond do
      invite.accepted_at -> {:accepted, gettext("Accepted")}
      DateTime.compare(invite.expires_at, DateTime.utc_now()) != :gt -> {:expired, gettext("Expired")}
      true -> {:pending, pgettext("invites", "Pending")}
    end
  end

  defp status_color(:accepted), do: "green"
  defp status_color(:expired), do: "gray"
  defp status_color(:pending), do: "blue"

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold text-heading"><%= gettext("Invitations") %></h1>
        <p class="text-sm text-muted mt-1">
          <%= gettext("Invited people get a one-time signup link by email.") %>
        </p>
      </div>

      <%!-- Invites only gate anything in invite mode; say so instead of letting
            an admin send links that nobody needs. --%>
      <div
        :if={@mode != :invite}
        class="rounded-lg border border-border bg-surface-alt px-4 py-3 text-sm text-body"
      >
        <%= if @mode == :open do %>
          <%= gettext(
            "Registration is currently open, so anyone can sign up without an invitation. Set registration_mode to \"invite\" in Settings ▸ Security for these to be required."
          ) %>
        <% else %>
          <%= gettext(
            "Registration is currently closed, so invitations won't be accepted either. Set registration_mode to \"invite\" in Settings ▸ Security."
          ) %>
        <% end %>
      </div>

      <.card>
        <h2 class="text-lg font-semibold text-heading mb-3"><%= gettext("Send invitations") %></h2>

        <form phx-submit="send" class="space-y-3">
          <textarea
            name="emails"
            rows="3"
            placeholder="ana@mail.com, juan@mail.com"
            class="w-full rounded-lg border border-border bg-surface text-heading px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-accent"
          ><%= @emails %></textarea>
          <div class="flex items-center justify-between gap-3">
            <p class="text-xs text-muted">
              <%= gettext("Separate addresses with commas, spaces or line breaks. Links expire in %{days} days.",
                days: Colloq.Invites.ttl_days()
              ) %>
            </p>
            <.button type="submit" class="shrink-0"><%= gettext("Send") %></.button>
          </div>
        </form>
      </.card>

      <.card>
        <h2 class="text-lg font-semibold text-heading mb-3"><%= gettext("Sent invitations") %></h2>

        <p :if={@invites == []} class="text-sm text-muted">
          <%= gettext("No invitations sent yet.") %>
        </p>

        <div :if={@invites != []} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-border">
                <th class="text-left py-2 px-3 text-muted font-medium"><%= gettext("Email") %></th>
                <th class="text-left py-2 px-3 text-muted font-medium"><%= gettext("Status") %></th>
                <th class="text-left py-2 px-3 text-muted font-medium"><%= gettext("Invited by") %></th>
                <th class="text-left py-2 px-3 text-muted font-medium"><%= gettext("Expires") %></th>
                <th class="text-right py-2 px-3 text-muted font-medium"></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={invite <- @invites} class="border-b border-border/50">
                <td class="py-2 px-3 text-heading"><%= invite.email %></td>
                <td class="py-2 px-3">
                  <% {kind, label} = status(invite) %>
                  <.badge color={status_color(kind)}><%= label %></.badge>
                </td>
                <td class="py-2 px-3 text-muted">
                  <%= if invite.invited_by, do: invite.invited_by.username, else: "—" %>
                </td>
                <td class="py-2 px-3 text-muted tabular-nums">
                  <%= Calendar.strftime(invite.expires_at, "%d/%m/%Y") %>
                </td>
                <td class="py-2 px-3 text-right whitespace-nowrap">
                  <button
                    :if={elem(status(invite), 0) == :pending}
                    type="button"
                    phx-click="resend"
                    phx-value-id={invite.id}
                    class="text-xs text-accent hover:underline mr-3"
                  >
                    <%= gettext("Resend") %>
                  </button>
                  <button
                    :if={is_nil(invite.accepted_at)}
                    type="button"
                    phx-click="revoke"
                    phx-value-id={invite.id}
                    data-confirm={gettext("Revoke this invitation?")}
                    class="text-xs text-danger hover:underline"
                  >
                    <%= pgettext("invites", "Revoke") %>
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
    </section>
    """
  end
end
