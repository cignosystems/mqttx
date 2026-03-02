defmodule MqttX.Client.Supervisor do
  @moduledoc """
  DynamicSupervisor for managing client connection lifecycles.

  Provides supervised client connections with automatic restart on crash.
  Use `MqttX.Client.connect_supervised/1` to start connections under this supervisor.

  ## Example

      {:ok, pid} = MqttX.Client.connect_supervised(
        host: "localhost",
        port: 1883,
        client_id: "my_client"
      )

      # List all supervised connections
      MqttX.Client.list()

      # Look up by client_id
      MqttX.Client.whereis("my_client")
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a supervised client connection.
  """
  @spec start_child(keyword()) :: DynamicSupervisor.on_start_child()
  def start_child(opts) do
    spec = {MqttX.Client.Connection, opts}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Stop a supervised client connection.
  """
  @spec stop_child(pid()) :: :ok | {:error, :not_found}
  def stop_child(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc """
  Count supervised connections.
  """
  @spec count() :: map()
  def count do
    DynamicSupervisor.count_children(__MODULE__)
  end

  @doc """
  List supervised connections.
  """
  @spec which_children() :: [{:undefined, pid() | :restarting, :worker | :supervisor, [module()]}]
  def which_children do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
