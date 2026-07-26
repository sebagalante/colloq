defmodule ColloqWeb.InviteRegistrationTest do
  use ColloqWeb.ConnCase
  import Phoenix.LiveViewTest
  import Colloq.Factory
  import ColloqWeb.Gettext

  alias Colloq.Invites
  alias Colloq.SiteSettings

  @endpoint ColloqWeb.Endpoint

  defp set_mode(mode), do: SiteSettings.put("registration_mode", mode, type: "string", group: "security")

  defp signup_params(email) do
    %{
      "email" => email,
      "username" => "invitado#{System.unique_integer([:positive])}",
      "display_name" => "Invitado",
      "password" => "unaclavelarga1",
      "password_confirmation" => "unaclavelarga1"
    }
  end

  describe "open mode" do
    test "shows the form to anyone", %{conn: conn} do
      set_mode("open")
      {:ok, _view, html} = live(conn, "/register")

      assert html =~ "name=\"user[password]\""
    end
  end

  describe "closed mode" do
    test "hides the form and the OAuth buttons", %{conn: conn} do
      set_mode("closed")
      {:ok, _view, html} = live(conn, "/register")

      refute html =~ "name=\"user[password]\""
      assert html =~ gettext("Registration is closed right now.")
    end

    test "rejects a submitted signup", %{conn: conn} do
      set_mode("closed")
      {:ok, view, _html} = live(conn, "/register")

      html = view |> render_submit("save", %{"user" => signup_params("sneaky@mail.com")})

      assert html =~ gettext("Registration is closed right now.")
      refute Colloq.Repo.get_by(Colloq.Accounts.User, email: "sneaky@mail.com")
    end
  end

  describe "invite mode" do
    test "without a token the form is hidden", %{conn: conn} do
      set_mode("invite")
      {:ok, _view, html} = live(conn, "/register")

      refute html =~ "name=\"user[password]\""
      assert html =~ gettext("You need a valid invitation to create an account.")
    end

    test "a valid token opens the form with the email prefilled", %{conn: conn} do
      {:ok, invite} = Invites.invite("guest@mail.com")
      set_mode("invite")

      {:ok, _view, html} = live(conn, "/register?invite=#{invite.token}")

      assert html =~ "name=\"user[password]\""
      assert html =~ "guest@mail.com"
    end

    test "signing up consumes the invite", %{conn: conn} do
      {:ok, invite} = Invites.invite("guest2@mail.com")
      set_mode("invite")

      {:ok, view, _html} = live(conn, "/register?invite=#{invite.token}")
      render_submit(view, "save", %{"user" => signup_params("guest2@mail.com")})

      assert Colloq.Repo.get_by(Colloq.Accounts.User, email: "guest2@mail.com")

      # Consumed: the same link can't create a second account.
      refute Invites.pending_by_token(invite.token)
    end

    test "the invited address wins over a tampered one", %{conn: conn} do
      {:ok, invite} = Invites.invite("real@mail.com")
      set_mode("invite")

      {:ok, view, _html} = live(conn, "/register?invite=#{invite.token}")
      render_submit(view, "save", %{"user" => signup_params("attacker@mail.com")})

      assert Colloq.Repo.get_by(Colloq.Accounts.User, email: "real@mail.com")
      refute Colloq.Repo.get_by(Colloq.Accounts.User, email: "attacker@mail.com")
    end

    test "a garbage token is refused on submit too", %{conn: conn} do
      set_mode("invite")
      {:ok, view, _html} = live(conn, "/register?invite=nope")

      html = render_submit(view, "save", %{"user" => signup_params("nope@mail.com")})

      assert html =~ gettext("You need a valid invitation to create an account.")
      refute Colloq.Repo.get_by(Colloq.Accounts.User, email: "nope@mail.com")
    end
  end

  describe "admin screen" do
    setup do
      admin = insert(:user, role: "admin", is_admin: true)
      %{admin: admin}
    end

    test "sends invitations from pasted addresses", %{conn: conn, admin: admin} do
      set_mode("invite")
      conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})

      {:ok, view, _html} = live(conn, "/admin/invites")
      html = render_submit(view, "send", %{"emails" => "uno@mail.com, dos@mail.com"})

      assert html =~ "uno@mail.com"
      assert html =~ "dos@mail.com"
      assert Invites.pending_for("uno@mail.com")
      assert Invites.pending_for("dos@mail.com")
    end

    test "warns when registration is open, since invites gate nothing", %{conn: conn, admin: admin} do
      set_mode("open")
      conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})

      {:ok, _view, html} = live(conn, "/admin/invites")

      # Compare up to the first quote: the rendered page escapes the quotes
      # around "invite", so the full string never matches literally.
      [head | _] =
        gettext(
          "Registration is currently open, so anyone can sign up without an invitation. Set registration_mode to \"invite\" in Settings ▸ Security for these to be required."
        )
        |> String.split("\"")

      assert html =~ head
    end

    test "revokes a pending invitation", %{conn: conn, admin: admin} do
      {:ok, invite} = Invites.invite("revoke@mail.com")
      conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})

      {:ok, view, _html} = live(conn, "/admin/invites")
      render_click(view, "revoke", %{"id" => invite.id})

      refute Invites.pending_by_token(invite.token)
    end
  end
end
