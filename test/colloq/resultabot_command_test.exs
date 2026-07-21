defmodule Colloq.ResultabotCommandTest do
  use ExUnit.Case, async: true

  alias Colloq.Permissions
  alias Colloq.Workers.ResultabotCommandWorker, as: Cmd

  describe "command?/1" do
    test "matches the command inside Tiptap HTML" do
      assert Cmd.command?("<p>/resultabot</p>")
    end

    test "matches regardless of case and surrounding whitespace" do
      assert Cmd.command?("<p>  /ResultaBot  </p>")
    end

    test "ignores a post that merely mentions the command mid-sentence" do
      # Only a post that *starts* with the command counts, so discussing it
      # doesn't start live coverage.
      refute Cmd.command?("<p>che, probá /resultabot en el hilo del partido</p>")
    end

    test "ignores ordinary posts" do
      refute Cmd.command?("<p>vamo racing carajo</p>")
    end

    test "ignores a nil body" do
      refute Cmd.command?(nil)
    end
  end

  describe ":start_match_bot permission" do
    test "staff roles can start coverage" do
      for role <- ~w(moderator admin super_admin) do
        assert Permissions.can?(%{role: role}, :start_match_bot),
               "#{role} should be able to start ResultaBot"
      end
    end

    test "a regular user cannot" do
      refute Permissions.can?(%{role: nil}, :start_match_bot)
    end

    test "an anonymous visitor cannot" do
      refute Permissions.can?(nil, :start_match_bot)
    end
  end

  describe "subcommand/1" do
    test "bare command starts coverage" do
      assert Cmd.subcommand("<p>/resultabot</p>") == :start
    end

    test "stop is parsed as stop, not start" do
      # This is the regression that matters: matching used to be prefix-only,
      # so "/resultabot stop" STARTED coverage — the exact opposite of what the
      # operator wanted, at the exact moment they wanted it.
      assert Cmd.subcommand("<p>/resultabot stop</p>") == :stop
    end

    test "status is parsed as status" do
      assert Cmd.subcommand("<p>/resultabot status</p>") == :status
    end

    test "accepts Spanish aliases" do
      assert Cmd.subcommand("<p>/resultabot parar</p>") == :stop
      assert Cmd.subcommand("<p>/resultabot estado</p>") == :status
    end

    test "is case and whitespace tolerant" do
      assert Cmd.subcommand("<p>  /ResultaBot   STOP  </p>") == :stop
    end

    test "an unknown argument does not silently start coverage" do
      assert Cmd.subcommand("<p>/resultabot fubar</p>") == {:unknown, "fubar"}
    end
  end
end
