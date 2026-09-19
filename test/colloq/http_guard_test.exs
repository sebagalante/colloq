defmodule Colloq.HttpGuardTest do
  use ExUnit.Case, async: true

  describe "validate/1" do
    test "accepts public http(s) URLs" do
      assert Colloq.HttpGuard.validate("https://example.com/foo?bar=1") == :ok
      assert Colloq.HttpGuard.validate("http://example.com") == :ok
      assert Colloq.HttpGuard.validate("http://8.8.8.8/x") == :ok
      assert Colloq.HttpGuard.validate("http://[2606:4700:4700::1111]/") == :ok
    end

    test "rejects non-http(s) schemes" do
      assert {:error, :bad_scheme} = Colloq.HttpGuard.validate("file:///etc/passwd")
      assert {:error, :bad_scheme} = Colloq.HttpGuard.validate("gopher://example.com")
      assert {:error, :bad_scheme} = Colloq.HttpGuard.validate("ftp://example.com/x")
    end

    test "rejects missing host or non-binary input" do
      assert {:error, reason} = Colloq.HttpGuard.validate("")
      assert reason in [:bad_url, :no_host, :bad_scheme]
      assert {:error, :not_binary} = Colloq.HttpGuard.validate(nil)
      assert {:error, :not_binary} = Colloq.HttpGuard.validate(42)
    end

    test "rejects hostnames we must never resolve or fetch" do
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://localhost:4000/admin")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://sub.localhost/x")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://printer.local/x")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://db.internal/x")
    end

    test "rejects literal IPv4 private/reserved addresses" do
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://127.0.0.1:4000/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://10.0.0.1/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://172.16.0.9/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://172.31.255.255/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://192.168.1.1/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://169.254.169.254/latest/meta-data/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://100.64.0.1/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://0.0.0.0/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://224.0.0.1/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://255.255.255.255/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://192.0.2.1/")
    end

    test "rejects literal IPv6 private/reserved addresses" do
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://[::1]:4000/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://[::]/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://[fc00::1]/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://[fd12:3456::1]/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://[fe80::1]/")
      # IPv4-mapped IPv6 carrying a loopback/private IPv4
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://[::ffff:127.0.0.1]/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://[::ffff:10.0.0.1]/")
      assert {:error, :blocked_host} = Colloq.HttpGuard.validate("http://[::ffff:192.168.0.1]/")
    end

    test "rejects unresolvable hostnames (offline/typos)" do
      # .invalid is guaranteed NXDOMAIN per RFC 2606; in CI there is no DNS for it.
      assert {:error, reason} = Colloq.HttpGuard.validate("http://does-not-exist.invalid/")
      assert reason in [:unresolvable, :blocked_host]
    end
  end

  describe "safe_url?/1" do
    test "mirrors validate/1 as a boolean" do
      assert Colloq.HttpGuard.safe_url?("https://example.com/") == true
      assert Colloq.HttpGuard.safe_url?("http://127.0.0.1/") == false
      assert Colloq.HttpGuard.safe_url?(nil) == false
    end
  end
end
