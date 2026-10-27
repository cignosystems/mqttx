defmodule MqttX.Server.RetainedStore do
  @moduledoc false

  # Per-listener ETS store for retained messages (§3.3.1.3).
  #
  # Rows are keyed by the topic's segment list in an `:ordered_set`:
  #
  #     {segments, topic, payload, qos, timestamp, expiry_interval, properties, version}
  #
  # `timestamp` (seconds) is when the message was stored, for Message Expiry;
  # `properties` are the PUBLISH properties a subscriber receives with the
  # message (MQTT-3.3.2-4, -15, -16, -17, -20), less Message Expiry, which
  # is recomputed on delivery from `timestamp` and `expiry_interval`;
  # `version` (`{microseconds, node, unique}`) orders writes across nodes. On
  # a distributed node a clear leaves its row behind with a `nil` payload,
  # so a replica written before the clear — from a node that missed it while
  # partitioned — loses to it instead of bringing the message back. Cleared
  # rows are swept after an hour (`sweep_cleared/2`) and are never matched.
  #
  # A subscription filter is answered with a single `:ets.select/2` whose
  # match pattern mirrors the filter — literal segments bound, `+` a wildcard
  # segment, `#` a wildcard tail — so matching runs inside ETS instead of
  # folding the whole table through Elixir per subscribe. On an ordered_set a
  # pattern with a bound literal prefix additionally bounds the traversal to
  # that key range, so `sensors/+/temp` only walks keys starting with
  # `["sensors", …]`.
  #
  # All writes funnel through `store/6` so the §4.7.2 `$`-guard, the
  # listener's size cap, and message-expiry bookkeeping live in one place
  # (previously duplicated between `MqttX.Transport.Handler` and
  # `MqttX.Server.WillDelay`).

  require Logger

  alias MqttX.Topic

  @type table :: :ets.table()

  @doc """
  Create (or reuse) the named retained table for a listener.

  Idempotent: transports call this on listener (re)start, and the table —
  owned by whichever process first created it — survives listener restarts
  within the same BEAM.
  """
  @spec create_table(atom()) :: atom()
  def create_table(name) when is_atom(name) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ref ->
        name
    end
  end

  @doc """
  Create an anonymous retained table (used by tests).
  """
  @spec new_table() :: table()
  def new_table do
    :ets.new(__MODULE__, [:public, :ordered_set])
  end

  @doc """
  Store (or, for an empty payload, clear — §3.3.1.3) a retained message.

  Must be called only after the user handler accepted the publish. The store
  is bounded by `max` distinct topics; existing topics can always be
  overwritten.
  """
  @spec store(
          table(),
          binary() | Topic.normalized_topic(),
          binary() | nil,
          0 | 1 | 2,
          map() | nil,
          non_neg_integer() | nil
        ) :: :ok
  def store(table, topic, payload, qos, properties, max) do
    _ = write(table, topic, payload, qos, properties, max)
    :ok
  end

  @doc """
  `store/6`, returning the row written — a cleared topic's row has a `nil`
  payload — or `:dropped` at the cap, so the write can be replicated to
  other nodes.
  """
  @spec write(
          table(),
          binary() | Topic.normalized_topic(),
          binary() | nil,
          0 | 1 | 2,
          map() | nil,
          non_neg_integer() | nil
        ) :: {:ok, tuple()} | :dropped
  def write(table, topic, payload, qos, properties, max) do
    segments = Topic.normalize(topic)
    existing = :ets.lookup(table, segments)
    version = next_version(existing)
    now = System.system_time(:second)

    cond do
      payload in [nil, <<>>] ->
        row = {segments, Topic.flatten(segments), nil, 0, now, nil, %{}, version}

        # On a distributed node the cleared row stays as a marker, so a
        # stale copy from a node that missed the clear loses to it. A marker
        # for a topic not here counts toward the cap like a message would,
        # so clears cannot grow the table past it. The clear is sent to the
        # other nodes either way.
        cond do
          not Node.alive?() -> :ets.delete(table, segments)
          (existing == [] and max) && :ets.info(table, :size) >= max -> :ok
          true -> :ets.insert(table, row)
        end

        {:ok, row}

      max && existing == [] && :ets.info(table, :size) >= max ->
        Logger.warning(
          "[MqttX.Server.RetainedStore] Retained store full (#{max} topics) — " <>
            "dropping retained message for #{inspect(Topic.flatten(segments))}"
        )

        :dropped

      true ->
        properties = properties || %{}
        expiry_interval = Map.get(properties, :message_expiry_interval)

        row =
          {segments, Topic.flatten(segments), payload, qos, now, expiry_interval,
           forwarded_properties(properties), version}

        :ets.insert(table, row)
        {:ok, row}
    end
  end

  # Later than the clock, and than whatever this node already has for the
  # topic: a write here must win wherever the row it replaces went, even if
  # another node's clock is ahead
  defp next_version(existing) do
    now = System.system_time(:microsecond)

    time =
      case existing do
        [{_, _, _, _, _, _, _, {time, _, _}}] when time >= now -> time + 1
        _ -> now
      end

    {time, node(), :erlang.unique_integer([:monotonic])}
  end

  @doc """
  Apply a row another node wrote (a cleared row included): it replaces this
  node's row for the topic unless that one is as new or newer. The cap
  applies to messages on topics new here.
  """
  @spec apply_replica(table(), tuple(), pos_integer() | nil) :: :ok
  def apply_replica(table, {segments, _, _payload, _, _, _, _, version} = row, max) do
    case :ets.lookup(table, segments) do
      [{_, _, _, _, _, _, _, existing}] when existing >= version ->
        :ok

      # New here, a message or a clear's marker alike: only within the cap
      [] when max != nil ->
        if :ets.info(table, :size) < max, do: :ets.insert(table, row)
        :ok

      _ ->
        :ets.insert(table, row)
        :ok
    end
  end

  @doc "Forget cleared topics older than `ttl` seconds. Returns how many went."
  @spec sweep_cleared(table(), pos_integer()) :: non_neg_integer()
  def sweep_cleared(table, ttl) do
    cutoff = System.system_time(:microsecond) - ttl * 1_000_000

    :ets.select_delete(table, [
      {{:_, :_, nil, :_, :_, :_, :_, {:"$1", :_, :_}}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  @doc """
  Every row, cleared ones included, for a node joining the cluster: `fun` is
  called with lists of at most `size` rows, so a large table is not copied
  into one message.
  """
  @spec each_chunk(table(), pos_integer(), ([tuple()] -> any())) :: :ok
  def each_chunk(table, size, fun), do: chunks(:ets.select(table, [{:_, [], [:"$_"]}], size), fun)

  defp chunks(:"$end_of_table", _fun), do: :ok

  defp chunks({rows, continuation}, fun) do
    fun.(rows)
    chunks(:ets.select(continuation), fun)
  end

  @doc """
  Return the non-expired retained messages matching a subscription filter, as
  `{topic, payload, qos, timestamp, expiry_interval, properties}` tuples.

  Expired entries encountered along the way are deleted. Per §4.7.2, a filter
  whose first level is a wildcard does not match `$`-prefixed topics.
  """
  @spec match(table(), binary() | Topic.normalized_topic()) ::
          [{binary(), binary(), 0 | 1 | 2, integer() | nil, non_neg_integer() | nil, map()}]
  def match(table, filter) do
    filter = Topic.normalize(filter)
    now = System.system_time(:second)

    candidates =
      if Topic.wildcard?(filter) do
        :ets.select(table, [
          {{key_pattern(filter), :_, :"$1", :_, :_, :_, :_, :_}, [{:"=/=", :"$1", nil}], [:"$_"]}
        ])
      else
        # An all-literal filter is exactly a key
        for {_, _, payload, _, _, _, _, _} = row <- :ets.lookup(table, filter),
            payload != nil,
            do: row
      end

    # Expiry runs on everything the select reached — BEFORE the §4.7.2
    # $-reject — so expired $-prefixed rows matched by a wildcard filter are
    # still purged (this lazy delete is the store's only expiry sweep, and a
    # store pinned at its cap by expired rows would otherwise never recover).
    {live, expired} =
      Enum.split_with(candidates, fn {_key, _topic, _payload, _qos, ts, exp, _props, _version} ->
        not expired?(ts, exp, now)
      end)

    Enum.each(expired, fn {key, _, _, _, _, _, _, _} -> :ets.delete(table, key) end)

    live
    |> reject_dollar_topics(filter)
    |> Enum.map(fn {_key, topic, payload, qos, ts, exp, props, _version} ->
      {topic, payload, qos, ts, exp, props}
    end)
  end

  # Build the ETS key pattern for a normalized filter. `#` matches the parent
  # level and everything below it, which is exactly a wildcard list tail
  # (`["a" | :_]` matches `["a"]`, `["a", "b"]`, …).
  defp key_pattern([:multi_level | _]), do: :_
  defp key_pattern([:single_level | rest]), do: [:_ | key_pattern(rest)]
  defp key_pattern([segment | rest]) when is_binary(segment), do: [segment | key_pattern(rest)]
  defp key_pattern([]), do: []

  # §4.7.2: filters starting with a wildcard must not match $-prefixed topics.
  # Only relevant when the first filter level is a wildcard — a literal first
  # level is already bound in the select pattern.
  defp reject_dollar_topics(rows, [first | _]) when first in [:single_level, :multi_level] do
    Enum.reject(rows, fn
      {[<<"$", _::binary>> | _], _, _, _, _, _, _, _} -> true
      _ -> false
    end)
  end

  defp reject_dollar_topics(rows, _filter), do: rows

  # Topic Alias is the publisher's connection state and a Subscription
  # Identifier belongs to each subscriber's subscription (§3.3.4), so neither
  # is kept; Message Expiry has its own column
  defp forwarded_properties(properties),
    do: Map.drop(properties, [:topic_alias, :subscription_identifier, :message_expiry_interval])

  defp expired?(nil, _exp, _now), do: false
  defp expired?(_ts, nil, _now), do: false
  defp expired?(ts, exp, now), do: now - ts > exp
end
