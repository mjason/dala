defmodule DalaWeb.RequestTooLargeError do
  defexception message: nil, plug_status: 413

  @impl true
  def exception(opts) do
    path = Keyword.get(opts, :path, "")
    message = Keyword.get(opts, :message, Dala.FileLimits.request_too_large_message(path))
    %__MODULE__{message: message}
  end
end
