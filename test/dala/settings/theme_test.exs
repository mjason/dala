defmodule Dala.Settings.ThemeTest do
  # async: false — asserts on the globally-seeded preset library and exercises
  # PubSub broadcasts, both shared process/DB state.
  use Dala.DataCase, async: false

  require Ash.Query

  alias Dala.Settings.Theme

  @sample %{"bg0" => "#101010", "mint" => "#22ff88", "ansiRed" => "#ff0000"}

  setup do
    # Guarantee the six presets exist inside this test's transaction,
    # independent of the boot-time seeder (and idempotent alongside it).
    Theme.ensure_builtin_presets()
    :ok
  end

  # ---- helpers ----

  defp user(email) do
    Dala.Accounts.User
    |> Ash.Changeset.for_create(:seed_user, %{email: email, password: "password1234"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create!(attrs, actor) do
    Theme
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(authorize?: false)
  end

  defp create(attrs, actor) do
    Theme
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create(authorize?: false)
  end

  defp list(actor) do
    Theme
    |> Ash.Query.for_read(:list, %{}, actor: actor)
    |> Ash.read!(authorize?: false)
  end

  defp get(id, actor) do
    Theme
    |> Ash.Query.for_read(:get, %{id: id}, actor: actor)
    |> Ash.read_one!(authorize?: false)
  end

  defp edit(theme, attrs, actor) do
    theme
    |> Ash.Changeset.for_update(:update, attrs, actor: actor)
    |> Ash.update(authorize?: false)
  end

  defp destroy(theme, actor) do
    theme
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
    |> Ash.destroy(authorize?: false)
  end

  defp builtins do
    Theme |> Ash.read!(authorize?: false) |> Enum.filter(& &1.builtin)
  end

  # ---- CRUD ----

  describe "CRUD" do
    test "create/get/update/destroy round-trip" do
      alice = user("alice-crud@example.com")

      theme = create!(%{name: "Mine", base: :dark, tokens: @sample}, alice)
      assert theme.name == "Mine"
      assert theme.base == :dark
      assert theme.tokens == @sample
      assert theme.builtin == false
      assert theme.owner_id == alice.id
      assert theme.user_id == alice.id

      assert get(theme.id, alice).id == theme.id

      {:ok, updated} = edit(theme, %{name: "Renamed", tokens: %{"bg0" => "#000000"}}, alice)
      assert updated.name == "Renamed"
      assert updated.tokens == %{"bg0" => "#000000"}

      assert destroy(updated, alice) == :ok
      assert get(theme.id, alice) == nil
    end
  end

  # ---- scoping / isolation ----

  describe "per-user isolation" do
    test "each user sees only their own themes plus the global library" do
      alice = user("alice-iso@example.com")
      bob = user("bob-iso@example.com")

      a = create!(%{name: "Alice Theme", base: :dark, tokens: @sample}, alice)
      b = create!(%{name: "Bob Theme", base: :light, tokens: @sample}, bob)
      g = create!(%{name: "Anon Theme", base: :dark, tokens: @sample}, nil)

      alice_ids = list(alice) |> Enum.map(& &1.id)
      assert a.id in alice_ids
      refute b.id in alice_ids
      assert g.id in alice_ids
      assert Enum.all?(builtins(), &(&1.id in alice_ids))

      bob_ids = list(bob) |> Enum.map(& &1.id)
      assert b.id in bob_ids
      refute a.id in bob_ids
      assert g.id in bob_ids

      # scoped get cannot reach out of the caller's library
      assert get(a.id, alice).id == a.id
      assert get(b.id, alice) == nil
    end

    test "list returns built-ins first, then the caller's themes alphabetically" do
      alice = user("alice-sort@example.com")
      create!(%{name: "Zebra", base: :dark, tokens: @sample}, alice)
      create!(%{name: "Apple", base: :dark, tokens: @sample}, alice)

      themes = list(alice)
      {builtin_part, rest} = Enum.split_while(themes, & &1.builtin)

      assert length(builtin_part) == 6
      refute Enum.any?(rest, & &1.builtin)

      rest_names = Enum.map(rest, & &1.name)
      assert rest_names == Enum.sort(rest_names)
      assert rest_names == ["Apple", "Zebra"]
    end
  end

  # ---- uniqueness ----

  describe "name uniqueness per owner" do
    test "a user cannot have two themes with the same name" do
      alice = user("alice-uniq@example.com")
      create!(%{name: "Dup", base: :dark, tokens: @sample}, alice)
      assert {:error, _} = create(%{name: "Dup", base: :light, tokens: @sample}, alice)
    end

    test "two different owners may reuse the same name" do
      alice = user("alice-uniq2@example.com")
      bob = user("bob-uniq2@example.com")
      create!(%{name: "Shared", base: :dark, tokens: @sample}, alice)
      assert %Theme{} = create!(%{name: "Shared", base: :dark, tokens: @sample}, bob)
    end

    test "two GLOBAL themes with the same name are rejected (sentinel fixes the NULL-distinct trap)" do
      create!(%{name: "GlobalDup", base: :dark, tokens: @sample}, nil)
      assert {:error, _} = create(%{name: "GlobalDup", base: :light, tokens: @sample}, nil)
    end
  end

  # ---- owner derivation ----

  describe "owner derivation" do
    test "create derives owner_id/user_id from the actor" do
      alice = user("alice-derive@example.com")

      owned = create!(%{name: "Derived", base: :dark, tokens: @sample}, alice)
      assert owned.owner_id == alice.id
      assert owned.user_id == alice.id

      anon = create!(%{name: "AnonDerived", base: :dark, tokens: @sample}, nil)
      assert anon.owner_id == Theme.global_id()
      assert anon.user_id == nil
    end

    test "the create action does not accept owner_id/user_id (a client cannot choose a library)" do
      accept = Ash.Resource.Info.action(Theme, :create).accept
      refute :owner_id in accept
      refute :user_id in accept
    end
  end

  # ---- ownership + built-in guard ----

  describe "write guard" do
    test "a user cannot update or delete another user's theme" do
      alice = user("alice-guard@example.com")
      bob = user("bob-guard@example.com")
      b = create!(%{name: "Bob's", base: :dark, tokens: @sample}, bob)

      assert {:error, %Ash.Error.Forbidden{}} = edit(b, %{name: "Hijacked"}, alice)
      assert {:error, %Ash.Error.Forbidden{}} = destroy(b, alice)

      assert get(b.id, bob).name == "Bob's"
    end

    test "built-in presets can never be updated or deleted" do
      alice = user("alice-builtin@example.com")
      [preset | _] = builtins()

      assert {:error, %Ash.Error.Forbidden{}} = edit(preset, %{name: "Nope"}, alice)
      assert {:error, %Ash.Error.Forbidden{}} = edit(preset, %{name: "Nope"}, nil)
      assert {:error, %Ash.Error.Forbidden{}} = destroy(preset, alice)
      assert {:error, %Ash.Error.Forbidden{}} = destroy(preset, nil)
    end

    test "a built-in preset can be forked into a new owned theme" do
      alice = user("alice-fork@example.com")
      preset = Enum.find(builtins(), &(&1.name == "Dracula"))

      fork = create!(%{name: "My Dracula", base: preset.base, tokens: preset.tokens}, alice)
      assert fork.builtin == false
      assert fork.owner_id == alice.id
      assert fork.tokens == preset.tokens
      refute fork.id == preset.id
    end
  end

  # ---- token whitelist ----

  describe "token validation" do
    test "unknown token keys are rejected on create" do
      alice = user("alice-tok1@example.com")

      assert {:error, _} =
               create(%{name: "Bad", base: :dark, tokens: %{"notAKey" => "#fff"}}, alice)
    end

    test "non-string token values are rejected on create" do
      alice = user("alice-tok2@example.com")
      assert {:error, _} = create(%{name: "Bad2", base: :dark, tokens: %{"bg0" => 123}}, alice)
    end

    test "unknown token keys are rejected on update too" do
      alice = user("alice-tok3@example.com")
      theme = create!(%{name: "T", base: :dark, tokens: %{"bg0" => "#111111"}}, alice)
      assert {:error, _} = edit(theme, %{tokens: %{"bogus" => "#fff"}}, alice)
    end

    test "a sparse map of valid tokens is accepted" do
      alice = user("alice-tok4@example.com")
      theme = create!(%{name: "Sparse", base: :dark, tokens: %{"bg0" => "#111111"}}, alice)
      assert theme.tokens == %{"bg0" => "#111111"}
    end

    test "a url() token value is rejected — no cross-user resource-load beacon" do
      alice = user("alice-tok5@example.com")

      assert {:error, _} =
               create(
                 %{
                   name: "Beacon",
                   base: :dark,
                   tokens: %{"bg0" => "url(https://evil.example/x.png)"}
                 },
                 alice
               )
    end

    test "an over-long token value is rejected" do
      alice = user("alice-tok6@example.com")
      big = "#" <> String.duplicate("a", 200)
      assert {:error, _} = create(%{name: "Big", base: :dark, tokens: %{"bg0" => big}}, alice)
    end

    test "hex, short-hex and rgba() colour values are accepted" do
      alice = user("alice-tok7@example.com")

      theme =
        create!(
          %{
            name: "Colours",
            base: :dark,
            tokens: %{
              "bg0" => "#abc",
              "mint" => "#22ff88",
              "termSelectionBackground" => "rgba(88, 110, 117, 0.3)"
            }
          },
          alice
        )

      assert theme.tokens["termSelectionBackground"] == "rgba(88, 110, 117, 0.3)"
      assert theme.tokens["bg0"] == "#abc"
    end
  end

  # ---- cascade ----

  describe "user deletion" do
    test "deleting a user cascades their themes; global presets remain" do
      alice = user("alice-cascade@example.com")
      a = create!(%{name: "Alice Cascade", base: :dark, tokens: @sample}, alice)

      # FK carries ON DELETE CASCADE; Accounts.User exposes no destroy action,
      # so delete straight through the DB (as the speech test does).
      Dala.Repo.query!("DELETE FROM users WHERE id = ?", [alice.id])

      ids = Theme |> Ash.read!(authorize?: false) |> Enum.map(& &1.id)
      refute a.id in ids
      assert length(builtins()) == 6
    end
  end

  # ---- presets ----

  describe "built-in presets" do
    test "ensure_builtin_presets/0 is idempotent: always exactly six built-ins" do
      Theme.ensure_builtin_presets()
      assert length(builtins()) == 6

      Theme.ensure_builtin_presets()
      assert length(builtins()) == 6

      ids = builtins() |> Enum.map(& &1.id) |> Enum.uniq()
      assert length(ids) == 6
    end

    test "presets are global, non-builtin-editable, and each fills all 45 canonical tokens" do
      keys = MapSet.new(Dala.Settings.Theme.Tokens.token_keys())
      assert MapSet.size(keys) == 45

      for preset <- Dala.Settings.Theme.Presets.all() do
        assert MapSet.new(Map.keys(preset.tokens)) == keys, "#{preset.name}: token keys mismatch"

        assert Enum.all?(Map.values(preset.tokens), &is_binary/1),
               "#{preset.name}: non-string value"
      end

      # the seeded rows are global + builtin
      for row <- builtins() do
        assert row.owner_id == Theme.global_id()
        assert row.user_id == nil
        assert row.builtin == true
      end
    end
  end

  # ---- realtime (channel wiring) ----

  describe "pub_sub" do
    test "creating a theme broadcasts theme_created on the settings topic" do
      alice = user("alice-pubsub@example.com")
      Phoenix.PubSub.subscribe(Dala.PubSub, "settings")

      theme = create!(%{name: "Broadcast", base: :dark, tokens: @sample}, alice)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "settings",
                       event: "theme_created",
                       payload: payload
                     },
                     1_000

      assert payload.id == theme.id
      assert payload.ownerId == alice.id
      assert payload.name == "Broadcast"
      assert payload.base == :dark
      assert payload.builtin == false
      assert payload.tokens == @sample
    end

    test "the theme_created payload shape matches the channel contract" do
      alice = user("alice-payload@example.com")
      theme = create!(%{name: "Shape", base: :dark, tokens: @sample}, alice)

      payload = Dala.Settings.Theme.Payloads.summary(%Ash.Notifier.Notification{data: theme})

      assert payload.id == theme.id
      assert payload.ownerId == alice.id
      assert payload.base == :dark
      assert payload.builtin == false
      assert payload.tokens == @sample

      assert Keyword.keys(Dala.Settings.Theme.Payloads.summary_fields()) ==
               [:id, :ownerId, :name, :base, :builtin, :tokens, :insertedAt, :updatedAt]
    end
  end
end
