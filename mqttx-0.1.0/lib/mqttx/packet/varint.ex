defmodule MqttX.Packet.Varint do
  @moduledoc """
  MQTT Variable Byte Integer encoding and decoding.

  Variable byte integers use 1-4 bytes to encode values from 0 to 268,435,455.
  Each byte uses 7 bits for data and 1 continuation bit.

  ## Encoding

      iex> MqttX.Packet.Varint.encode(127)
      <<127>>

      iex> MqttX.Packet.Varint.encode(128)
      <<128, 1>>

      iex> MqttX.Packet.Varint.encode(16383)
      <<255, 127>>

  ## Decoding

      iex> MqttX.Packet.Varint.decode(<<128, 1, "rest">>)
      {:ok, 128, "rest"}
  """

  import Bitwise

  @max_varint 268_435_455

  @doc """
  Encode an integer as a variable byte integer.

  Returns a binary of 1-4 bytes.
  """
  @spec encode(non_neg_integer()) :: binary()
  def encode(i) when i >= 0 and i <= 127 do
    <<0::1, i::7>>
  end

  def encode(i) when i >= 0 and i <= @max_varint do
    encode_loop(i, <<>>)
  end

  defp encode_loop(i, acc) when i < 128 do
    <<acc::binary, 0::1, i::7>>
  end

  defp encode_loop(i, acc) do
    encode_loop(i >>> 7, <<acc::binary, 1::1, i &&& 0x7F::7>>)
  end

  @doc """
  Encode an integer as iodata (more efficient for building packets).
  """
  @spec encode_iodata(non_neg_integer()) :: iodata()
  def encode_iodata(i) when i >= 0 and i <= 127 do
    [<<0::1, i::7>>]
  end

  def encode_iodata(i) when i >= 0 and i <= @max_varint do
    encode_iodata_loop(i, [])
  end

  defp encode_iodata_loop(i, acc) when i < 128 do
    Enum.reverse([<<0::1, i::7>> | acc])
  end

  defp encode_iodata_loop(i, acc) do
    encode_iodata_loop(i >>> 7, [<<1::1, i &&& 0x7F::7>> | acc])
  end

  @doc """
  Decode a variable byte integer from binary data.

  Returns `{:ok, value, rest}` on success, `:incomplete` if more data needed,
  or `{:error, reason}` on failure.
  """
  @spec decode(binary()) :: {:ok, non_neg_integer(), binary()} | :incomplete | {:error, atom()}

  # Optimized single-byte case (most common)
  def decode(<<0::1, len::7, rest::binary>>) do
    {:ok, len, rest}
  end

  # Two bytes
  def decode(<<1::1, b1::7, 0::1, b2::7, rest::binary>>) do
    {:ok, b1 + (b2 <<< 7), rest}
  end

  # Three bytes
  def decode(<<1::1, b1::7, 1::1, b2::7, 0::1, b3::7, rest::binary>>) do
    {:ok, b1 + (b2 <<< 7) + (b3 <<< 14), rest}
  end

  # Four bytes
  def decode(<<1::1, b1::7, 1::1, b2::7, 1::1, b3::7, 0::1, b4::7, rest::binary>>) do
    value = b1 + (b2 <<< 7) + (b3 <<< 14) + (b4 <<< 21)

    if value <= @max_varint do
      {:ok, value, rest}
    else
      {:error, :varint_overflow}
    end
  end

  # Malformed (continuation bit set on 4th byte)
  def decode(<<1::1, _::7, 1::1, _::7, 1::1, _::7, 1::1, _::7, _::binary>>) do
    {:error, :varint_overflow}
  end

  # Incomplete data
  def decode(<<1::1, _::7>>) do
    :incomplete
  end

  def decode(<<1::1, _::7, 1::1, _::7>>) do
    :incomplete
  end

  def decode(<<1::1, _::7, 1::1, _::7, 1::1, _::7>>) do
    :incomplete
  end

  def decode(<<>>) do
    :incomplete
  end

  @doc """
  Calculate the byte length needed to encode a value.
  """
  @spec byte_length(non_neg_integer()) :: 1 | 2 | 3 | 4
  def byte_length(i) when i >= 0 and i <= 127, do: 1
  def byte_length(i) when i <= 16_383, do: 2
  def byte_length(i) when i <= 2_097_151, do: 3
  def byte_length(i) when i <= @max_varint, do: 4

  @doc """
  Maximum value that can be encoded.
  """
  @spec max_value :: non_neg_integer()
  def max_value, do: @max_varint
end
