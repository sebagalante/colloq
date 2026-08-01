defmodule Colloq.MessageEmbedWorkerTest do
  @moduledoc """
  Which chat links earn a preview card.

  `preview_url/1` is the gate for both the worker and the send path (a job is
  only enqueued when it returns something), so the cases that matter are the
  ones that must NOT produce a card: messages with no link, and links that the
  bubble already renders inline as media.
  """
  use Colloq.DataCase, async: true

  alias Colloq.Workers.MessageEmbedWorker

  test "picks the link out of a message" do
    assert MessageEmbedWorker.preview_url("mirá esto https://example.com/post") ==
             "https://example.com/post"
  end

  test "no link, no card" do
    assert MessageEmbedWorker.preview_url("dadada") == nil
    assert MessageEmbedWorker.preview_url("") == nil
    assert MessageEmbedWorker.preview_url(nil) == nil
  end

  test "skips URLs the bubble already renders itself" do
    # Images and YouTube are detected from the body at render time and embedded
    # inline — a card on top of the embed would be the same link twice.
    assert MessageEmbedWorker.preview_url("https://example.com/cat.jpg") == nil
    assert MessageEmbedWorker.preview_url("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == nil
  end

  test "one card per message, even with several links" do
    body = "https://example.com/one y https://example.org/two"

    assert MessageEmbedWorker.preview_url(body) == "https://example.com/one"
  end

  test "falls through to the link when the message also carries media" do
    body = "https://example.com/cat.jpg y https://example.org/article"

    assert MessageEmbedWorker.preview_url(body) == "https://example.org/article"
  end
end
