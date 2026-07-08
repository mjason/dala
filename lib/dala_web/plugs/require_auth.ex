defmodule DalaWeb.Plugs.RequireAuth do
  @moduledoc """
  Blocks unauthenticated requests when authentication is enabled
  (`DALA_AUTH_ENABLED=true`). A no-op when authentication is disabled.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    if not Dala.Auth.enabled?() or conn.assigns[:current_user] do
      conn
    else
      case Keyword.get(opts, :mode, :page) do
        :api ->
          conn
          |> put_status(:unauthorized)
          |> json(%{
            success: false,
            errors: [%{type: "unauthorized", message: "authentication required"}]
          })
          |> halt()

        :page ->
          conn
          |> redirect(to: "/sign-in")
          |> halt()
      end
    end
  end
end
