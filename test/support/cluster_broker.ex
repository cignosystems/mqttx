defmodule MqttX.Test.ClusterBroker do
  @moduledoc """
  A broker handler that fans every publish out through
  `MqttX.Server.deliver/3`, compiled under `test/support` so peer nodes
  started by the cluster tests can load it from the code path.
  """
  use MqttX.Server

  @impl true
  def init(_opts), do: %{client_id: nil}

  @impl true
  def handle_connect(client_id, _credentials, state), do: {:ok, %{state | client_id: client_id}}

  @impl true
  def handle_publish(topic, payload, opts, state) do
    {:ok, _} = MqttX.Server.deliver(topic, payload, Map.put(opts, :publisher, state.client_id))
    {:ok, state}
  end

  @impl true
  def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}

  @impl true
  def handle_disconnect(_reason, _state), do: :ok

  @doc """
  Start a listener on this node and keep it alive from a process that is not
  the caller — a listener started straight from an `:rpc` call would die
  with the call.
  """
  def start_listener(name, port, opts \\ []) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, server} =
          MqttX.Server.start_link(__MODULE__, [], [port: port, name: name] ++ opts)

        send(parent, {:listener_started, server})
        Process.sleep(:infinity)
      end)

    receive do
      {:listener_started, server} -> {:ok, server, pid}
    after
      5_000 -> {:error, :timeout}
    end
  end
end
