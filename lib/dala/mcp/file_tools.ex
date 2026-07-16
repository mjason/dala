defmodule Dala.Mcp.FileTools do
  @moduledoc """
  MCP file tools. Currently one: `get_download_url`, which hands an agent a
  short-lived, path-scoped HTTP link (see `DalaWeb.FileDownloadToken`) so it can
  download one server file over plain HTTP without the app session cookie.

  Gated by the SAME `read` permission as terminal read: both are "read the
  machine's data" capabilities, off by default, flipped on together in the
  Settings panel. `call/3` re-checks the flag so a stale `tools/list` can never
  be used to bypass it.
  """

  @tools ~w(get_download_url)

  def tool_names, do: @tools

  def instructions(%{read: true}) do
    "For file bytes, call get_download_url with an absolute path to get a " <>
      "short-lived tokenized HTTP download link (works without the app login)."
  end

  def instructions(_access), do: ""

  def tools(%{read: true}), do: [download_url_tool()]
  def tools(_access), do: []

  @doc """
  Run a file tool. `ctx` may carry `:base_url` (the origin the MCP request came
  in on) so the returned URL is absolute; it falls back to the endpoint's own
  configured URL.
  """
  def call(name, arguments, ctx) when name in @tools do
    if Dala.Settings.Mcp.terminal_access().read do
      execute(name, normalize(arguments), ctx)
    else
      {:error, "MCP file access is disabled in dala Settings (enable read access)"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def call(_name, _arguments, _ctx), do: {:error, :unknown_tool}

  defp execute("get_download_url", %{"path" => path}, ctx) when is_binary(path) do
    abs = Dala.Paths.expand_user(path)

    case File.stat(abs) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        token = DalaWeb.FileDownloadToken.sign(abs)

        query =
          URI.encode_query(%{"path" => abs, "download" => "1", "token" => token})

        {:ok,
         %{
           url: absolute(ctx, "/files/raw?" <> query),
           path: abs,
           filename: Path.basename(abs),
           bytes: size,
           contentType: MIME.from_path(abs),
           expiresInSeconds: DalaWeb.FileDownloadToken.max_age()
         }}

      {:ok, _stat} ->
        {:error, "not a regular file: #{abs}"}

      {:error, reason} ->
        {:error, "cannot read #{abs}: #{:file.format_error(reason)}"}
    end
  end

  defp execute("get_download_url", _arguments, _ctx), do: {:error, "path is required"}

  defp absolute(%{base_url: base}, relative) when is_binary(base) and base != "",
    do: base <> relative

  defp absolute(_ctx, relative), do: DalaWeb.Endpoint.url() <> relative

  defp normalize(arguments) when is_map(arguments), do: arguments
  defp normalize(_arguments), do: %{}

  defp download_url_tool do
    %{
      "name" => "get_download_url",
      "description" =>
        "Return a short-lived, token-authenticated HTTP URL for downloading ONE server file " <>
          "(readable without the app login; the token unlocks only this path and expires). " <>
          "Pass an absolute path (~ is expanded). Also returns the file's size and content type. " <>
          "Requires MCP read access.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Absolute path to a regular server file (a leading ~ is expanded)."
          }
        },
        "required" => ["path"]
      }
    }
  end
end
