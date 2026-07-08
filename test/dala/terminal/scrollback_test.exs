defmodule Dala.Terminal.ScrollbackTest do
  use ExUnit.Case, async: false

  alias Dala.Terminal.Scrollback

  setup do
    id = "scrollback-test-" <> Ash.UUID.generate()
    on_exit(fn -> Scrollback.clear(id) end)
    %{id: id}
  end

  test "append assigns increasing seqs and replay returns chunks in order", %{id: id} do
    assert Scrollback.append(id, "hello ") == 0
    assert Scrollback.append(id, "world") == 1

    assert Scrollback.replay(id) == [{0, "hello "}, {1, "world"}]
    assert Scrollback.last_seq(id) == 1
  end

  test "unknown sessions replay empty", %{id: id} do
    assert Scrollback.replay(id) == []
    assert Scrollback.last_seq(id) == -1
  end

  test "trims oldest chunks once the byte limit is exceeded", %{id: id} do
    for _ <- 0..9, do: Scrollback.append(id, String.duplicate("x", 1_000))

    :ok = Scrollback.set_limit(id, 3_000)

    assert [{7, _}, {8, _}, {9, _}] = Scrollback.replay(id)

    # appending keeps enforcing the limit
    assert Scrollback.append(id, String.duplicate("y", 1_000)) == 10
    assert [{8, _}, {9, _}, {10, chunk}] = Scrollback.replay(id)
    assert chunk == String.duplicate("y", 1_000)
  end

  test "clear removes chunks and resets meta", %{id: id} do
    Scrollback.append(id, "data")
    :ok = Scrollback.clear(id)

    assert Scrollback.replay(id) == []
    assert Scrollback.last_seq(id) == -1
  end
end
