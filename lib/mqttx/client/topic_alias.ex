defmodule MqttX.Client.TopicAlias do
  @moduledoc false

  # MQTT 5.0 topic-alias handling (§3.3.2.3.4) for the client connection.
  # Operates on the connection state map's alias fields:
  # `server_topic_alias_maximum` / `topic_to_alias` / `next_alias` (outgoing)
  # and `alias_to_topic` / `connect_properties` (incoming). All three maps are
  # reset per connection by `apply_connack_settings/2`.

  @doc """
  Apply an outgoing topic alias to a PUBLISH when the server supports them:
  reuse the alias for a repeated topic (sending an empty topic), or assign
  the next free one. Returns `{topic, properties, state}`.
  """
  def apply_outgoing(topic, properties, %{server_topic_alias_maximum: max} = state)
      when max > 0 and not is_map_key(properties, :topic_alias) do
    case Map.get(state.topic_to_alias, topic) do
      nil when state.next_alias <= max ->
        # Assign new alias: send topic + alias (server learns the mapping)
        alias_id = state.next_alias
        new_props = Map.put(properties, :topic_alias, alias_id)
        new_map = Map.put(state.topic_to_alias, topic, alias_id)
        {topic, new_props, %{state | topic_to_alias: new_map, next_alias: alias_id + 1}}

      nil ->
        # All aliases used, send normally
        {topic, properties, state}

      alias_id ->
        # Reuse existing alias: send empty topic + alias
        new_props = Map.put(properties, :topic_alias, alias_id)
        {"", new_props, state}
    end
  end

  def apply_outgoing(topic, properties, state) do
    {topic, properties, state}
  end

  @doc """
  Resolve the topic alias on an incoming PUBLISH.

  The codec normalizes non-empty topics to a list of segments; only the
  alias-without-topic form arrives as the empty binary `""`. Returns
  `{:ok, topic, state}` or `{:error, :invalid_topic_alias | :unknown_topic_alias}`.
  """
  def resolve_incoming(packet, state) do
    topic_alias = get_in(packet, [:properties, :topic_alias])
    topic = packet.topic

    cond do
      # No alias in packet
      is_nil(topic_alias) ->
        {:ok, topic, state}

      # §3.3.2.3.4: Topic Alias 0 is a Protocol Error, and the broker must not
      # exceed the Topic Alias Maximum we advertised in CONNECT.
      topic_alias < 1 or topic_alias > advertised_maximum(state) ->
        {:error, :invalid_topic_alias}

      # Alias with topic: store the mapping
      topic != "" and topic != [] ->
        alias_to_topic = Map.put(state.alias_to_topic, topic_alias, topic)
        {:ok, topic, %{state | alias_to_topic: alias_to_topic}}

      # Alias only: look up from stored mapping. An unmapped alias is a
      # protocol error (§3.3.2.3.4) — never deliver with a made-up topic.
      true ->
        case Map.fetch(state.alias_to_topic, topic_alias) do
          {:ok, resolved_topic} -> {:ok, resolved_topic, state}
          :error -> {:error, :unknown_topic_alias}
        end
    end
  end

  # The Topic Alias Maximum we advertised in CONNECT (§3.1.2.11.5 — absent
  # means 0, i.e. the broker may not use aliases at all).
  defp advertised_maximum(state) do
    Map.get(state.connect_properties || %{}, :topic_alias_maximum, 0)
  end
end
