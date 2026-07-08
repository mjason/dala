defmodule DalaWeb.AuthGateTest do
  use DalaWeb.ConnCase, async: false

  defp enable_auth(_context) do
    Application.put_env(:dala, :auth_enabled, true)
    on_exit(fn -> Application.put_env(:dala, :auth_enabled, false) end)
    :ok
  end

  defp seed_user! do
    Dala.Accounts.User
    |> Ash.Changeset.for_create(
      :seed_user,
      %{email: "gate-test@dala.dev", password: "password123"},
      authorize?: false
    )
    |> Ash.create!()

    # Sign in through the strategy so the returned user carries the token
    # metadata that store_in_session/2 expects.
    strategy = AshAuthentication.Info.strategy!(Dala.Accounts.User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => "gate-test@dala.dev",
        "password" => "password123"
      })

    user
  end

  describe "with authentication disabled (default)" do
    test "the terminal SPA is open", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ ~s(id="app")
    end

    test "the RPC endpoint is open", %{conn: conn} do
      conn = post(conn, ~p"/rpc/run", %{"action" => "list_sessions", "fields" => ["id"]})
      assert %{"success" => true} = json_response(conn, 200)
    end
  end

  describe "with authentication enabled" do
    setup :enable_auth

    test "anonymous SPA requests are redirected to sign-in", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == "/sign-in"
    end

    test "anonymous RPC requests get 401", %{conn: conn} do
      conn = post(conn, ~p"/rpc/run", %{"action" => "list_sessions", "fields" => ["id"]})

      assert %{"success" => false, "errors" => [%{"type" => "unauthorized"}]} =
               json_response(conn, 401)
    end

    test "signed-in users reach the terminal with a socket token", %{conn: conn} do
      user = seed_user!()

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(user)
        |> get(~p"/")

      html = html_response(conn, 200)
      assert html =~ ~s(id="app")
      assert html =~ "socket-token"

      [_, token] = Regex.run(~r/name="socket-token" content="([^"]+)"/, html)
      assert {:ok, socket_user} = Dala.Auth.verify_bearer_token(token)
      assert socket_user.id == user.id
    end

    test "the websocket rejects missing or bogus tokens and accepts Ash bearer tokens" do
      user = seed_user!()

      assert :error = DalaWeb.UserSocket.connect(%{}, socket_stub(), %{})
      assert :error = DalaWeb.UserSocket.connect(%{"token" => "garbage"}, socket_stub(), %{})

      token = user.__metadata__.token

      assert {:ok, socket} = DalaWeb.UserSocket.connect(%{"token" => token}, socket_stub(), %{})
      assert socket.assigns.user_id == user.id
    end

    test "revoked bearer tokens (sign-out) lose websocket access" do
      user = seed_user!()
      token = user.__metadata__.token

      assert {:ok, _socket} = DalaWeb.UserSocket.connect(%{"token" => token}, socket_stub(), %{})

      :ok = AshAuthentication.TokenResource.Actions.revoke(Dala.Accounts.Token, token, [])

      assert :error = DalaWeb.UserSocket.connect(%{"token" => token}, socket_stub(), %{})
    end
  end

  defp socket_stub do
    %Phoenix.Socket{endpoint: DalaWeb.Endpoint, handler: DalaWeb.UserSocket}
  end
end
