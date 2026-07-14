defmodule Dala.Terminal.SpeechTest do
  # Transcription reads its endpoint/model/api key from the server-side
  # settings row (Dala.Settings.Speech) — never from the client.
  use Dala.DataCase, async: false

  defp configure(attrs, actor \\ nil) do
    Dala.Settings.Speech
    |> Ash.ActionInput.for_action(:save, attrs, actor: actor)
    |> Ash.run_action!()
  end

  defp run_transcribe(args, actor \\ nil) do
    Dala.Terminal.Speech
    |> Ash.ActionInput.for_action(:transcribe, args, actor: actor)
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
    configure(%{endpoint: "http://127.0.0.1:#{port}/v1", model: "whisper-large-v3"})

    result = run_transcribe(%{audio_base64: Base.encode64("RIFF-fake-wav-bytes")})

    assert result == %{text: "你好，世界", error: nil}

    request = Task.await(task)
    assert request =~ "POST /v1/audio/transcriptions"
    assert request =~ "whisper-large-v3"
    assert request =~ "RIFF-fake-wav-bytes"
    refute request =~ "authorization"
  end

  test "SSRF regression: a client-supplied endpoint/model/api_key is refused, not honoured" do
    args =
      Enum.map(Ash.Resource.Info.action(Dala.Terminal.Speech, :transcribe).arguments, & &1.name)

    refute :endpoint in args
    refute :model in args
    refute :api_key in args

    {port, task} = fake_server(fn _request -> ~s({"text": "ok"}) end)
    configure(%{endpoint: "http://127.0.0.1:#{port}/v1", model: "m"})

    # Naming an endpoint is rejected outright — the server never POSTs
    # anywhere a client asked it to.
    assert_raise Ash.Error.Invalid, fn ->
      run_transcribe(%{
        endpoint: "http://169.254.169.254/latest/meta-data",
        model: "m",
        api_key: "sk-attacker",
        audio_base64: Base.encode64("x")
      })
    end

    # The configured endpoint still works (and is the ONLY one used).
    assert run_transcribe(%{audio_base64: Base.encode64("x")}) == %{text: "ok", error: nil}
    refute Task.await(task) =~ "169.254.169.254"
  end

  test "with nothing configured, a friendly error comes back instead of a request" do
    result = run_transcribe(%{audio_base64: Base.encode64("x")})

    assert result.text == nil
    assert result.error == Dala.Terminal.Speech.not_configured_error()
  end

  test "each user transcribes against their own configured endpoint" do
    alice =
      Dala.Accounts.User
      |> Ash.Changeset.for_create(
        :seed_user,
        %{email: "speech-alice@example.com", password: "password1234"},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    {port, task} = fake_server(fn _request -> ~s({"text": "alice"}) end)

    # The global row points somewhere else entirely; alice's row wins for alice.
    configure(%{endpoint: "http://127.0.0.1:9/v1", model: "global-m"})
    configure(%{endpoint: "http://127.0.0.1:#{port}/v1", model: "alice-m"}, alice)

    assert run_transcribe(%{audio_base64: Base.encode64("x")}, alice) ==
             %{text: "alice", error: nil}

    assert Task.await(task) =~ "alice-m"
  end

  test "an explicit prompt rides along in the multipart form" do
    {port, task} = fake_server(fn _request -> ~s({"text": "ok"}) end)
    configure(%{endpoint: "http://127.0.0.1:#{port}/v1", model: "m"})

    run_transcribe(%{
      prompt: "dala, zellij, Elixir, Phoenix LiveView, opencode",
      audio_base64: Base.encode64("x")
    })

    request = Task.await(task)
    assert request =~ ~s(name="prompt")
    assert request =~ "Phoenix LiveView"
  end

  test "empty prompt is omitted entirely" do
    {port, task} = fake_server(fn _request -> ~s({"text": "ok"}) end)
    configure(%{endpoint: "http://127.0.0.1:#{port}/v1", model: "m"})

    run_transcribe(%{prompt: "", audio_base64: Base.encode64("x")})

    request = Task.await(task)
    refute request =~ ~s(name="prompt")
  end

  test "without an explicit prompt, the project's dala.jsonc prompt is used via cwd" do
    dir = Path.join(System.tmp_dir!(), "dala-speech-cwd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(
      Path.join(dir, "dala.jsonc"),
      ~s({ "speech": { "prompt": "This talk covers basedpyright." } })
    )

    {port, task} = fake_server(fn _request -> ~s({"text": "ok"}) end)
    configure(%{endpoint: "http://127.0.0.1:#{port}/v1", model: "m"})

    run_transcribe(%{cwd: dir, audio_base64: Base.encode64("x")})

    request = Task.await(task)
    assert request =~ ~s(name="prompt")
    assert request =~ "This talk covers basedpyright."
  end

  test "cwd without any dala.jsonc sends no prompt at all" do
    dir = Path.join(System.tmp_dir!(), "dala-speech-none-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {port, task} = fake_server(fn _request -> ~s({"text": "ok"}) end)
    configure(%{endpoint: "http://127.0.0.1:#{port}/v1", model: "m"})

    run_transcribe(%{cwd: dir, audio_base64: Base.encode64("x")})

    refute Task.await(task) =~ ~s(name="prompt")
  end

  test "the stored api key becomes a bearer header" do
    {port, task} = fake_server(fn _request -> ~s({"text": "ok"}) end)

    configure(%{
      endpoint: "http://127.0.0.1:#{port}/v1/audio/transcriptions",
      model: "m",
      api_key: "sk-secret"
    })

    run_transcribe(%{audio_base64: Base.encode64("x")})

    request = Task.await(task)
    # full /audio/transcriptions endpoints are used as-is (not doubled)
    assert request =~ "POST /v1/audio/transcriptions HTTP"
    assert request =~ "authorization: Bearer sk-secret"
  end

  test "server errors surface as error, not text" do
    {port, _task} = fake_server(fn _request -> "not json at all" end)
    configure(%{endpoint: "http://127.0.0.1:#{port}", model: "m"})

    result = run_transcribe(%{audio_base64: Base.encode64("x")})

    assert result.text == nil
    assert is_binary(result.error) and result.error != ""
  end

  test "bad endpoint and bad base64 are friendly errors" do
    configure(%{endpoint: "ftp://x", model: "m"})

    assert %{error: "endpoint must be an http(s) URL"} =
             run_transcribe(%{audio_base64: Base.encode64("x")})

    configure(%{endpoint: "http://127.0.0.1:9/v1", model: "m"})
    assert %{error: "invalid base64 audio"} = run_transcribe(%{audio_base64: "!!"})
  end
end
