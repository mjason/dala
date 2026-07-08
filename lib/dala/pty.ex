defmodule Dala.Pty do
  @moduledoc """
  NIF bindings to the Rust `portable-pty` crate.

  `open/7` spawns a shell attached to a fresh pseudo-terminal. The calling
  process becomes the owner and receives:

    * `{:pty_data, id, binary}` for every chunk the terminal produces
    * `{:pty_exit, id, exit_code}` once the child exits

  The returned resource must be kept in the owner's state: when it is
  garbage collected the child process is killed.
  """

  use Rustler, otp_app: :dala, crate: "dala_pty"

  @type pty :: reference()

  @spec open(
          String.t(),
          String.t(),
          [String.t()],
          String.t(),
          [{String.t(), String.t()}],
          pos_integer(),
          pos_integer()
        ) :: pty()
  def open(_id, _shell, _args, _cwd, _env, _rows, _cols), do: :erlang.nif_error(:nif_not_loaded)

  @spec write(pty(), binary()) :: :ok
  def write(_pty, _data), do: :erlang.nif_error(:nif_not_loaded)

  @spec resize(pty(), pos_integer(), pos_integer()) :: :ok
  def resize(_pty, _rows, _cols), do: :erlang.nif_error(:nif_not_loaded)

  @spec kill(pty()) :: :ok
  def kill(_pty), do: :erlang.nif_error(:nif_not_loaded)

  @spec child_pid(pty()) :: pos_integer() | nil
  def child_pid(_pty), do: :erlang.nif_error(:nif_not_loaded)
end
