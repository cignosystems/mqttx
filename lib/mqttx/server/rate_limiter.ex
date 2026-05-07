defmodule MqttX.Server.RateLimiter do
  @moduledoc """
  Token bucket rate limiter using ETS for lock-free per-client counters.

  Provides connection-rate and message-rate limiting for MQTT servers.
  Counters are stored in ETS with atomic `update_counter` operations,
  safe for concurrent access from multiple transport handler processes.

  The periodic counter reset runs as a supervised GenServer, ensuring
  the timer is restarted if it crashes.

  ## Usage

      limiter = MqttX.Server.RateLimiter.new(
        max_connections: 100,    # new connections per interval
        max_messages: 1000,      # messages per client per interval
        interval: 1000           # window size in ms (default)
      )

      case MqttX.Server.RateLimiter.allow_connection?(limiter) do
        :ok -> # accept connection
        {:error, :rate_limited} -> # reject with 0x9F
      end

      case MqttX.Server.RateLimiter.allow_message?(limiter, client_id) do
        :ok -> # process message
        {:error, :rate_limited} -> # reject with 0x96
      end
  """

  @type t :: %{
          table: :ets.table(),
          max_connections: pos_integer() | nil,
          max_messages: pos_integer() | nil,
          interval: pos_integer(),
          timer_pid: pid() | nil
        }

  @doc """
  Create a new rate limiter.

  ## Options

  - `:max_connections` - Maximum new connections per interval (default: nil, unlimited)
  - `:max_messages` - Maximum messages per client per interval (default: nil, unlimited)
  - `:interval` - Window size in milliseconds (default: 1000)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max_connections = Keyword.get(opts, :max_connections)
    max_messages = Keyword.get(opts, :max_messages)
    interval = Keyword.get(opts, :interval, 1000)

    table =
      :ets.new(:mqttx_rate_limiter, [
        :public,
        :set,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    # Initialize connection counter
    :ets.insert(table, {:connections, 0})

    # Start periodic reset timer as a GenServer
    {:ok, timer_pid} = MqttX.Server.RateLimiter.Timer.start_link(table: table, interval: interval)

    %{
      table: table,
      max_connections: max_connections,
      max_messages: max_messages,
      interval: interval,
      timer_pid: timer_pid
    }
  end

  @doc """
  Check and increment the connection counter.

  Returns `:ok` if the connection is allowed, or `{:error, :rate_limited}`
  if the connection rate limit has been exceeded.
  """
  @spec allow_connection?(t()) :: :ok | {:error, :rate_limited}
  def allow_connection?(%{max_connections: nil}), do: :ok

  def allow_connection?(%{table: table, max_connections: max}) do
    count = :ets.update_counter(table, :connections, {2, 1})

    if count <= max do
      :ok
    else
      # Decrement back since we won't use this slot
      :ets.update_counter(table, :connections, {2, -1})
      {:error, :rate_limited}
    end
  end

  @doc """
  Check and increment the per-client message counter.

  Returns `:ok` if the message is allowed, or `{:error, :rate_limited}`
  if the per-client message rate limit has been exceeded.
  """
  @spec allow_message?(t(), binary()) :: :ok | {:error, :rate_limited}
  def allow_message?(%{max_messages: nil}, _client_id), do: :ok

  def allow_message?(%{table: table, max_messages: max}, client_id) do
    key = {:msg, client_id}

    count =
      try do
        :ets.update_counter(table, key, {2, 1})
      rescue
        ArgumentError ->
          :ets.insert_new(table, {key, 1})
          1
      end

    if count <= max do
      :ok
    else
      :ets.update_counter(table, key, {2, -1})
      {:error, :rate_limited}
    end
  end

  @doc """
  Reset all counters. Called automatically on each interval tick.
  """
  @spec reset(t()) :: :ok
  def reset(%{table: table}) do
    :ets.delete_all_objects(table)
    :ets.insert(table, {:connections, 0})
    :ok
  end

  @doc """
  Clean up the rate limiter, deleting the ETS table and stopping the timer.
  """
  @spec cleanup(t()) :: :ok
  def cleanup(%{table: table, timer_pid: timer_pid}) do
    if timer_pid && Process.alive?(timer_pid) do
      try do
        GenServer.stop(timer_pid, :normal, 5000)
      catch
        :exit, _ -> :ok
      end
    end

    try do
      :ets.delete(table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end
end

defmodule MqttX.Server.RateLimiter.Timer do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    interval = Keyword.fetch!(opts, :interval)
    schedule_reset(interval)
    {:ok, %{table: table, interval: interval}}
  end

  @impl true
  def handle_info(:reset, state) do
    try do
      :ets.delete_all_objects(state.table)
      :ets.insert(state.table, {:connections, 0})
    rescue
      ArgumentError -> :ok
    end

    schedule_reset(state.interval)
    {:noreply, state}
  end

  defp schedule_reset(interval) do
    Process.send_after(self(), :reset, interval)
  end
end
