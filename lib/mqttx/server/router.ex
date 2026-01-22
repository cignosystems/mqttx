defmodule MqttX.Server.Router do
  @moduledoc """
  Topic router for MQTT servers.

  The router maintains a subscription table and provides efficient
  topic matching for message routing.

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
          subscriptions: [subscription()],
          by_client: %{term() => [subscription()]},
          shared_groups: %{binary() => shared_group()}
        }

  defstruct subscriptions: [], by_client: %{}, shared_groups: %{}

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

    sub = %{
      filter: normalized,
      client: client,
      qos: qos,
      opts: Map.new(extra_opts)
    }

    # Add to main list
    subscriptions = [sub | router.subscriptions]

    # Add to client index
    client_subs = Map.get(router.by_client, client, [])
    by_client = Map.put(router.by_client, client, [sub | client_subs])

    %{router | subscriptions: subscriptions, by_client: by_client}
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

    # Also track in by_client for cleanup
    sub = %{
      filter: normalized,
      client: client,
      qos: qos,
      opts: Map.put(Map.new(extra_opts), :shared_group, group)
    }

    client_subs = Map.get(router.by_client, client, [])
    by_client = Map.put(router.by_client, client, [sub | client_subs])

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

    # Remove from main list
    subscriptions =
      Enum.reject(router.subscriptions, fn sub ->
        sub.client == client and sub.filter == normalized
      end)

    # Update client index
    client_subs = Map.get(router.by_client, client, [])

    new_client_subs =
      Enum.reject(client_subs, fn sub ->
        sub.filter == normalized and not Map.has_key?(sub.opts, :shared_group)
      end)

    by_client =
      if new_client_subs == [] do
        Map.delete(router.by_client, client)
      else
        Map.put(router.by_client, client, new_client_subs)
      end

    %{router | subscriptions: subscriptions, by_client: by_client}
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

    # Update client index
    client_subs = Map.get(router.by_client, client, [])

    new_client_subs =
      Enum.reject(client_subs, fn sub ->
        sub.filter == normalized and Map.get(sub.opts, :shared_group) == group
      end)

    by_client =
      if new_client_subs == [] do
        Map.delete(router.by_client, client)
      else
        Map.put(router.by_client, client, new_client_subs)
      end

    %{router | shared_groups: shared_groups, by_client: by_client}
  end

  @doc """
  Remove all subscriptions for a client.
  """
  @spec unsubscribe_all(t(), term()) :: t()
  def unsubscribe_all(router, client) do
    subscriptions =
      Enum.reject(router.subscriptions, fn sub ->
        sub.client == client
      end)

    # Remove client from all shared groups
    shared_groups =
      router.shared_groups
      |> Enum.map(fn {group, data} ->
        new_members = Enum.reject(data.members, fn {c, _} -> c == client end)
        {group, %{data | members: new_members}}
      end)
      |> Enum.reject(fn {_group, data} -> data.members == [] end)
      |> Map.new()

    by_client = Map.delete(router.by_client, client)

    %{router | subscriptions: subscriptions, shared_groups: shared_groups, by_client: by_client}
  end

  @doc """
  Find all matching subscriptions for a topic.

  Returns a list of `{client, opts}` tuples for each matching subscription.

  For shared subscriptions, only one client per group is selected (round-robin).
  """
  @spec match(t(), binary() | Topic.normalized_topic()) :: [{term(), map()}]
  def match(router, topic) do
    normalized = normalize_topic(topic)

    # Get regular subscription matches
    regular_matches =
      router.subscriptions
      |> Enum.filter(fn sub -> Topic.matches?(sub.filter, normalized) end)
      |> Enum.map(fn sub -> {sub.client, Map.put(sub.opts, :qos, sub.qos)} end)
      |> Enum.uniq_by(fn {client, _opts} -> client end)

    # Get shared subscription matches (one per group, round-robin)
    shared_matches =
      router.shared_groups
      |> Enum.filter(fn {_group, data} -> Topic.matches?(data.filter, normalized) end)
      |> Enum.map(fn {_group, data} ->
        # Select client using round-robin
        index = rem(data.index, length(data.members))
        {client, opts} = Enum.at(data.members, index)
        {client, opts}
      end)

    # Combine, avoiding duplicates (regular takes priority)
    regular_clients = MapSet.new(regular_matches, fn {client, _} -> client end)

    filtered_shared =
      Enum.reject(shared_matches, fn {client, _} -> MapSet.member?(regular_clients, client) end)

    regular_matches ++ filtered_shared
  end

  @doc """
  Find all matching subscriptions and advance round-robin for shared groups.

  This is the same as `match/2` but also updates the router state
  to advance the round-robin index for matched shared subscriptions.

  Returns `{matches, updated_router}`.
  """
  @spec match_and_advance(t(), binary() | Topic.normalized_topic()) :: {[{term(), map()}], t()}
  def match_and_advance(router, topic) do
    normalized = normalize_topic(topic)

    # Get regular subscription matches
    regular_matches =
      router.subscriptions
      |> Enum.filter(fn sub -> Topic.matches?(sub.filter, normalized) end)
      |> Enum.map(fn sub -> {sub.client, Map.put(sub.opts, :qos, sub.qos)} end)
      |> Enum.uniq_by(fn {client, _opts} -> client end)

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
    Map.get(router.by_client, client, [])
  end

  @doc """
  Get the total number of subscriptions.
  """
  @spec count(t()) :: non_neg_integer()
  def count(router) do
    length(router.subscriptions)
  end

  @doc """
  Get the number of unique clients with subscriptions.
  """
  @spec client_count(t()) :: non_neg_integer()
  def client_count(router) do
    map_size(router.by_client)
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
