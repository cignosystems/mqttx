defmodule MqttX.Payload.Protobuf do
  @moduledoc """
  Protocol Buffers payload codec using Protox.

  Requires the `protox` optional dependency.

  Unlike JSON, Protobuf requires knowing the message type for decoding.
  This codec provides both a generic interface and message-specific functions.

  ## Usage

      # Encoding (a binary; encode_iodata/1 for iodata)
      {:ok, binary} = MqttX.Payload.Protobuf.encode(my_proto_struct)

      # Decoding (requires message module)
      {:ok, struct} = MqttX.Payload.Protobuf.decode(binary, MyMessage)

      # For the behaviour interface, use with a message type in the term
      {:ok, binary} = MqttX.Payload.Protobuf.encode({MyMessage, data})
  """

  @behaviour MqttX.Payload

  @decode_doc """
  Decode a Protobuf message with the specified message module.

  ## Example

      {:ok, message} = MqttX.Payload.Protobuf.decode(binary, MyProto.Message)
  """

  @encode_iodata_doc """
  Encode to iodata (more efficient, avoids binary copy).
  """

  # Binary data, so the format indicator stays at its default (0); only the
  # content type is declared.
  @impl true
  def metadata, do: %{content_type: "application/protobuf"}

  @impl true
  def decode(binary) when is_binary(binary) do
    # Generic decode requires message type - return error
    {:error, :message_type_required}
  end

  # Protox is an optional package: what calls it is compiled only when it is
  # present, so a project without it gets no undefined-function warnings and
  # the codec answers :protox_not_available instead
  if Code.ensure_loaded?(Protox) do
    @impl true
    def encode(struct) when is_struct(struct) do
      with {:ok, iodata} <- encode_iodata(struct), do: {:ok, IO.iodata_to_binary(iodata)}
    end

    def encode({module, data}) when is_atom(module) and is_map(data),
      do: encode_message(module, data)

    def encode(_term), do: {:error, :invalid_protobuf_term}

    @doc @decode_doc
    @spec decode(binary(), module()) :: {:ok, struct()} | {:error, term()}
    def decode(binary, message_module) when is_binary(binary) and is_atom(message_module) do
      case Protox.decode(binary, message_module) do
        {:ok, struct} -> {:ok, struct}
        {:error, reason} -> {:error, {:protobuf_decode_error, reason}}
      end
    end

    @doc @encode_iodata_doc
    @spec encode_iodata(struct()) :: {:ok, iodata()} | {:error, term()}
    def encode_iodata(struct) when is_struct(struct) do
      case Protox.encode(struct) do
        {:ok, iodata, _size} -> {:ok, iodata}
        {:error, reason} -> {:error, {:protobuf_encode_error, reason}}
      end
    rescue
      e -> {:error, {:protobuf_encode_error, e}}
    end
  else
    @impl true
    def encode(struct) when is_struct(struct), do: {:error, :protox_not_available}

    def encode({module, data}) when is_atom(module) and is_map(data),
      do: encode_message(module, data)

    def encode(_term), do: {:error, :invalid_protobuf_term}

    @doc @decode_doc
    @spec decode(binary(), module()) :: {:ok, struct()} | {:error, term()}
    def decode(binary, message_module) when is_binary(binary) and is_atom(message_module),
      do: {:error, :protox_not_available}

    @doc @encode_iodata_doc
    @spec encode_iodata(struct()) :: {:ok, iodata()} | {:error, term()}
    def encode_iodata(struct) when is_struct(struct), do: {:error, :protox_not_available}
  end

  # A message given as its module and fields
  defp encode_message(module, data) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0),
      do: encode(struct(module, data)),
      else: {:error, {:unknown_message_module, module}}
  end
end
