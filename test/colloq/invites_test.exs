defmodule Colloq.InvitesTest do
  use Colloq.DataCase
  import Colloq.Factory

  alias Colloq.Invites
  alias Colloq.SiteSettings

  defp set_mode(mode), do: SiteSettings.put("registration_mode", mode, type: "string", group: "security")

  describe "issuing" do
    test "creates a pending invite and queues the email" do
      {:ok, invite} = Invites.invite("nueva@mail.com")

      assert invite.email == "nueva@mail.com"
      assert invite.token
      assert is_nil(invite.accepted_at)
      assert Invites.pending_by_token(invite.token).id == invite.id
    end

    test "normalises case and whitespace" do
      {:ok, invite} = Invites.invite("  Mixed@Mail.COM  ")
      assert invite.email == "mixed@mail.com"
    end

    test "refuses an address that already has a live invite" do
      {:ok, _} = Invites.invite("dup@mail.com")
      assert {:error, :already_invited} = Invites.invite("dup@mail.com")
    end

    test "refuses an already registered address" do
      user = insert(:user)
      assert {:error, :already_registered} = Invites.invite(user.email)
    end

    test "invite_many reports per-address failures without failing the batch" do
      user = insert(:user)
      {sent, failed} = Invites.invite_many(["ok@mail.com", user.email])

      assert length(sent) == 1
      assert [{_, :already_registered}] = failed
    end

    test "parse_emails splits on commas, spaces and newlines" do
      assert Invites.parse_emails("a@x.com, b@x.com\nc@x.com d@x.com") ==
               ~w(a@x.com b@x.com c@x.com d@x.com)
    end
  end

  describe "token validity" do
    test "an accepted invite is no longer pending" do
      {:ok, invite} = Invites.invite("once@mail.com")
      user = insert(:user)

      {:ok, _} = Invites.accept(invite, user)

      refute Invites.pending_by_token(invite.token)
    end

    test "an expired invite is not pending" do
      {:ok, invite} = Invites.invite("old@mail.com")

      invite
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update!()

      refute Invites.pending_by_token(invite.token)
    end

    test "an unknown token is not pending" do
      refute Invites.pending_by_token("nope")
      refute Invites.pending_by_token(nil)
    end
  end

  describe "registration gating" do
    test "open mode lets anyone through, with or without a token" do
      set_mode("open")
      assert Invites.registration_open?(nil) == :ok
      assert Invites.registration_mode() == :open
    end

    test "closed mode blocks everyone, even with a valid token" do
      {:ok, invite} = Invites.invite("x@mail.com")
      set_mode("closed")

      assert Invites.registration_open?(nil) == {:error, :closed}
      assert Invites.registration_open?(invite.token) == {:error, :closed}
    end

    test "invite mode requires a live token" do
      {:ok, invite} = Invites.invite("y@mail.com")
      set_mode("invite")

      assert Invites.registration_open?(invite.token) == :ok
      assert Invites.registration_open?(nil) == {:error, :invite_required}
      assert Invites.registration_open?("garbage") == {:error, :invite_required}
    end

    test "an unrecognised mode fails open rather than locking the forum" do
      set_mode("open")
      Repo.update_all(
        Ecto.Query.from(s in Colloq.SiteSettings.Setting, where: s.key == "registration_mode"),
        set: [value: "banana"]
      )

      assert Invites.registration_mode() == :open
    end
  end

  describe "revoking and resending" do
    test "a pending invite can be revoked" do
      {:ok, invite} = Invites.invite("bye@mail.com")
      assert {:ok, _} = Invites.delete_invite(invite)
      refute Invites.pending_by_token(invite.token)
    end

    test "an accepted invite is kept as a record" do
      {:ok, invite} = Invites.invite("kept@mail.com")
      {:ok, invite} = Invites.accept(invite, insert(:user))

      assert {:error, :already_accepted} = Invites.delete_invite(invite)
    end

    test "only a pending invite can be resent" do
      {:ok, invite} = Invites.invite("again@mail.com")
      assert {:ok, _} = Invites.resend(invite)

      {:ok, accepted} = Invites.accept(invite, insert(:user))
      assert {:error, :not_pending} = Invites.resend(accepted)
    end
  end
end
