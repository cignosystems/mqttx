defmodule MqttX.Payload do
  @moduledoc """
  Behaviour for payload codecs.

  Payload codecs handle encoding and decoding of MQTT message payloads.

  ## Built-in Codecs

  - `MqttX.Payload.Raw` - Pass-through, no encoding
  - `MqttX.Payload.JSON` - JSON encoding via Jason
  - `MqttX.Payload.Protobuf` - Protocol Buffers via Protox

  ## Custom Codec Example

      defmodule MyCodec do
        @behaviour MqttX.Payload

        @impl true
        def encode(term) do
          {:ok, :erlang.term_to_binary(term)}
        end

        @impl true
        def decode(binary) do
          {:ok, :erlang.binary_to_term(binary)}
        end
      end
  """

  @doc """
  Encode a term to binary.
  """
  @callback encode(term()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Decode a binary to a term.
  """
  @callback decode(binary()) :: {:ok, term()} | {:error, term()}

  @doc """
  Encode using the specified codec.
  """
  @spec encode(module(), term()) :: {:ok, binary()} | {:error, term()}
  def encode(codec, term) do
    codec.encode(term)
  end

  @doc """
  Decode using the specified codec.
  """
  @spec decode(module(), binary()) :: {:ok, term()} | {:error, term()}
  def decode(codec, binary) do
    codec.decode(binary)
  end
end
