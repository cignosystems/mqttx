defmodule MqttX.SessionPersistenceE2ETest do
  @moduledoc """
  Server-side sessions over real sockets: an MqttX client connects with Clean
  Start 0, drops, has messages delivered to its session meanwhile, and gets
  them — and `session_present: true` — when it reconnects.
  """
  use ExUnit.Case, async: false

  alias MqttX.Test.ForwardingHandler

  defmodule Broker do
    @moduledoc false
    use MqttX.Server

    @impl true
    def init(_opts), do: %{client_id: nil}

    @impl true
    def handle_connect(client_id, _credentials, state),
      do: {:ok, %{state | client_id: client_id}}

    # Authorization would go here; the fan-out is the broker's
    @impl true
    def handle_publish(topic, payload, opts, state) do
      MqttX.Server.deliver(topic, payload, Map.put(opts, :publisher, state.client_id))
      {:ok, state}
    end

    @impl true
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}

    @impl true
    def handle_disconnect(_reason, _state), do: :ok
  end

  @persistent [clean_session: false, connect_properties: %{session_expiry_interval: 300}]

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    name = :"session_e2e_#{port}"
    {:ok, server} = MqttX.Server.start_link(Broker, [], port: port, name: name)
    Process.sleep(50)

    {:ok, port: port, name: name, server: server}
  end

  defp connect(port, client_id, opts) do
    base = [
      host: "127.0.0.1",
      port: port,
      client_id: client_id,
      protocol_version: 5,
      await_connect: true,
      handler: ForwardingHandler,
      handler_state: %{pid: self()}
    ]

    {:ok, client} = MqttX.Client.connect(Keyword.merge(base, opts))
    client
  end

  # Disconnect and wait until the broker no longer counts the client as connected
  defp disconnect(client, port, client_id) do
    :ok = MqttX.Client.disconnect(client)
    key = {:"mqttx_retained_#{port}", client_id}

    Enum.find(1..100, fn _ ->
      Registry.lookup(MqttX.Server.ConnectionRegistry, key) == [] or
        (Process.sleep(10) && false)
    end) || flunk("broker still lists #{client_id} as connected")
  end

  defp await_acked(client) do
    Enum.find(1..200, fn _ ->
      :sys.get_state(client).pending_acks == %{} or (Process.sleep(10) && false)
    end) || flunk("publish never acknowledged")
  end

  test "a session resumes with its subscriptions and the messages delivered while it was away",
       ctx do
    sub = connect(ctx.port, "e2e-sub", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: false}}, 2_000
    {:ok, [1]} = MqttX.Client.subscribe(sub, "e2e/#", qos: 1)
    disconnect(sub, ctx.port, "e2e-sub")

    # Another client publishes, and the application delivers by listener name
    pub = connect(ctx.port, "e2e-pub", [])
    :ok = MqttX.Client.publish(pub, "e2e/1", "while away", qos: 1)
    :ok = MqttX.Client.publish(pub, "e2e/zero", "not queued", qos: 0)
    await_acked(pub)
    assert {:ok, 1} = MqttX.Server.deliver(ctx.name, "e2e/2", "from the app", %{qos: 1})

    # Back, without subscribing again
    sub = connect(ctx.port, "e2e-sub", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 2_000
    assert_receive {:mqtt_event, :message, {["e2e", "1"], "while away", _}}, 2_000
    assert_receive {:mqtt_event, :message, {["e2e", "2"], "from the app", _}}, 2_000
    refute_receive {:mqtt_event, :message, {["e2e", "zero"], _, _}}, 200

    :ok = MqttX.Client.publish(pub, "e2e/3", "live", qos: 1)
    assert_receive {:mqtt_event, :message, {["e2e", "3"], "live", _}}, 2_000

    # The publisher's own no_local-free subscription is untouched: nothing echoed
    refute_receive {:mqtt_event, :message, _}, 100

    MqttX.Client.disconnect(sub)
    MqttX.Client.disconnect(pub)
    Process.sleep(50)
    ThousandIsland.stop(ctx.server)
  end

  test "Clean Start 1 discards the session", ctx do
    sub = connect(ctx.port, "e2e-clean", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: false}}, 2_000
    {:ok, [1]} = MqttX.Client.subscribe(sub, "clean/#", qos: 1)
    disconnect(sub, ctx.port, "e2e-clean")

    assert {:ok, 1} = MqttX.Server.deliver(ctx.name, "clean/1", "queued", %{qos: 1})

    sub = connect(ctx.port, "e2e-clean", clean_session: true)
    assert_receive {:mqtt_event, :connected, %{session_present: false}}, 2_000
    refute_receive {:mqtt_event, :message, _}, 300

    MqttX.Client.disconnect(sub)
    Process.sleep(50)
    ThousandIsland.stop(ctx.server)
  end
end
