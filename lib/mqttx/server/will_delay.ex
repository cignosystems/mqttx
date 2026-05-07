defmodule MqttX.Server.WillDelay do
  @moduledoc false

  # Owns Will Delay Interval timers (§3.1.3.2.2).
  #
  # Replaces an earlier `Task.start/1 + Process.sleep/1` implementation that
  # was both unsupervised (lost on app restart) and uncancellable. The spec
  # requires that if a client reconnects with the same client_id within its
  # advertised will_delay_interval, the pending Will MUST NOT be sent.
  #
  # Keyed by client_id. New schedules replace any existing pending will for
  # that client_id; explicit cancel/1 (called on a fresh CONNECT) drops the
  # entry without firing.

  use GenServer

  @type ctx :: %{
          required(:retained_table) => :ets.tid(),
          required(:handler) => module(),
          required(:handler_state) => term()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec schedule(binary(), map(), non_neg_integer(), ctx()) :: :ok
  def schedule(client_id, will, delay_ms, ctx) do
    GenServer.cast(__MODULE__, {:schedule, client_id, will, delay_ms, ctx})
  end

  @spec cancel(binary()) :: :ok
  def cancel(client_id) do
    GenServer.cast(__MODULE__, {:cancel, client_id})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:schedule, client_id, will, delay_ms, ctx}, pending) do
    pending = drop_existing(pending, client_id)
    ref = make_ref()
    timer = Process.send_after(self(), {:fire, client_id, ref, will, ctx}, delay_ms)
    {:noreply, Map.put(pending, client_id, {timer, ref})}
  end

  def handle_cast({:cancel, client_id}, pending) do
    {:noreply, drop_existing(pending, client_id)}
  end

  @impl true
  def handle_info({:fire, client_id, ref, will, ctx}, pending) do
    # Defensive: only fire if the entry's ref still matches — guards against
    # the race where cancel/1 runs after Process.send_after's message is
    # already in our mailbox.
    case Map.get(pending, client_id) do
      {_timer, ^ref} ->
        do_publish_will(will, ctx)
        {:noreply, Map.delete(pending, client_id)}

      _ ->
        {:noreply, pending}
    end
  end

  defp drop_existing(pending, client_id) do
    case Map.pop(pending, client_id) do
      {nil, p} ->
        p

      {{timer, _ref}, p} ->
        Process.cancel_timer(timer)
        p
    end
  end

  defp do_publish_will(will, ctx) do
    will_props = Map.get(will, :properties, %{}) || %{}

    opts = %{
      qos: will.qos,
      retain: will.retain,
      dup: false,
      packet_id: nil,
      properties: will_props
    }

    if will.retain do
      store_retained(will.topic, will.payload, will.qos, will_props, ctx.retained_table)
    end

    ctx.handler.handle_publish(will.topic, will.payload, opts, ctx.handler_state)
  end

  defp store_retained(topic, <<>>, _qos, _props, table) do
    :ets.delete(table, topic_key(topic))
    :ok
  end

  defp store_retained(topic, payload, qos, props, table) do
    key = topic_key(topic)
    normalized_list = MqttX.Topic.normalize(key)
    timestamp = System.system_time(:second)
    expiry_interval = Map.get(props || %{}, :message_expiry_interval)
    :ets.insert(table, {key, normalized_list, payload, qos, timestamp, expiry_interval})
    :ok
  end

  defp topic_key(topic) when is_list(topic), do: Enum.join(topic, "/")
  defp topic_key(topic) when is_binary(topic), do: topic
end
