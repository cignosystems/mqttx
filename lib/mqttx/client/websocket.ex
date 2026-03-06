defmodule MqttX.Client.WebSocket do
  @moduledoc false
  # Minimal WebSocket client for MQTT over WebSocket.
  # Handles HTTP upgrade handshake and WebSocket binary framing (RFC 6455).
  # Only supports binary frames (opcode 0x02) as required by MQTT.

  @doc """
  Perform WebSocket HTTP upgrade over an existing TCP/SSL socket.
  Returns :ok on successful upgrade or {:error, reason}.
  """
  def upgrade(socket, transport, host, path) do
    key = :crypto.strong_rand_bytes(16) |> Base.encode64()

    request =
      "GET #{path} HTTP/1.1\r\n" <>
        "Host: #{host}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        "Sec-WebSocket-Protocol: mqtt\r\n" <>
        "\r\n"

    with :ok <- send_raw(socket, transport, request),
         {:ok, response} <- recv_upgrade_response(socket, transport, <<>>) do
      response_lower = String.downcase(response)

      if String.contains?(response, "101") and
           String.contains?(response_lower, "upgrade: websocket") do
        :ok
      else
        {:error, :upgrade_failed}
      end
    end
  end

  @doc """
  Encode data as a WebSocket binary frame (client-masked).
  Returns iodata.
  """
  def encode_frame(data) do
    payload = IO.iodata_to_binary(data)
    len = byte_size(payload)
    mask_key = :crypto.strong_rand_bytes(4)
    masked = mask(payload, mask_key)

    header =
      cond do
        len < 126 ->
          <<1::1, 0::3, 2::4, 1::1, len::7>>

        len < 65536 ->
          <<1::1, 0::3, 2::4, 1::1, 126::7, len::16>>

        true ->
          <<1::1, 0::3, 2::4, 1::1, 127::7, len::64>>
      end

    [header, mask_key, masked]
  end

  @doc """
  Decode WebSocket frames from binary buffer.
  Returns {:ok, payloads, rest} where payloads is a list of binary payloads,
  or {:incomplete, buffer} if not enough data.
  """
  def decode_frames(buffer) do
    decode_frames(buffer, [])
  end

  defp decode_frames(buffer, acc) do
    case decode_one_frame(buffer) do
      {:ok, :ping, _payload, rest} ->
        # Ping handled at connection level
        decode_frames(rest, acc)

      {:ok, :pong, _payload, rest} ->
        decode_frames(rest, acc)

      {:ok, :close, _payload, _rest} ->
        {:close, Enum.reverse(acc)}

      {:ok, :binary, payload, rest} ->
        decode_frames(rest, [payload | acc])

      {:ok, :text, payload, rest} ->
        # Treat text as binary for MQTT
        decode_frames(rest, [payload | acc])

      :incomplete ->
        {:ok, Enum.reverse(acc), buffer}
    end
  end

  defp decode_one_frame(<<_fin::1, _rsv::3, opcode::4, second_byte, rest::binary>>) do
    mask_bit = Bitwise.bsr(second_byte, 7)
    len_tag = Bitwise.band(second_byte, 0x7F)

    case decode_length(len_tag, mask_bit, rest) do
      {:ok, len, mask_key, payload_rest} when byte_size(payload_rest) >= len ->
        <<payload::binary-size(len), remaining::binary>> = payload_rest

        payload =
          if mask_key do
            mask(payload, mask_key)
          else
            payload
          end

        type =
          case opcode do
            0x01 -> :text
            0x02 -> :binary
            0x08 -> :close
            0x09 -> :ping
            0x0A -> :pong
            _ -> :binary
          end

        {:ok, type, payload, remaining}

      {:ok, _len, _mask_key, _payload_rest} ->
        :incomplete

      :incomplete ->
        :incomplete
    end
  end

  defp decode_one_frame(_), do: :incomplete

  defp decode_length(len, 0, rest) when len < 126 do
    {:ok, len, nil, rest}
  end

  defp decode_length(len, 1, <<mask::4-binary, rest::binary>>) when len < 126 do
    {:ok, len, mask, rest}
  end

  defp decode_length(126, 0, <<len::16, rest::binary>>) do
    {:ok, len, nil, rest}
  end

  defp decode_length(126, 1, <<len::16, mask::4-binary, rest::binary>>) do
    {:ok, len, mask, rest}
  end

  defp decode_length(127, 0, <<len::64, rest::binary>>) do
    {:ok, len, nil, rest}
  end

  defp decode_length(127, 1, <<len::64, mask::4-binary, rest::binary>>) do
    {:ok, len, mask, rest}
  end

  defp decode_length(_, _, _), do: :incomplete

  @doc """
  Encode a WebSocket pong frame (response to ping).
  """
  def encode_pong(payload \\ <<>>) do
    len = byte_size(payload)
    mask_key = :crypto.strong_rand_bytes(4)
    masked = mask(payload, mask_key)
    [<<1::1, 0::3, 0x0A::4, 1::1, len::7>>, mask_key, masked]
  end

  @doc """
  Encode a WebSocket close frame.
  """
  def encode_close do
    mask_key = :crypto.strong_rand_bytes(4)
    [<<1::1, 0::3, 0x08::4, 1::1, 0::7>>, mask_key]
  end

  # XOR masking per RFC 6455
  defp mask(data, <<k0, k1, k2, k3>>) do
    mask_bytes(data, {k0, k1, k2, k3}, 0, [])
  end

  defp mask_bytes(<<>>, _key, _i, acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp mask_bytes(<<b, rest::binary>>, {k0, k1, k2, k3} = key, i, acc) do
    k =
      case rem(i, 4) do
        0 -> k0
        1 -> k1
        2 -> k2
        3 -> k3
      end

    mask_bytes(rest, key, i + 1, [Bitwise.bxor(b, k) | acc])
  end

  defp send_raw(socket, :tcp, data), do: :gen_tcp.send(socket, data)
  defp send_raw(socket, :ssl, data), do: :ssl.send(socket, data)

  defp recv_upgrade_response(socket, transport, buffer) do
    recv_fn =
      case transport do
        :tcp -> fn -> :gen_tcp.recv(socket, 0, 5000) end
        :ssl -> fn -> :ssl.recv(socket, 0, 5000) end
      end

    case recv_fn.() do
      {:ok, data} ->
        buffer = buffer <> data

        if String.contains?(buffer, "\r\n\r\n") do
          {:ok, buffer}
        else
          recv_upgrade_response(socket, transport, buffer)
        end

      {:error, _} = err ->
        err
    end
  end
end
