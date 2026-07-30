defmodule MqttX do
  @moduledoc """
  MqttX — Fast, pure Elixir MQTT 5.0 — client, server, and codec in one package.

  Key features:
  - High-performance packet codec
  - Transport-agnostic server/broker
  - Modern client with automatic reconnection

  **[See full documentation, installation guide, and examples →](readme.html)**

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
        transport: MqttX.Transport.ThousandIsland,
        port: 1883
      )

  ### Client

      # connect/1 is asynchronous; await_connect: true blocks until the
      # session is live so the calls below work inline.
      {:ok, client} = MqttX.Client.connect(
        host: "localhost",
        port: 1883,
        client_id: "my_client",
        await_connect: true
      )

      {:ok, _granted} = MqttX.Client.subscribe(client, "sensors/#", qos: 1)
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
  Returns the library version (read from the `:mqttx` app spec, never hardcoded).
  """
  @spec version :: String.t()
  def version do
    case Application.spec(:mqttx, :vsn) do
      nil -> "unknown"
      vsn -> List.to_string(vsn)
    end
  end

  @doc """
  Defines a module-based MQTT client (see `MqttX.SimpleClient` for the full
  callback documentation).

      defmodule MyClient do
        use MqttX

        @impl true
        def handle_message(topic, payload, _packet, state) do
          publish("ack/" <> Enum.join(topic, "/"), payload, qos: 1)
          {:ok, state}
        end
      end

      children = [{MyClient, host: "broker.example.com", client_id: "my-client"}]
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour MqttX.SimpleClient

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          restart: :transient,
          type: :worker
        }
      end

      def start_link(opts \\ []) do
        MqttX.SimpleClient.start_link(__MODULE__, opts)
      end

      @doc "Publish via this client (safe to call from inside callbacks)."
      def publish(topic, payload, opts \\ []),
        do: MqttX.SimpleClient.publish(__MODULE__, topic, payload, opts)

      @doc "Subscribe via this client (safe to call from inside callbacks)."
      def subscribe(topics, opts \\ []),
        do: MqttX.SimpleClient.subscribe(__MODULE__, topics, opts)

      @doc "Unsubscribe via this client."
      def unsubscribe(topics), do: MqttX.SimpleClient.unsubscribe(__MODULE__, topics)

      @doc "Whether the underlying connection is currently established."
      def connected?, do: MqttX.SimpleClient.connected?(__MODULE__)

      @doc "Disconnect from the broker and stop the client."
      def disconnect(opts \\ []), do: MqttX.SimpleClient.disconnect(__MODULE__, opts)

      # Default (overridable) callbacks
      @impl MqttX.SimpleClient
      def init(_opts), do: {:ok, %{}}

      @impl MqttX.SimpleClient
      def handle_message(_topic, _payload, _packet, state), do: {:ok, state}

      @impl MqttX.SimpleClient
      def handle_connected(_info, state), do: {:ok, state}

      @impl MqttX.SimpleClient
      def handle_disconnected(_reason, state), do: {:ok, state}

      @impl MqttX.SimpleClient
      def handle_publish_error(_topic, _packet_id, _reason_code, state), do: {:ok, state}

      @impl MqttX.SimpleClient
      def handle_info(_message, state), do: {:ok, state}

      defoverridable init: 1,
                     handle_message: 4,
                     handle_connected: 2,
                     handle_disconnected: 2,
                     handle_publish_error: 4,
                     handle_info: 2,
                     child_spec: 1
    end
  end
end
