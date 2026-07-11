defmodule Dala.Terminal.Speech do
  @moduledoc """
  Speech-to-text via an OpenAI-compatible transcription endpoint (vLLM's
  Whisper serving, LocalAI, faster-whisper-server, or OpenAI itself). The
  browser records, the server forwards — the endpoint usually lives on
  localhost where the page can't reach it directly (CORS, mixed content).
  """

  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Terminal,
    extensions: [AshTypescript.Resource]

  # Whisper-class models cap around 25 MB uploads; a minute of 16 kHz mono
  # WAV is ~2 MB, so this is generous.
  @audio_max_bytes 25 * 1024 * 1024

  typescript do
    type_name "Speech"
  end

  actions do
    action :transcribe, :map do
      description """
      Forward recorded audio to the configured OpenAI-compatible
      `/audio/transcriptions` endpoint and return the transcript.
      """

      constraints fields: [
                    text: [type: :string],
                    error: [type: :string]
                  ]

      # Base URL like "http://127.0.0.1:8000/v1" (or the full
      # /audio/transcriptions URL — both accepted).
      argument :endpoint, :string, allow_nil?: false
      argument :model, :string, allow_nil?: false
      argument :api_key, :string

      argument :audio_base64, :string do
        allow_nil? false
        constraints trim?: false
      end

      run fn input, _context ->
        with {:ok, audio} <- Base.decode64(input.arguments.audio_base64),
             :ok <- check_size(audio),
             {:ok, url} <- transcription_url(input.arguments.endpoint) do
          request(url, input.arguments.model, Map.get(input.arguments, :api_key), audio)
        else
          :error -> {:ok, %{text: nil, error: "invalid base64 audio"}}
          {:error, message} -> {:ok, %{text: nil, error: message}}
        end
      end
    end
  end

  defp check_size(audio) when byte_size(audio) > @audio_max_bytes,
    do: {:error, "audio too large (max #{div(@audio_max_bytes, 1024 * 1024)} MB)"}

  defp check_size(_audio), do: :ok

  defp transcription_url(endpoint) do
    endpoint = String.trim_trailing(String.trim(endpoint), "/")

    url =
      if String.ends_with?(endpoint, "/audio/transcriptions") do
        endpoint
      else
        endpoint <> "/audio/transcriptions"
      end

    case URI.new(url) do
      {:ok, %URI{scheme: scheme}} when scheme in ["http", "https"] -> {:ok, url}
      _ -> {:error, "endpoint must be an http(s) URL"}
    end
  end

  defp request(url, model, api_key, audio) do
    headers =
      case api_key do
        key when is_binary(key) and key != "" -> [{"authorization", "Bearer #{key}"}]
        _ -> []
      end

    result =
      Req.post(url,
        headers: headers,
        form_multipart: [
          model: model,
          response_format: "json",
          file: {audio, filename: "audio.wav", content_type: "audio/wav"}
        ],
        connect_options: [timeout: 10_000],
        receive_timeout: 120_000,
        retry: false
      )

    case result do
      {:ok, %Req.Response{status: 200, body: %{"text" => text}}} when is_binary(text) ->
        {:ok, %{text: String.trim(text), error: nil}}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok,
         %{text: nil, error: "unexpected response: #{inspect(body) |> String.slice(0, 200)}"}}

      {:ok, %Req.Response{status: status, body: body}} ->
        detail =
          case body do
            %{"error" => %{"message" => message}} -> message
            %{"message" => message} when is_binary(message) -> message
            other -> other |> inspect() |> String.slice(0, 200)
          end

        {:ok, %{text: nil, error: "HTTP #{status}: #{detail}"}}

      {:error, exception} ->
        {:ok, %{text: nil, error: Exception.message(exception)}}
    end
  end
end
