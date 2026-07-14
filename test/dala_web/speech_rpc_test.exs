defmodule DalaWeb.SpeechRpcTest do
  @moduledoc """
  End-to-end per-user isolation for the speech settings, exercised through the
  REAL RPC pipeline (`POST /rpc/run` → `RequireAuth` → `set_actor` →
  `AshTypescript.Rpc.run_action`), NOT a bare `Ash.run_action`. This is the
  highest-risk face: if actor threading ever silently collapsed onto the shared
  global row, a signed-in user could read (or forward audio with) another
  user's endpoint + key. These assertions make that regression loud.
  """
  use DalaWeb.ConnCase, async: false

  setup do
    Application.put_env(:dala, :auth_enabled, true)
    on_exit(fn -> Application.put_env(:dala, :auth_enabled, false) end)
    :ok
  end

  # Sign in through the password strategy so the user carries the token
  # metadata `store_in_session/2` expects (same shape as AuthGateTest).
  defp sign_in(email) do
    Dala.Accounts.User
    |> Ash.Changeset.for_create(:seed_user, %{email: email, password: "password123"},
      authorize?: false
    )
    |> Ash.create!()

    strategy = AshAuthentication.Info.strategy!(Dala.Accounts.User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => "password123"
      })

    user
  end

  defp as_user(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp rpc(conn, user, action, input) do
    conn
    |> as_user(user)
    |> post(~p"/rpc/run", %{
      "action" => action,
      "input" => input,
      "fields" => ["endpoint", "model", "apiKeySet"]
    })
    |> json_response(200)
  end

  test "signed-in users never see each other's speech config through /rpc/run", %{conn: conn} do
    alice = sign_in("alice-rpc@dala.dev")
    bob = sign_in("bob-rpc@dala.dev")

    # Alice saves her endpoint + key over RPC.
    saved =
      rpc(conn, alice, "set_speech_settings", %{
        "endpoint" => "http://alice/v1",
        "model" => "alice-m",
        "apiKey" => "sk-alice"
      })

    assert %{"success" => true, "data" => %{"endpoint" => "http://alice/v1", "apiKeySet" => true}} =
             saved

    # Bob reads HIS OWN config through the same pipeline: empty, NOT Alice's.
    bob_read = rpc(conn, bob, "speech_settings", %{})
    assert %{"success" => true, "data" => bob_data} = bob_read
    assert (bob_data["endpoint"] || "") == ""
    assert bob_data["apiKeySet"] in [false, nil]
    refute bob_data["endpoint"] == "http://alice/v1"
    # Nothing in the whole response body carries Alice's key.
    refute inspect(bob_read) =~ "sk-alice"

    # Alice still sees her own — actor threading didn't wipe it.
    assert %{"data" => %{"endpoint" => "http://alice/v1", "apiKeySet" => true}} =
             rpc(conn, alice, "speech_settings", %{})

    # And at the server layer, each actor resolves to its own key (Bob's is
    # nil — he never inherits the global row, let alone Alice's).
    assert Dala.Settings.Speech.config(bob).api_key == nil
    assert Dala.Settings.Speech.config(alice).api_key == "sk-alice"
  end

  test "each signed-in user writes their own row; neither overwrites the other", %{conn: conn} do
    alice = sign_in("alice2-rpc@dala.dev")
    bob = sign_in("bob2-rpc@dala.dev")

    rpc(conn, alice, "set_speech_settings", %{
      "endpoint" => "http://alice/v1",
      "model" => "a",
      "apiKey" => "sk-alice"
    })

    rpc(conn, bob, "set_speech_settings", %{
      "endpoint" => "http://bob/v1",
      "model" => "b",
      "apiKey" => "sk-bob"
    })

    # Bob's save didn't clobber Alice's row (no collapse onto one shared id).
    assert %{"data" => %{"endpoint" => "http://alice/v1"}} =
             rpc(conn, alice, "speech_settings", %{})

    assert %{"data" => %{"endpoint" => "http://bob/v1"}} =
             rpc(conn, bob, "speech_settings", %{})

    assert Dala.Settings.Speech.config(alice).api_key == "sk-alice"
    assert Dala.Settings.Speech.config(bob).api_key == "sk-bob"
  end
end
