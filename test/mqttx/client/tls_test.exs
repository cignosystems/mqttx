defmodule MqttX.Client.TLSTest do
  @moduledoc """
  TLS on the client verifies by default (since 0.11.0): the broker certificate
  must chain to a trusted CA and match the host name. These tests run a real
  MqttX broker on ThousandIsland's SSL transport with the certificates under
  `test/fixtures/tls` — a private CA and a certificate for `localhost` only.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MqttX.Client.Connection
  alias MqttX.Test.ForwardingHandler

  @fixtures Path.expand("../../fixtures/tls", __DIR__)
  @ca Path.join(@fixtures, "ca.pem")

  defmodule Broker do
    @moduledoc false
    use MqttX.Server

    @impl true
    def init(opts), do: %{notify: Keyword.fetch!(opts, :notify)}

    @impl true
    def handle_connect(client_id, _credentials, state) do
      send(state.notify, {:server, :connect, client_id})
      {:ok, state}
    end

    @impl true
    def handle_publish(topic, payload, _opts, state) do
      send(state.notify, {:server, :publish, MqttX.Topic.flatten(topic), payload})
      {:ok, state}
    end

    @impl true
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}

    @impl true
    def handle_disconnect(_reason, _state), do: :ok
  end

  setup do
    port = free_port()

    {:ok, server} =
      MqttX.Server.start_link(Broker, [notify: self()],
        transport: MqttX.Transport.ThousandIsland,
        port: port,
        transport_module: ThousandIsland.Transports.SSL,
        transport_options: [
          certfile: Path.join(@fixtures, "server.pem"),
          keyfile: Path.join(@fixtures, "server-key.pem")
        ]
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

  defp connect(host, port, client_id, ssl_opts) do
    {:ok, client} =
      Connection.start_link(
        host: host,
        port: port,
        transport: :ssl,
        ssl_opts: ssl_opts,
        client_id: client_id,
        protocol_version: 5,
        handler: ForwardingHandler,
        handler_state: %{pid: self()}
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

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  test "connects when the certificate chains to the supplied CA and names the host",
       %{port: port} do
    client = connect("localhost", port, "tls-ok", cacertfile: @ca)

    assert :ok = Connection.await_connect(client, 5_000)
    assert_receive {:server, :connect, "tls-ok"}, 2_000

    # Traffic flows both ways over the encrypted socket: the PUBLISH reaches
    # the broker, its PUBACK clears our in-flight slot
    :ok = Connection.publish(client, "tls/t", "secret", qos: 1)
    assert_receive {:server, :publish, "tls/t", "secret"}, 2_000
    assert eventually(fn -> :sys.get_state(client).pending_acks == %{} end)
  end

  test "refuses a broker whose certificate is not signed by a trusted CA", %{port: port} do
    log =
      capture_log(fn ->
        # Default trust: the OS store, which has never heard of our CA
        client = connect("localhost", port, "tls-unknown-ca", [])
        assert {:error, {:tls_alert, {:unknown_ca, _}}} = Connection.await_connect(client, 5_000)
      end)

    assert log =~ "Connection failed"
    refute_received {:server, :connect, _}
  end

  test "refuses a certificate that does not name the host it connected to", %{port: port} do
    capture_log(fn ->
      # The certificate names `localhost`; 127.0.0.1 is the same machine but
      # not the same name
      client = connect("127.0.0.1", port, "tls-wrong-host", cacertfile: @ca)
      assert {:error, {:tls_alert, {alert, _}}} = Connection.await_connect(client, 5_000)
      assert alert in [:handshake_failure, :bad_certificate]
    end)

    refute_received {:server, :connect, _}
  end

  test "verify: :verify_none connects anyway and says so loudly", %{port: port} do
    log =
      capture_log(fn ->
        client = connect("127.0.0.1", port, "tls-insecure", verify: :verify_none)
        assert :ok = Connection.await_connect(client, 5_000)
      end)

    assert log =~ "verification is DISABLED"
    assert_receive {:server, :connect, "tls-insecure"}, 2_000
  end
end
