defmodule MqttX.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for client connections (used by server)
      {Registry, keys: :unique, name: MqttX.ClientRegistry},
      # Owner of the default session ETS table — must outlive any client.
      MqttX.Session.ETSOwner,
      # Owns Will Delay Interval timers across connection lifecycles.
      MqttX.Server.WillDelay,
      # Owns Session Expiry Interval timers across connection lifecycles.
      MqttX.Server.SessionExpiry,
      # client_id → connection pid, for §3.1.4-3 session takeover
      {Registry, keys: :duplicate, name: MqttX.Server.ConnectionRegistry},
      # Delivery across nodes: the :pg scope listeners group by name in, the
      # per-listener member registry, and the members' supervisor
      %{id: :mqttx_pg, start: {:pg, :start_link, [MqttX.Server.Cluster.scope()]}},
      {Registry, keys: :unique, name: MqttX.Server.Cluster.Registry},
      {DynamicSupervisor, name: MqttX.Server.Cluster.Supervisor, strategy: :one_for_one},
      # DynamicSupervisor for managed client connections
      MqttX.Client.Supervisor
    ]

    opts = [strategy: :one_for_one, name: MqttX.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
