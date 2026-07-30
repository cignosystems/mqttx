defmodule MqttX.Client.ConnectFsmTest do
  # Regression tests for the event-driven CONNECT handshake: the client used
  # to sit in a blocking `receive` between CONNECT and CONNACK, so every
  # GenServer call stalled for up to the connect timeout.
  use ExUnit.Case, async: false

  alias MqttX.Packet.Codec

  test "calls are served while the CONNACK is still outstanding" do
    # A broker that accepts the socket but never sends CONNACK
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    silent_broker =
      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        {:ok, _connect} = :gen_tcp.recv(sock, 0, 5_000)

        receive do
          :stop -> :gen_tcp.close(sock)
        end
      end)

    {:ok, client} =
      MqttX.Client.Connection.start_link(
        host: "localhost",
        port: port,
        client_id: "fsm-test",
        protocol_version: 5
      )

    # Let the client enter the connecting state
    Process.sleep(100)

    {micros, result} =
      :timer.tc(fn -> MqttX.Client.Connection.connected?(client) end)

    assert result == false
    # The old blocking handshake would hold this call for up to 5s
    assert micros < 500_000

    {micros_pub, pub_result} =
      :timer.tc(fn ->
        MqttX.Client.Connection.publish(client, "t", "x", qos: 1)
      end)

    assert pub_result == {:error, :not_connected}
    assert micros_pub < 500_000

    send(silent_broker, :stop)
    GenServer.stop(client, :normal, 1_000)
    :gen_tcp.close(listen)
  end

  test "handshake deadline fires and the client retries" do
    # Broker never sends CONNACK on the first connection, completes on the second
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {:ok, _} = :gen_tcp.recv(sock, 0, 10_000)
      # never answer; wait for the client to give up and reconnect
      {:ok, sock2} = :gen_tcp.accept(listen, 15_000)
      {:ok, _} = :gen_tcp.recv(sock2, 0, 10_000)

      {:ok, connack} =
        Codec.encode(5, %{
          type: :connack,
          session_present: false,
          reason_code: 0,
          properties: %{}
        })

      :ok = :gen_tcp.send(sock2, connack)
      send(parent, :second_connect_completed)

      receive do
        :stop -> :ok
      end
    end)

    {:ok, client} =
      MqttX.Client.Connection.start_link(
        host: "localhost",
        port: port,
        client_id: "fsm-timeout-test",
        protocol_version: 5
      )

    # connack timeout is 5s + backoff ~1s before the retry
    assert_receive :second_connect_completed, 15_000
    Process.sleep(100)
    assert MqttX.Client.Connection.connected?(client)

    GenServer.stop(client, :normal, 1_000)
    :gen_tcp.close(listen)
  end

  describe "connect/1 readiness contract" do
    # The handshake is asynchronous (so a client can start before the broker is
    # reachable), which means connect/1 returns before the session is live.
    # This was previously masked: the old blocking handshake made calls queue
    # in the mailbox until CONNACK, so `connect |> subscribe` appeared to work.
    # Docs promised that behaviour; these tests pin what actually happens.

    test "connect/1 returns before the session is live" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      broker =
        spawn_link(fn ->
          {:ok, sock} = :gen_tcp.accept(listen, 5_000)
          {:ok, _connect} = :gen_tcp.recv(sock, 0, 5_000)
          # Deliberately slow CONNACK
          Process.sleep(300)
          send_connack(sock)

          receive do
            :stop -> :gen_tcp.close(sock)
          after
            5_000 -> :gen_tcp.close(sock)
          end
        end)

      {:ok, client} =
        MqttX.Client.connect(
          host: "localhost",
          port: port,
          client_id: "async-contract",
          protocol_version: 5
        )

      refute MqttX.Client.connected?(client)
      assert {:error, :not_connected} = MqttX.Client.publish(client, "t", "p", qos: 1)

      # ...and becomes usable once CONNACK lands
      assert eventually(fn -> MqttX.Client.connected?(client) end)

      send(broker, :stop)
      GenServer.stop(client, :normal, 1_000)
      :gen_tcp.close(listen)
    end

    test "await_connect: true returns only once the session is live" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      broker =
        spawn_link(fn ->
          {:ok, sock} = :gen_tcp.accept(listen, 5_000)
          {:ok, _connect} = :gen_tcp.recv(sock, 0, 5_000)
          Process.sleep(300)
          send_connack(sock)

          receive do
            :stop -> :gen_tcp.close(sock)
          after
            5_000 -> :gen_tcp.close(sock)
          end
        end)

      {:ok, client} =
        MqttX.Client.connect(
          host: "localhost",
          port: port,
          client_id: "await-contract",
          protocol_version: 5,
          await_connect: true
        )

      # No sleep, no polling: the session must already be live
      assert MqttX.Client.connected?(client)

      send(broker, :stop)
      GenServer.stop(client, :normal, 1_000)
      :gen_tcp.close(listen)
    end

    test "await_connect: true surfaces a failed first attempt and leaves no process" do
      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      before = length(Process.list())

      assert {:error, reason} =
               MqttX.Client.connect(
                 host: "localhost",
                 port: port,
                 client_id: "await-fail",
                 await_connect: true
               )

      assert reason in [:econnrefused, :timeout, :closed]
      # the client was stopped rather than left retrying in the background
      assert length(Process.list()) <= before + 1
    end
  end

  defp send_connack(sock) do
    {:ok, connack} =
      Codec.encode(5, %{type: :connack, session_present: false, reason_code: 0, properties: %{}})

    :ok = :gen_tcp.send(sock, connack)
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
