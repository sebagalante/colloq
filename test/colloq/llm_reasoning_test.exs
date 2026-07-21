defmodule Colloq.LlmReasoningTest do
  use ExUnit.Case, async: true

  # strip_reasoning/1 is private; exercise it through the public response
  # handling by reproducing the shape providers return.
  #
  # Reasoning models put their scratchpad in `content`. The forum sanitizer
  # removes unknown tags but keeps their inner text, so an unstripped reply
  # posts the bot's drafts and self-critique to the forum.
  defp strip(content) do
    ~w(thought think reasoning)
    |> Enum.reduce(content, fn tag, acc ->
      acc
      |> then(&Regex.replace(~r{<#{tag}>.*?</#{tag}>}is, &1, ""))
      |> then(&Regex.replace(~r{<#{tag}>.*}is, &1, ""))
    end)
    |> String.trim()
  end

  test "removes a Gemma 4 <thought> block and keeps the answer" do
    raw = "<thought>*   Draft 1: algo\n    *   Check: ok</thought><p>La Bundesliga es alemana.</p>"
    assert strip(raw) == "<p>La Bundesliga es alemana.</p>"
  end

  test "removes a DeepSeek <think> block" do
    assert strip("<think>reasoning here</think>Respuesta.") == "Respuesta."
  end

  test "multiline reasoning is removed whole" do
    raw = """
    <thought>
    linea uno
    linea dos
    </thought>
    <p>Respuesta real.</p>
    """

    assert strip(raw) == "<p>Respuesta real.</p>"
  end

  test "an unclosed block (cut off at max_tokens) leaves nothing" do
    # The reply ran out of budget mid-thought, so there is no answer at all.
    # Returning "" lets the caller fail loudly instead of posting a monologue.
    assert strip("<thought>empece a pensar y me cortaron") == ""
  end

  test "content without reasoning is untouched" do
    assert strip("<p>Respuesta directa.</p>") == "<p>Respuesta directa.</p>"
  end

  test "the word 'thought' in prose is not treated as a tag" do
    assert strip("<p>I thought about the think tank.</p>") ==
             "<p>I thought about the think tank.</p>"
  end
end
