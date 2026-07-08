defmodule Dala.Auth do
  @moduledoc """
  Runtime toggle for account authentication.

  Authentication is optional: it is enabled by setting `DALA_AUTH_ENABLED=true`
  (see `config/runtime.exs`), in which case sign-in requires one of the
  pre-seeded accounts from `DALA_USERS`. When disabled (the default) the
  terminal is open to anyone who can reach the server.

  The terminal websocket authenticates with the same AshAuthentication bearer
  token that the browser session holds, so revoking tokens (sign out,
  log-out-everywhere) also cuts off socket access.
  """

  alias AshAuthentication.{Info, Jwt, TokenResource}

  # Matches ash_authentication's session key for Dala.Accounts.User
  # (`"#{subject_name}_token"`) — the session stores the bearer token itself
  # because `require_token_presence_for_authentication?` is enabled.
  @session_key "user_token"

  def enabled? do
    Application.get_env(:dala, :auth_enabled, false)
  end

  @doc "The signed-in user's bearer token, as stored in the session by Ash."
  def bearer_token(conn) do
    Plug.Conn.get_session(conn, @session_key)
  end

  @doc """
  Verifies an AshAuthentication bearer token and returns its user.

  Mirrors `AshAuthentication.Plug.Helpers.retrieve_from_bearer/3`: the JWT
  must be valid, non-actor-scoped, still present in the token store, and
  resolve to a user.
  """
  def verify_bearer_token(token) when is_binary(token) do
    with {:ok, %{"sub" => subject, "jti" => jti} = claims, resource}
         when not is_map_key(claims, "act") <- Jwt.verify(token, :dala),
         {:ok, token_resource} <- Info.authentication_tokens_token_resource(resource),
         {:ok, [_token_record]} <-
           TokenResource.Actions.get_token(token_resource, %{"jti" => jti, "purpose" => "user"}),
         {:ok, user} <- AshAuthentication.subject_to_user(subject, resource) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  def verify_bearer_token(_token), do: :error
end
