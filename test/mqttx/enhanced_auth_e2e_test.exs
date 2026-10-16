defmodule MqttX.EnhancedAuthE2ETest do
  @moduledoc """
  MQTT 5.0 enhanced authentication (§4.12) end to end: a real MqttX broker over
  TCP whose handler runs a toy challenge–response mechanism, and a real MqttX
  client whose handler answers it. The exchange runs before CONNACK; a wrong
  proof is refused with CONNACK 0x87 and reaches the client as a connack_error.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MqttX.Client.Connection

  @method "TOY-NONCE"

  defmodule Broker do
    @moduledoc false
    use MqttX.Server

    @impl true
    def init(opts), do: %{notify: Keyword.fetch!(opts, :notify), nonce: nil}

    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    @impl true
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}

    @impl true
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}

    @impl true
    def handle_disconnect(_reason, _state), do: :ok

    # The mechanism: challenge with a fresh nonce, accept "proof:" <> nonce
    @impl true
    def handle_auth("TOY-NONCE", nil, state) do
      nonce = Base.encode16(:crypto.strong_rand_bytes(8))
      {:continue, nonce, %{state | nonce: nonce}}
    end

    def handle_auth("TOY-NONCE", proof, %{nonce: nonce} = state) when is_binary(nonce) do
      if proof == "proof:" <> nonce do
        send(state.notify, {:broker, :authenticated})
        {:ok, "server-ok", state}
      else
        send(state.notify, {:broker, :rejected})
        {:error, 0x87, state}
      end
    end

    def handle_auth(_other_method, _data, state), do: {:error, 0x8C, state}
  end

  defmodule ClientHandler do
    @moduledoc false
    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end

    def handle_auth(0x18, %{authentication_data: nonce}, %{proof: proof} = state) do
      {:continue, proof.(nonce), state}
    end
  end

  setup do
    port = free_port()

    {:ok, server} =
      MqttX.Server.start_link(Broker, [notify: self()],
        transport: MqttX.Transport.ThousandIsland,
        port: port
      )

    on_exit(fn ->
      try do
        ThousandIsland.stop(server)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, port: port}
  end

  defp free_port do
    {:ok, s} = :gen_tcp.listen(0, [])
    {:ok, p} = :inet.port(s)
    :gen_tcp.close(s)
    p
  end

  defp connect(port, client_id, proof) do
    {:ok, client} =
      Connection.start_link(
        host: "localhost",
        port: port,
        client_id: client_id,
        protocol_version: 5,
        connect_properties: %{authentication_method: @method},
        handler: ClientHandler,
        handler_state: %{pid: self(), proof: proof}
      )

    on_exit(fn ->
      try do
        GenServer.stop(client, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    client
  end

  test "the client answers the broker's challenge; CONNACK carries the method and final data",
       %{port: port} do
    client = connect(port, "e2e-auth-ok", fn nonce -> "proof:" <> nonce end)

    assert :ok = Connection.await_connect(client, 5_000)
    assert_receive {:broker, :authenticated}, 2_000
    assert_receive {:mqtt_event, :connected, %{properties: props}}, 2_000
    assert props.authentication_method == @method
    assert props.authentication_data == "server-ok"

    # The session really is up
    assert {:ok, [1]} = Connection.subscribe(client, "e2e/#", qos: 1)
  end

  test "a wrong proof is refused with CONNACK 0x87 Not authorized", %{port: port} do
    capture_log(fn ->
      client = connect(port, "e2e-auth-bad", fn _nonce -> "proof:forged" end)

      assert {:error, {:connack_error, 0x87, _}} = Connection.await_connect(client, 5_000)
      assert_receive {:broker, :rejected}, 2_000
      assert_receive {:mqtt_event, :disconnected, {:connack_error, 0x87, _}}, 2_000
    end)
  end
end
