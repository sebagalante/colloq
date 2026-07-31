defmodule Colloq.Accounts.UserPasswordTest do
  @moduledoc """
  Covers the two properties that are easy to regress silently: plaintext
  passwords must never survive into inspected output, and the rules must be the
  same whichever way a password gets set (registration or reset).
  """
  use ExUnit.Case, async: true

  alias Colloq.Accounts.User

  @valid %{
    email: "a@example.com",
    username: "someone",
    password: "correct horse",
    password_confirmation: "correct horse"
  }

  defp registration(attrs \\ %{}),
    do: User.registration_changeset(%User{}, Map.merge(@valid, attrs))

  defp password_error(changeset) do
    changeset.errors |> Keyword.get_values(:password) |> Enum.map(&elem(&1, 0))
  end

  describe "redaction" do
    test "an inspected changeset does not leak the plaintext password" do
      dumped = inspect(registration(), limit: :infinity)

      refute dumped =~ "correct horse"
      assert dumped =~ "**redacted**"
    end

    test "an inspected user struct leaks neither the password nor the hash" do
      user = %User{password: "correct horse", password_hash: "$2b$12$abcdefghijklmnop"}
      dumped = inspect(user, limit: :infinity)

      refute dumped =~ "correct horse"
      refute dumped =~ "$2b$12$abcdefghijklmnop"
    end
  end

  describe "registration_changeset/2 password rules" do
    test "accepts a valid password and stores only a hash" do
      changeset = registration()

      assert changeset.valid?
      hash = Ecto.Changeset.get_change(changeset, :password_hash)
      assert is_binary(hash)
      refute hash == "correct horse"
      assert Bcrypt.verify_pass("correct horse", hash)
    end

    test "rejects a password under 8 characters" do
      changeset = registration(%{password: "short", password_confirmation: "short"})

      refute changeset.valid?
      assert password_error(changeset) != []
    end

    test "rejects a password over the 72-byte bcrypt limit" do
      long = String.duplicate("a", 73)
      changeset = registration(%{password: long, password_confirmation: long})

      refute changeset.valid?
      assert password_error(changeset) != []
    end

    test "accepts exactly 72 bytes" do
      at_limit = String.duplicate("a", 72)
      assert registration(%{password: at_limit, password_confirmation: at_limit}).valid?
    end

    # The limit is bcrypt's input length in bytes, so it has to be measured in
    # bytes: 40 multi-byte characters are well under 72 graphemes but over the
    # limit the algorithm actually applies.
    test "measures the limit in bytes, not characters" do
      multibyte = String.duplicate("ñ", 40)
      refute registration(%{password: multibyte, password_confirmation: multibyte}).valid?
      assert byte_size(multibyte) == 80
      assert String.length(multibyte) == 40
    end

    test "rejects a mismatched confirmation" do
      changeset = registration(%{password_confirmation: "something else"})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :password_confirmation)
    end

    test "does not hash when the changeset is invalid" do
      changeset = registration(%{password: "short", password_confirmation: "short"})
      assert Ecto.Changeset.get_change(changeset, :password_hash) == nil
    end
  end

  describe "password_changeset/2" do
    # Before this existed the reset flow hashed straight into
    # Ecto.Changeset.change/2, so none of these rules applied to a reset.
    test "hashes a valid new password" do
      changeset =
        User.password_changeset(%User{}, %{
          password: "brand new pass",
          password_confirmation: "brand new pass"
        })

      assert changeset.valid?

      assert Bcrypt.verify_pass(
               "brand new pass",
               Ecto.Changeset.get_change(changeset, :password_hash)
             )
    end

    test "enforces the same length rules as registration" do
      too_short =
        User.password_changeset(%User{}, %{password: "abc", password_confirmation: "abc"})

      refute too_short.valid?

      long = String.duplicate("a", 73)
      too_long = User.password_changeset(%User{}, %{password: long, password_confirmation: long})
      refute too_long.valid?
    end

    test "enforces confirmation" do
      changeset =
        User.password_changeset(%User{}, %{
          password: "a valid one",
          password_confirmation: "different"
        })

      refute changeset.valid?
    end

    test "requires a password" do
      refute User.password_changeset(%User{}, %{}).valid?
    end
  end
end
