defmodule MqttX.Server.Delivery do
  @moduledoc false

  # Fan-out behind MqttX.Server.deliver/3: match a message against every
  # session of a listener and hand it to each one. Delivery always goes
  # through the session's queue in MqttX.Server.SessionStore — written first,
  # then the connection (if there is one) is poked to drain it. Sending to the
  # connection process directly would lose a message that lands in the
  # mailbox of a connection that is closing, and a queued message cannot be
  # lost that way: whichever connection next owns the session drains it.

  require Logger

  alias MqttX.Server.SessionStore
  alias MqttX.Topic

  @default_max_outbound_queue 10_000

  @type ctx :: %{
          sessions: SessionStore.t(),
          retained_table: :ets.table(),
          max_outbound_queue: pos_integer() | nil
        }

  @doc """
  The listener context deliver/4 works from, built once per listener from the
  handler options (whose `:transport_opts` hold the protocol options).
  """
  @spec listener_context(term(), SessionStore.t(), :ets.table()) :: ctx()
  def listener_context(handler_opts, sessions, retained_table) do
    protocol_opts =
      if Keyword.keyword?(handler_opts),
        do: Keyword.get(handler_opts, :transport_opts, %{}),
        else: %{}

    %{
      sessions: sessions,
      retained_table: retained_table,
      max_outbound_queue: max_outbound_queue(protocol_opts)
    }
  end

  @doc "The :max_outbound_queue protocol option, normalized (`nil` = unbounded)."
  @spec max_outbound_queue(term()) :: pos_integer() | nil
  def max_outbound_queue(protocol_opts) do
    value =
      cond do
        is_map(protocol_opts) -> Map.get(protocol_opts, :max_outbound_queue)
        is_list(protocol_opts) -> Keyword.get(protocol_opts, :max_outbound_queue)
        true -> nil
      end

    case value do
      :infinity -> nil
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_outbound_queue
    end
  end

  @doc """
  Deliver `payload` on `topic` to every session subscribed to it. Returns the
  number of sessions it was queued for.
  """
  @spec deliver(ctx(), binary() | [binary()], term(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def deliver(ctx, topic, payload, opts) when is_map(opts) do
    topic = Topic.flatten(topic)

    with {:ok, _segments} <- Topic.validate_publish(topic),
         {:ok, payload, opts} <- encode_payload(payload, opts) do
      publisher = Map.get(opts, :publisher)

      # Topic Alias is per-connection state the broker never assigns
      # (MQTT-3.1.2-26) and Subscription Identifiers belong to each
      # subscriber's own subscriptions (§3.3.4): neither may be relayed
      opts =
        opts
        |> Map.delete(:publisher)
        |> Map.update(:properties, %{}, fn props ->
          Map.drop(props || %{}, [:topic_alias, :subscription_identifier])
        end)

      queued_at = System.monotonic_time(:millisecond)
      online? = fn client -> connections(ctx, client) != [] end

      count =
        ctx.sessions
        |> SessionStore.match(topic, publisher, online?)
        |> Enum.count(fn {client, sub_opts} ->
          enqueue(ctx, client, topic, payload, apply_subscription(opts, sub_opts), queued_at)
        end)

      {:ok, count}
    end
  end

  @doc """
  Apply a `:codec` (a `MqttX.Payload` module) named in `opts`: the payload is a
  term to encode with it, and the codec's metadata (payload format indicator,
  content type) is merged under any explicit properties.
  """
  @spec encode_payload(term(), map()) :: {:ok, binary(), map()} | {:error, term()}
  def encode_payload(payload, %{codec: codec} = opts) when not is_nil(codec) do
    with {:ok, binary, properties} <-
           MqttX.Payload.encode_with(codec, payload, Map.get(opts, :properties, %{})) do
      {:ok, binary, opts |> Map.delete(:codec) |> Map.put(:properties, properties)}
    end
  end

  def encode_payload(payload, opts), do: {:ok, payload, opts}

  # The subscription's options shape the delivery: QoS capped at the granted
  # QoS (§3.8.4), the retain flag kept only for Retain As Published
  # (§3.3.1.3), its Subscription Identifier(s) attached (§3.3.4).
  defp apply_subscription(opts, sub_opts) do
    qos = min(Map.get(opts, :qos, 0), Map.get(sub_opts, :qos, 0))
    retain = !!(Map.get(opts, :retain, false) && Map.get(sub_opts, :retain_as_published, false))
    properties = Map.get(opts, :properties, %{})

    properties =
      case Map.get(sub_opts, :subscription_identifier) do
        nil -> properties
        id_or_ids -> Map.put(properties, :subscription_identifier, id_or_ids)
      end

    %{qos: qos, retain: retain, properties: properties}
  end

  defp enqueue(ctx, client, topic, payload, opts, queued_at) do
    pids = connections(ctx, client)

    cond do
      # Queueing QoS 0 for an absent client is optional (§4.1) and this
      # broker does not do it
      pids == [] and opts.qos == 0 ->
        false

      # Subscriptions outlive a session only until its expiry is noticed
      pids == [] and not SessionStore.exists?(ctx.sessions, client) ->
        false

      true ->
        entry = {topic, payload, opts, queued_at}

        case SessionStore.enqueue(ctx.sessions, client, entry, ctx.max_outbound_queue) do
          :ok ->
            Enum.each(pids, &send(&1, :mqttx_drain))
            true

          {:error, :full} ->
            Logger.warning(
              "[MqttX.Server] Queue full (#{ctx.max_outbound_queue}) — dropping QoS #{opts.qos} " <>
                "message on #{inspect(topic)} for #{inspect(client)}"
            )

            false
        end
    end
  end

  # The connection(s) currently holding this client id on the listener — the
  # same registry and scope session takeover uses
  defp connections(ctx, client) do
    for {pid, _} <- Registry.lookup(MqttX.Server.ConnectionRegistry, {ctx.retained_table, client}),
        do: pid
  end
end
