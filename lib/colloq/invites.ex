defmodule Colloq.Invites do
  @moduledoc """
  Invitations context.

  Only meaningful while `registration_mode` is `"invite"` — see
  `registration_open?/1` for how the three modes gate signup. Kept out of
  `Colloq.Accounts` because invites are their own lifecycle (issue → send →
  accept/expire) and that module is already large.
  """
  import Ecto.Query, warn: false

  alias Colloq.Repo
  alias Colloq.Accounts.Invite
  alias Colloq.SiteSettings
  alias Colloq.Workers.InviteWorker

  @default_ttl_days 14

  @doc """
  How long a new invite stays valid. Configurable via the `invite_ttl_days`
  site setting; defaults to #{@default_ttl_days} days.
  """
  def ttl_days do
    case SiteSettings.get("invite_ttl_days") do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_ttl_days
    end
  end

  @doc """
  Issues an invite for `email` and queues the delivery email.

  Refuses an address that already has a usable invite (`{:error, :already_invited}`)
  or that is already registered (`{:error, :already_registered}`) — both would
  otherwise send mail that can't be acted on.
  """
  def invite(email, invited_by \\ nil) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    cond do
      registered?(normalized) ->
        {:error, :already_registered}

      pending_for(normalized) != nil ->
        {:error, :already_invited}

      true ->
        %{email: normalized, invited_by_id: invited_by && invited_by.id}
        |> Invite.create_changeset(ttl_days())
        |> Repo.insert()
        |> case do
          {:ok, invite} ->
            %{invite_id: invite.id}
            |> InviteWorker.new()
            |> Oban.insert()

            {:ok, invite}

          error ->
            error
        end
    end
  end

  @doc """
  Issues invites for a list of addresses, returning `{successes, failures}`.

  Failures carry the reason per address so the admin screen can say which ones
  didn't go out and why, rather than failing the whole batch on one bad entry.
  """
  def invite_many(emails, invited_by \\ nil) when is_list(emails) do
    emails
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.reduce({[], []}, fn email, {ok, failed} ->
      case invite(email, invited_by) do
        {:ok, invite} -> {[invite | ok], failed}
        {:error, reason} -> {ok, [{email, reason} | failed]}
      end
    end)
    |> then(fn {ok, failed} -> {Enum.reverse(ok), Enum.reverse(failed)} end)
  end

  @doc "Parses a textarea of addresses separated by commas, semicolons or newlines."
  def parse_emails(text) when is_binary(text), do: String.split(text, ~r/[\s,;]+/, trim: true)
  def parse_emails(_), do: []

  @doc "Every invite, newest first, with the issuer and acceptor preloaded."
  def list_invites do
    Invite
    |> order_by([i], desc: i.inserted_at)
    |> preload([:invited_by, :accepted_by])
    |> Repo.all()
  end

  @doc "Looks up a usable invite by token. Expired and accepted ones return nil."
  def pending_by_token(token) when is_binary(token) do
    case Repo.get_by(Invite, token: token) do
      nil -> nil
      invite -> if Invite.pending?(invite), do: invite, else: nil
    end
  end

  def pending_by_token(_), do: nil

  @doc "The usable invite for `email`, if any."
  def pending_for(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    Invite
    |> where([i], i.email == ^normalized and is_nil(i.accepted_at))
    |> where([i], i.expires_at > ^DateTime.utc_now())
    |> limit(1)
    |> Repo.one()
  end

  def pending_for(_), do: nil

  @doc "Marks `invite` accepted by `user`."
  def accept(%Invite{} = invite, user) do
    invite |> Invite.accept_changeset(user) |> Repo.update()
  end

  @doc "Stamps `invite` as delivered."
  def mark_sent(%Invite{} = invite) do
    invite |> Invite.sent_changeset() |> Repo.update()
  end

  @doc "Revokes an invite outright. Accepted ones are kept as a record."
  def delete_invite(%Invite{accepted_at: nil} = invite), do: Repo.delete(invite)
  def delete_invite(%Invite{}), do: {:error, :already_accepted}

  @doc "Re-queues the email for a still-pending invite."
  def resend(%Invite{} = invite) do
    if Invite.pending?(invite) do
      %{invite_id: invite.id} |> InviteWorker.new() |> Oban.insert()
      {:ok, invite}
    else
      {:error, :not_pending}
    end
  end

  def get_invite!(id), do: Repo.get!(Invite, id)

  # ---------------------------------------------------------------------------
  # Registration gating
  # ---------------------------------------------------------------------------

  @doc """
  The current registration mode: `:open`, `:invite` or `:closed`.

  Anything unrecognised reads as `:open` — a broken setting shouldn't lock
  everyone out of a public forum.
  """
  def registration_mode do
    case SiteSettings.get("registration_mode") do
      "invite" -> :invite
      "closed" -> :closed
      _ -> :open
    end
  end

  @doc """
  Whether signup may proceed, given the token in the URL (or `nil`).

  Returns `:ok`, `{:error, :closed}`, or `{:error, :invite_required}`.
  """
  def registration_open?(token \\ nil) do
    case registration_mode() do
      :open -> :ok
      :closed -> {:error, :closed}
      :invite -> if pending_by_token(token), do: :ok, else: {:error, :invite_required}
    end
  end

  defp registered?(email) do
    Repo.exists?(from u in Colloq.Accounts.User, where: fragment("lower(?)", u.email) == ^email)
  end
end
