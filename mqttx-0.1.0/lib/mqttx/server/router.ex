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
  """

  alias MqttX.Topic

  @type subscription :: %{
          filter: Topic.normalized_topic(),
          client: term(),
          qos: 0 | 1 | 2,
          opts: map()
        }

  @type t :: %__MODULE__{
          subscriptions: [subscription()],
          by_client: %{term() => [subscription()]}
        }

  defstruct subscriptions: [], by_client: %{}

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
  """
  @spec subscribe(t(), binary() | Topic.normalized_topic(), term(), keyword()) :: t()
  def subscribe(router, filter, client, opts \\ []) do
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

  @doc """
  Remove a subscription from the router.
  """
  @spec unsubscribe(t(), binary() | Topic.normalized_topic(), term()) :: t()
  def unsubscribe(router, filter, client) do
    normalized = normalize_filter(filter)

    # Remove from main list
    subscriptions = Enum.reject(router.subscriptions, fn sub ->
      sub.client == client and sub.filter == normalized
    end)

    # Update client index
    client_subs = Map.get(router.by_client, client, [])
    new_client_subs = Enum.reject(client_subs, fn sub ->
      sub.filter == normalized
    end)

    by_client = if new_client_subs == [] do
      Map.delete(router.by_client, client)
    else
      Map.put(router.by_client, client, new_client_subs)
    end

    %{router | subscriptions: subscriptions, by_client: by_client}
  end

  @doc """
  Remove all subscriptions for a client.
  """
  @spec unsubscribe_all(t(), term()) :: t()
  def unsubscribe_all(router, client) do
    subscriptions = Enum.reject(router.subscriptions, fn sub ->
      sub.client == client
    end)

    by_client = Map.delete(router.by_client, client)

    %{router | subscriptions: subscriptions, by_client: by_client}
  end

  @doc """
  Find all matching subscriptions for a topic.

  Returns a list of `{client, opts}` tuples for each matching subscription.
  """
  @spec match(t(), binary() | Topic.normalized_topic()) :: [{term(), map()}]
  def match(router, topic) do
    normalized = normalize_topic(topic)

    router.subscriptions
    |> Enum.filter(fn sub -> Topic.matches?(sub.filter, normalized) end)
    |> Enum.map(fn sub -> {sub.client, Map.put(sub.opts, :qos, sub.qos)} end)
    |> Enum.uniq_by(fn {client, _opts} -> client end)
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
