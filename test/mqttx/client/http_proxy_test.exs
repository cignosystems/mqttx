defmodule MqttX.Client.HttpProxyTest do
  # Tests for the HTTP CONNECT proxy option (GitHub issue #2): the client
  # tunnels through a forward proxy before MQTT bytes flow.
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec

  defmodule Forwarder do
    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end
  end

  # A minimal CONNECT proxy that records the request, replies with the
  # configured status, and (on 200) then behaves as a scripted MQTT broker.
  defp start_proxy(parent, status_line) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    pid =
      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        request = recv_until_blank_line(sock, <<>>)
        send(parent, {:proxy_request, request})
        :ok = :gen_tcp.send(sock, status_line <> "\r\n\r\n")

        if String.contains?(status_line, "200") do
          # Now act as the broker behind the tunnel
          {%{type: :connect} = connect, _buf} = recv_packet(sock, <<>>)
          send(parent, {:broker_connect, connect})

          {:ok, connack} =
            Codec.encode(5, %{
              type: :connack,
              session_present: false,
              reason_code: 0,
              properties: %{}
            })

          :ok = :gen_tcp.send(sock, connack)

          receive do
            :stop -> :gen_tcp.close(sock)
          after
            10_000 -> :gen_tcp.close(sock)
          end
        else
          :gen_tcp.close(sock)
        end
      end)

    {pid, port, listen}
  end

  test "tunnels MQTT through an HTTP CONNECT proxy with Basic auth" do
    {proxy, proxy_port, listen} = start_proxy(self(), "HTTP/1.1 200 Connection established")

    {:ok, client} =
      MqttX.Client.Connection.start_link(
        host: "target.example.com",
        port: 1883,
        proxy: [host: "localhost", port: proxy_port, auth: {"user", "pass"}],
        client_id: "proxy-test",
        protocol_version: 5,
        handler: Forwarder,
        handler_state: %{pid: self()}
      )

    # The proxy saw a well-formed CONNECT request for the *target*
    assert_receive {:proxy_request, request}, 5_000
    assert request =~ "CONNECT target.example.com:1883 HTTP/1.1"
    assert request =~ "Host: target.example.com:1883"
    assert request =~ "Proxy-Authorization: Basic #{Base.encode64("user:pass")}"

    # MQTT flowed through the tunnel
    assert_receive {:broker_connect, %{client_id: "proxy-test"}}, 5_000
    assert_receive {:mqtt_event, :connected, _}, 5_000
    assert MqttX.Client.Connection.connected?(client)

    send(proxy, :stop)
    GenServer.stop(client, :normal, 1_000)
    :gen_tcp.close(listen)
  end

  test "no Proxy-Authorization header without auth" do
    {proxy, proxy_port, listen} = start_proxy(self(), "HTTP/1.1 200 Connection established")

    {:ok, client} =
      MqttX.Client.Connection.start_link(
        host: "target.example.com",
        port: 1883,
        proxy: [host: "localhost", port: proxy_port],
        client_id: "proxy-noauth",
        protocol_version: 5,
        handler: Forwarder,
        handler_state: %{pid: self()}
      )

    assert_receive {:proxy_request, request}, 5_000
    refute request =~ "Proxy-Authorization"
    assert_receive {:mqtt_event, :connected, _}, 5_000

    send(proxy, :stop)
    GenServer.stop(client, :normal, 1_000)
    :gen_tcp.close(listen)
  end

  test "proxy rejection (407) fails the connect attempt and retries" do
    {_proxy, proxy_port, listen} =
      start_proxy(self(), "HTTP/1.1 407 Proxy Authentication Required")

    {:ok, client} =
      MqttX.Client.Connection.start_link(
        host: "target.example.com",
        port: 1883,
        proxy: [host: "localhost", port: proxy_port],
        client_id: "proxy-reject",
        protocol_version: 5,
        handler: Forwarder,
        handler_state: %{pid: self()}
      )

    assert_receive {:proxy_request, _}, 5_000

    # Never connects; the client stays alive retrying with backoff
    refute_receive {:mqtt_event, :connected, _}, 1_500
    refute MqttX.Client.Connection.connected?(client)
    assert Process.alive?(client)

    GenServer.stop(client, :normal, 1_000)
    :gen_tcp.close(listen)
  end

  defp recv_until_blank_line(sock, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
      recv_until_blank_line(sock, buffer <> data)
    end
  end

  defp recv_packet(sock, buffer) do
    case Codec.decode(5, buffer) do
      {:ok, {packet, rest}} ->
        {packet, rest}

      {:error, :incomplete} ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
        recv_packet(sock, buffer <> data)
    end
  end
end
