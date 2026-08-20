defmodule Dala.Updater.Status do
  @moduledoc false

  @states ~w(queued applying succeeded rolled_back failed)

  def read(nil), do: nil

  def read(root) when is_binary(root) do
    with {:ok, body} <- File.read(path(root)),
         {:ok, %{} = raw} <- Jason.decode(body),
         state when state in @states <- raw["state"],
         true <- optional_string?(raw["message"]),
         true <- optional_string?(raw["version"]),
         true <- optional_string?(raw["updatedAt"]) do
      %{
        state: state,
        message: raw["message"],
        version: raw["version"],
        updated_at: raw["updatedAt"]
      }
    else
      _ -> nil
    end
  end

  def write(root, state, message, version)
      when is_binary(root) and state in @states and is_binary(message) and is_binary(version) do
    payload = %{
      state: state,
      message: message,
      version: version,
      updatedAt: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- File.mkdir_p(root),
         :ok <- File.write(path(root), Jason.encode!(payload) <> "\r\n") do
      :ok
    end
  end

  def path(root), do: Path.join(root, "update-status.json")

  def states, do: @states

  defp optional_string?(value), do: is_nil(value) or is_binary(value)
end
