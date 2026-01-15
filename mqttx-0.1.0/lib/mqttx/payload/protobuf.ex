defmodule MqttX.Payload.Protobuf do
  @moduledoc """
  Protocol Buffers payload codec using Protox.

  Requires the `protox` optional dependency.

  Unlike JSON, Protobuf requires knowing the message type for decoding.
  This codec provides both a generic interface and message-specific functions.

  ## Usage

      # Encoding (returns iodata by default)
      {:ok, binary} = MqttX.Payload.Protobuf.encode(my_proto_struct)

      # Decoding (requires message module)
      {:ok, struct} = MqttX.Payload.Protobuf.decode(binary, MyMessage)

      # For the behaviour interface, use with a message type in the term
      {:ok, binary} = MqttX.Payload.Protobuf.encode({MyMessage, data})
  """

  @behaviour MqttX.Payload

  @impl true
  def encode(struct) when is_struct(struct) do
    if Code.ensure_loaded?(Protox) do
      case Protox.encode(struct) do
        {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
        {:error, reason} -> {:error, {:protobuf_encode_error, reason}}
      end
    else
      {:error, :protox_not_available}
    end
  end

  def encode({module, data}) when is_atom(module) and is_map(data) do
    if Code.ensure_loaded?(Protox) do
      struct = struct(module, data)
      encode(struct)
    else
      {:error, :protox_not_available}
    end
  end

  def encode(_term) do
    {:error, :invalid_protobuf_term}
  end

  @impl true
  def decode(binary) when is_binary(binary) do
    # Generic decode requires message type - return error
    {:error, :message_type_required}
  end

  @doc """
  Decode a Protobuf message with the specified message module.

  ## Example

      {:ok, message} = MqttX.Payload.Protobuf.decode(binary, MyProto.Message)
  """
  @spec decode(binary(), module()) :: {:ok, struct()} | {:error, term()}
  def decode(binary, message_module) when is_binary(binary) and is_atom(message_module) do
    if Code.ensure_loaded?(Protox) do
      case Protox.decode(binary, message_module) do
        {:ok, struct} -> {:ok, struct}
        {:error, reason} -> {:error, {:protobuf_decode_error, reason}}
      end
    else
      {:error, :protox_not_available}
    end
  end

  @doc """
  Encode to iodata (more efficient, avoids binary copy).
  """
  @spec encode_iodata(struct()) :: {:ok, iodata()} | {:error, term()}
  def encode_iodata(struct) when is_struct(struct) do
    if Code.ensure_loaded?(Protox) do
      Protox.encode(struct)
    else
      {:error, :protox_not_available}
    end
  end
end
