defmodule Colloq.GeoIPTest do
  use ExUnit.Case, async: false

  alias Colloq.GeoIP

  # No GeoLite2 database is configured in test, which is the state the app must
  # tolerate: lookups fail soft and the loader never starts. The "with a
  # database" half is exercised manually against MaxMind's test fixture — see
  # the module doc — since the real .mmdb isn't something to commit.
  describe "without a database configured" do
    setup do
      previous = Application.get_env(:colloq, GeoIP)
      Application.put_env(:colloq, GeoIP, license_key: nil, path: nil)
      on_exit(fn -> Application.put_env(:colloq, GeoIP, previous || []) end)
      :ok
    end

    test "configured?/0 is false" do
      refute GeoIP.configured?()
    end

    test "no loader is added to the supervision tree" do
      assert GeoIP.child_spec_or_nil() == nil
    end

    test "lookups fail soft rather than raising" do
      assert GeoIP.lookup("190.211.0.1") == :error
      assert GeoIP.lookup({190, 211, 0, 1}) == :error
      assert GeoIP.lookup(nil) == :error
      assert GeoIP.lookup("not an ip") == :error
      assert GeoIP.lookup(42) == :error
    end

    test "describe/1 returns nil, so callers render nothing" do
      assert GeoIP.describe("190.211.0.1") == nil
      assert GeoIP.describe(nil) == nil
    end
  end

  describe "source selection" do
    setup do
      previous = Application.get_env(:colloq, GeoIP)
      on_exit(fn -> Application.put_env(:colloq, GeoIP, previous || []) end)
      :ok
    end

    test "a path wins over a license key" do
      Application.put_env(:colloq, GeoIP, path: "/tmp/x.mmdb", license_key: "abc")
      assert %{start: {_, _, [_, load_from, _]}} = GeoIP.child_spec_or_nil()
      # locus normalises the path to a charlist as it parses the source.
      assert load_from == {:filesystem, ~c"/tmp/x.mmdb"}
    end

    test "a license key downloads from MaxMind" do
      Application.put_env(:colloq, GeoIP, path: nil, license_key: "abc")
      assert %{start: {_, _, [_, load_from, _]}} = GeoIP.child_spec_or_nil()
      assert load_from == {:maxmind, :"GeoLite2-City"}
    end

    test "blank env vars count as unset" do
      Application.put_env(:colloq, GeoIP, path: "  ", license_key: "")
      refute GeoIP.configured?()
    end
  end
end
