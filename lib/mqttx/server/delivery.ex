defmodule MqttX.Server.Delivery do
  @moduledoc false

  # Fan-out behind MqttX.Server.deliver/3: match a message against every
  # session of a listener and hand it to each one. A session that outlives
  # its connection gets the message through its queue in
  # MqttX.Server.SessionStore — written first, then the connection (if any)
  # is poked to drain it — because a message sent straight to a closing
  # connection's mailbox would be lost, while a queued one is drained by
  # whichever connection next owns the session. A session that ends with its
  # connection has nothing to lose that way, so it is sent to directly: the
  # common clean-session case stays off the store and off the publisher's
  # process (measured at roughly three times the fan-out rate).

  require Logger

  alias MqttX.Packet.Buffer
  alias MqttX.Server.Cluster
  alias MqttX.Server.SessionStore
  alias MqttX.Topic

  @default_max_outbound_queue 10_000

  @default_max_retained 100_000
  @default_session_flush_interval 1_000

  @type ctx :: %{
          required(:sessions) => SessionStore.t(),
          required(:retained_table) => :ets.table(),
          required(:max_outbound_queue) => pos_integer() | nil,
          required(:listener) => term() | nil,
          optional(:max_retained_messages) => pos_integer() | nil,
          optional(:session_flush_interval) => pos_integer()
        }

  @doc """
  The listener context deliver/4 works from, built once per listener from the
  handler options (whose `:transport_opts` hold the protocol options) and the
  listener's own start options.
  """
  @spec listener_context(term(), SessionStore.t(), :ets.table(), keyword()) :: ctx()
  def listener_context(handler_opts, sessions, retained_table, listener_opts \\ []) do
    protocol_opts =
      if Keyword.keyword?(handler_opts),
        do: Keyword.get(handler_opts, :transport_opts, %{}),
        else: %{}

    max_retained =
      case get_opt(protocol_opts, :max_retained_messages) do
        :infinity -> nil
        n when is_integer(n) and n > 0 -> n
        _ -> @default_max_retained
      end

    flush_interval =
      case Keyword.get(listener_opts, :session_flush_interval) do
        n when is_integer(n) and n > 0 -> n
        _ -> @default_session_flush_interval
      end

    %{
      sessions: sessions,
      retained_table: retained_table,
      max_outbound_queue: max_outbound_queue(protocol_opts),
      max_retained_messages: max_retained,
      session_flush_interval: flush_interval,
      listener: sessions.listener
    }
  end

  defp get_opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_opt(_opts, _key), do: nil

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
      listener = ctx[:listener]

      # Every node sees the message under one id, so a session moving
      # between two of them gets it once
      id = if listener, do: make_ref()
      count = fan_out(ctx, id, topic, payload, opts, :all)

      # Every other node of the listener's group fans out on its own side,
      # with the payload already encoded; shared groups were decided here
      if listener, do: Cluster.deliver(listener, id, topic, payload, opts)

      {:ok, count}
    end
  end

  @doc false
  # The fan-out on this node for a message another node already encoded. Its
  # shared groups are left out: the delivering node picked one member for
  # each, across the cluster, and sent that one directly.
  def deliver_local(ctx, id, topic, payload, opts),
    do: {:ok, fan_out(ctx, id, topic, payload, opts, :skip)}

  @doc false
  # One delivery to one session on this node, from another node: a session
  # that moved here from it. `opts`
  # already has the subscription applied; `age` is how long ago (ms) the
  # message was queued there.
  def deliver_to(ctx, client, {id, topic, payload, opts, age}) do
    queued_at = System.monotonic_time(:millisecond) - age
    enqueue(ctx, id, client, topic, payload, opts, queued_at, :forwarded)
  end

  defp fan_out(ctx, id, topic, payload, opts, shared) do
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

    ctx.sessions
    |> SessionStore.match(topic, publisher, online?(ctx), shared)
    |> Enum.count(fn
      {client, sub_opts} ->
        opts = apply_subscription(opts, sub_opts)
        enqueue(ctx, id, client, topic, payload, opts, queued_at, :direct)

      # A shared group's member on another node: this node's cluster member
      # sends it there and picks another member if that node does not take it
      {:remote, node, client, sub_opts, {filter, group}} ->
        shared = %{
          id: id,
          topic: topic,
          payload: payload,
          opts: opts,
          publisher: publisher,
          filter: filter,
          group: group,
          queued_at: queued_at,
          tried: MapSet.new([{node, client}]),
          offline: []
        }

        Cluster.deliver_shared(ctx.listener, node, client, sub_opts, shared)
        false
    end)
  end

  defp online?(ctx), do: fn client -> connections(ctx, client) != [] end

  @doc false
  # A shared group's member on this node, picked by another node: `:ok` if
  # the message was taken, `:offline` if its client is not connected (the
  # picking node tries a connected member first, and comes back with
  # `force` if there is none), `:gone` if it cannot be delivered here.
  def deliver_shared(ctx, client, {id, topic, payload, opts, age}, force) do
    queued_at = System.monotonic_time(:millisecond) - age

    case SessionStore.get(ctx.sessions, client) do
      nil ->
        :gone

      session ->
        online = connections(ctx, client) != [] or Map.has_key?(session, :moved_to)

        cond do
          online or Map.has_key?(session, :placeholder) or (force and opts.qos > 0) ->
            if enqueue(ctx, id, client, topic, payload, opts, queued_at, :forwarded),
              do: :ok,
              else: :gone

          opts.qos > 0 ->
            :offline

          true ->
            :gone
        end
    end
  end

  @doc false
  # The next member for a shared delivery the picked member's node did not
  # take: delivered here (`:done`), or `{:send, node, client, sub_opts,
  # message, force, shared}` for the cluster member to send. A member that
  # answered `:offline` is tried again, with `force`, only once no connected
  # member is left.
  def next_shared(ctx, shared) do
    pick =
      SessionStore.pick_shared(
        ctx.sessions,
        shared.filter,
        shared.group,
        shared.publisher,
        shared.tried,
        online?(ctx)
      )

    case {pick, shared.offline} do
      {{:remote, node, client, sub_opts}, _} ->
        shared = %{shared | tried: MapSet.put(shared.tried, {node, client})}
        {:send, node, client, sub_opts, shared_message(shared, sub_opts), false, shared}

      {{client, sub_opts}, _} ->
        opts = apply_subscription(shared.opts, sub_opts)

        enqueue(
          ctx,
          shared.id,
          client,
          shared.topic,
          shared.payload,
          opts,
          shared.queued_at,
          :forwarded
        )

        :done

      {nil, [{node, client, sub_opts} | rest]} ->
        shared = %{shared | offline: rest}
        {:send, node, client, sub_opts, shared_message(shared, sub_opts), true, shared}

      {nil, []} ->
        Logger.debug(
          "[MqttX.Server] No member of shared group #{inspect(shared.group)} took " <>
            "the message on #{inspect(shared.topic)}"
        )

        :done
    end
  end

  @doc false
  def shared_message(shared, sub_opts) do
    opts = apply_subscription(shared.opts, sub_opts)
    age = System.monotonic_time(:millisecond) - shared.queued_at
    {shared.id, shared.topic, shared.payload, opts, age}
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

  @doc false
  # Deliver what was held for a session while its fence was up, oldest
  # first; a copy the node it left forwarded meanwhile went ahead
  def release(ctx, client) do
    case SessionStore.take_held(ctx.sessions, client) do
      [] ->
        :ok

      held ->
        for {id, topic, payload, opts, queued_at} <- held,
            do: enqueue(ctx, id, client, topic, payload, opts, queued_at, :released)

        release(ctx, client)
    end
  end

  # `via`: `:direct` for a message this node matched, `:forwarded` for one
  # another node sent for the session, `:released` for one held here
  defp enqueue(ctx, id, client, topic, payload, opts, queued_at, via) do
    case SessionStore.get(ctx.sessions, client) do
      # The session left for another node: it is delivered there
      %{moved_to: node} ->
        age = System.monotonic_time(:millisecond) - queued_at
        Cluster.deliver_to(ctx.listener, node, client, {id, topic, payload, opts, age})
        true

      # The session is arriving from another node, and both may match the
      # message: only the first copy counts
      %{handoff_until: until} = session when id != nil ->
        cond do
          # It just arrived, and the node it left forwards what it matched
          # before: a message matched here waits behind those, so a
          # publisher's messages keep their order (§4.6)
          via == :direct and SessionStore.fenced?(ctx.sessions, client) ->
            held = {id, topic, Buffer.detach(payload), opts, queued_at}
            SessionStore.hold_message(ctx.sessions, client, held)

            # The fence may have come down while this went in, after the
            # held messages were let out
            if not SessionStore.fenced?(ctx.sessions, client),
              do: Cluster.release(ctx, client)

            true

          until > System.system_time(:millisecond) ->
            # Held messages are older than this one
            if via == :direct and SessionStore.held?(ctx.sessions, client),
              do: Cluster.release(ctx, client)

            if SessionStore.seen?(ctx.sessions, client, id, until),
              do: false,
              else: hand_over(ctx, session, id, client, topic, payload, opts, queued_at)

          true ->
            hand_over(ctx, session, id, client, topic, payload, opts, queued_at)
        end

      session ->
        hand_over(ctx, session, id, client, topic, payload, opts, queued_at)
    end
  end

  defp hand_over(ctx, session, id, client, topic, payload, opts, queued_at) do
    pids = connections(ctx, client)

    cond do
      # Queueing QoS 0 for an absent client is optional (§4.1) and this
      # broker does not do it
      pids == [] and opts.qos == 0 ->
        false

      # Subscriptions outlive a session only until its expiry is noticed
      session == nil ->
        false

      # A session that outlives its connection goes queue-first: a message
      # sent straight to a closing connection would be lost, a queued one is
      # drained by whichever connection next owns the session. A session that
      # ends with its connection (or has none) has nothing to lose that way —
      # the direct send keeps the fan-out off the store and out of the
      # publisher's process.
      pids == [] or session[:persistent] ->
        # The id travels with a queued message, in case the session moves
        opts = if id, do: Map.put(opts, :id, id), else: opts
        queue(ctx, client, pids, {topic, payload, opts, queued_at})

      true ->
        Enum.each(pids, &send(&1, {:mqttx_deliver, client, topic, payload, opts, queued_at}))
        true
    end
  end

  defp queue(ctx, client, pids, {topic, payload, opts, queued_at}) do
    # Kept, maybe for long: with memory of its own, not a reference into the
    # whole read the message arrived in
    entry = {topic, Buffer.detach(payload), opts, queued_at}

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

  # The connection(s) currently holding this client id on the listener — the
  # same registry and scope session takeover uses
  defp connections(ctx, client) do
    key = {ctx.retained_table, client}
    for {pid, _} <- Registry.lookup(MqttX.Server.ConnectionRegistry, key), do: pid
  end
end
