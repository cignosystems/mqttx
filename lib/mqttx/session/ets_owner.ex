defmodule MqttX.Session.ETSOwner do
  @moduledoc false

  # Long-lived owner of the default :mqttx_sessions ETS table.
  #
  # Without this process the first short-lived caller of
  # MqttX.Session.ETSStore.init/1 ends up owning the table; when that process
  # exits the table is destroyed and every other client loses its session
  # state — defeating the whole point of clean_session=false. By owning the
  # table here under the application supervisor we tie its lifetime to the
  # OTP application, not to a request handler.

  use GenServer

  @table :mqttx_sessions

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

  @impl true
  def handle_call({:ensure_table, table}, _from, state) do
    create_if_missing(table)
    {:reply, :ok, state}
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    create_if_missing(table)
    {:ok, %{table: table}}
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
