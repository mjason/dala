defmodule Dala.ProjectConfig do
  @moduledoc """
  Read and patch the per-project `dala.jsonc` for non-LSP settings —
  currently the speech `"prompt"` — the Whisper transcription prompt, fed
  to the decoder as if it were the preceding transcript, so the model
  mimics its spelling, punctuation and script style.

  Writes are TEXT-level patches, not decode/re-encode, so hand-written
  comments and formatting in an existing config survive. The patched body
  is re-parsed before it touches disk; a patch that would corrupt the file
  is refused.
  """

  @prompt_re ~r/("prompt"\s*:\s*)"(?:[^"\\]|\\.)*"/
  @speech_open_re ~r/("speech"\s*:\s*\{)/

  @doc """
  The effective transcription prompt for a directory: the nearest
  `dala.jsonc` walking up (stopping at the git toplevel or `$HOME`) wins.
  Returns the file that holds — or would hold — it, so the UI can show
  where edits land.
  """
  def speech_prompt(dir) do
    case config_file(dir) do
      nil ->
        %{path: Path.join(dir, "dala.jsonc"), exists: false, prompt: ""}

      path ->
        prompt =
          with {:ok, body} <- File.read(path),
               {:ok, %{"speech" => %{"prompt" => text}}} when is_binary(text) <-
                 Jason.decode(Dala.Jsonc.strip(body)) do
            text
          else
            _ -> ""
          end

        %{path: path, exists: true, prompt: prompt}
    end
  end

  @doc """
  Write the transcription prompt into the nearest `dala.jsonc`, or create
  one in `dir` when none exists on the way up.
  """
  def put_speech_prompt(dir, prompt) when is_binary(prompt) do
    path = config_file(dir) || Path.join(dir, "dala.jsonc")
    encoded = Jason.encode!(prompt)

    body =
      case File.read(path) do
        {:ok, existing} -> patch(existing, encoded)
        {:error, _} -> new_config(encoded)
      end

    case Jason.decode(Dala.Jsonc.strip(body)) do
      {:ok, %{}} ->
        case File.write(path, body) do
          :ok -> {:ok, path}
          {:error, reason} -> {:error, "cannot write #{path}: #{reason}"}
        end

      _ ->
        {:error, "refusing to write #{path}: the patched config would not parse"}
    end
  end

  defp patch(body, encoded) do
    cond do
      # A speech block with a prompt key: swap the value in place. Scope
      # the match to AFTER the "speech" key so an unrelated prompt string
      # earlier in the file can't be clobbered.
      speech_prompt_present?(body) ->
        [before, rest] = String.split(body, "\"speech\"", parts: 2)

        patched =
          Regex.replace(@prompt_re, rest, fn _, pre -> pre <> encoded end, global: false)

        before <> "\"speech\"" <> patched

      # A speech block without a prompt: prepend the key right after its
      # opening brace (a trailing comma before `}` is fine — we parse JSONC).
      Regex.match?(@speech_open_re, body) ->
        Regex.replace(
          @speech_open_re,
          body,
          fn _, pre -> pre <> "\n    \"prompt\": " <> encoded <> "," end,
          global: false
        )

      # No speech block: open one right after the config's first brace.
      String.contains?(body, "{") ->
        Regex.replace(
          ~r/\{/,
          body,
          fn _ -> "{\n  \"speech\": {\n    \"prompt\": " <> encoded <> "\n  }," end,
          global: false
        )

      # Empty or unsalvageable file: start over.
      true ->
        new_config(encoded)
    end
  end

  defp speech_prompt_present?(body) do
    case String.split(body, "\"speech\"", parts: 2) do
      [_before, rest] -> Regex.match?(@prompt_re, rest)
      _ -> false
    end
  end

  defp new_config(encoded) do
    """
    {
      // dala project config — see the README's dala.jsonc section
      "speech": {
        // Whisper transcription prompt: written as if it were the PRECEDING
        // transcript — a natural sentence (same language you speak) with your
        // jargon embedded. The model mimics its spelling and punctuation.
        // Only the last ~224 tokens are used.
        "prompt": #{encoded}
      }
    }
    """
  end

  defp config_file(dir) do
    Dala.Paths.walk_up(dir, fn current ->
      path = Path.join(current, "dala.jsonc")
      if File.regular?(path), do: path
    end)
  end
end
