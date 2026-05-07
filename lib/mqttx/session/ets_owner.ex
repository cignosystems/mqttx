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

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)

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

    {:ok, %{table: table}}
  end
end
