defmodule MqttX.Server.RetainedStore do
  @moduledoc false

  # Per-listener ETS store for retained messages (§3.3.1.3).
  #
  # Rows are keyed by the topic's segment list in an `:ordered_set`:
  #
  #     {segments, topic, payload, qos, timestamp, expiry_interval}
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
  def store(table, topic, payload, _qos, _properties, _max) when payload in [nil, <<>>] do
    :ets.delete(table, Topic.normalize(topic))
    :ok
  end

  def store(table, topic, payload, qos, properties, max) do
    segments = Topic.normalize(topic)

    if max && not :ets.member(table, segments) && :ets.info(table, :size) >= max do
      Logger.warning(
        "[MqttX.Server.RetainedStore] Retained store full (#{max} topics) — " <>
          "dropping retained message for #{inspect(Topic.flatten(segments))}"
      )

      :ok
    else
      timestamp = System.system_time(:second)
      expiry_interval = Map.get(properties || %{}, :message_expiry_interval)

      :ets.insert(
        table,
        {segments, Topic.flatten(segments), payload, qos, timestamp, expiry_interval}
      )

      :ok
    end
  end

  @doc """
  Return the non-expired retained messages matching a subscription filter, as
  `{topic, payload, qos, timestamp, expiry_interval}` tuples.

  Expired entries encountered along the way are deleted. Per §4.7.2, a filter
  whose first level is a wildcard does not match `$`-prefixed topics.
  """
  @spec match(table(), binary() | Topic.normalized_topic()) ::
          [{binary(), binary(), 0 | 1 | 2, integer() | nil, non_neg_integer() | nil}]
  def match(table, filter) do
    filter = Topic.normalize(filter)
    now = System.system_time(:second)

    candidates =
      if Topic.wildcard?(filter) do
        :ets.select(table, [{{key_pattern(filter), :_, :_, :_, :_, :_}, [], [:"$_"]}])
      else
        # An all-literal filter is exactly a key
        :ets.lookup(table, filter)
      end

    # Expiry runs on everything the select reached — BEFORE the §4.7.2
    # $-reject — so expired $-prefixed rows matched by a wildcard filter are
    # still purged (this lazy delete is the store's only expiry sweep, and a
    # store pinned at its cap by expired rows would otherwise never recover).
    {live, expired} =
      Enum.split_with(candidates, fn {_key, _topic, _payload, _qos, ts, exp} ->
        not expired?(ts, exp, now)
      end)

    Enum.each(expired, fn {key, _, _, _, _, _} -> :ets.delete(table, key) end)

    live
    |> reject_dollar_topics(filter)
    |> Enum.map(fn {_key, topic, payload, qos, ts, exp} -> {topic, payload, qos, ts, exp} end)
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
      {[<<"$", _::binary>> | _], _, _, _, _, _} -> true
      _ -> false
    end)
  end

  defp reject_dollar_topics(rows, _filter), do: rows

  defp expired?(nil, _exp, _now), do: false
  defp expired?(_ts, nil, _now), do: false
  defp expired?(ts, exp, now), do: now - ts > exp
end
