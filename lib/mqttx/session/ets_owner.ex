defmodule MqttX.Session.ETSOwner do
  @moduledoc false

  # Long-lived owner of the session ETS tables, and their expiry sweeper.
  #
  # Without this process the first short-lived caller of
  # MqttX.Session.ETSStore.init/1 ends up owning the table; when that process
  # exits the table is destroyed and every other client loses its session
  # state — defeating the whole point of clean_session=false. By owning the
  # table here under the application supervisor we tie its lifetime to the
  # OTP application, not to a request handler.
  #
  # Every table created through here is also swept on an interval: records
  # whose `expires_at` has passed are deleted (see
  # MqttX.Session.ETSStore.sweep_expired/2), so a long-running VM does not
  # accumulate sessions the broker discarded long ago.

  use GenServer

  require Logger

  @table :mqttx_sessions
  @default_sweep_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  # Create (if missing) a session table OWNED BY THIS PROCESS, so its
  # lifetime is tied to the application rather than to whichever connection
  # process happened to ask first. Serializing creation through the
  # GenServer also removes the check-then-create race between two
  # connections initializing the same table concurrently.
  @spec ensure_table(atom()) :: :ok
  def ensure_table(table) when is_atom(table) do
    GenServer.call(__MODULE__, {:ensure_table, table})
  end

  @doc false
  # Sweep expired sessions from every owned table now. Returns the number of
  # records deleted. Mainly for tests and operators; the periodic sweep runs
  # on its own.
  @spec sweep_now() :: non_neg_integer()
  def sweep_now do
    GenServer.call(__MODULE__, :sweep)
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    create_if_missing(table)

    interval =
      Keyword.get(
        opts,
        :sweep_interval,
        Application.get_env(:mqttx, :session_sweep_interval, @default_sweep_interval_ms)
      )

    schedule_sweep(interval)
    {:ok, %{tables: MapSet.new([table]), sweep_interval: interval}}
  end

  @impl true
  def handle_call({:ensure_table, table}, _from, state) do
    create_if_missing(table)
    {:reply, :ok, %{state | tables: MapSet.put(state.tables, table)}}
  end

  def handle_call(:sweep, _from, state) do
    {:reply, sweep(state), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state)
    schedule_sweep(state.sweep_interval)
    {:noreply, state}
  end

  defp schedule_sweep(interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :sweep, interval)
  end

  defp schedule_sweep(_disabled), do: :ok

  defp sweep(state) do
    now = System.system_time(:second)

    Enum.reduce(state.tables, 0, fn table, acc ->
      # A table can only vanish if someone deleted it out from under us;
      # don't let that take the owner (and every other table) down.
      case :ets.whereis(table) do
        :undefined -> acc
        _ -> acc + MqttX.Session.ETSStore.sweep_expired(table, now)
      end
    end)
    |> tap(fn
      0 -> :ok
      n -> Logger.debug("[MqttX.Session] Swept #{n} expired session(s)")
    end)
  end

  defp create_if_missing(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      _ ->
        :ok
    end
  end
end
