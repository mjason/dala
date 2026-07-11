defmodule Dala.Terminal.SpeechTest do
  use ExUnit.Case, async: true

  defp run_transcribe(args) do
    Dala.Terminal.Speech
    |> Ash.ActionInput.for_action(:transcribe, args)
    |> Ash.run_action!()
  end

  defp fake_server(response_fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 10_000)
        request = read_request(socket, "")
        body = response_fun.(request)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
            body
        )

        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        request
      end)

    {port, task}
  end

  defp read_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} ->
        acc = acc <> chunk

        # Read until the multipart terminator arrives (all Req uploads here
        # are small enough for this naive accumulation).
        if String.contains?(acc, "--\r\n") or String.length(acc) > 1_000_000 do
          acc
        else
          read_request(socket, acc)
        end

      _ ->
        acc
    end
  end

  test "posts multipart audio and returns the transcript" do
    {port, task} = fake_server(fn _request -> ~s({"text": " 你好，世界 "}) end)

    result =
      run_transcribe(%{
        endpoint: "http://127.0.0.1:#{port}/v1",
        model: "whisper-large-v3",
        audio_base64: Base.encode64("RIFF-fake-wav-bytes")
      })

    assert result == %{text: "你好，世界", error: nil}

    request = Task.await(task)
    assert request =~ "POST /v1/audio/transcriptions"
    assert request =~ "whisper-large-v3"
    assert request =~ "RIFF-fake-wav-bytes"
    refute request =~ "authorization"
  end

  test "api key becomes a bearer header" do
    {port, task} = fake_server(fn _request -> ~s({"text": "ok"}) end)

    run_transcribe(%{
      endpoint: "http://127.0.0.1:#{port}/v1/audio/transcriptions",
      model: "m",
      api_key: "sk-secret",
      audio_base64: Base.encode64("x")
    })

    request = Task.await(task)
    # full /audio/transcriptions endpoints are used as-is (not doubled)
    assert request =~ "POST /v1/audio/transcriptions HTTP"
    assert request =~ "authorization: Bearer sk-secret"
  end

  test "server errors surface as error, not text" do
    {port, _task} = fake_server(fn _request -> "not json at all" end)

    result =
      run_transcribe(%{
        endpoint: "http://127.0.0.1:#{port}",
        model: "m",
        audio_base64: Base.encode64("x")
      })

    assert result.text == nil
    assert is_binary(result.error) and result.error != ""
  end

  test "bad endpoint and bad base64 are friendly errors" do
    assert %{error: "endpoint must be an http(s) URL"} =
             run_transcribe(%{endpoint: "ftp://x", model: "m", audio_base64: Base.encode64("x")})

    assert %{error: "invalid base64 audio"} =
             run_transcribe(%{endpoint: "http://127.0.0.1:9/v1", model: "m", audio_base64: "!!"})
  end
end
