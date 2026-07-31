defmodule Colloq.Media.Sniff do
  @moduledoc """
  Content-type detection from a file's *contents* rather than from what the
  client claims it is.

  Both the browser-supplied `content_type` and the filename extension are
  attacker-controlled, and they were trusted independently: `validate/1` checked
  the content type while `store/1` took the extension from the filename, so a
  file named `pwn.html` declared as `image/png` passed validation and was then
  served out of priv/static as `text/html` — stored XSS on our own origin.
  Everything that decides how an upload is stored and served now comes from
  here instead.

  SVG has no magic number (it is just XML), so it is matched structurally and
  cannot be verified the way a raster format can. It is still accepted, but
  script inside it is neutralised at serve time by the sandbox CSP in
  `ColloqWeb.Plugs.UploadHeaders` — never treat an SVG that passed through here
  as inert markup.
  """

  @probe_bytes 1024

  @typedoc """
  `:inline` — safe for the browser to render in place (`<img>`, `<video>`).
  `:attachment` — must be served with `Content-Disposition: attachment` so it
  can never be opened as a document on our origin.
  """
  @type disposition :: :inline | :attachment

  @type detected :: %{content_type: String.t(), ext: String.t(), disposition: disposition()}

  # Extensions we are willing to serve inline. Anything absent is forced to
  # download, so an unrecognised or newly-added format fails closed.
  @inline_exts ~w(.png .jpg .jpeg .gif .webp .svg .mp4 .webm .ogg .mp3 .m4a)

  @doc """
  Detects the real type of the file at `path`.

  Returns `{:ok, detected}` for formats we recognise, `:unknown` otherwise —
  callers must treat `:unknown` as opaque bytes, never as something renderable.
  """
  @spec detect(String.t()) :: {:ok, detected()} | :unknown
  def detect(path) when is_binary(path) do
    case read_head(path) do
      {:ok, head} -> classify(head)
      :error -> :unknown
    end
  end

  @doc """
  Disposition for an already-stored file, keyed off its extension.

  Used at serve time, where the bytes aren't at hand: the extension is
  trustworthy there precisely because `detect/1` chose it at upload time.
  """
  @spec disposition_for_extension(String.t()) :: disposition()
  def disposition_for_extension(ext) when is_binary(ext) do
    if String.downcase(ext) in @inline_exts, do: :inline, else: :attachment
  end

  @doc """
  Reduces a client-supplied filename to a bare, safe extension.

  Only used for files we could not identify, purely so downloads keep a
  meaningful name — the type they are served with never comes from here.
  """
  @spec safe_extension(String.t() | nil) :: String.t()
  def safe_extension(filename) when is_binary(filename) do
    filename
    |> Path.extname()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9.]/, "")
    |> case do
      "." <> rest when rest != "" -> "." <> String.slice(rest, 0, 8)
      _ -> ".bin"
    end
  end

  def safe_extension(_), do: ".bin"

  defp read_head(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @probe_bytes)) do
      {:ok, data} when is_binary(data) -> {:ok, data}
      _ -> :error
    end
  end

  defp classify(<<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>),
    do: ok("image/png", ".png", :inline)

  defp classify(<<0xFF, 0xD8, 0xFF, _::binary>>), do: ok("image/jpeg", ".jpg", :inline)
  defp classify(<<"GIF87a", _::binary>>), do: ok("image/gif", ".gif", :inline)
  defp classify(<<"GIF89a", _::binary>>), do: ok("image/gif", ".gif", :inline)

  defp classify(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>),
    do: ok("image/webp", ".webp", :inline)

  defp classify(<<_::binary-size(4), "ftyp", _::binary>>), do: ok("video/mp4", ".mp4", :inline)
  defp classify(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: ok("video/webm", ".webm", :inline)
  defp classify(<<"OggS", _::binary>>), do: ok("audio/ogg", ".ogg", :inline)
  defp classify(<<"ID3", _::binary>>), do: ok("audio/mpeg", ".mp3", :inline)
  defp classify(<<0xFF, 0xFB, _::binary>>), do: ok("audio/mpeg", ".mp3", :inline)

  # Documents and archives are recognised only so they keep a sensible name on
  # download — they are never rendered in place. A PDF in particular is a
  # scripting host, so serving one inline on our origin is an XSS vector.
  defp classify(<<"%PDF-", _::binary>>), do: ok("application/pdf", ".pdf", :attachment)
  defp classify(<<"PK", 0x03, 0x04, _::binary>>), do: ok("application/zip", ".zip", :attachment)

  defp classify(head) when is_binary(head) do
    trimmed = head |> String.replace_prefix("﻿", "") |> String.trim_leading()

    cond do
      String.starts_with?(trimmed, "<svg") ->
        ok("image/svg+xml", ".svg", :inline)

      String.starts_with?(trimmed, "<?xml") and svg_root?(trimmed) ->
        ok("image/svg+xml", ".svg", :inline)

      true ->
        :unknown
    end
  end

  # An XML declaration alone proves nothing; require an actual <svg> root
  # within the probed window so arbitrary XML isn't stored under a .svg name.
  defp svg_root?(trimmed), do: String.contains?(trimmed, "<svg")

  defp ok(content_type, ext, disposition),
    do: {:ok, %{content_type: content_type, ext: ext, disposition: disposition}}
end
