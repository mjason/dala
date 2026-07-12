defmodule Dala.ProjectConfig do
  @moduledoc """
  Read and patch the per-project `dala.jsonc` for non-LSP settings —
  currently the speech `"hotwords"` (the Whisper vocabulary prompt).

  Writes are TEXT-level patches, not decode/re-encode, so hand-written
  comments and formatting in an existing config survive. The patched body
  is re-parsed before it touches disk; a patch that would corrupt the file
  is refused.
  """

  alias Dala.Lsp.Discovery

  @hotwords_re ~r/("hotwords"\s*:\s*)"(?:[^"\\]|\\.)*"/
  @speech_open_re ~r/("speech"\s*:\s*\{)/

  @doc """
  The effective hotwords for a directory: the nearest `dala.jsonc` walking
  up (stopping at the git toplevel or `$HOME`) wins. Returns the file that
  holds — or would hold — them, so the UI can show where edits land.
  """
  def speech_hotwords(dir) do
    case config_file(dir) do
      nil ->
        %{path: Path.join(dir, "dala.jsonc"), exists: false, hotwords: ""}

      path ->
        hotwords =
          with {:ok, body} <- File.read(path),
               {:ok, %{"speech" => %{"hotwords" => words}}} when is_binary(words) <-
                 Jason.decode(Discovery.strip_jsonc(body)) do
            words
          else
            _ -> ""
          end

        %{path: path, exists: true, hotwords: hotwords}
    end
  end

  @doc """
  Write hotwords into the nearest `dala.jsonc`, or create one in `dir`
  when none exists on the way up.
  """
  def put_speech_hotwords(dir, hotwords) when is_binary(hotwords) do
    path = config_file(dir) || Path.join(dir, "dala.jsonc")
    encoded = Jason.encode!(hotwords)

    body =
      case File.read(path) do
        {:ok, existing} -> patch(existing, encoded)
        {:error, _} -> new_config(encoded)
      end

    case Jason.decode(Discovery.strip_jsonc(body)) do
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
      # A speech block with a hotwords key: swap the value in place. Scope
      # the match to AFTER the "speech" key so an unrelated hotwords string
      # earlier in the file can't be clobbered.
      speech_hotwords_present?(body) ->
        [before, rest] = String.split(body, "\"speech\"", parts: 2)

        patched =
          Regex.replace(@hotwords_re, rest, fn _, pre -> pre <> encoded end, global: false)

        before <> "\"speech\"" <> patched

      # A speech block without hotwords: prepend the key right after its
      # opening brace (a trailing comma before `}` is fine — we parse JSONC).
      Regex.match?(@speech_open_re, body) ->
        Regex.replace(
          @speech_open_re,
          body,
          fn _, pre -> pre <> "\n    \"hotwords\": " <> encoded <> "," end,
          global: false
        )

      # No speech block: open one right after the config's first brace.
      String.contains?(body, "{") ->
        Regex.replace(
          ~r/\{/,
          body,
          fn _ -> "{\n  \"speech\": {\n    \"hotwords\": " <> encoded <> "\n  }," end,
          global: false
        )

      # Empty or unsalvageable file: start over.
      true ->
        new_config(encoded)
    end
  end

  defp speech_hotwords_present?(body) do
    case String.split(body, "\"speech\"", parts: 2) do
      [_before, rest] -> Regex.match?(@hotwords_re, rest)
      _ -> false
    end
  end

  defp new_config(encoded) do
    """
    {
      // dala project config — see the README's dala.jsonc section
      "speech": {
        // Whisper hotwords: comma-separated jargon (library names, project
        // terms) that biases voice transcription toward these spellings
        "hotwords": #{encoded}
      }
    }
    """
  end

  defp config_file(dir) do
    top = Discovery.git_toplevel(dir)
    home = System.user_home()

    Stream.iterate(dir, &Path.dirname/1)
    |> Enum.reduce_while(nil, fn current, _acc ->
      path = Path.join(current, "dala.jsonc")

      cond do
        File.regular?(path) -> {:halt, path}
        current == top or current == home or Path.dirname(current) == current -> {:halt, nil}
        true -> {:cont, nil}
      end
    end)
  end
end
