defmodule MqttX.Session.ETSStore do
  @moduledoc """
  ETS-based in-memory session store.

  The built-in `MqttX.Session.Store` implementation. Sessions live in an ETS
  table owned by a supervised process, so they survive a connection crash and
  persist for the lifetime of the BEAM VM. Session persistence is off unless
  you pass `:session_store` explicitly to `MqttX.Client.connect/1`.

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

  ## Expiry

  Records carry `expires_at` (see `MqttX.Session.Store`). `MqttX.Session.ETSOwner`
  sweeps every table it owns on an interval (default 60s, configurable with
  `config :mqttx, session_sweep_interval: ms`), deleting expired records;
  `sweep_expired/2` runs the same sweep on demand.

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

    # All tables (default and custom) are created via ETSOwner so they are
    # owned by a supervised, long-lived process. Creating them here would
    # make the *connection process* the owner — the table would die exactly
    # on the crash the session store exists to survive.
    if :ets.whereis(table) == :undefined do
      MqttX.Session.ETSOwner.ensure_table(table)
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

  @doc """
  Delete every session in `table` whose `expires_at` is at or before `now`
  (unix seconds). Returns the number of sessions deleted.

  Records without an integer `expires_at` (pre-5 sessions, `0xFFFFFFFF`, or
  records written before expiry was tracked) are never swept.
  """
  @spec sweep_expired(atom() | :ets.tid(), integer()) :: non_neg_integer()
  def sweep_expired(table, now \\ System.system_time(:second)) do
    :ets.select_delete(table, [
      {{:_, %{expires_at: :"$1"}}, [{:is_integer, :"$1"}, {:"=<", :"$1", now}], [true]}
    ])
  end
end
