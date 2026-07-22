defmodule Dala.Updater.AttemptResultTest do
  use ExUnit.Case, async: false

  alias Dala.Updater

  @attempt_id "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
  @other_attempt_id "6ba7b811-9dad-11d1-80b4-00c04fd430c8"

  setup do
    root =
      Path.join(System.tmp_dir!(), "dala-update-result-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "logs/update-results"))

    previous = Application.get_env(:dala, :release_root, :unset)
    Application.put_env(:dala, :release_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      case previous do
        :unset -> Application.delete_env(:dala, :release_root)
        value -> Application.put_env(:dala, :release_root, value)
      end
    end)

    {:ok, root: root}
  end

  test "an attempt reads only its own pending and authoritative final result", %{root: root} do
    started_at = DateTime.utc_now() |> DateTime.to_iso8601()

    write_result(root, @attempt_id, %{
      attempt_id: @attempt_id,
      status: "pending",
      target: "v0.26.0",
      previous: "v0.25.17",
      started_at: started_at
    })

    write_result(root, @other_attempt_id, %{
      attempt_id: @other_attempt_id,
      success: false,
      rolled_back: true,
      target: "v0.27.0",
      previous: "v0.25.17",
      message: "health check failed; rolled back",
      completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    assert {:ok,
            %{
              attempt_id: @attempt_id,
              status: "pending",
              target: "v0.26.0",
              started_at: ^started_at
            }} = Updater.update_result(@attempt_id)

    assert {:ok,
            %{
              attempt_id: @other_attempt_id,
              status: "failed",
              rolled_back: true,
              target: "v0.27.0",
              message: "health check failed; rolled back"
            }} = Updater.update_result(@other_attempt_id)
  end

  test "a successful helper result is authoritative", %{root: root} do
    started_at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
    completed_at = DateTime.utc_now() |> DateTime.to_iso8601()

    write_active(root, %{
      attempt_id: @attempt_id,
      target: "v0.26.0",
      started_at: started_at
    })

    write_result(root, @attempt_id, %{
      attempt_id: @attempt_id,
      success: true,
      rolled_back: false,
      target: "v0.26.0",
      previous: "v0.25.17",
      message: "updated to v0.26.0",
      completed_at: completed_at
    })

    assert {:ok,
            %{
              attempt_id: @attempt_id,
              status: "succeeded",
              rolled_back: false,
              target: "v0.26.0",
              message: "updated to v0.26.0",
              started_at: nil,
              completed_at: ^completed_at
            }} = Updater.update_result(@attempt_id)
  end

  test "attempt ids are strictly validated before path construction", %{root: root} do
    outside = Path.join(root, "logs/escaped.json")

    assert {:error, "invalid update attempt id"} = Updater.update_result("../escaped")
    assert {:error, "invalid update attempt id"} = Updater.update_result("#{@attempt_id}.json")
    refute File.exists?(outside)
  end

  test "status is safely unknown when the updater is disabled", %{root: root} do
    Application.delete_env(:dala, :release_root)

    assert {:ok, %{attempt_id: nil, status: "unknown"}} = Updater.update_result(nil)

    assert {:ok, %{attempt_id: @attempt_id, status: "unknown"}} =
             Updater.update_result(@attempt_id)

    Application.put_env(:dala, :release_root, root)
  end

  test "a result with a different embedded attempt id is never accepted", %{root: root} do
    write_result(root, @attempt_id, %{
      attempt_id: @other_attempt_id,
      success: true,
      rolled_back: false,
      target: "v0.26.0",
      previous: "v0.25.17",
      message: "wrong attempt",
      completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    assert {:ok, %{attempt_id: @attempt_id, status: "unknown"}} =
             Updater.update_result(@attempt_id)
  end

  test "a corrupt result is reported as unknown rather than trusted", %{root: root} do
    path = Path.join([root, "logs", "update-results", "#{@attempt_id}.json"])
    File.write!(path, "{not-json")

    assert {:ok, %{attempt_id: @attempt_id, status: "unknown"}} =
             Updater.update_result(@attempt_id)
  end

  test "id-less status never adopts a global active manifest", %{root: root} do
    started_at = DateTime.utc_now() |> DateTime.to_iso8601()

    write_result(root, @attempt_id, %{
      attempt_id: @attempt_id,
      status: "pending",
      target: "v0.26.0",
      previous: "v0.25.17",
      started_at: started_at
    })

    write_active(root, %{
      attempt_id: @attempt_id,
      target: "v0.26.0",
      started_at: started_at
    })

    assert {:ok, %{attempt_id: nil, status: "unknown"}} = Updater.update_result(nil)
  end

  test "the typed updater status action and RPC expose attempt correlation", %{root: root} do
    write_result(root, @attempt_id, %{
      attempt_id: @attempt_id,
      status: "pending",
      target: "v0.26.0",
      previous: "v0.25.17",
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    result =
      Dala.Terminal.Updater
      |> Ash.ActionInput.for_action(:update_status, %{attempt_id: @attempt_id})
      |> Ash.run_action!()

    assert %{attempt_id: @attempt_id, status: "pending", target: "v0.26.0"} = result

    updater_rpc =
      Dala.Terminal
      |> AshTypescript.Rpc.Info.typescript_rpc()
      |> Enum.find(&(&1.resource == Dala.Terminal.Updater))

    assert Enum.any?(
             updater_rpc.rpc_actions,
             &(&1.name == :update_status and &1.action == :update_status)
           )

    assert {:error, _error} =
             Dala.Terminal.Updater
             |> Ash.ActionInput.for_action(:update_status, %{})
             |> Ash.run_action()
  end

  defp write_result(root, attempt_id, payload) do
    path = Path.join([root, "logs", "update-results", "#{attempt_id}.json"])
    File.write!(path, Jason.encode!(payload))
  end

  defp write_active(root, payload) do
    File.write!(Path.join([root, "logs", "update-active.json"]), Jason.encode!(payload))
  end
end
