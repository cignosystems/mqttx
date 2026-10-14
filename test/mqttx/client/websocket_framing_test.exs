defmodule MqttX.Client.WebSocketFramingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MqttX.Client.WebSocket
  alias MqttX.Packet.Buffer

  # An unmasked (server-to-client) frame; by default a whole binary message.
  # opcode 2 = binary, 0 = continuation; fin 0 = more fragments follow.
  defp frame(payload, fin \\ 1, opcode \\ 2) do
    len = byte_size(payload)

    header =
      cond do
        len < 126 -> <<fin::1, 0::3, opcode::4, 0::1, len::7>>
        len < 65_536 -> <<fin::1, 0::3, opcode::4, 0::1, 126::7, len::16>>
        true -> <<fin::1, 0::3, opcode::4, 0::1, 127::7, len::64>>
      end

    header <> payload
  end

  describe "declared_length/1" do
    test "7-bit length: 2-byte header" do
      assert WebSocket.declared_length(frame("hello")) == {:ok, 2 + 5}
    end

    test "16-bit length: 4-byte header" do
      assert WebSocket.declared_length(frame(:binary.copy("x", 300))) == {:ok, 4 + 300}
    end

    test "64-bit length: 10-byte header" do
      assert WebSocket.declared_length(frame(:binary.copy("x", 70_000))) == {:ok, 10 + 70_000}
    end

    test "a masked frame counts its 4-byte masking key" do
      masked = <<1::1, 0::3, 2::4, 1::1, 5::7, 1, 2, 3, 4, "hello">>
      assert WebSocket.declared_length(masked) == {:ok, 2 + 4 + 5}
    end

    test "is readable from the header alone, before any payload arrives" do
      <<header::binary-size(10), _payload::binary>> = frame(:binary.copy("x", 70_000))
      assert WebSocket.declared_length(header) == {:ok, 10 + 70_000}
    end

    test "is :incomplete until the whole header has arrived" do
      assert WebSocket.declared_length(<<>>) == :incomplete
      assert WebSocket.declared_length(<<0x82>>) == :incomplete
      # half of a 16-bit length
      assert WebSocket.declared_length(<<0x82, 126, 1>>) == :incomplete
      # part of a 64-bit length
      assert WebSocket.declared_length(<<0x82, 127, 0, 0, 0>>) == :incomplete
      # masked, masking key cut short
      assert WebSocket.declared_length(<<0x82, 1::1, 5::7, 1, 2>>) == :incomplete
    end

    test "a frame over the size ceiling is not given a length to wait for" do
      over = <<1::1, 0::3, 2::4, 0::1, 127::7, 16_777_217::64>>

      assert WebSocket.declared_length(over) == :incomplete
      # ...because decode_frames/2 rejects it outright
      assert WebSocket.decode_frames(over, WebSocket.initial_frag()) ==
               {:error, :frame_too_large}
    end

    test "agrees with what decode_frames/2 consumes" do
      for size <- [0, 1, 125, 126, 300, 65_535, 65_536, 70_000] do
        frame = frame(:binary.copy("p", size))
        assert WebSocket.declared_length(frame) == {:ok, byte_size(frame)}

        assert {:ok, [payload], [], <<>>, _frag} =
                 WebSocket.decode_frames(frame, WebSocket.initial_frag())

        assert byte_size(payload) == size
      end
    end
  end

  describe "fragmented messages" do
    # The ceiling a single frame is already held to
    @ceiling 16_777_216

    # One decode call per frame, threading the fragmentation state — as the
    # client does across reads
    defp feed_frames(frames) do
      Enum.reduce_while(frames, {[], WebSocket.initial_frag()}, fn frame, {acc, frag} ->
        case WebSocket.decode_frames(frame, frag) do
          {:ok, payloads, [], <<>>, frag} -> {:cont, {acc ++ payloads, frag}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end

    defp zeros(bytes), do: :binary.copy(<<0>>, bytes)

    test "start, continuation and final frames are joined into one message" do
      frames = [frame("ab", 0, 2), frame("cd", 0, 0), frame("ef", 1, 0)]
      assert feed_frames(frames) == {["abcdef"], WebSocket.initial_frag()}
    end

    test "a message exactly at the ceiling is accepted" do
      half = zeros(div(@ceiling, 2))

      assert {[message], _frag} = feed_frames([frame(half, 0, 2), frame(half, 1, 0)])
      assert byte_size(message) == @ceiling
    end

    test "one byte over the ceiling is rejected on a continuation frame" do
      half = zeros(div(@ceiling, 2))
      frames = [frame(half, 0, 2), frame(half, 0, 0), frame(<<0>>, 0, 0)]

      assert feed_frames(frames) == {:error, :message_too_large}
    end

    test "one byte over the ceiling is rejected on the final frame" do
      half = zeros(div(@ceiling, 2))
      frames = [frame(half, 0, 2), frame(half <> <<0>>, 1, 0)]

      assert feed_frames(frames) == {:error, :message_too_large}
    end

    test "the limit holds when every fragment arrives in a single read" do
      half = zeros(div(@ceiling, 2))

      stream =
        IO.iodata_to_binary([frame(half, 0, 2), frame(half, 0, 0), frame(<<0>>, 1, 0)])

      assert WebSocket.decode_frames(stream, WebSocket.initial_frag()) ==
               {:error, :message_too_large}
    end

    test "small fragments that never end are stopped at the ceiling" do
      # The peer never has to send a single large frame: 64 KiB at a time
      piece = zeros(65_536)
      frames = [frame(piece, 0, 2) | List.duplicate(frame(piece, 0, 0), 300)]
      assert byte_size(piece) * length(frames) > @ceiling

      assert feed_frames(frames) == {:error, :message_too_large}
    end

    test "the limit is per message, not cumulative across messages" do
      part = zeros(5 * 1_048_576)
      message = [frame(part, 0, 2), frame(part, 1, 0)]

      # Two 10 MiB messages back to back: 20 MiB in total, each under the limit
      assert {[first, second], _frag} = feed_frames(message ++ message)
      assert byte_size(first) == 10 * 1_048_576
      assert byte_size(second) == 10 * 1_048_576
    end

    test "an unfragmented message at the ceiling is unaffected" do
      assert {:ok, [message], [], <<>>, _frag} =
               WebSocket.decode_frames(frame(zeros(@ceiling)), WebSocket.initial_frag())

      assert byte_size(message) == @ceiling
    end
  end

  # Drive the frame buffer the way the client does
  defp feed(chunks) do
    {payloads, buffer, _frag} =
      Enum.reduce(chunks, {[], Buffer.new(), WebSocket.initial_frag()}, fn chunk,
                                                                           {acc, buffer, frag} ->
        case Buffer.push(buffer, chunk) do
          {:more, buffer} ->
            {acc, buffer, frag}

          {:ready, binary} ->
            {:ok, payloads, [], rest, frag} = WebSocket.decode_frames(binary, frag)
            {acc ++ payloads, Buffer.stash(rest, &WebSocket.declared_length/1), frag}
        end
      end)

    {payloads, buffer}
  end

  defp split(<<>>, _sizes, _all), do: []
  defp split(binary, [], all), do: split(binary, all, all)

  defp split(binary, [size | sizes], all) do
    size = min(size, byte_size(binary))
    <<chunk::binary-size(^size), rest::binary>> = binary
    [chunk | split(rest, sizes, all)]
  end

  property "frames survive any chunking of the byte stream" do
    check all(
            payloads <-
              list_of(
                one_of([
                  binary(max_length: 200),
                  map(integer(120..130), &:binary.copy(<<1>>, &1)),
                  map(integer(65_530..65_540), &:binary.copy(<<2>>, &1))
                ]),
                min_length: 1,
                max_length: 5
              ),
            sizes <- list_of(integer(1..4_000), min_length: 1, max_length: 6)
          ) do
      stream = payloads |> Enum.map(&frame/1) |> IO.iodata_to_binary()

      assert {decoded, buffer} = feed(split(stream, sizes, sizes))
      assert decoded == payloads
      assert Buffer.size(buffer) == 0
    end
  end
end
