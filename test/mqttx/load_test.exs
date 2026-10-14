defmodule MqttX.LoadTest do
  @moduledoc """
  End-to-end load validation: many clients, many messages, real sockets.
  Excluded by default (`mix test --include load`) — it takes a few seconds
  and its time bounds are deliberately loose. It asserts completeness (every
  message arrives exactly as many times as it should, every QoS 1 publish is
  acknowledged, nothing disconnects), not raw speed; `bench/e2e.exs` is for
  numbers.
  """
  use ExUnit.Case, async: false
  @moduletag :load
  @moduletag timeout: 120_000

  defmodule Broker do
    use MqttX.Server

    def init(opts), do: %{counter: Keyword.fetch!(opts, :counter)}

    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    @impl true
    def handle_subscribe(topics, state) do
      Registry.register(MqttX.LoadTest.Registry, :subscribers, nil)
      {:ok, Enum.map(topics, & &1.qos), state}
    end

    @impl true
    def handle_publish(["load", "fanout" | _] = topic, payload, opts, state) do
      :counters.add(state.counter, 1, 1)

      Registry.dispatch(MqttX.LoadTest.Registry, :subscribers, fn entries ->
        for {pid, _} <- entries, do: send(pid, {:fanout, topic, payload, opts.qos})
      end)

      {:ok, state}
    end

    def handle_publish(_topic, _payload, _opts, state) do
      :counters.add(state.counter, 1, 1)
      {:ok, state}
    end

    @impl true
    def handle_info({:fanout, topic, payload, qos}, state) do
      {:publish, topic, payload, %{qos: qos, retain: false}, state}
    end

    @impl true
    def handle_disconnect(_reason, _state), do: :ok
  end

  defmodule ClientHandler do
    def handle_mqtt_event(:message, {_topic, payload, _packet}, state) do
      :counters.add(state.counter, 1, 1)
      :counters.add(state.bytes, 1, byte_size(payload))
      state
    end

    def handle_mqtt_event(:disconnected, reason, state) do
      send(state.test, {:disconnected, reason})
      state
    end

    def handle_mqtt_event(_event, _data, state), do: state
  end

  @publishers 20
  @messages_per_publisher 250
  @subscribers 20
  @fanout_messages 500
  @payload :binary.copy(<<"m">>, 256)

  setup do
    {:ok, _} = Registry.start_link(keys: :duplicate, name: MqttX.LoadTest.Registry)
    received = :counters.new(1, [:write_concurrency])

    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    {:ok, server} =
      MqttX.Server.start_link(Broker, [counter: received],
        port: port,
        transport: MqttX.Transport.ThousandIsland
      )

    Process.sleep(100)

    {:ok, port: port, received: received, server: server}
  end

  # Clients first, then the listener — in the test body rather than on_exit,
  # because the server is linked to the test process and is already stopping
  # by the time on_exit callbacks run
  defp teardown(clients, server) do
    Enum.each(clients, &MqttX.Client.disconnect/1)
    Process.sleep(100)
    ThousandIsland.stop(server)
  end

  defp connect(port, client_id, counters) do
    {:ok, client} =
      MqttX.Client.connect(
        host: "127.0.0.1",
        port: port,
        client_id: client_id,
        protocol_version: 5,
        await_connect: true,
        handler: ClientHandler,
        handler_state: Map.put(counters, :test, self())
      )

    client
  end

  defp counters, do: %{counter: :counters.new(1, []), bytes: :counters.new(1, [])}

  defp await(counter, target, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> :counters.get(counter, 1) end)
    |> Enum.find(fn count ->
      count >= target or System.monotonic_time(:millisecond) > deadline or
        (Process.sleep(5) && false)
    end)
  end

  # Publish, waiting out client-side flow control rather than giving up
  defp publish!(client, topic, payload, qos) do
    case MqttX.Client.publish(client, topic, payload, qos: qos) do
      :ok ->
        :ok

      {:error, :flow_control} ->
        Process.sleep(1)
        publish!(client, topic, payload, qos)
    end
  end

  test "concurrent QoS 1 publishers: every message arrives once and is acknowledged",
       %{port: port, received: received, server: server} do
    clients = for i <- 1..@publishers, do: connect(port, "load-pub-#{i}", counters())

    tasks =
      for client <- clients do
        Task.async(fn ->
          for _ <- 1..@messages_per_publisher, do: publish!(client, "load/uplink", @payload, 1)
        end)
      end

    Enum.each(tasks, &Task.await(&1, 60_000))
    expected = @publishers * @messages_per_publisher

    assert await(received, expected, 30_000) == expected,
           "broker received #{:counters.get(received, 1)} of #{expected} messages"

    # Every QoS 1 publish must be acknowledged — nothing left in flight
    Process.sleep(200)

    for client <- clients do
      assert :sys.get_state(client).pending_acks == %{}
    end

    refute_received {:disconnected, _}
    teardown(clients, server)
  end

  test "fan-out: every subscriber gets every message, intact",
       %{port: port, server: server} do
    subscriber_counters = for _ <- 1..@subscribers, do: counters()

    subscribers =
      for {c, i} <- Enum.with_index(subscriber_counters, 1) do
        client = connect(port, "load-sub-#{i}", c)
        {:ok, [0]} = MqttX.Client.subscribe(client, "load/fanout/#", qos: 0)
        client
      end

    publisher = connect(port, "load-fanout-pub", counters())
    for _ <- 1..@fanout_messages, do: publish!(publisher, "load/fanout/t", @payload, 0)

    for c <- subscriber_counters do
      assert await(c.counter, @fanout_messages, 30_000) == @fanout_messages
      assert :counters.get(c.bytes, 1) == @fanout_messages * byte_size(@payload)
    end

    refute_received {:disconnected, _}
    teardown([publisher | subscribers], server)
  end
end
