defmodule Dala.FileLimits do
  @moduledoc """
  Runtime file-transfer limits shared by HTTP parsing, controllers, terminal
  attachments and file editing. Values may be overridden through the
  `:dala, :file_limits` application config.
  """

  @mib 1024 * 1024
  @defaults %{
    drawer_upload_bytes: 2 * 1024 * @mib,
    browser_attachment_bytes: 512 * @mib,
    mcp_attachment_bytes: 64 * @mib,
    managed_attachment_bytes: 5 * 1024 * @mib,
    text_write_bytes: 50 * @mib,
    preview_default_bytes: 1 * @mib,
    preview_max_bytes: 16 * @mib
  }

  for key <- Map.keys(@defaults) do
    def unquote(key)(), do: bytes(unquote(key))
  end

  def bytes(key) when is_map_key(@defaults, key) do
    configured = Application.get_env(:dala, :file_limits, %{})

    value =
      if is_map(configured),
        do: Map.get(configured, key, @defaults[key]),
        else: Keyword.get(configured, key, @defaults[key])

    if is_integer(value) and value > 0, do: value, else: @defaults[key]
  end

  @doc "Multipart parser budget for the two streaming upload routes."
  def multipart_request_bytes("/files/upload"), do: drawer_upload_bytes() + @mib
  def multipart_request_bytes("/files/attachment"), do: browser_attachment_bytes() + @mib
  def multipart_request_bytes(_path), do: 8_000_000

  @doc "Raw JSON request budget for text saves and MCP Base64 attachments."
  def json_request_bytes("/rpc/run"), do: text_write_bytes() + 2 * @mib

  def json_request_bytes("/mcp") do
    # Base64 expands by 4/3; leave room for the JSON-RPC envelope and metadata.
    div(mcp_attachment_bytes() + 2, 3) * 4 + @mib
  end

  def json_request_bytes(_path), do: 8_000_000

  def request_too_large_message("/files/upload") do
    "file upload is too large (max #{format(drawer_upload_bytes())} per file)"
  end

  def request_too_large_message("/files/attachment") do
    "terminal attachment is too large (max #{format(browser_attachment_bytes())} per file)"
  end

  def request_too_large_message("/rpc/run") do
    "request is too large (text files may be saved up to #{format(text_write_bytes())})"
  end

  def request_too_large_message("/mcp") do
    "MCP request is too large (decoded attachments may be up to #{format(mcp_attachment_bytes())})"
  end

  def request_too_large_message(_path), do: "request is too large"

  def format(bytes) when rem(bytes, 1024 * @mib) == 0, do: "#{div(bytes, 1024 * @mib)} GB"
  def format(bytes) when rem(bytes, @mib) == 0, do: "#{div(bytes, @mib)} MB"
  def format(bytes), do: "#{bytes} bytes"
end
