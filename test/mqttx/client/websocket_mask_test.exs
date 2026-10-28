defmodule MqttX.Client.WebSocketMaskTest do
  @moduledoc """
  Client frames are masked (RFC 6455 §5.3): every payload byte XORed with
  the key byte at its position modulo four. The encoder does it a word at a
  time; this checks it against the byte-by-byte definition for every
  length that exercises a different tail.
  """
  use ExUnit.Case, async: true

  alias MqttX.Client.WebSocket

  defp reference(payload, key) do
    for {byte, i} <- Enum.with_index(:binary.bin_to_list(payload)),
        into: <<>>,
        do: <<Bitwise.bxor(byte, :binary.at(key, rem(i, 4)))>>
  end

  defp parse(frame) do
    case IO.iodata_to_binary(frame) do
      <<_::8, 1::1, len::7, key::4-binary, masked::binary>> when len < 126 ->
        {len, key, masked}

      <<_::8, 1::1, 126::7, len::16, key::4-binary, masked::binary>> ->
        {len, key, masked}

      <<_::8, 1::1, 127::7, len::64, key::4-binary, masked::binary>> ->
        {len, key, masked}
    end
  end

  test "masking matches the byte-by-byte definition at every tail length" do
    for len <- Enum.concat([0..70, [125, 126, 127, 1_000, 65_535, 65_536, 65_537, 100_003]]) do
      payload = :crypto.strong_rand_bytes(len)
      {^len, key, masked} = parse(WebSocket.encode_frame(payload))
      assert byte_size(masked) == len
      assert masked == reference(payload, key), "length #{len}"
    end
  end

  test "a masked frame decodes back to its payload" do
    for len <- [0, 1, 7, 16, 33, 4_096] do
      payload = :crypto.strong_rand_bytes(len)
      {^len, key, masked} = parse(WebSocket.encode_frame(payload))
      assert reference(masked, key) == payload
    end
  end
end
