defmodule Dala.Settings.SpeechTest do
  use Dala.DataCase, async: false

  alias Dala.Settings.Speech

  defp current(actor \\ nil) do
    Speech
    |> Ash.ActionInput.for_action(:current, %{}, actor: actor)
    |> Ash.run_action!()
  end

  defp save(args, actor \\ nil) do
    Speech
    |> Ash.ActionInput.for_action(:save, args, actor: actor)
    |> Ash.run_action!()
  end

  defp user(email) do
    Dala.Accounts.User
    |> Ash.Changeset.for_create(:seed_user, %{email: email, password: "password1234"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  describe "current (singleton read)" do
    test "with no row at all it reads as empty defaults" do
      assert current() == %{endpoint: "", model: "", api_key_set: false}
    end

    test "round-trips endpoint and model" do
      assert save(%{endpoint: "http://127.0.0.1:8000/v1", model: "whisper-large-v3"}) ==
               %{
                 endpoint: "http://127.0.0.1:8000/v1",
                 model: "whisper-large-v3",
                 api_key_set: false
               }

      assert current() == %{
               endpoint: "http://127.0.0.1:8000/v1",
               model: "whisper-large-v3",
               api_key_set: false
             }
    end

    test "a second save updates the same row instead of creating another" do
      save(%{endpoint: "http://a/v1", model: "m"})
      save(%{endpoint: "http://b/v1", model: "m2"})

      assert current().endpoint == "http://b/v1"
      assert length(Ash.read!(Speech, authorize?: false)) == 1
    end
  end

  describe "api key" do
    test "is never returned by the read action — only api_key_set" do
      save(%{endpoint: "http://a/v1", model: "m", api_key: "sk-super-secret"})

      result = current()
      assert result.api_key_set == true
      refute Map.has_key?(result, :api_key)
      refute inspect(result) =~ "sk-super-secret"
    end

    test "an empty api key on update keeps the stored one" do
      save(%{endpoint: "http://a/v1", model: "m", api_key: "sk-keep-me"})
      save(%{endpoint: "http://b/v1", model: "m", api_key: ""})

      assert current().api_key_set == true
      assert Speech.config(nil).api_key == "sk-keep-me"
      assert Speech.config(nil).endpoint == "http://b/v1"
    end

    test "an omitted api key on update keeps the stored one" do
      save(%{endpoint: "http://a/v1", model: "m", api_key: "sk-keep-me"})
      save(%{endpoint: "http://b/v1", model: "m"})

      assert Speech.config(nil).api_key == "sk-keep-me"
    end

    test "clear_api_key wipes it" do
      save(%{endpoint: "http://a/v1", model: "m", api_key: "sk-gone"})
      assert save(%{clear_api_key: true}).api_key_set == false

      assert Speech.config(nil).api_key == nil
      # clearing the key leaves endpoint/model alone
      assert Speech.config(nil).endpoint == "http://a/v1"
    end

    test "is not a selectable field of any client-facing action" do
      for action <- [:current, :save] do
        fields = Ash.Resource.Info.action(Speech, action).constraints[:fields]
        assert Keyword.keys(fields) == [:endpoint, :model, :api_key_set]
      end

      # ...and the api key isn't even nameable in the generated client: the
      # attribute is private, so it appears in no resource schema.
      refute File.read!("assets/js/ash_types.ts") =~ "apiKey"
    end
  end

  describe "per-user isolation" do
    test "two users keep separate settings; neither sees the other's" do
      alice = user("alice@example.com")
      bob = user("bob@example.com")

      save(%{endpoint: "http://alice/v1", model: "alice-m", api_key: "sk-alice"}, alice)
      save(%{endpoint: "http://bob/v1", model: "bob-m", api_key: "sk-bob"}, bob)

      assert current(alice) == %{endpoint: "http://alice/v1", model: "alice-m", api_key_set: true}
      assert current(bob) == %{endpoint: "http://bob/v1", model: "bob-m", api_key_set: true}

      assert Speech.config(alice).api_key == "sk-alice"
      assert Speech.config(bob).api_key == "sk-bob"
    end

    test "the anonymous (global) row is separate from any user's row" do
      alice = user("alice2@example.com")

      save(%{endpoint: "http://global/v1", model: "g", api_key: "sk-global"})
      # A signed-in user does NOT inherit (or see) the global row's key.
      assert current(alice) == %{endpoint: "", model: "", api_key_set: false}
      assert Speech.config(alice).api_key == nil

      save(%{endpoint: "http://alice/v1", model: "a"}, alice)
      assert current().endpoint == "http://global/v1"
      assert current(alice).endpoint == "http://alice/v1"
      assert Speech.config(nil).api_key == "sk-global"
    end

    test "a user's row records the owner; the global row has none" do
      alice = user("alice3@example.com")
      save(%{endpoint: "http://alice/v1", model: "a"}, alice)
      save(%{endpoint: "http://global/v1", model: "g"})

      rows = Ash.read!(Speech, authorize?: false)
      assert Enum.find(rows, &(&1.endpoint == "http://alice/v1")).user_id == alice.id
      assert Enum.find(rows, &(&1.endpoint == "http://global/v1")).user_id == nil
    end

    test "deleting a user cascades: their speech row (and its key) goes with them" do
      alice = user("alice4@example.com")
      save(%{endpoint: "http://alice/v1", model: "a", api_key: "sk-alice"}, alice)
      # A separate global row must survive — only the owned row cascades.
      save(%{endpoint: "http://global/v1", model: "g"})

      # The FK carries `ON DELETE CASCADE`, so removing the user removes their
      # row (no orphan, no constraint error) — deleting straight through the
      # DB since Accounts.User exposes no destroy action.
      Dala.Repo.query!("DELETE FROM users WHERE id = ?", [alice.id])

      endpoints = Ash.read!(Speech, authorize?: false) |> Enum.map(& &1.endpoint)
      refute "http://alice/v1" in endpoints
      assert "http://global/v1" in endpoints
    end
  end
end
