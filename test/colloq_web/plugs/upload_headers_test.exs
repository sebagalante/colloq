defmodule ColloqWeb.Plugs.UploadHeadersTest do
  @moduledoc """
  `Plug.Static` is mounted above the router, so uploads bypass the browser
  pipeline's CSP entirely. These pin the headers that replace it.
  """
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ColloqWeb.Plugs.UploadHeaders

  defp call(path), do: UploadHeaders.call(conn(:get, path), UploadHeaders.init([]))

  test "sandboxes uploads so a stored svg can't run script on direct navigation" do
    conn = call("/uploads/evil.svg")

    csp = hd(get_resp_header(conn, "content-security-policy"))
    assert csp =~ "sandbox"
    assert csp =~ "default-src 'none'"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cross-origin-resource-policy") == ["same-origin"]
  end

  test "renderable types stay inline" do
    for path <- ~w(/uploads/a.png /uploads/a.svg /uploads/a.mp4) do
      assert get_resp_header(call(path), "content-disposition") == []
    end
  end

  test "anything that could open as a document is forced to download" do
    for path <- ~w(/uploads/a.html /uploads/a.xhtml /uploads/a.pdf /uploads/a.bin) do
      assert get_resp_header(call(path), "content-disposition") == ["attachment"],
             "expected #{path} to be forced to download"
    end
  end

  test "leaves non-upload paths alone so the router's own CSP applies" do
    for path <- ~w(/ /forum /assets/app.js /uploads) do
      assert get_resp_header(call(path), "content-security-policy") == []
    end
  end
end
