defmodule MqttX.WillRetainedE2ETest do
  @moduledoc """
  Wills and retained messages over real sockets, routed the way the server
  guide shows: `handle_publish/4` hands every message to
  `MqttX.Server.deliver/3`, and an MqttX client subscribes to it. Asserts
  what the subscriber receives, which a handler that only records its
  `handle_publish/4` calls cannot see.
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

  @user_properties [{"a", "2"}, {"c", "3"}]

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    {:ok, server} = MqttX.Server.start_link(Broker, [], port: port, name: :"will_e2e_#{port}")
    Process.sleep(50)

    {:ok, port: port, server: server}
  end

  defp connect(port, client_id, opts \\ []) do
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
    assert_receive {:mqtt_event, :connected, _}, 2_000
    client
  end

  # The socket closes with the process, without a DISCONNECT: the Will fires
  defp drop(client) do
    # connect/1 links the client to us
    Process.unlink(client)
    ref = Process.monitor(client)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^ref, :process, ^client, :killed}
  end

  defp stop(ctx, clients) do
    Enum.each(clients, &MqttX.Client.disconnect/1)
    Process.sleep(50)
    ThousandIsland.stop(ctx.server)
  end

  describe "Will Properties (§3.1.3.2)" do
    test "a Will with Will Properties reaches subscribers with them, less the Will Delay Interval",
         ctx do
      sub = connect(ctx.port, "will-sub")
      {:ok, [1]} = MqttX.Client.subscribe(sub, "will/props", qos: 1)

      dying =
        connect(ctx.port, "will-props",
          will_topic: "will/props",
          will_payload: "gone",
          will_qos: 1,
          will_properties: %{
            will_delay_interval: 0,
            content_type: "text/plain",
            user_properties: @user_properties
          }
        )

      drop(dying)

      assert_receive {:mqtt_event, :message, {["will", "props"], "gone", packet}}, 2_000
      # MQTT-3.1.3-10: the User Properties in their order
      assert packet.properties.user_properties == @user_properties
      assert packet.properties.content_type == "text/plain"
      # Will Delay Interval is a Will Property only (§2.2.2.2)
      refute Map.has_key?(packet.properties, :will_delay_interval)

      stop(ctx, [sub])
    end

    test "a delayed Will is delivered when its Will Delay Interval passes (MQTT-3.1.3-9)", ctx do
      sub = connect(ctx.port, "delay-sub")
      {:ok, [1]} = MqttX.Client.subscribe(sub, "will/delayed", qos: 1)

      dying =
        connect(ctx.port, "will-delayed",
          # The session must outlive the connection for the delay to apply
          connect_properties: %{session_expiry_interval: 30},
          will_topic: "will/delayed",
          will_payload: "late goodbye",
          will_qos: 1,
          will_properties: %{will_delay_interval: 1, user_properties: @user_properties}
        )

      drop(dying)

      refute_receive {:mqtt_event, :message, {["will", "delayed"], _, _}}, 500

      assert_receive {:mqtt_event, :message, {["will", "delayed"], "late goodbye", packet}},
                     2_000

      assert packet.properties.user_properties == @user_properties
      refute Map.has_key?(packet.properties, :will_delay_interval)

      stop(ctx, [sub])
    end
  end
end
