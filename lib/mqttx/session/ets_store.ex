defmodule MqttX.Session.ETSStore do
  @moduledoc """
  ETS-based in-memory session store.

  This is the default session store implementation. Sessions are stored in
  an ETS table and persist for the lifetime of the BEAM VM.

  ## Options

  - `:table` - Name of the ETS table (default: `:mqttx_sessions`)

  ## Usage

      {:ok, client} = MqttX.Client.connect(
        host: "localhost",
        client_id: "my_client",
        clean_session: false,
        session_store: MqttX.Session.ETSStore
      )

      # Or with custom table name
      {:ok, client} = MqttX.Client.connect(
        host: "localhost",
        client_id: "my_client",
        clean_session: false,
        session_store: {MqttX.Session.ETSStore, table: :my_sessions}
      )

  ## Limitations

  - Sessions are lost when the BEAM VM restarts
  - Not suitable for distributed deployments (sessions are node-local)

  For persistent storage across restarts, implement a custom store using
  the `MqttX.Session.Store` behaviour with your preferred database.
  """

  @behaviour MqttX.Session.Store

  @default_table :mqttx_sessions

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)

    # Create table if it doesn't exist
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, :set])

      _ref ->
        # Table already exists
        :ok
    end

    {:ok, %{table: table}}
  end

  @impl true
  def save(client_id, session, %{table: table}) do
    :ets.insert(table, {client_id, session})
    :ok
  end

  @impl true
  def load(client_id, %{table: table}) do
    case :ets.lookup(table, client_id) do
      [{^client_id, session}] -> {:ok, session}
      [] -> :not_found
    end
  end

  @impl true
  def delete(client_id, %{table: table}) do
    :ets.delete(table, client_id)
    :ok
  end
end
