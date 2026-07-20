defmodule Dala.Terminal.Boot do
  @moduledoc """
  Reconciles sessions that were running before a BEAM restart: shells live in
  detached holder processes (`Dala.Terminal.Holder`), so any session whose
  holder is still alive is reattached; the rest are marked exited (their
  shells died — VM reboot, holder crash, or exit while dala was down).
  """

  require Ash.Query
  require Logger

  def child_spec(_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :transient}
  end

  @doc "Runs synchronously during supervision-tree startup."
  def start_link do
    run()
    :ignore
  end

  def run do
    sessions =
      Dala.Terminal.Session
      |> Ash.Query.filter(status == :running)
      |> Ash.read!()

    run_bounded(sessions, &reconcile/1, max_concurrency: 4)
  end

  @doc false
  def run_bounded(items, fun, opts \\ []) when is_function(fun, 1) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 4)

    items
    |> Task.async_stream(
      fn item ->
        try do
          fun.(item)
          :ok
        rescue
          error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
        catch
          kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
        end
      end,
      max_concurrency: max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.each(fn
      {:ok, :ok} ->
        :ok

      {:ok, {:error, formatted}} ->
        Logger.error("terminal boot reconciliation failed:\n#{formatted}")

      {:exit, reason} ->
        Logger.error("terminal boot reconciliation exited: #{inspect(reason)}")
    end)

    :ok
  end

  defp reconcile(session) do
    id = to_string(session.id)

    with true <- Dala.Terminal.Holder.exists?(id),
         {:ok, _pid} <- Dala.Terminal.Server.ensure_started(session) do
      Logger.info("reattached terminal session #{id}")
    else
      _no_holder_or_failed ->
        exit_code = Dala.Terminal.Holder.take_exit_status(id)
        Dala.Terminal.mark_exited!(session, %{exit_code: exit_code})
    end
  end
end
