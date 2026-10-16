defmodule MqttX.Server do
  @moduledoc """
  MQTT Server behaviour.

  Implement this behaviour to create a custom MQTT server/broker.

  ## Example

      defmodule MyApp.MqttHandler do
        use MqttX.Server

        @impl true
        def init(_opts) do
          %{subscriptions: %{}}
        end

        @impl true
        def handle_connect(client_id, credentials, state) do
          IO.puts("Client connected: " <> client_id)
          {:ok, state}
        end

        @impl true
        def handle_publish(topic, payload, opts, state) do
          IO.puts("Received: " <> inspect({topic, payload}))
          {:ok, state}
        end

        @impl true
        def handle_subscribe(topics, state) do
          qos_list = Enum.map(topics, fn t -> t.qos end)
          {:ok, qos_list, state}
        end

        @impl true
        def handle_disconnect(reason, state) do
          IO.puts("Client disconnected: " <> inspect(reason))
          :ok
        end
      end

      # Start the server
      MqttX.Server.start_link(MyApp.MqttHandler, [],
        transport: MqttX.Transport.ThousandIsland,
        port: 1883
      )

  ## Callbacks

  The following callbacks are required:

  - `init/1` - Initialize handler state
  - `handle_connect/3` - Handle client connection
  - `handle_publish/4` - Handle incoming PUBLISH messages
  - `handle_subscribe/2` - Handle SUBSCRIBE requests
  - `handle_disconnect/2` - Handle client disconnection

  Optional callbacks:

  - `handle_connect/4` - Like `handle_connect/3` but also receives connection
    info (protocol version, keepalive); preferred when defined
  - `handle_unsubscribe/2` - Handle UNSUBSCRIBE requests
  - `handle_puback/2` - Handle PUBACK/PUBCOMP for QoS 1/2 messages
  - `handle_info/2` - Handle arbitrary messages sent to the connection process
  - `handle_auth/3` - Enhanced authentication exchange (MQTT 5.0 AUTH)
  - `handle_session_expired/2` - Session expiry notification (MQTT 5.0)

  ## Session state limitation

  Session state (subscriptions, in-flight QoS 1/2 messages) currently lives
  in the connection process and dies with it: the broker does not queue
  messages for disconnected persistent sessions, and reconnecting clients
  always receive `session_present: false`. Model durable state in your
  handler (e.g. via `Phoenix.PubSub` or your database) if you need
  persistence across connections.
  """

  require Logger

  @type client_id :: binary()
  @type credentials :: %{username: binary() | nil, password: binary() | nil}
  @type topic :: MqttX.Topic.normalized_topic()
  @type payload :: binary()
  @type publish_opts :: %{
          qos: 0 | 1 | 2,
          retain: boolean(),
          dup: boolean(),
          packet_id: non_neg_integer() | nil,
          properties: map()
        }
  @type subscribe_topic :: %{
          topic: topic(),
          qos: 0 | 1 | 2,
          no_local: boolean(),
          retain_as_published: boolean(),
          retain_handling: 0 | 1 | 2
        }
  @type reason_code :: non_neg_integer()
  @type state :: term()

  @doc """
  Initialize the handler state.

  Called when starting the server.
  """
  @callback init(opts :: term()) :: state()

  @doc """
  Handle a client connection.

  Called when a client sends a CONNECT packet.

  Return `{:ok, new_state}` to accept the connection,
  or `{:error, reason_code, new_state}` to reject.
  """
  @callback handle_connect(client_id(), credentials(), state()) ::
              {:ok, state()} | {:error, reason_code(), state()}

  @type connect_info :: %{
          protocol_version: 3 | 4 | 5,
          keep_alive: non_neg_integer(),
          authentication_method: binary() | nil
        }

  @doc """
  Handle a client connection with connection metadata.

  Same as `handle_connect/3` but receives an additional `connect_info` map
  with protocol metadata:

    - `protocol_version` — 3 (MQTT 3.1), 4 (MQTT 3.1.1), or 5 (MQTT 5.0)
    - `keep_alive` — client's requested keepalive in seconds
    - `authentication_method` — the MQTT 5.0 Authentication Method the client
      asked for, or `nil`. When set, `handle_auth/3` runs after this callback
      accepts, and the CONNACK waits for that exchange (§4.12)

  If both `handle_connect/4` and `handle_connect/3` are defined,
  `handle_connect/4` takes precedence.

  Two notes that apply to both arities. A client that sent a zero-length
  Client Identifier arrives here with the one the broker assigned (§3.1.3.1;
  v5 clients learn it from the CONNACK). And the reason code of an
  `{:error, reason_code, state}` refusal is an MQTT 5.0 code: for a 3.1.1
  client it is mapped to the nearest CONNACK return code — `0x84` → 1,
  `0x85` → 2, `0x86` → 4, `0x87` and anything else → 5, server
  unavailable/busy/redirect codes → 3 — and a v5 client only ever receives a
  code the CONNACK defines (others become `0x80`).
  """
  @callback handle_connect(client_id(), credentials(), connect_info(), state()) ::
              {:ok, state()} | {:error, reason_code(), state()}

  @doc """
  Handle an incoming PUBLISH message.

  Called when a client publishes a message. `{:error, reason, state}` refuses
  it — but the message is still acknowledged (MQTT-3.3.4-1), or the publisher
  would hold its Packet Identifier in flight forever. A QoS 1 PUBLISH gets a
  PUBACK whose MQTT 5.0 Reason Code reflects `reason`: `0x87` Not authorized
  for `:unauthorized`, `:not_authorized` or `:forbidden`; `0x97` for
  `:quota_exceeded`; `0x90` for `:topic_name_invalid`; `0x99` for
  `:payload_format_invalid`; an integer that is itself a PUBACK code as given;
  anything else `0x80`. A pre-5 PUBACK has no code. A QoS 2 PUBLISH is
  completed with PUBCOMP at PUBREL. `{:disconnect, ...}` ends the connection
  instead, which also publishes the client's Will.
  """
  @callback handle_publish(topic(), payload(), publish_opts(), state()) ::
              {:ok, state()}
              | {:error, term(), state()}
              | {:disconnect, reason_code(), state()}
              | {:disconnect, reason_code(), map(), state()}

  @doc """
  Handle a SUBSCRIBE request.

  Returns one grant per requested topic, in order: `0`, `1`, or `2` accepts
  the subscription at that QoS; a reason code `>= 0x80` (e.g. `0x87` Not
  authorized) rejects that topic in the SUBACK — the rejected filter gets no
  retained delivery and is not added to the connection's routing index.
  """
  @callback handle_subscribe([subscribe_topic()], state()) ::
              {:ok, [0 | 1 | 2 | reason_code()], state()}
              | {:disconnect, reason_code(), state()}
              | {:disconnect, reason_code(), map(), state()}

  @doc """
  Handle client disconnection.

  Called when the client disconnects or the connection is closed.
  """
  @callback handle_disconnect(reason :: term(), state()) :: :ok

  @doc """
  Handle an UNSUBSCRIBE request.
  """
  @callback handle_unsubscribe([topic()], state()) ::
              {:ok, state()}
              | {:disconnect, reason_code(), state()}
              | {:disconnect, reason_code(), map(), state()}

  @doc """
  Handle a PUBACK for QoS 1 messages.
  """
  @callback handle_puback(packet_id :: non_neg_integer(), state()) :: {:ok, state()}

  @doc """
  Drive an MQTT 5.0 enhanced authentication exchange (§4.12).

  A client opts in by sending an Authentication Method in its CONNECT. Once
  `handle_connect` has accepted, this callback is called with that method and
  the CONNECT's Authentication Data (the mechanism's first client message,
  `nil` if there was none), and then once more for every AUTH packet the
  client sends in reply to a challenge. The CONNACK is not sent until the
  exchange ends. The same callback serves re-authentication on a live
  connection (§4.12.1), where success is answered with AUTH 0x00 instead of a
  CONNACK.

  Return values:
  - `{:ok, state}` - Authentication complete: CONNACK success (or AUTH 0x00)
  - `{:ok, data, state}` - Complete, with `data` as the mechanism's final
    server message (e.g. a SCRAM server-final) carried in the CONNACK/AUTH
  - `{:continue, data, state}` - Send AUTH 0x18 carrying `data` as a challenge
    and wait for the client's answer
  - `{:error, reason_code, state}` - Authentication failed: CONNACK with
    `reason_code` (DISCONNECT when re-authenticating) and the connection
    closes. `0x87` Not authorized and `0x8C` Bad authentication method are the
    usual codes

  The default implementation returns `{:error, 0x8C, state}`, so a client that
  asks for enhanced authentication against a handler without it is refused
  rather than silently connected. The mechanism itself (SCRAM, a token
  exchange, …) is the handler's to implement.

  ## Example

      def handle_auth("SCRAM-SHA-256", client_first, %{scram: nil} = state) do
        {challenge, scram} = MyScram.server_first(client_first)
        {:continue, challenge, %{state | scram: scram}}
      end

      def handle_auth("SCRAM-SHA-256", client_final, %{scram: scram} = state) do
        case MyScram.verify(scram, client_final) do
          {:ok, server_final} -> {:ok, server_final, %{state | scram: nil}}
          :error -> {:error, 0x87, %{state | scram: nil}}
        end
      end

      def handle_auth(_other_method, _data, state), do: {:error, 0x8C, state}
  """
  @callback handle_auth(method :: binary(), data :: binary() | nil, state()) ::
              {:ok, state()}
              | {:ok, binary(), state()}
              | {:continue, binary(), state()}
              | {:error, reason_code(), state()}

  @doc """
  Handle custom messages (e.g., from PubSub for outgoing MQTT publishes).

  Return values:
  - `{:ok, state}` - Continue with updated state
  - `{:publish, topic, payload, state}` - Send PUBLISH to client, then continue
  - `{:publish, topic, payload, opts, state}` - Send PUBLISH with options:
    `:qos`, `:retain`, `:properties`, and `:codec` — a `MqttX.Payload`
    module that encodes `payload` (a term) and adds its
    `payload_format_indicator` / `content_type` to the properties
  - `{:disconnect, reason_code, state}` - Send DISCONNECT and close connection
  - `{:disconnect, reason_code, properties, state}` - Send DISCONNECT with properties and close
  - `{:stop, reason, state}` - Close the connection

  ## Publish routing

  A `{:publish, ...}` return is matched against the client's subscriptions,
  and each matching subscription's options are applied to the delivery:

  - QoS is capped at the granted QoS (§3.8.4)
  - the `retain` opt is forwarded only if the subscription set
    Retain As Published; otherwise the flag is cleared (§3.3.1.3)
  - the subscription's Subscription Identifier(s) are attached (§3.3.4)
  - pass `publisher: originating_client_id` in `opts` to honor `no_local`
    subscriptions: delivery is suppressed when the originating client is this
    client (§3.8.3.1). The key is stripped before sending.

  A publish that matches none of the client's subscriptions is sent as-is
  (QoS and retain taken verbatim from `opts`), preserving the behavior of
  releases before 0.12 for brokers that make delivery decisions themselves.

  Exit signals from processes the handler linked to (`{:EXIT, pid, reason}`)
  are not delivered here: a `:normal` exit is ignored, any other closes the
  connection and `handle_disconnect/2` receives `{:linked_process_exit, reason}`.
  """
  @callback handle_info(message :: term(), state()) ::
              {:ok, state()}
              | {:publish, binary(), binary(), state()}
              | {:publish, binary(), binary(), map(), state()}
              | {:disconnect, reason_code(), state()}
              | {:disconnect, reason_code(), map(), state()}
              | {:stop, term(), state()}

  @doc """
  Handle session expiry (MQTT 5.0).

  Called when a client's session expires after `session_expiry_interval` seconds
  post-disconnect. Use this to clean up session state (subscriptions, queued messages, etc.).
  """
  @callback handle_session_expired(client_id(), state()) :: :ok

  @optional_callbacks [
    handle_connect: 4,
    handle_unsubscribe: 2,
    handle_puback: 2,
    handle_info: 2,
    handle_auth: 3,
    handle_session_expired: 2
  ]

  @doc """
  Use MqttX.Server to define default implementations.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour MqttX.Server

      @impl true
      def handle_unsubscribe(_topics, state) do
        {:ok, state}
      end

      @impl true
      def handle_puback(_packet_id, state) do
        {:ok, state}
      end

      @impl true
      def handle_info(_message, state) do
        {:ok, state}
      end

      @impl true
      def handle_auth(_method, _data, state) do
        # Default: enhanced auth not supported
        {:error, 0x8C, state}
      end

      @impl true
      def handle_session_expired(_client_id, _state) do
        :ok
      end

      defoverridable handle_unsubscribe: 2,
                     handle_puback: 2,
                     handle_info: 2,
                     handle_auth: 3,
                     handle_session_expired: 2
    end
  end

  @doc """
  Disconnect a client from the server with an MQTT 5.0 reason code.

  Sends a DISCONNECT packet to the client and closes the connection.
  The `pid` is the transport process handling the client connection.

  A close the broker initiates is not a graceful one: the client's Will, if
  it set one, is published (§3.1.2.5 — only a client DISCONNECT 0x00 discards
  it). A `session_expiry_interval` in `properties` is dropped, since only
  clients may send it (MQTT-3.14.2-2).

  ## Example

      MqttX.Server.disconnect(client_pid, 0x98)  # Use assigned client identifier
      MqttX.Server.disconnect(client_pid, 0x89, %{reason_string: "Session taken over"})
  """
  @spec disconnect(pid(), reason_code(), map()) :: :ok
  def disconnect(pid, reason_code, properties \\ %{}) do
    send(pid, {:server_disconnect, reason_code, properties})
    :ok
  end

  @doc """
  Start an MQTT server.

  ## Options

  - `:transport` - Transport module (default: `MqttX.Transport.ThousandIsland`)
  - `:port` - Port to listen on (default: 1883)

  All other options are passed to the transport adapter.
  """
  @spec start_link(module(), term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(handler, handler_opts, opts \\ []) do
    warn_deprecated_transport_opts(handler_opts)
    transport = Keyword.get(opts, :transport, MqttX.Transport.ThousandIsland)
    transport_opts = Keyword.drop(opts, [:name])

    transport.start_link(handler, handler_opts, transport_opts)
  end

  # Retransmission knobs from before 0.12.0. Still accepted so existing
  # configs keep starting; see the CHANGELOG for the removal plan.
  @deprecated_transport_opts [:qos2_retry_interval, :qos2_max_retries]

  defp warn_deprecated_transport_opts(handler_opts) when is_list(handler_opts) do
    transport_opts = Keyword.get(handler_opts, :transport_opts, %{})

    present =
      if is_map(transport_opts),
        do: Enum.filter(@deprecated_transport_opts, &Map.has_key?(transport_opts, &1)),
        else: []

    if present != [] do
      Logger.warning(
        "[MqttX.Server] deprecated transport_opts ignored since 0.12.0: " <>
          Enum.map_join(present, " and ", &inspect/1) <>
          ". The broker does not re-send QoS 1/2 packets on a live connection " <>
          "(MQTT §4.4); remove them."
      )
    end
  end

  defp warn_deprecated_transport_opts(_handler_opts), do: :ok
end
