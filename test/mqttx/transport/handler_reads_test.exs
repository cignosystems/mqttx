defmodule MqttX.Transport.HandlerReadsTest do
  @moduledoc """
  What the connection handler does once per read rather than once per
  packet: the acknowledgements of a read's packets go out in one write, in
  the order they were made and ahead of anything else sent during the read;
  the keep-alive clock restarts after the read's packets, and not for a
  packet that has only partly arrived.
  """
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec
  alias MqttX.Transport.Handler, as: Proto

  defmodule Handler do
    use MqttX.Server

    def init(_opts), do: %{}
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
    def handle_disconnect(_reason, _state), do: :ok
  end

  defp encode(packet), do: elem(Codec.encode(5, packet), 1)

  # Every packet in one write, in order
  defp written do
    assert_receive {:sent, data}
    decode_all(IO.iodata_to_binary(data), [])
  end

  defp decode_all(<<>>, acc), do: Enum.reverse(acc)

  defp decode_all(bytes, acc) do
    {:ok, {packet, rest}} = Codec.decode(5, bytes)
    decode_all(rest, [packet | acc])
  end

  defp publish(id, qos, payload \\ "p") do
    encode(%{
      type: :publish,
      topic: "t/#{id}",
      payload: payload,
      qos: qos,
      retain: false,
      dup: false,
      packet_id: if(qos > 0, do: id),
      properties: %{}
    })
  end

  setup do
    table = MqttX.Server.RetainedStore.new_table()
    test = self()
    send_fn = fn data -> send(test, {:sent, data}) end
    {:ok, state} = Proto.init(Handler, [transport_opts: %{}], table, nil, send_fn)

    connect =
      encode(%{
        type: :connect,
        protocol_version: 5,
        client_id: "reads",
        username: nil,
        password: nil,
        will: nil,
        clean_session: true,
        keep_alive: 60,
        properties: %{}
      })

    {:ok, state} = Proto.handle_data(connect, state)
    assert [%{type: :connack, reason_code: 0}] = written()
    {:ok, state: state}
  end

  test "the acknowledgements of a read's packets go out in one write, in order", %{state: s} do
    read = publish(1, 1) <> publish(2, 1) <> publish(3, 2) <> publish(4, 1)
    {:ok, s} = Proto.handle_data(read, s)

    assert [
             %{type: :puback, packet_id: 1},
             %{type: :puback, packet_id: 2},
             %{type: :pubrec, packet_id: 3},
             %{type: :puback, packet_id: 4}
           ] = written()

    refute_received {:sent, _}

    pubrel = encode(%{type: :pubrel, packet_id: 3, reason_code: 0, properties: %{}})
    {:ok, _s} = Proto.handle_data(pubrel <> publish(5, 1), s)
    assert [%{type: :pubcomp, packet_id: 3}, %{type: :puback, packet_id: 5}] = written()
    refute_received {:sent, _}
  end

  test "no more than sixteen acknowledgements wait at a time", %{state: s} do
    read = Enum.map_join(1..20, &publish(&1, 1))
    {:ok, _s} = Proto.handle_data(read, s)

    assert Enum.map(written(), & &1.packet_id) == Enum.to_list(1..16)
    assert Enum.map(written(), & &1.packet_id) == Enum.to_list(17..20)
    refute_received {:sent, _}
  end

  test "a packet sent during the read goes out behind the acknowledgements made before it",
       %{state: s} do
    read = publish(1, 1) <> encode(%{type: :pingreq}) <> publish(2, 1)
    {:ok, _s} = Proto.handle_data(read, s)

    assert [%{type: :puback, packet_id: 1}, %{type: :pingresp}] = written()
    assert [%{type: :puback, packet_id: 2}] = written()
    refute_received {:sent, _}
  end

  test "the keep-alive clock restarts once per read, and not for a partial packet", %{state: s} do
    before = s.keepalive_timer
    assert is_reference(before)

    {:ok, s} = Proto.handle_data(publish(1, 0) <> publish(2, 0), s)
    assert s.keepalive_timer != before
    assert Process.read_timer(before) == false
    armed = s.keepalive_timer

    # The first bytes of a packet: nothing arrived yet, as far as §3.1.2.10
    # is concerned
    whole = publish(3, 1, :binary.copy("x", 200))
    <<head::binary-size(5), tail::binary>> = whole
    {:ok, s} = Proto.handle_data(head, s)
    assert s.keepalive_timer == armed
    refute_received {:sent, _}

    {:ok, s} = Proto.handle_data(tail, s)
    assert s.keepalive_timer != armed
    assert [%{type: :puback, packet_id: 3}] = written()
  end

  test "a QoS 2 message kept until PUBREL does not keep the whole read alive", %{state: s} do
    # A small QoS 2 message, then a large one, in one read
    read = publish(1, 2, "small") <> publish(2, 0, :binary.copy("x", 60_000))
    {:ok, s} = Proto.handle_data(read, s)
    assert [%{type: :pubrec, packet_id: 1}] = written()

    {%{payload: payload}, _opts} = s.pending_qos2_rx[1]
    assert payload == "small"
    assert :binary.referenced_byte_size(payload) < 1_000
  end
end
