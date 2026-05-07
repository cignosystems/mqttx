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
      # DynamicSupervisor for managed client connections
      MqttX.Client.Supervisor
    ]

    opts = [strategy: :one_for_one, name: MqttX.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
