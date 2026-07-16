defmodule DalaWeb.FileDownloadToken do
  @moduledoc """
  Short-lived, PATH-SCOPED bearer for `GET /files/raw`.

  The MCP `get_download_url` tool mints one of these so an agent (or a human it
  hands the link to) can download exactly one file over plain HTTP without the
  app session cookie. `Phoenix.Token` signs the ABSOLUTE path with the
  endpoint's `secret_key_base`, so a token cannot be forged and only unlocks the
  single file it names — never a directory, never another path, never a write.
  It expires after `max_age/0` seconds.
  """

  @salt "file download v1"
  @max_age 3_600

  @doc "Seconds a freshly signed token stays valid."
  def max_age, do: @max_age

  @doc "Sign a token that authorizes downloading exactly `abs_path`."
  def sign(abs_path) when is_binary(abs_path) do
    Phoenix.Token.sign(DalaWeb.Endpoint, @salt, abs_path)
  end

  @doc """
  True when `token` is a valid, unexpired signature for `abs_path` exactly.
  A signature for any other path (or a tampered/expired token) is false.
  """
  def valid_for?(token, abs_path) when is_binary(token) and is_binary(abs_path) do
    case Phoenix.Token.verify(DalaWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, signed} -> signed == abs_path
      {:error, _reason} -> false
    end
  end

  def valid_for?(_token, _abs_path), do: false
end
