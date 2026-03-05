defmodule MqttX.Server.Router do
  @moduledoc """
  Topic router for MQTT servers.

  The router maintains a trie-based subscription table and provides efficient
  topic matching for message routing. Matching is O(L + K) where L is the
  topic depth and K is the number of matching subscriptions, compared to
  the previous O(N) linear scan across all subscriptions.

  ## Usage

      router = MqttX.Server.Router.new()
      router = MqttX.Server.Router.subscribe(router, "sensors/+/temp", client_ref, qos: 1)
      router = MqttX.Server.Router.subscribe(router, "alerts/#", client_ref, qos: 0)

      matches = MqttX.Server.Router.match(router, "sensors/room1/temp")
      # => [{client_ref, %{qos: 1}}]

  ## Shared Subscriptions (MQTT 5.0)

  Shared subscriptions allow load balancing messages across multiple clients.
  Use the `$share/group_name/topic_filter` format:

      router = MqttX.Server.Router.subscribe(router, "$share/workers/jobs/#", client1, qos: 1)
      router = MqttX.Server.Router.subscribe(router, "$share/workers/jobs/#", client2, qos: 1)

      # Messages to "jobs/task1" are delivered to client1 or client2 (round-robin)
      matches = MqttX.Server.Router.match(router, "jobs/task1")
      # => [{client1, %{qos: 1}}] or [{client2, %{qos: 1}}]
  """

  alias MqttX.Topic

  @type subscription :: %{
          filter: Topic.normalized_topic(),
          client: term(),
          qos: 0 | 1 | 2,
          opts: map()
        }

  @type shared_group :: %{
          filter: Topic.normalized_topic(),
          members: [{term(), map()}],
          index: non_neg_integer()
        }

  @type t :: %__MODULE__{
          trie: map(),
          by_client: %{
            term() => [
              {:normal, Topic.normalized_topic()} | {:shared, binary(), Topic.normalized_topic()}
            ]
          },
          shared_groups: %{binary() => shared_group()},
          count: non_neg_integer()
        }

  defstruct trie: %{children: %{}, subscribers: %{}},
            by_client: %{},
            shared_groups: %{},
            count: 0

  @doc """
  Create a new empty router.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Add a subscription to the router.

  ## Options

  - `:qos` - Maximum QoS level (default: 0)
  - Any additional options are stored with the subscription

  ## Shared Subscriptions

  Use `$share/group_name/topic_filter` format for shared subscriptions:

      router = MqttX.Server.Router.subscribe(router, "$share/workers/jobs/#", client, qos: 1)
  """
  @spec subscribe(t(), binary() | Topic.normalized_topic(), term(), keyword()) :: t()
  def subscribe(router, filter, client, opts \\ [])

  def subscribe(router, filter, client, opts) when is_binary(filter) do
    case Topic.parse_shared(filter) do
      {:shared, group, topic_filter} ->
        subscribe_shared(router, group, topic_filter, client, opts)

      {:normal, _} ->
        subscribe_normal(router, filter, client, opts)
    end
  end

  def subscribe(router, filter, client, opts) do
    subscribe_normal(router, filter, client, opts)
  end

  defp subscribe_normal(router, filter, client, opts) do
    normalized = normalize_filter(filter)
    qos = Keyword.get(opts, :qos, 0)
    extra_opts = Keyword.drop(opts, [:qos])
    client_opts = Map.put(Map.new(extra_opts), :qos, qos)

    # Insert into trie
    trie = trie_insert(router.trie, normalized, client, client_opts)

    # Track in by_client index
    client_entries = Map.get(router.by_client, client, [])
    by_client = Map.put(router.by_client, client, [{:normal, normalized} | client_entries])

    %{router | trie: trie, by_client: by_client, count: router.count + 1}
  end

  defp subscribe_shared(router, group, topic_filter, client, opts) do
    normalized = normalize_filter(topic_filter)
    qos = Keyword.get(opts, :qos, 0)
    extra_opts = Keyword.drop(opts, [:qos])
    member_opts = Map.put(Map.new(extra_opts), :qos, qos)

    shared_groups =
      Map.update(
        router.shared_groups,
        group,
        # Create new group
        %{filter: normalized, members: [{client, member_opts}], index: 0},
        fn existing_group ->
          # Add client to existing group if not already a member
          if Enum.any?(existing_group.members, fn {c, _} -> c == client end) do
            existing_group
          else
            %{existing_group | members: existing_group.members ++ [{client, member_opts}]}
          end
        end
      )

    # Track in by_client index
    client_entries = Map.get(router.by_client, client, [])
    by_client = Map.put(router.by_client, client, [{:shared, group, normalized} | client_entries])

    %{router | shared_groups: shared_groups, by_client: by_client}
  end

  @doc """
  Remove a subscription from the router.
  """
  @spec unsubscribe(t(), binary() | Topic.normalized_topic(), term()) :: t()
  def unsubscribe(router, filter, client) when is_binary(filter) do
    case Topic.parse_shared(filter) do
      {:shared, group, topic_filter} ->
        unsubscribe_shared(router, group, topic_filter, client)

      {:normal, _} ->
        unsubscribe_normal(router, filter, client)
    end
  end

  def unsubscribe(router, filter, client) do
    unsubscribe_normal(router, filter, client)
  end

  defp unsubscribe_normal(router, filter, client) do
    normalized = normalize_filter(filter)

    # Remove from trie
    {trie, removed} = trie_remove(router.trie, normalized, client)

    # Update by_client index
    client_entries = Map.get(router.by_client, client, [])

    new_client_entries =
      List.delete(client_entries, {:normal, normalized})

    by_client =
      if new_client_entries == [] do
        Map.delete(router.by_client, client)
      else
        Map.put(router.by_client, client, new_client_entries)
      end

    count_delta = if removed, do: 1, else: 0
    %{router | trie: trie, by_client: by_client, count: max(0, router.count - count_delta)}
  end

  defp unsubscribe_shared(router, group, topic_filter, client) do
    normalized = normalize_filter(topic_filter)

    # Remove from shared group
    shared_groups =
      case Map.get(router.shared_groups, group) do
        nil ->
          router.shared_groups

        group_data ->
          new_members = Enum.reject(group_data.members, fn {c, _} -> c == client end)

          if new_members == [] do
            Map.delete(router.shared_groups, group)
          else
            Map.put(router.shared_groups, group, %{group_data | members: new_members})
          end
      end

    # Update by_client index
    client_entries = Map.get(router.by_client, client, [])

    new_client_entries =
      List.delete(client_entries, {:shared, group, normalized})

    by_client =
      if new_client_entries == [] do
        Map.delete(router.by_client, client)
      else
        Map.put(router.by_client, client, new_client_entries)
      end

    %{router | shared_groups: shared_groups, by_client: by_client}
  end

  @doc """
  Remove all subscriptions for a client.
  """
  @spec unsubscribe_all(t(), term()) :: t()
  def unsubscribe_all(router, client) do
    client_entries = Map.get(router.by_client, client, [])

    # Remove each subscription from its respective structure
    {trie, count_removed, shared_groups} =
      Enum.reduce(client_entries, {router.trie, 0, router.shared_groups}, fn
        {:normal, filter}, {trie_acc, removed, sg_acc} ->
          {new_trie, did_remove} = trie_remove(trie_acc, filter, client)
          delta = if did_remove, do: 1, else: 0
          {new_trie, removed + delta, sg_acc}

        {:shared, group, _filter}, {trie_acc, removed, sg_acc} ->
          new_sg =
            case Map.get(sg_acc, group) do
              nil ->
                sg_acc

              group_data ->
                new_members = Enum.reject(group_data.members, fn {c, _} -> c == client end)

                if new_members == [] do
                  Map.delete(sg_acc, group)
                else
                  Map.put(sg_acc, group, %{group_data | members: new_members})
                end
            end

          {trie_acc, removed, new_sg}
      end)

    by_client = Map.delete(router.by_client, client)

    %{
      router
      | trie: trie,
        by_client: by_client,
        shared_groups: shared_groups,
        count: max(0, router.count - count_removed)
    }
  end

  @doc """
  Find all matching subscriptions for a topic.

  Returns a list of `{client, opts}` tuples for each matching subscription.

  For shared subscriptions, only one client per group is selected (round-robin).

  The optional `publisher` parameter enables no_local filtering: subscriptions
  with `no_local: true` are excluded when the publisher matches the subscriber.
  """
  @spec match(t(), binary() | Topic.normalized_topic(), term()) :: [{term(), map()}]
  def match(router, topic, publisher \\ nil) do
    normalized = normalize_topic(topic)

    # Get regular subscription matches via trie traversal
    regular_matches =
      trie_match(router.trie, normalized)
      |> Enum.uniq_by(fn {client, _opts} -> client end)
      |> filter_no_local(publisher)

    # Get shared subscription matches (one per group, round-robin)
    shared_matches =
      router.shared_groups
      |> Enum.filter(fn {_group, data} -> Topic.matches?(data.filter, normalized) end)
      |> Enum.map(fn {_group, data} ->
        index = rem(data.index, length(data.members))
        Enum.at(data.members, index)
      end)

    # Combine, avoiding duplicates (regular takes priority)
    regular_clients = MapSet.new(regular_matches, fn {client, _} -> client end)

    filtered_shared =
      Enum.reject(shared_matches, fn {client, _} -> MapSet.member?(regular_clients, client) end)

    regular_matches ++ filtered_shared
  end

  @doc """
  Find all matching subscriptions and advance round-robin for shared groups.

  This is the same as `match/3` but also updates the router state
  to advance the round-robin index for matched shared subscriptions.

  Returns `{matches, updated_router}`.
  """
  @spec match_and_advance(t(), binary() | Topic.normalized_topic(), term()) ::
          {[{term(), map()}], t()}
  def match_and_advance(router, topic, publisher \\ nil) do
    normalized = normalize_topic(topic)

    # Get regular subscription matches via trie traversal
    regular_matches =
      trie_match(router.trie, normalized)
      |> Enum.uniq_by(fn {client, _opts} -> client end)
      |> filter_no_local(publisher)

    # Get shared subscription matches and advance indices
    {shared_matches, updated_shared_groups} =
      router.shared_groups
      |> Enum.filter(fn {_group, data} -> Topic.matches?(data.filter, normalized) end)
      |> Enum.map_reduce(router.shared_groups, fn {group, data}, acc ->
        index = rem(data.index, length(data.members))
        {client, opts} = Enum.at(data.members, index)

        # Advance the index
        updated_data = %{data | index: data.index + 1}
        updated_acc = Map.put(acc, group, updated_data)

        {{client, opts}, updated_acc}
      end)

    # Combine, avoiding duplicates
    regular_clients = MapSet.new(regular_matches, fn {client, _} -> client end)

    filtered_shared =
      Enum.reject(shared_matches, fn {client, _} -> MapSet.member?(regular_clients, client) end)

    matches = regular_matches ++ filtered_shared
    updated_router = %{router | shared_groups: updated_shared_groups}

    {matches, updated_router}
  end

  @doc """
  Get all subscriptions for a client.
  """
  @spec subscriptions_for(t(), term()) :: [subscription()]
  def subscriptions_for(router, client) do
    router.by_client
    |> Map.get(client, [])
    |> Enum.map(fn
      {:normal, filter} ->
        # Look up the subscriber opts from the trie
        opts = trie_get_subscriber(router.trie, filter, client)
        qos = Map.get(opts, :qos, 0)
        %{filter: filter, client: client, qos: qos, opts: Map.delete(opts, :qos)}

      {:shared, group, filter} ->
        # Look up from shared_groups
        case Map.get(router.shared_groups, group) do
          %{members: members} ->
            {_, member_opts} = Enum.find(members, {client, %{}}, fn {c, _} -> c == client end)
            qos = Map.get(member_opts, :qos, 0)

            %{
              filter: filter,
              client: client,
              qos: qos,
              opts: Map.put(Map.delete(member_opts, :qos), :shared_group, group)
            }

          nil ->
            %{filter: filter, client: client, qos: 0, opts: %{shared_group: group}}
        end
    end)
  end

  @doc """
  Get the total number of subscriptions.
  """
  @spec count(t()) :: non_neg_integer()
  def count(router) do
    router.count
  end

  @doc """
  Get the number of unique clients with subscriptions.
  """
  @spec client_count(t()) :: non_neg_integer()
  def client_count(router) do
    map_size(router.by_client)
  end

  # ============================================================================
  # TRIE OPERATIONS
  # ============================================================================

  # Insert a client subscription at the trie node reached by walking the filter segments
  defp trie_insert(node, [], client, opts) do
    subscribers = Map.put(node.subscribers, client, opts)
    %{node | subscribers: subscribers}
  end

  defp trie_insert(node, [segment | rest], client, opts) do
    key = segment_key(segment)
    child = Map.get(node.children, key, %{children: %{}, subscribers: %{}})
    updated_child = trie_insert(child, rest, client, opts)
    %{node | children: Map.put(node.children, key, updated_child)}
  end

  # Remove a client from the trie node at the given filter path.
  # Returns {updated_node, removed?} and prunes empty nodes on the way back up.
  defp trie_remove(node, [], client) do
    if Map.has_key?(node.subscribers, client) do
      subscribers = Map.delete(node.subscribers, client)
      {%{node | subscribers: subscribers}, true}
    else
      {node, false}
    end
  end

  defp trie_remove(node, [segment | rest], client) do
    key = segment_key(segment)

    case Map.get(node.children, key) do
      nil ->
        {node, false}

      child ->
        {updated_child, removed} = trie_remove(child, rest, client)

        # Prune empty nodes
        children =
          if updated_child.subscribers == %{} and updated_child.children == %{} do
            Map.delete(node.children, key)
          else
            Map.put(node.children, key, updated_child)
          end

        {%{node | children: children}, removed}
    end
  end

  # Match a topic against the trie, collecting all matching subscribers.
  # For each segment, we branch into: exact match, :single_level, and :multi_level.
  defp trie_match(node, []) do
    # Exact end of topic - collect subscribers here
    subscribers = Map.to_list(node.subscribers)

    # Also check for multi-level wildcard at this position
    multi_subs =
      case Map.get(node.children, :multi_level) do
        nil -> []
        multi_node -> Map.to_list(multi_node.subscribers)
      end

    subscribers ++ multi_subs
  end

  defp trie_match(node, [segment | rest]) do
    # 1. Exact segment match
    exact_matches =
      case Map.get(node.children, segment) do
        nil -> []
        child -> trie_match(child, rest)
      end

    # 2. Single-level wildcard (+) match
    single_matches =
      case Map.get(node.children, :single_level) do
        nil -> []
        child -> trie_match(child, rest)
      end

    # 3. Multi-level wildcard (#) match - matches everything from here
    multi_matches =
      case Map.get(node.children, :multi_level) do
        nil -> []
        child -> Map.to_list(child.subscribers)
      end

    exact_matches ++ single_matches ++ multi_matches
  end

  # Look up a specific client's opts at a trie path
  defp trie_get_subscriber(node, [], client) do
    Map.get(node.subscribers, client, %{})
  end

  defp trie_get_subscriber(node, [segment | rest], client) do
    key = segment_key(segment)

    case Map.get(node.children, key) do
      nil -> %{}
      child -> trie_get_subscriber(child, rest, client)
    end
  end

  # Convert a normalized filter segment to a trie key
  defp segment_key(:single_level), do: :single_level
  defp segment_key(:multi_level), do: :multi_level
  defp segment_key(segment), do: segment

  # Filter out subscriptions with no_local when publisher matches subscriber
  defp filter_no_local(matches, nil), do: matches

  defp filter_no_local(matches, publisher) do
    Enum.reject(matches, fn {client, opts} ->
      client == publisher and Map.get(opts, :no_local, false)
    end)
  end

  # Normalize filter (can be string or list)
  defp normalize_filter(filter) when is_binary(filter) do
    Topic.normalize(filter)
  end

  defp normalize_filter(filter) when is_list(filter) do
    filter
  end

  # Normalize topic (can be string or list)
  defp normalize_topic(topic) when is_binary(topic) do
    Topic.normalize(topic)
  end

  defp normalize_topic(topic) when is_list(topic) do
    topic
  end
end
