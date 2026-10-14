defmodule MqttX.Packet.BufferTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MqttX.Packet.Buffer
  alias MqttX.Packet.Codec

  defp publish(payload, topic \\ "t") do
    {:ok, data} =
      Codec.encode(4, %{
        type: :publish,
        topic: topic,
        payload: payload,
        qos: 0,
        retain: false,
        dup: false,
        packet_id: nil,
        properties: %{}
      })

    IO.iodata_to_binary(data)
  end

  # Split `binary` into chunks, cycling through `sizes`
  defp split(binary, sizes), do: split(binary, sizes, sizes, [])

  defp split(<<>>, _sizes, _all, acc), do: Enum.reverse(acc)
  defp split(binary, [], all, acc), do: split(binary, all, all, acc)

  defp split(binary, [size | sizes], all, acc) do
    size = min(size, byte_size(binary))
    <<chunk::binary-size(^size), rest::binary>> = binary
    split(rest, sizes, all, [chunk | acc])
  end

  # Drive the buffer the way the connection handlers do: push each read,
  # decode everything decodable, stash the tail. Also counts decode attempts.
  defp feed(chunks) do
    {buffer, packets, attempts} =
      Enum.reduce(chunks, {Buffer.new(), [], 0}, fn chunk, {buffer, packets, attempts} ->
        case Buffer.push(buffer, chunk) do
          {:more, buffer} -> {buffer, packets, attempts}
          {:ready, binary} -> drain(binary, packets, attempts + 1)
        end
      end)

    {Enum.reverse(packets), buffer, attempts}
  end

  defp drain(binary, packets, attempts) do
    case Codec.decode(4, binary) do
      {:ok, {packet, rest}} -> drain(rest, [packet | packets], attempts)
      {:error, :incomplete} -> {Buffer.stash(binary), packets, attempts}
    end
  end

  describe "an empty buffer" do
    test "is the empty binary, so `<<>>` resets it" do
      assert Buffer.new() == <<>>
      assert Buffer.size(Buffer.new()) == 0
      refute Buffer.pending?(Buffer.new())
    end

    test "hands a read straight to the decoder without copying" do
      assert Buffer.push(Buffer.new(), "abc") == {:ready, "abc"}
    end

    test "stashing nothing leaves it empty" do
      assert Buffer.stash(<<>>) == <<>>
    end
  end

  describe "a tail whose header is not readable yet" do
    test "is kept as-is and re-offered to the decoder with the next read" do
      packet = publish(:binary.copy("x", 300))
      # One byte: packet type only, the remaining-length varint has not arrived
      <<first::binary-size(1), rest::binary>> = packet

      buffer = Buffer.stash(first)
      refute Buffer.pending?(buffer)
      assert Buffer.size(buffer) == 1

      assert {:ready, ^packet} = Buffer.push(buffer, rest)
    end

    test "a varint cut mid-way is not mistaken for a length" do
      packet = publish(:binary.copy("x", 300))
      # Type byte plus the first (continuation) byte of a two-byte varint
      <<partial::binary-size(2), _::binary>> = packet

      refute Buffer.pending?(Buffer.stash(partial))
    end
  end

  describe "a tail whose length is known" do
    test "waits for exactly that many bytes, then yields the whole packet" do
      packet = publish(:crypto.strong_rand_bytes(100_000))
      [head | chunks] = split(packet, [1460])
      {middle, [last]} = Enum.split(chunks, -1)

      buffer = Buffer.stash(head)
      assert Buffer.pending?(buffer)
      assert Buffer.size(buffer) == byte_size(head)

      buffer =
        Enum.reduce(middle, buffer, fn chunk, buffer ->
          assert {:more, buffer} = Buffer.push(buffer, chunk)
          assert Buffer.pending?(buffer)
          buffer
        end)

      assert Buffer.size(buffer) == byte_size(packet) - byte_size(last)
      assert {:ready, ^packet} = Buffer.push(buffer, last)
    end

    test "bytes past the awaited packet come back in the same binary" do
      first = publish(:binary.copy("a", 5_000))
      second = publish("b")
      <<head::binary-size(100), tail::binary>> = first

      buffer = Buffer.stash(head)
      assert {:ready, ready} = Buffer.push(buffer, tail <> second)
      assert ready == first <> second
    end

    test "a complete packet is never parked" do
      packet = publish("complete")
      refute Buffer.pending?(Buffer.stash(packet))
    end

    test "is decoded once, not once per read" do
      packet = publish(:binary.copy("z", 64_000))
      chunks = split(packet, [1000])
      assert length(chunks) > 60

      assert {[%{payload: payload}], <<>>, attempts} = feed(chunks)
      assert byte_size(payload) == 64_000
      # One attempt on the first read (incomplete) and one when it is complete
      assert attempts == 2
    end
  end

  describe "custom framing" do
    test "stash/2 takes the length from the given function" do
      # A toy protocol: one length byte, then that many bytes
      framing = fn <<len, _::binary>> -> {:ok, 1 + len} end

      buffer = Buffer.stash(<<5, "ab">>, framing)
      assert Buffer.pending?(buffer)
      assert {:more, buffer} = Buffer.push(buffer, "cd")
      assert {:ready, <<5, "abcde">>} = Buffer.push(buffer, "e")
    end

    test "anything other than {:ok, length} leaves the tail unparked" do
      refute Buffer.pending?(Buffer.stash("abc", fn _ -> :incomplete end))
      refute Buffer.pending?(Buffer.stash("abc", fn _ -> {:error, :malformed_header} end))
    end
  end

  # Payload sizes straddle the 1-, 2- and 3-byte remaining-length encodings
  defp payload_gen do
    one_of([
      binary(max_length: 200),
      map(integer(100..300), &:binary.copy(<<1>>, &1)),
      map(integer(16_300..16_500), &:binary.copy(<<2>>, &1)),
      map(integer(0..40_000), &:binary.copy(<<3>>, &1))
    ])
  end

  property "packets survive any chunking of the byte stream" do
    check all(
            payloads <- list_of(payload_gen(), min_length: 1, max_length: 6),
            sizes <- list_of(integer(1..3_000), min_length: 1, max_length: 8)
          ) do
      stream = payloads |> Enum.map(&publish/1) |> IO.iodata_to_binary()

      assert {packets, buffer, _attempts} = feed(split(stream, sizes))
      assert Enum.map(packets, & &1.payload) == payloads
      assert Buffer.size(buffer) == 0
    end
  end
end
