defmodule MqttX.Client.InboundBufferTest do
  @moduledoc """
  The client's receive path: a packet arriving across many reads is
  reassembled without re-scanning what is already buffered
  (`MqttX.Packet.Buffer`), over TCP and over WebSocket, and `:max_packet_size`
  is enforced on the DECLARED length of every packet before any of it is
  parked.
  """
  use ExUnit.Case, async: false

  alias MqttX.Packet.Buffer
  alias MqttX.Packet.Codec

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  defmodule Forwarder do
    def handle_mqtt_event(event, data, %{pid: pid} = state) do
      send(pid, {:mqtt_event, event, data})
      state
    end
  end

  setup do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, nodelay: true])

    on_exit(fn -> :gen_tcp.close(listen) end)
    {:ok, port} = :inet.port(listen)
    {:ok, listen: listen, port: port}
  end

  defp encode!(packet) do
    {:ok, data} = Codec.encode(5, packet)
    IO.iodata_to_binary(data)
  end

  defp connack, do: encode!(%{type: :connack, session_present: false, reason_code: 0})

  defp publish(topic, payload) do
    encode!(%{
      type: :publish,
      topic: topic,
      payload: payload,
      qos: 0,
      retain: false,
      dup: false,
      packet_id: nil,
      properties: %{}
    })
  end

  # A PUBLISH fixed header declaring ~256 MB; the body is never sent
  defp oversized_header(type \\ 3), do: <<type::4, 0::4, 0xFF, 0xFF, 0xFF, 0x7F>>

  # Write `binary` in `size`-byte pieces, pausing so each lands in its own read
  defp dribble(sock, binary, size) when byte_size(binary) <= size do
    :ok = :gen_tcp.send(sock, binary)
  end

  defp dribble(sock, binary, size) do
    <<part::binary-size(^size), rest::binary>> = binary
    :ok = :gen_tcp.send(sock, part)
    Process.sleep(1)
    dribble(sock, rest, size)
  end

  # Accept one connection, answer CONNECT with `reply`, then run the script
  defp start_broker(ctx, script, reply \\ nil) do
    reply = reply || connack()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(ctx.listen, 5_000)
      {:ok, _connect} = :gen_tcp.recv(sock, 0, 5_000)
      :ok = :gen_tcp.send(sock, reply)
      script.(sock)
      hold_open(sock)
    end)
  end

  # Same, speaking WebSocket: HTTP upgrade first, every MQTT write framed
  defp start_ws_broker(ctx, script, reply \\ nil) do
    reply = reply || ws_frame(connack())

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(ctx.listen, 5_000)
      request = recv_http(sock, <<>>)
      [_, key] = Regex.run(~r/Sec-WebSocket-Key: (\S+)/i, request)
      accept = Base.encode64(:crypto.hash(:sha, key <> @ws_guid))

      :ok =
        :gen_tcp.send(
          sock,
          "HTTP/1.1 101 Switching Protocols\r\n" <>
            "Upgrade: websocket\r\n" <>
            "Connection: Upgrade\r\n" <>
            "Sec-WebSocket-Accept: #{accept}\r\n" <>
            "Sec-WebSocket-Protocol: mqtt\r\n\r\n"
        )

      # The client's CONNECT (a masked frame) — its contents don't matter here
      {:ok, _connect} = :gen_tcp.recv(sock, 0, 5_000)
      :ok = :gen_tcp.send(sock, reply)
      script.(sock)
      hold_open(sock)
    end)
  end

  defp hold_open(sock) do
    receive do
      :done -> :gen_tcp.close(sock)
    after
      15_000 -> :ok
    end
  end

  defp recv_http(sock, acc) do
    {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
    acc = acc <> data
    if String.contains?(acc, "\r\n\r\n"), do: acc, else: recv_http(sock, acc)
  end

  # An unmasked (server-to-client) frame; by default a whole binary message.
  # opcode 2 = binary, 0 = continuation; fin 0 = more fragments follow.
  defp ws_frame(payload, fin \\ 1, opcode \\ 2) do
    len = byte_size(payload)

    header =
      cond do
        len < 126 -> <<fin::1, 0::3, opcode::4, 0::1, len::7>>
        len < 65_536 -> <<fin::1, 0::3, opcode::4, 0::1, 126::7, len::16>>
        true -> <<fin::1, 0::3, opcode::4, 0::1, 127::7, len::64>>
      end

    header <> payload
  end

  defp connect(ctx, client_id, opts \\ []) do
    {:ok, client} =
      MqttX.Client.Connection.start_link(
        Keyword.merge(
          [
            host: "localhost",
            port: ctx.port,
            client_id: client_id,
            protocol_version: 5,
            handler: Forwarder,
            handler_state: %{pid: self()}
          ],
          opts
        )
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

  describe "over TCP" do
    test "a PUBLISH arriving across many reads is delivered intact", ctx do
      test_pid = self()
      payload = :crypto.strong_rand_bytes(120_000)
      packet = publish("big/t", payload)
      <<first_half::binary-size(60_000), second_half::binary>> = packet

      start_broker(ctx, fn sock ->
        dribble(sock, first_half, 1_460)
        send(test_pid, {:half_sent, self()})

        receive do
          :continue -> dribble(sock, second_half, 1_460)
        end
      end)

      client = connect(ctx, "buf-tcp-big")
      assert_receive {:mqtt_event, :connected, _}, 5_000
      assert_receive {:half_sent, broker}, 5_000
      Process.sleep(100)

      # Mid-packet: parked with exactly the bytes received, nothing delivered
      buffer = :sys.get_state(client).buffer
      assert Buffer.pending?(buffer)
      assert Buffer.size(buffer) == 60_000
      refute_received {:mqtt_event, :message, _}

      send(broker, :continue)
      assert_receive {:mqtt_event, :message, {["big", "t"], ^payload, _packet}}, 5_000
      assert :sys.get_state(client).buffer == <<>>
    end

    test "small packets interleaved with a fragmented one all arrive, in order", ctx do
      big = :crypto.strong_rand_bytes(30_000)

      start_broker(ctx, fn sock ->
        stream = publish("seq/1", "one") <> publish("seq/2", big) <> publish("seq/3", "three")
        dribble(sock, stream, 997)
      end)

      connect(ctx, "buf-tcp-seq")

      assert_receive {:mqtt_event, :message, {["seq", "1"], "one", _}}, 5_000
      assert_receive {:mqtt_event, :message, {["seq", "2"], ^big, _}}, 5_000
      assert_receive {:mqtt_event, :message, {["seq", "3"], "three", _}}, 5_000
    end
  end

  describe "max_packet_size" do
    test "an over-limit packet behind a valid one in the same read is rejected", ctx do
      start_broker(ctx, fn sock ->
        # One write: a packet under the limit, then a complete one over it
        :ok =
          :gen_tcp.send(
            sock,
            publish("lim/ok", "fine") <> publish("lim/big", :binary.copy("x", 400))
          )
      end)

      connect(ctx, "buf-limit-complete", max_packet_size: 128)

      assert_receive {:mqtt_event, :message, {["lim", "ok"], "fine", _}}, 5_000
      assert_receive {:mqtt_event, :disconnected, {:protocol_error, :packet_too_large}}, 5_000
      refute_received {:mqtt_event, :message, {["lim", "big"], _, _}}
    end

    test "an over-limit header is rejected when read, not parked until more data comes",
         ctx do
      start_broker(ctx, fn sock ->
        # The oversized packet's body never follows — the header alone must
        # be enough to close
        :ok = :gen_tcp.send(sock, publish("lim/ok", "fine") <> oversized_header())
      end)

      connect(ctx, "buf-limit-header", max_packet_size: 128)

      assert_receive {:mqtt_event, :message, {["lim", "ok"], "fine", _}}, 5_000
      assert_receive {:mqtt_event, :disconnected, {:protocol_error, :packet_too_large}}, 1_500
    end

    test "an over-limit packet during the handshake fails the connect at once", ctx do
      # Instead of CONNACK: a CONNACK-typed header declaring ~256 MB
      start_broker(ctx, fn _sock -> :ok end, oversized_header(2))

      client = connect(ctx, "buf-limit-handshake")

      {micros, result} =
        :timer.tc(fn -> MqttX.Client.Connection.await_connect(client) end)

      assert result == {:error, :packet_too_large}
      # Well inside the 5 s handshake deadline
      assert micros < 2_000_000

      # A failed handshake, not a half-open one: free to retry
      refute :sys.get_state(client).connecting
    end
  end

  describe "over WebSocket" do
    test "a frame arriving across many reads is reassembled", ctx do
      test_pid = self()
      payload = :crypto.strong_rand_bytes(100_000)
      frame = ws_frame(publish("ws/big", payload))
      <<first_half::binary-size(50_000), second_half::binary>> = frame

      start_ws_broker(ctx, fn sock ->
        dribble(sock, first_half, 1_460)
        send(test_pid, {:half_sent, self()})

        receive do
          :continue -> dribble(sock, second_half, 1_460)
        end
      end)

      client = connect(ctx, "buf-ws-frame", transport: :ws)
      assert_receive {:mqtt_event, :connected, _}, 5_000
      assert_receive {:half_sent, broker}, 5_000
      Process.sleep(100)

      # Mid-frame: the frame buffer is parked, the MQTT buffer untouched
      state = :sys.get_state(client)
      assert Buffer.pending?(state.ws_buffer)
      assert Buffer.size(state.ws_buffer) == 50_000
      assert state.buffer == <<>>

      send(broker, :continue)
      assert_receive {:mqtt_event, :message, {["ws", "big"], ^payload, _}}, 5_000

      state = :sys.get_state(client)
      assert state.ws_buffer == <<>>
      assert state.buffer == <<>>
    end

    test "an over-limit frame during the handshake fails the connect at once", ctx do
      # Instead of CONNACK: a frame header declaring one byte over the 16 MiB
      # frame ceiling
      over_ceiling = <<1::1, 0::3, 2::4, 0::1, 127::7, 16_777_217::64>>
      start_ws_broker(ctx, fn _sock -> :ok end, over_ceiling)

      client = connect(ctx, "buf-ws-handshake", transport: :ws)

      {micros, result} =
        :timer.tc(fn -> MqttX.Client.Connection.await_connect(client) end)

      assert result == {:error, :frame_too_large}
      assert micros < 2_000_000
      refute :sys.get_state(client).connecting
    end

    test "a fragmented message is reassembled", ctx do
      payload = :crypto.strong_rand_bytes(30_000)
      packet = publish("ws/frag", payload)
      <<a::binary-size(10_000), b::binary-size(10_000), c::binary>> = packet

      start_ws_broker(ctx, fn sock ->
        # One message in three frames: start, continuation, final continuation
        :ok = :gen_tcp.send(sock, ws_frame(a, 0, 2))
        Process.sleep(20)
        :ok = :gen_tcp.send(sock, ws_frame(b, 0, 0))
        Process.sleep(20)
        :ok = :gen_tcp.send(sock, ws_frame(c, 1, 0))
      end)

      connect(ctx, "buf-ws-frag", transport: :ws)
      assert_receive {:mqtt_event, :message, {["ws", "frag"], ^payload, _}}, 5_000
    end

    test "a fragmented message that never ends cannot grow without bound", ctx do
      test_pid = self()
      mib = :binary.copy(<<0>>, 1_048_576)

      start_ws_broker(ctx, fn sock ->
        # A message that starts and then only ever continues: 20 MiB of
        # fragments, none of them final, each well under the per-frame ceiling
        :ok = :gen_tcp.send(sock, ws_frame(mib, 0, 2))
        for _ <- 1..19, do: :gen_tcp.send(sock, ws_frame(mib, 0, 0))
        send(test_pid, :fragments_sent)
      end)

      client = connect(ctx, "buf-ws-endless", transport: :ws, max_packet_size: 4_096)
      assert_receive {:mqtt_event, :connected, _}, 5_000
      assert_receive :fragments_sent, 15_000

      assert_receive {:mqtt_event, :disconnected, {:protocol_error, :message_too_large}}, 5_000

      # ...and what had been accumulated is released, not kept for the retry
      {held, _type} = :sys.get_state(client).ws_frag
      assert held == <<>>
    end

    test "an MQTT packet spread over several frames is reassembled", ctx do
      test_pid = self()
      payload = :crypto.strong_rand_bytes(40_000)
      packet = publish("ws/split", payload)
      <<a::binary-size(10_000), b::binary-size(10_000), c::binary>> = packet

      start_ws_broker(ctx, fn sock ->
        :ok = :gen_tcp.send(sock, ws_frame(a))
        Process.sleep(20)
        :ok = :gen_tcp.send(sock, ws_frame(b))
        send(test_pid, {:two_frames_sent, self()})

        receive do
          :continue ->
            :ok = :gen_tcp.send(sock, ws_frame(c) <> ws_frame(publish("ws/after", "x")))
        end
      end)

      client = connect(ctx, "buf-ws-split", transport: :ws)
      assert_receive {:mqtt_event, :connected, _}, 5_000
      assert_receive {:two_frames_sent, broker}, 5_000
      Process.sleep(100)

      # Both frames are complete, the MQTT packet inside them is not
      state = :sys.get_state(client)
      assert state.ws_buffer == <<>>
      assert Buffer.pending?(state.buffer)
      assert Buffer.size(state.buffer) == 20_000

      send(broker, :continue)
      assert_receive {:mqtt_event, :message, {["ws", "split"], ^payload, _}}, 5_000
      assert_receive {:mqtt_event, :message, {["ws", "after"], "x", _}}, 5_000
    end
  end
end
