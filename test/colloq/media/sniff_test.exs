defmodule Colloq.Media.SniffTest do
  @moduledoc """
  The regression these cover: uploads used to be classified by the client's
  `content_type` while the stored extension came from the client's filename, so
  the two could disagree and a `.html` declared as `image/png` ended up served
  from our own origin as text/html.
  """
  use ExUnit.Case, async: true

  alias Colloq.Media.Sniff

  defp write(bytes) do
    path = Path.join(System.tmp_dir!(), "sniff-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "detect/1" do
    test "identifies raster images by magic bytes" do
      assert {:ok, %{content_type: "image/png", ext: ".png", disposition: :inline}} =
               Sniff.detect(write(<<0x89, "PNG\r\n", 0x1A, 0x0A, 0::size(64)>>))

      assert {:ok, %{content_type: "image/jpeg", ext: ".jpg"}} =
               Sniff.detect(write(<<0xFF, 0xD8, 0xFF, 0xE0, 0::size(64)>>))

      assert {:ok, %{content_type: "image/gif", ext: ".gif"}} =
               Sniff.detect(write("GIF89a" <> <<0::size(64)>>))

      assert {:ok, %{content_type: "image/webp", ext: ".webp"}} =
               Sniff.detect(write("RIFF" <> <<1, 2, 3, 4>> <> "WEBP" <> <<0::size(32)>>))
    end

    test "identifies svg with and without an xml declaration" do
      assert {:ok, %{content_type: "image/svg+xml", ext: ".svg"}} =
               Sniff.detect(write(~s|<svg xmlns="http://www.w3.org/2000/svg"/>|))

      assert {:ok, %{content_type: "image/svg+xml"}} =
               Sniff.detect(
                 write(~s|<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg"/>|)
               )
    end

    test "does not mistake other markup for an image" do
      assert :unknown = Sniff.detect(write("<html><script>alert(1)</script></html>"))
      assert :unknown = Sniff.detect(write(~s|<?xml version="1.0"?><rss><channel/></rss>|))
      assert :unknown = Sniff.detect(write(""))
    end

    test "a png-shaped name does not make a file a png" do
      # The exact bypass: the client claims image/png and names it .png, but the
      # bytes are HTML. Detection sees only the bytes.
      assert :unknown = Sniff.detect(write("<html><script>alert(1)</script></html>"))
    end

    test "documents and archives are recognised but never inline" do
      assert {:ok, %{content_type: "application/pdf", disposition: :attachment}} =
               Sniff.detect(write("%PDF-1.7 ..."))

      assert {:ok, %{content_type: "application/zip", disposition: :attachment}} =
               Sniff.detect(write(<<"PK", 3, 4, 0::size(64)>>))
    end

    test "audio and video keep their type so chat embeds still play" do
      assert {:ok, %{content_type: "video/mp4", disposition: :inline}} =
               Sniff.detect(write(<<0, 0, 0, 24, "ftypisom", 0::size(32)>>))

      assert {:ok, %{content_type: "video/webm", disposition: :inline}} =
               Sniff.detect(write(<<0x1A, 0x45, 0xDF, 0xA3, 0::size(64)>>))
    end
  end

  describe "disposition_for_extension/1" do
    test "fails closed for anything not explicitly renderable" do
      for ext <- ~w(.png .jpg .svg .mp4 .PNG),
          do: assert(Sniff.disposition_for_extension(ext) == :inline)

      for ext <- ~w(.html .htm .xhtml .xml .pdf .zip .bin .exe ""),
          do: assert(Sniff.disposition_for_extension(ext) == :attachment)
    end
  end

  describe "safe_extension/1" do
    test "reduces a client filename to bare characters" do
      assert Sniff.safe_extension("a.html") == ".html"
      assert Sniff.safe_extension("x.PnG") == ".png"
      assert Sniff.safe_extension("a.tar.gz") == ".gz"
      assert Sniff.safe_extension("x.verylongextension") == ".verylong"
    end

    test "falls back for names carrying no usable extension" do
      assert Sniff.safe_extension("no-ext") == ".bin"
      assert Sniff.safe_extension("../../etc/passwd") == ".bin"
      assert Sniff.safe_extension(nil) == ".bin"
    end
  end
end
