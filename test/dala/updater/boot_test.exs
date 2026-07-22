defmodule Dala.Updater.BootTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Dala.Updater.Boot

  @version "99.0.0"

  test "accepts release scripts containing immutable ETF values" do
    instructions = [
      :boot,
      127,
      -12,
      1.25,
      1 <<< 100,
      %{<<"key">> => <<1, 2, 3>>},
      <<1::size(3)>>,
      [1, 2, 3]
    ]

    assert :ok = Boot.validate(script(instructions), @version)
  end

  test "accepts a bit binary whose final byte has eight used bits" do
    encoded = script([<<1::size(3)>>])

    valid =
      :binary.replace(
        encoded,
        <<77, 0, 0, 0, 1, 3, 32>>,
        <<77, 0, 0, 0, 1, 8, 32>>
      )

    assert valid != encoded
    assert :ok = Boot.validate(valid, @version)
  end

  test "accepts the legacy 31-byte float external term" do
    encoded = script([1.25])
    float_payload = "1.25" <> :binary.copy(<<0>>, 27)

    legacy =
      :binary.replace(
        encoded,
        <<70, 63, 244, 0, 0, 0, 0, 0, 0>>,
        <<99, float_payload::binary>>
      )

    assert :ok = Boot.validate(legacy, @version)
  end

  test "rejects bit binaries with zero used bits or no payload" do
    encoded = script([<<1::size(3)>>])

    zero_bits = :binary.replace(encoded, <<77, 0, 0, 0, 1, 3, 32>>, <<77, 0, 0, 0, 1, 0, 32>>)

    empty = :binary.replace(encoded, <<77, 0, 0, 0, 1, 3, 32>>, <<77, 0, 0, 0, 0, 0>>)

    assert {:error, :invalid_term} = Boot.validate(zero_bits, @version)
    assert {:error, :invalid_term} = Boot.validate(empty, @version)
  end

  test "accepts an unknown atom without interning it" do
    placeholder = "boot_atom_placeholder"
    replacement = "z" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
    replacement = binary_size_pad(replacement, byte_size(placeholder))

    encoded =
      :erlang.term_to_binary({
        :script,
        {:dala, @version},
        [:boot_atom_placeholder]
      })

    assert byte_size(replacement) == byte_size(placeholder)
    refute atom_exists?(replacement)

    altered = :binary.replace(encoded, placeholder, replacement)
    assert :ok = Boot.validate(altered, @version)
    refute atom_exists?(replacement)
  end

  test "rejects compressed external terms" do
    compressed =
      :erlang.term_to_binary(
        {:script, {:dala, @version}, [String.duplicate("x", 10_000)]},
        compressed: 9
      )

    assert <<131, 80, _rest::binary>> = compressed
    assert {:error, :invalid_term} = Boot.validate(compressed, @version)
  end

  test "rejects runtime terms instead of guessing their payload layout" do
    assert {:error, :invalid_term} = Boot.validate(script([self()]), @version)
    assert {:error, :invalid_term} = Boot.validate(script([make_ref()]), @version)
  end

  test "rejects malformed UTF-8 atoms" do
    placeholder = "valid_atom"
    encoded = :erlang.term_to_binary({:script, {:dala, @version}, [:valid_atom]})

    malformed =
      :binary.replace(encoded, placeholder, <<255, 255, 255, 255, 255, 255, 255, 255, 255, 255>>)

    assert {:error, :invalid_term} = Boot.validate(malformed, @version)
  end

  test "rejects a term deeper than the parser limit" do
    nested = Enum.reduce(1..140, :leaf, fn _, value -> {value} end)
    assert {:error, :invalid_term} = Boot.validate(script([nested]), @version)
  end

  test "rejects a collection that exceeds the node budget without growing the stack" do
    instructions = :lists.duplicate(200_000, :ok)
    assert {:error, :invalid_term} = Boot.validate(script(instructions), @version)
  end

  test "rejects malformed external term envelopes" do
    assert {:error, :invalid_term} = Boot.validate(<<131, 104, 0>>, @version)

    malformed =
      :erlang.term_to_binary({:script, {:dala, @version}, [:ok]})
      |> :binary.replace(<<131>>, <<130>>)

    assert {:error, :invalid_term} = Boot.validate(malformed, @version)
  end

  defp script(instructions),
    do: :erlang.term_to_binary({:script, {:dala, @version}, instructions})

  defp atom_exists?(value) do
    case :erlang.binary_to_existing_atom(value, :utf8) do
      atom when is_atom(atom) -> true
    end
  rescue
    ArgumentError -> false
  end

  defp binary_size_pad(value, size) when byte_size(value) < size do
    value <> String.duplicate("x", size - byte_size(value))
  end

  defp binary_size_pad(value, size) when byte_size(value) > size,
    do: binary_part(value, 0, size)

  defp binary_size_pad(value, _size), do: value
end
