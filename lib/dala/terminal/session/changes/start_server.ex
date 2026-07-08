defmodule Dala.Terminal.Session.Changes.StartServer do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, session} ->
        case Dala.Terminal.Server.ensure_started(session) do
          {:ok, _pid} ->
            {:ok, session}

          {:error, reason} ->
            {:error,
             Ash.Error.Invalid.exception(errors: ["could not start terminal: #{inspect(reason)}"])}
        end

      _changeset, error ->
        error
    end)
  end
end
