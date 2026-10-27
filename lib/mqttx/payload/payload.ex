defmodule MqttX.Payload do
  @moduledoc """
  Behaviour for payload codecs.

  Payload codecs handle encoding and decoding of MQTT message payloads, and
  declare what they produce — the MQTT 5.0 Payload Format Indicator and
  Content Type (§3.3.2.3.2, §3.3.2.3.9) — so a publish can carry both
  without the caller spelling them out.

  ## Built-in Codecs

  - `MqttX.Payload.Raw` - Pass-through, no encoding, declares nothing
  - `MqttX.Payload.JSON` - JSON via the OTP 27+ built-in `JSON` module;
    declares `payload_format_indicator: 1`, `content_type: "application/json"`
  - `MqttX.Payload.Protobuf` - Protocol Buffers via Protox; declares
    `content_type: "application/protobuf"`

  ## Publishing with a codec

  Pass `codec:` to `MqttX.Client.publish/4` (or the `publish/3` injected by
  `use MqttX`), and the payload is a term:

      MqttX.Client.publish(client, "sensors/room1", %{temp: 21.5},
        qos: 1,
        codec: MqttX.Payload.JSON
      )

  The term is encoded in the calling process, and the codec's `metadata/0`
  is merged into the PUBLISH properties underneath any you pass explicitly.
  A broker handler can do the same from `handle_info/2` with
  `{:publish, topic, term, %{qos: 1, codec: MqttX.Payload.JSON}, state}`.
  On the receiving side `content_type` arrives in the packet's properties,
  so a handler can pick the codec to `decode/1` with.

  ## Custom Codec Example

      defmodule MyCodec do
        @behaviour MqttX.Payload

        @impl true
        def encode(term) do
          {:ok, :erlang.term_to_binary(term)}
        end

        # [:safe]: the bytes come from the network; without it a peer could
        # fill the atom table or send funs. Even so, External Term Format is
        # for payloads from peers you trust.
        @impl true
        def decode(binary) do
          {:ok, :erlang.binary_to_term(binary, [:safe])}
        rescue
          ArgumentError -> {:error, :not_a_term}
        end

        # Optional: what to tell receivers about the bytes
        @impl true
        def metadata, do: %{content_type: "application/x-erlang-binary"}
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

  @typedoc """
  What a codec declares about its output, as PUBLISH properties:
  `:payload_format_indicator` is `1` when the bytes are UTF-8 text
  (§3.3.2.3.2), `:content_type` a MIME type (§3.3.2.3.9).
  """
  @type metadata :: %{
          optional(:payload_format_indicator) => 0 | 1,
          optional(:content_type) => String.t()
        }

  @doc """
  Properties describing this codec's encoding, merged into every PUBLISH
  sent with `codec: __MODULE__`. Optional — a codec that does not define it
  declares nothing.
  """
  @callback metadata() :: metadata()

  @optional_callbacks metadata: 0

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

  @doc """
  The codec's `metadata/0`, or `%{}` if it does not define one.
  """
  @spec metadata(module()) :: metadata()
  def metadata(codec) do
    if Code.ensure_loaded?(codec) and function_exported?(codec, :metadata, 0),
      do: codec.metadata(),
      else: %{}
  end

  @doc """
  Encode `term` with `codec` for publishing.

  Returns the binary payload and `properties` with the codec's metadata
  merged underneath — an explicit `:content_type` or
  `:payload_format_indicator` in `properties` wins. Encoding errors are the
  codec's, unchanged.
  """
  @spec encode_with(module(), term(), map() | nil) :: {:ok, binary(), map()} | {:error, term()}
  def encode_with(codec, term, properties \\ %{}) do
    with {:ok, binary} <- codec.encode(term) do
      {:ok, binary, Map.merge(metadata(codec), properties || %{})}
    end
  end
end
