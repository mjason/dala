defmodule Dala.Settings.PromptOptimizer do
  @moduledoc """
  Per-user configuration for rewriting composer drafts with a DeepSeek or
  OpenAI-compatible chat-completions endpoint.

  The API key stays on the server. Client-facing reads expose only whether a
  key is configured, while `optimize` performs the outbound request using the
  row belonging to the current actor.
  """

  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Settings,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  require Ash.Query

  @global_id "00000000-0000-0000-0000-000000000000"
  @default_endpoint "https://api.deepseek.com"
  @default_model "deepseek-v4-flash"
  @default_prompt """
                  Rewrite the user's draft into a clear, precise prompt for an AI assistant. Correct typos, speech-recognition mistakes, grammar, and disordered logic while preserving the user's intent, requirements, technical terms, file paths, code, and Markdown. Do not answer the prompt or add new requirements. Return only the rewritten prompt, in the same language as the draft. If it is already clear, return it unchanged.
                  """
                  |> String.trim()
  @summary_fields [
    endpoint: [type: :string],
    model: [type: :string],
    prompt: [type: :string],
    api_key_set: [type: :boolean]
  ]

  sqlite do
    table "prompt_optimizer_settings"
    repo Dala.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  typescript do
    type_name "PromptOptimizerSettings"
  end

  actions do
    # Internal persistence actions. Only the actor-scoped generic actions
    # below may be exposed over RPC.
    defaults [:read]

    create :upsert do
      accept [:id, :user_id, :endpoint, :model, :prompt]
      upsert? true

      argument :api_key, :string, sensitive?: true
      change set_attribute(:api_key, arg(:api_key))
    end

    update :put do
      accept [:endpoint, :model, :prompt]
      argument :api_key, :string, sensitive?: true
      change set_attribute(:api_key, arg(:api_key))
    end

    action :current, :map do
      description "The caller's prompt optimizer settings. Never returns the API key."

      constraints fields: @summary_fields

      run fn _input, context -> {:ok, summary(context.actor)} end
    end

    action :save, :map do
      description """
      Store the caller's prompt optimizer settings. An omitted or empty API
      key leaves the stored key untouched; `clear_api_key: true` wipes it.
      """

      argument :endpoint, :string, constraints: [allow_empty?: true]
      argument :model, :string, constraints: [allow_empty?: true]

      argument :prompt, :string,
        constraints: [allow_empty?: true, trim?: false, max_length: 20_000]

      argument :api_key, :string, sensitive?: true
      argument :clear_api_key, :boolean, default: false

      constraints fields: @summary_fields

      run fn input, context -> save(context.actor, input.arguments) end
    end

    action :optimize, :map do
      description "Rewrite a composer draft using the caller's configured prompt optimizer."

      argument :text, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: false, max_length: 50_000]

      constraints fields: [
                    text: [type: :string, allow_nil?: true],
                    error: [type: :string, allow_nil?: true]
                  ]

      run fn input, context -> optimize(context.actor, input.arguments.text) end
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true, public?: true

    attribute :endpoint, :string do
      public? true
      allow_nil? false
      default @default_endpoint
      constraints allow_empty?: true
    end

    attribute :model, :string do
      public? true
      allow_nil? false
      default @default_model
      constraints allow_empty?: true
    end

    attribute :prompt, :string do
      public? true
      allow_nil? false
      default @default_prompt
      constraints allow_empty?: true, trim?: false, max_length: 20_000
    end

    attribute :api_key, :string do
      public? false
      sensitive? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Dala.Accounts.User do
      public? true
      allow_nil? true
      attribute_writable? true
    end
  end

  @doc "The default system prompt shown before a row has been saved."
  def default_prompt, do: @default_prompt

  @doc "The complete actor-scoped configuration for server-side callers."
  def config(actor) do
    case row(actor) do
      nil ->
        default_config()

      row ->
        %{
          endpoint: row.endpoint || @default_endpoint,
          model: row.model || @default_model,
          prompt: row.prompt || @default_prompt,
          api_key: row.api_key
        }
    end
  end

  @doc "The configuration safe to return to a browser."
  def summary(actor) do
    config = config(actor)

    %{
      endpoint: config.endpoint,
      model: config.model,
      prompt: config.prompt,
      api_key_set: present?(config.api_key)
    }
  end

  @doc "Upsert the configuration belonging to `actor`."
  def save(actor, args) do
    row = row(actor)
    defaults = default_config()

    attrs = %{
      endpoint: pick(Map.get(args, :endpoint), row && row.endpoint, defaults.endpoint),
      model: pick(Map.get(args, :model), row && row.model, defaults.model),
      prompt: pick(Map.get(args, :prompt), row && row.prompt, defaults.prompt),
      api_key: api_key(args, row)
    }

    result =
      case row do
        nil ->
          attrs = Map.merge(attrs, %{id: owner_id(actor), user_id: actor_id(actor)})
          Ash.create(__MODULE__, attrs, action: :upsert, authorize?: false)

        row ->
          Ash.update(row, attrs, action: :put, authorize?: false)
      end

    with {:ok, _saved} <- result, do: {:ok, summary(actor)}
  end

  @doc "Run a chat-completions rewrite with the configuration belonging to `actor`."
  def optimize(actor, text) when is_binary(text) do
    config = config(actor)

    with :ok <- configured(config),
         {:ok, url} <- chat_completions_url(config.endpoint) do
      request(url, config, text)
    else
      {:error, message} -> {:ok, %{text: nil, error: message}}
    end
  end

  @doc false
  def chat_completions_url(endpoint) when is_binary(endpoint) do
    endpoint = endpoint |> String.trim() |> String.trim_trailing("/")

    url =
      if String.ends_with?(endpoint, "/chat/completions") do
        endpoint
      else
        endpoint <> "/chat/completions"
      end

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, url}

      _ ->
        {:error, "endpoint must be an http(s) URL"}
    end
  end

  def chat_completions_url(_endpoint), do: {:error, "endpoint must be an http(s) URL"}

  defp request(url, config, text) do
    options =
      [
        headers: [{"authorization", "Bearer #{config.api_key}"}],
        json: %{
          "model" => config.model,
          "messages" => [
            %{"role" => "system", "content" => config.prompt},
            %{"role" => "user", "content" => text}
          ],
          "stream" => false,
          "temperature" => 0.2
        },
        connect_options: [timeout: 10_000],
        receive_timeout: 120_000,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:dala, __MODULE__, []))

    result =
      Req.post(url, options)

    case result do
      {:ok,
       %Req.Response{
         status: status,
         body: %{"choices" => [%{"message" => %{"content" => content}} | _]}
       }}
      when status in 200..299 and is_binary(content) ->
        {:ok, %{text: String.trim(content), error: nil}}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, %{text: nil, error: "unexpected response: #{preview(body)}"}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{text: nil, error: "HTTP #{status}: #{error_detail(body)}"}}

      {:error, exception} ->
        {:ok, %{text: nil, error: Exception.message(exception)}}
    end
  end

  defp error_detail(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_detail(%{"message" => message}) when is_binary(message), do: message
  defp error_detail(body), do: preview(body)

  defp preview(body), do: body |> inspect() |> String.slice(0, 300)

  defp configured(%{endpoint: endpoint, model: model, api_key: key}) do
    cond do
      not present?(endpoint) -> {:error, "prompt_optimizer_not_configured"}
      not present?(model) -> {:error, "prompt_optimizer_not_configured"}
      not present?(key) -> {:error, "prompt_optimizer_not_configured"}
      true -> :ok
    end
  end

  defp default_config do
    %{endpoint: @default_endpoint, model: @default_model, prompt: @default_prompt, api_key: nil}
  end

  defp api_key(args, row) do
    stored = row && row.api_key

    cond do
      Map.get(args, :clear_api_key) == true -> nil
      present?(Map.get(args, :api_key)) -> args.api_key
      true -> stored
    end
  end

  defp pick(new, stored, fallback)
  defp pick(new, _stored, _fallback) when is_binary(new), do: new
  defp pick(_new, stored, _fallback) when is_binary(stored), do: stored
  defp pick(_new, _stored, fallback), do: fallback

  defp row(actor) do
    __MODULE__
    |> Ash.Query.filter(id == ^owner_id(actor))
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp owner_id(actor), do: actor_id(actor) || @global_id
  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_actor), do: nil
end
