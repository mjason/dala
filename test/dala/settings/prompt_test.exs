defmodule Dala.Settings.PromptTest do
  @moduledoc """
  The prompt stash resource: quick capture (`:stash`), recall order
  (`:list` — stashed first, newest first), use-then-archive (`:archive`),
  `:restore`, and the manual ownership guard shared with themes.
  """
  use Dala.DataCase, async: false

  alias Dala.Settings.Prompt

  defp stash!(content, actor \\ nil) do
    Prompt
    |> Ash.Changeset.for_create(:stash, %{content: content}, actor: actor)
    |> Ash.create!()
  end

  defp list(actor \\ nil) do
    Prompt |> Ash.Query.for_read(:list, %{}, actor: actor) |> Ash.read!()
  end

  describe "stash + list" do
    test "captured prompts come back stashed, newest first" do
      first = stash!("first idea")
      wait_for_next_storage_tick(first.inserted_at)
      stash!("second idea")

      assert [%{content: "second idea", status: :stashed}, %{content: "first idea"}] = list()
    end

    test "archived entries sort after the live stash" do
      used = stash!("used prompt")
      stash!("live prompt")

      used |> Ash.Changeset.for_update(:archive, %{}) |> Ash.update!()

      assert [
               %{content: "live prompt", status: :stashed},
               %{content: "used prompt", status: :archived}
             ] =
               list()
    end

    test "empty content is rejected" do
      assert {:error, %Ash.Error.Invalid{}} =
               Prompt |> Ash.Changeset.for_create(:stash, %{content: ""}) |> Ash.create()
    end
  end

  defp wait_for_next_storage_tick(timestamp) do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    timestamp = DateTime.truncate(timestamp, :millisecond)

    if DateTime.after?(now, timestamp) do
      :ok
    else
      receive do
      after
        1 -> wait_for_next_storage_tick(timestamp)
      end
    end
  end

  describe "archive / restore" do
    test "archive stamps used_at; restore clears it" do
      prompt = stash!("idea")
      assert prompt.used_at == nil

      archived = prompt |> Ash.Changeset.for_update(:archive, %{}) |> Ash.update!()
      assert archived.status == :archived
      assert %DateTime{} = archived.used_at

      restored = archived |> Ash.Changeset.for_update(:restore, %{}) |> Ash.update!()
      assert restored.status == :stashed
      assert restored.used_at == nil
    end
  end

  describe "ownership" do
    test "an anonymous caller cannot touch another user's prompt" do
      prompt =
        Ash.Seed.seed!(Prompt, %{
          content: "theirs",
          status: :stashed,
          owner_id: Ash.UUID.generate()
        })

      assert {:error, %Ash.Error.Forbidden{}} =
               prompt |> Ash.Changeset.for_update(:archive, %{}, actor: nil) |> Ash.update()

      assert list(nil) == []
    end
  end
end
