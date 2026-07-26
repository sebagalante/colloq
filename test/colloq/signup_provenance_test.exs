defmodule Colloq.SignupProvenanceTest do
  @moduledoc """
  The address an account registered from.

  `last_ip` is overwritten by every login, so without this the signup address
  was gone the moment the account was first used — exactly when a moderator
  would want it.
  """
  use Colloq.DataCase

  alias Colloq.Accounts

  defp attrs(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        "email" => "nuevo#{n}@mail.com",
        "username" => "nuevo#{n}",
        "display_name" => "Nuevo",
        "password" => "unaclavelarga1",
        "password_confirmation" => "unaclavelarga1"
      },
      overrides
    )
  end

  test "stores the signup IP from an :inet tuple" do
    {:ok, user} = Accounts.register_user(attrs(), {181, 22, 33, 44})
    assert user.signup_ip == "181.22.33.44"
  end

  test "accepts a string address too" do
    {:ok, user} = Accounts.register_user(attrs(), "200.1.2.3")
    assert user.signup_ip == "200.1.2.3"
  end

  test "handles IPv6" do
    {:ok, user} = Accounts.register_user(attrs(), {8193, 3512, 0, 0, 0, 0, 0, 1})
    assert user.signup_ip =~ ":"
  end

  test "registering without an IP still works" do
    # The disconnected LiveView mount has no connect_info, and tests/console
    # calls pass nothing. A missing address must never fail a signup.
    {:ok, user} = Accounts.register_user(attrs())
    assert is_nil(user.signup_ip)
  end

  test "a junk address is ignored rather than raising" do
    {:ok, user} = Accounts.register_user(attrs(), :not_an_ip)
    assert is_nil(user.signup_ip)
  end

  test "the signup IP survives a later login from somewhere else" do
    {:ok, user} = Accounts.register_user(attrs(), "181.22.33.44")

    Accounts.record_login(user.id, {8, 8, 8, 8})
    reloaded = Repo.get!(Colloq.Accounts.User, user.id)

    assert reloaded.last_ip == "8.8.8.8", "last_ip should track the newest login"
    assert reloaded.signup_ip == "181.22.33.44", "signup_ip must not be overwritten"
  end

  test "OAuth signups are stamped too" do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oauth(
        %{
          "provider" => "google",
          "uid" => "uid-#{n}",
          "email" => "oauth#{n}@mail.com",
          "username" => "oauth#{n}",
          "display_name" => "OAuth"
        },
        "190.5.6.7"
      )

    assert user.signup_ip == "190.5.6.7"
  end

  test "an existing OAuth account keeps its original signup IP" do
    n = System.unique_integer([:positive])

    oauth = %{
      "provider" => "google",
      "uid" => "uid-#{n}",
      "email" => "oauth#{n}@mail.com",
      "username" => "oauth#{n}",
      "display_name" => "OAuth"
    }

    {:ok, first} = Accounts.find_or_create_from_oauth(oauth, "190.5.6.7")
    {:ok, again} = Accounts.find_or_create_from_oauth(oauth, "8.8.8.8")

    assert again.id == first.id
    assert again.signup_ip == "190.5.6.7"
  end
end
