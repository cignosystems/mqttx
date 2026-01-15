defmodule MqttX do
  @moduledoc """
  MqttX - Pure Elixir MQTT 3.1.1/5.0 Library

  A comprehensive MQTT library featuring:
  - High-performance packet codec
  - Transport-agnostic server/broker
  - Modern client with automatic reconnection

  ## Quick Start

  ### Server

      defmodule MyApp.MqttHandler do
        use MqttX.Server

        @impl true
        def handle_connect(client_id, credentials, state) do
          {:ok, Map.put(state, :client_id, client_id)}
        end

        @impl true
        def handle_publish(topic, payload, opts, state) do
          IO.inspect({topic, payload}, label: "Received")
          {:ok, state}
        end
      end

      # Start server
      MqttX.Server.start_link(MyApp.MqttHandler, [],
        transport: :thousand_island,
        port: 1883
      )

  ### Client

      {:ok, client} = MqttX.Client.connect(
        host: "localhost",
        port: 1883,
        client_id: "my_client"
      )

      :ok = MqttX.Client.subscribe(client, "sensors/#", qos: 1)
      :ok = MqttX.Client.publish(client, "sensors/temp", "25.5", qos: 0)

  ### Packet Codec

      # Encode
      packet = %{type: :publish, topic: "test", payload: "hello", qos: 0, retain: false}
      {:ok, binary} = MqttX.Packet.encode(4, packet)

      # Decode
      {:ok, {decoded, rest}} = MqttX.Packet.decode(4, binary)

  ## Protocol Versions

  - MQTT 3.1 (version 3)
  - MQTT 3.1.1 (version 4)
  - MQTT 5.0 (version 5)
  """

  @type mqtt_version :: 3 | 4 | 5
  @type qos :: 0 | 1 | 2
  @type topic :: binary() | [binary() | :single_level | :multi_level]
  @type packet_type ::
          :connect
          | :connack
          | :publish
          | :puback
          | :pubrec
          | :pubrel
          | :pubcomp
          | :subscribe
          | :suback
          | :unsubscribe
          | :unsuback
          | :pingreq
          | :pingresp
          | :disconnect
          | :auth

  @doc """
  Returns the library version.
  """
  @spec version :: String.t()
  def version, do: "0.1.3"
end
