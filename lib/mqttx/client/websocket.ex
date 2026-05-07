defmodule MqttX.Client.WebSocket do
  @moduledoc false
  # Minimal WebSocket client for MQTT over WebSocket.
  # Handles HTTP upgrade handshake and WebSocket binary framing (RFC 6455).
  # Supports binary, text, ping/pong, close, and continuation frames.

  require Logger

  # RFC 6455 §1.3
  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @typedoc """
  Opaque fragmentation state threaded across `decode_frames/2` calls. A WebSocket
  message can be split across multiple frames (FIN=0 starts/continues, FIN=1
  ends); since one TCP read can land mid-message, we keep the partial buffer
  here. `{<<>>, nil}` means no message in progress.
  """
  @type frag_state :: {binary(), :binary | :text | nil}

  @initial_frag {<<>>, nil}

  @doc """
  Initial fragmentation state — pass into `decode_frames/2` on first call.
  """
  def initial_frag, do: @initial_frag

  @doc """
  Perform WebSocket HTTP upgrade over an existing TCP/SSL socket.
  Returns :ok on successful upgrade or {:error, reason}.
  """
  def upgrade(socket, transport, host, path) do
    raw_key = :crypto.strong_rand_bytes(16)
    key = Base.encode64(raw_key)

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
         {:ok, response} <- recv_upgrade_response(socket, transport, <<>>),
         :ok <- validate_upgrade_response(response, key) do
      :ok
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
  Decode WebSocket frames from a binary buffer, threading fragmentation state.

  Returns `{:ok, payloads, rest, new_frag_state}` for normal data frames or
  `{:close, payloads}` if a Close frame was seen. Callers that don't need to
  distinguish fragmented messages can use `decode_frames/1` (initial state).
  """
  def decode_frames(buffer), do: decode_frames(buffer, @initial_frag)

  def decode_frames(buffer, frag) do
    decode_frames(buffer, [], frag)
  end

  defp decode_frames(buffer, acc, {frag_buf, frag_type} = frag) do
    case decode_one_frame(buffer) do
      {:ok, :ping, _payload, rest} ->
        decode_frames(rest, acc, frag)

      {:ok, :pong, _payload, rest} ->
        decode_frames(rest, acc, frag)

      {:ok, :close, _payload, _rest} ->
        {:close, Enum.reverse(acc)}

      # First fragment (FIN=0, opcode=binary|text)
      {:ok, {:fragment_start, type}, payload, rest} ->
        decode_frames(rest, acc, {payload, type})

      # Middle fragment (FIN=0, opcode=continuation 0x00)
      {:ok, :fragment_middle, payload, rest} ->
        decode_frames(rest, acc, {frag_buf <> payload, frag_type})

      # Final fragment (FIN=1, opcode=continuation 0x00)
      {:ok, :fragment_end, payload, rest} ->
        complete = frag_buf <> payload
        decode_frames(rest, [complete | acc], @initial_frag)

      # Standalone complete data frame (FIN=1, opcode=binary|text)
      {:ok, type, payload, rest} when type in [:binary, :text] ->
        decode_frames(rest, [payload | acc], frag)

      :incomplete ->
        {:ok, Enum.reverse(acc), buffer, frag}
    end
  end

  defp decode_one_frame(<<fin::1, _rsv::3, opcode::4, second_byte, rest::binary>>) do
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

        type = classify_frame(fin, opcode)
        {:ok, type, payload, remaining}

      {:ok, _len, _mask_key, _payload_rest} ->
        :incomplete

      :incomplete ->
        :incomplete
    end
  end

  defp decode_one_frame(_), do: :incomplete

  defp classify_frame(1, 0x00), do: :fragment_end
  defp classify_frame(0, 0x00), do: :fragment_middle
  defp classify_frame(0, 0x01), do: {:fragment_start, :text}
  defp classify_frame(0, 0x02), do: {:fragment_start, :binary}
  defp classify_frame(1, 0x01), do: :text
  defp classify_frame(1, 0x02), do: :binary
  defp classify_frame(_, 0x08), do: :close
  defp classify_frame(_, 0x09), do: :ping
  defp classify_frame(_, 0x0A), do: :pong
  # Unknown opcode — treat as binary so it surfaces upstream rather than hanging
  defp classify_frame(_, _), do: :binary

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

  # XOR masking per RFC 6455. `:crypto.exor/2` is dramatically faster than the
  # previous byte-by-byte recursion (especially for large MQTT publishes) — it
  # delegates to the OpenSSL/SIMD path on most VMs.
  defp mask(<<>>, _key), do: <<>>

  defp mask(data, mask_key) when byte_size(mask_key) == 4 do
    data_len = byte_size(data)
    full = div(data_len, 4)
    rem_bytes = rem(data_len, 4)
    pad = :binary.copy(mask_key, full) <> binary_part(mask_key, 0, rem_bytes)
    :crypto.exor(data, pad)
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

  # RFC 6455 §4.1: validate the server's upgrade response. Required:
  #   - Status line "HTTP/1.x 101 ..."
  #   - "Upgrade: websocket" header
  #   - Sec-WebSocket-Accept = Base64(SHA1(client_key + magic GUID))
  # Strongly recommended:
  #   - Sec-WebSocket-Protocol echoed as "mqtt" (we only warn if missing —
  #     several MQTT brokers omit it but otherwise speak the protocol fine).
  defp validate_upgrade_response(response, client_key) do
    cond do
      not status_101?(response) ->
        {:error, :upgrade_failed}

      not String.contains?(String.downcase(response), "upgrade: websocket") ->
        {:error, :upgrade_failed}

      not accept_matches?(response, client_key) ->
        {:error, :sec_websocket_accept_mismatch}

      true ->
        warn_if_protocol_missing(response)
        :ok
    end
  end

  defp status_101?(response) do
    case String.split(response, "\r\n", parts: 2) do
      [status_line | _] ->
        # "HTTP/1.1 101 Switching Protocols"
        String.match?(status_line, ~r/^HTTP\/1\.[01]\s+101(\s|$)/)

      _ ->
        false
    end
  end

  defp accept_matches?(response, client_key) do
    expected = expected_accept(client_key)

    case Regex.run(~r/Sec-WebSocket-Accept:\s*([^\r\n]+)/i, response) do
      [_, value] -> String.trim(value) == expected
      nil -> false
    end
  end

  defp expected_accept(client_key) do
    :sha
    |> :crypto.hash(client_key <> @ws_guid)
    |> Base.encode64()
  end

  defp warn_if_protocol_missing(response) do
    case Regex.run(~r/Sec-WebSocket-Protocol:\s*([^\r\n]+)/i, response) do
      [_, value] ->
        if String.downcase(String.trim(value)) != "mqtt" do
          Logger.warning(
            "[MqttX.Client.WebSocket] Server echoed Sec-WebSocket-Protocol=#{inspect(value)} (expected mqtt)"
          )
        end

      nil ->
        Logger.debug("[MqttX.Client.WebSocket] Server did not echo Sec-WebSocket-Protocol header")
    end
  end
end
