defmodule MqttX.Packet.Buffer do
  @moduledoc false

  # Receive-side reassembly buffer, shared by the broker connection handler
  # and the client (for the MQTT byte stream and for WebSocket frames).
  #
  # The obvious implementation — `buffer <> data`, then try to decode — is
  # quadratic for a packet that arrives across many reads. Decoding
  # pattern-matches the buffer, and a binary that has been matched loses the
  # runtime's in-place append optimization, so every read re-copies
  # everything buffered so far: a 16 MiB packet arriving in 1460-byte
  # segments cost about 7 s of CPU that way.
  #
  # Once the fixed header of an incomplete packet has been read its total
  # length is known, so there is nothing to decode until that many bytes are
  # in hand. Until then each read is consed onto an iolist — O(1), no copy,
  # no match — and the iolist is flattened exactly once, when the packet is
  # complete.
  #
  # Representation: a plain binary while the length of the packet at the head
  # is not known yet (only ever a few header bytes — or nothing, so `<<>>` is
  # a valid empty buffer), otherwise `{chunks, size, need}`.
  #
  # The length is taken on trust from the peer, so the CALLER must apply its
  # packet-size limit to the declared length before stashing: a stashed
  # packet accumulates toward `need` without being looked at again.

  alias MqttX.Packet.Codec

  @type t :: binary() | {chunks :: iodata(), size :: non_neg_integer(), need :: pos_integer()}

  # Reads the total on-the-wire length a packet/frame declares from its
  # leading bytes: `{:ok, total}`, or anything else while the header itself
  # is still incomplete.
  @type framing :: (binary() -> {:ok, non_neg_integer()} | term())

  @spec new() :: t()
  def new, do: <<>>

  @doc """
  Number of bytes currently buffered.
  """
  @spec size(t()) :: non_neg_integer()
  def size(buffer) when is_binary(buffer), do: byte_size(buffer)
  def size({_chunks, size, _need}), do: size

  @doc """
  True while a packet of known length is still arriving — there is nothing to
  decode until more bytes are pushed.
  """
  @spec pending?(t()) :: boolean()
  def pending?(buffer), do: is_tuple(buffer)

  @doc """
  Append received bytes.

  Returns `{:ready, binary}` when the buffered bytes are worth handing to the
  decoder — everything received so far, flattened — or `{:more, buffer}` when
  the packet at the head is known to be incomplete still.
  """
  @spec push(t(), binary()) :: {:ready, binary()} | {:more, t()}
  def push(<<>>, data), do: {:ready, data}

  # Length not known yet: at most a partial fixed header is buffered, so this
  # copies a handful of bytes.
  def push(buffer, data) when is_binary(buffer), do: {:ready, buffer <> data}

  def push({chunks, size, need}, data) do
    size = size + byte_size(data)

    if size < need do
      {:more, {[chunks, data], size, need}}
    else
      {:ready, IO.iodata_to_binary([chunks, data])}
    end
  end

  @doc """
  Keep the undecoded tail the decoder reported as incomplete.

  `framing` reads the declared total length from the tail's header (default:
  the MQTT fixed header). When it is readable, later `push/2` calls wait for
  that many bytes instead of re-attempting a decode on every read.
  """
  @spec stash(binary(), framing()) :: t()
  def stash(rest, framing \\ &Codec.declared_length/1)

  def stash(<<>>, _framing), do: <<>>

  def stash(rest, framing) when is_binary(rest) do
    size = byte_size(rest)

    case framing.(rest) do
      {:ok, need} when need > size -> {rest, size, need}
      _ -> rest
    end
  end
end
