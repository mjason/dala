defmodule Dala.Settings.PromptOptimizerTest do
  use Dala.DataCase, async: false

  alias Dala.Settings.PromptOptimizer

  defp current(actor \\ nil) do
    PromptOptimizer
    |> Ash.ActionInput.for_action(:current, %{}, actor: actor)
    |> Ash.run_action!()
  end

  defp save(args, actor \\ nil) do
    PromptOptimizer
    |> Ash.ActionInput.for_action(:save, args, actor: actor)
    |> Ash.run_action!()
  end

  defp optimize(text, actor \\ nil) do
    PromptOptimizer
    |> Ash.ActionInput.for_action(:optimize, %{text: text}, actor: actor)
    |> Ash.run_action!()
  end

  defp user(email) do
    Dala.Accounts.User
    |> Ash.Changeset.for_create(:seed_user, %{email: email, password: "password1234"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  describe "settings" do
    test "returns useful DeepSeek defaults without exposing an API key" do
      assert current() == %{
               endpoint: "https://api.deepseek.com",
               model: "deepseek-v4-flash",
               prompt: PromptOptimizer.default_prompt(),
               api_key_set: false
             }

      refute Map.has_key?(current(), :api_key)
    end

    test "round-trips editable settings while keeping the key private" do
      result =
        save(%{
          endpoint: "https://example.test/v1",
          model: "custom-model",
          prompt: "Correct mistakes only.",
          api_key: "sk-secret"
        })

      assert result == %{
               endpoint: "https://example.test/v1",
               model: "custom-model",
               prompt: "Correct mistakes only.",
               api_key_set: true
             }

      assert PromptOptimizer.config(nil).api_key == "sk-secret"
      refute inspect(result) =~ "sk-secret"
    end

    test "an empty key preserves the stored key and clear_api_key removes it" do
      save(%{api_key: "sk-keep"})
      save(%{prompt: "A newer prompt", api_key: ""})

      assert PromptOptimizer.config(nil).api_key == "sk-keep"
      assert save(%{clear_api_key: true}).api_key_set == false
      assert PromptOptimizer.config(nil).api_key == nil
    end

    test "keeps each user's settings isolated from the global row" do
      alice = user("prompt-alice@example.com")
      bob = user("prompt-bob@example.com")

      save(%{prompt: "Global", api_key: "sk-global"})
      save(%{prompt: "Alice", api_key: "sk-alice"}, alice)

      assert current().prompt == "Global"
      assert current(alice).prompt == "Alice"
      assert current(bob).prompt == PromptOptimizer.default_prompt()
      assert PromptOptimizer.config(bob).api_key == nil
    end
  end

  describe "chat completion URL" do
    test "accepts a DeepSeek base URL, a v1 base, or a complete endpoint" do
      assert PromptOptimizer.chat_completions_url("https://api.deepseek.com") ==
               {:ok, "https://api.deepseek.com/chat/completions"}

      assert PromptOptimizer.chat_completions_url("https://host.test/v1/") ==
               {:ok, "https://host.test/v1/chat/completions"}

      assert PromptOptimizer.chat_completions_url("https://host.test/chat/completions") ==
               {:ok, "https://host.test/chat/completions"}
    end

    test "rejects non-http endpoints" do
      assert PromptOptimizer.chat_completions_url("file:///etc/passwd") ==
               {:error, "endpoint must be an http(s) URL"}
    end
  end

  describe "optimize" do
    setup do
      previous = Application.get_env(:dala, PromptOptimizer)
      Application.put_env(:dala, PromptOptimizer, plug: {Req.Test, PromptOptimizer})

      on_exit(fn ->
        if previous do
          Application.put_env(:dala, PromptOptimizer, previous)
        else
          Application.delete_env(:dala, PromptOptimizer)
        end
      end)

      :ok
    end

    test "requires a configured API key" do
      assert optimize("messy draft") == %{
               text: nil,
               error: "prompt_optimizer_not_configured"
             }
    end

    test "sends the configured system prompt and returns only rewritten text" do
      save(%{
        endpoint: "https://api.deepseek.com/v1",
        model: "deepseek-chat",
        prompt: "Fix the draft.",
        api_key: "sk-test"
      })

      Req.Test.stub(PromptOptimizer, fn conn ->
        assert conn.request_path == "/v1/chat/completions"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-test"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload["model"] == "deepseek-chat"

        assert payload["messages"] == [
                 %{"role" => "system", "content" => "Fix the draft."},
                 %{"role" => "user", "content" => "fix teh bug"}
               ]

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "Fix the bug."}}]
        })
      end)

      assert optimize("fix teh bug") == %{text: "Fix the bug.", error: nil}
    end

    test "returns provider errors without leaking the API key" do
      save(%{api_key: "sk-never-show", prompt: "Fix it."})

      Req.Test.stub(PromptOptimizer, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"message" => "invalid credentials"}})
      end)

      result = optimize("draft")
      assert result == %{text: nil, error: "HTTP 401: invalid credentials"}
      refute inspect(result) =~ "sk-never-show"
    end
  end
end
