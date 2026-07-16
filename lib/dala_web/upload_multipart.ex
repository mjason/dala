defmodule DalaWeb.UploadMultipart do
  @moduledoc """
  Route-aware multipart parser. Plug streams file parts to temporary files;
  this module only selects a bounded request budget for each upload surface.
  """

  @behaviour Plug.Parsers
  @multipart Plug.Parsers.MULTIPART

  @impl true
  def init(opts), do: opts

  @impl true
  def parse(conn, "multipart", subtype, headers, opts)
      when subtype in ["form-data", "mixed"] do
    parser_opts =
      opts
      |> Keyword.put(:length, Dala.FileLimits.multipart_request_bytes(conn.request_path))
      |> @multipart.init()

    case @multipart.parse(conn, "multipart", subtype, headers, parser_opts) do
      {:error, :too_large, _conn} ->
        raise DalaWeb.RequestTooLargeError, path: conn.request_path

      result ->
        result
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}
end
