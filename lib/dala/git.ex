defmodule Dala.Git do
  @moduledoc """
  NIF bindings to libgit2 (via the Rust `git2` crate) for the git panel.

  All functions take an absolute path anywhere inside a repository; the
  repository root is discovered automatically. Only local operations are
  supported — there is no network transport.

  Fallible functions return `{:ok, value}` / `{:error, message}`.
  """

  use Rustler, otp_app: :dala, crate: "dala_git"

  def status(_path), do: nif_error()
  def diff_file(_path, _file), do: nif_error()
  def stage(_path, _file), do: nif_error()
  def unstage(_path, _file), do: nif_error()
  def discard(_path, _file), do: nif_error()
  def commit(_path, _message), do: nif_error()
  def log(_path, _limit), do: nif_error()
  def show(_path, _hash), do: nif_error()
  def branches(_path), do: nif_error()
  def checkout(_path, _name), do: nif_error()

  defp nif_error, do: :erlang.nif_error(:nif_not_loaded)
end
