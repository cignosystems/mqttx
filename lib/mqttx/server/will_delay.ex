defmodule MqttX.Server.WillDelay do
  @moduledoc false

  # Owns Will Delay Interval timers (§3.1.3.2.2).
  #
  # Replaces an earlier `Task.start/1 + Process.sleep/1` implementation that
  # was both unsupervised (lost on app restart) and uncancellable. The spec
  # requires that if a client reconnects with the same client_id within its
  # advertised will_delay_interval, the pending Will MUST NOT be sent.
  #
  # Keyed by {retained_table, client_id} — the same scope session takeover
  # uses, so two listeners in one VM cannot cancel each other's timers. New
  # schedules replace any existing pending will for that key; explicit
  # cancel/1 (called on a fresh CONNECT) drops the entry without firing.

  use GenServer

  require Logger

  @type ctx :: %{
          required(:retained_table) => :ets.tid(),
          required(:handler) => module(),
          required(:handler_state) => term(),
          optional(:listener) => term(),
          optional(:delivery) => map() | nil,
          optional(:max_retained_messages) => non_neg_integer() | nil
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec schedule(term(), map(), non_neg_integer(), ctx()) :: :ok
  def schedule(client_id, will, delay_ms, ctx) do
    GenServer.cast(__MODULE__, {:schedule, client_id, will, delay_ms, ctx})
  end

  @spec cancel(term()) :: :ok
  def cancel(client_id) do
    GenServer.cast(__MODULE__, {:cancel, client_id})
  end

  @doc "Publish the pending Will now: the session it belongs to has ended."
  @spec fire(term()) :: :ok
  def fire(client_id) do
    GenServer.cast(__MODULE__, {:fire_now, client_id})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:schedule, client_id, will, delay_ms, ctx}, pending) do
    pending = drop_existing(pending, client_id)
    ref = make_ref()
    timer = Process.send_after(self(), {:fire, client_id, ref, will, ctx}, delay_ms)
    {:noreply, Map.put(pending, client_id, {timer, ref, will, ctx})}
  end

  def handle_cast({:cancel, client_id}, pending) do
    {:noreply, drop_existing(pending, client_id)}
  end

  def handle_cast({:fire_now, client_id}, pending) do
    case Map.get(pending, client_id) do
      {_timer, _ref, will, ctx} ->
        publish_safely(will, ctx)
        {:noreply, drop_existing(pending, client_id)}

      nil ->
        {:noreply, pending}
    end
  end

  @impl true
  def handle_info({:fire, client_id, ref, will, ctx}, pending) do
    # Defensive: only fire if the entry's ref still matches — guards against
    # the race where cancel/1 runs after Process.send_after's message is
    # already in our mailbox.
    case Map.get(pending, client_id) do
      {_timer, ^ref, _will, _ctx} ->
        publish_safely(will, ctx)
        {:noreply, Map.delete(pending, client_id)}

      _ ->
        {:noreply, pending}
    end
  end

  defp drop_existing(pending, client_id) do
    case Map.pop(pending, client_id) do
      {nil, p} ->
        p

      {{timer, _ref, _will, _ctx}, p} ->
        Process.cancel_timer(timer)
        p
    end
  end

  # One client's handler raising must not lose every other client's Will:
  # this server is shared by all of them
  defp publish_safely(will, ctx) do
    do_publish_will(will, ctx)
  rescue
    e ->
      Logger.error(
        "[MqttX.Server.WillDelay] handle_publish failed for a Will: " <>
          Exception.message(e) <> "\n" <> Exception.format_stacktrace(__STACKTRACE__)
      )

      :ok
  catch
    kind, value ->
      Logger.error(
        "[MqttX.Server.WillDelay] handle_publish failed for a Will: #{kind} #{inspect(value)}"
      )

      :ok
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

    # Same rule as the immediate Will path in MqttX.Transport.Handler: the Will
    # is attacker-supplied and handle_publish is its only authorization gate, so
    # ask first and store the retained entry only if the handler accepted it.
    result =
      with_delivery(Map.get(ctx, :delivery), fn ->
        ctx.handler.handle_publish(will.topic, will.payload, opts, ctx.handler_state)
      end)

    # The store honors the listener's retained cap — a delayed Will must not
    # be a way around it (existing topics can always be overwritten).
    if will.retain and match?({:ok, _}, result) do
      MqttX.Server.Cluster.store_retained(
        Map.get(ctx, :listener),
        ctx.retained_table,
        will.topic,
        will.payload,
        will.qos,
        will_props,
        Map.get(ctx, :max_retained_messages)
      )
    end

    result
  end

  # MqttX.Server.deliver/3 finds its listener in the calling process. This
  # process serves every listener, so the Will's connection context is set
  # only for the handle_publish/4 call that publishes it
  defp with_delivery(nil, fun), do: fun.()

  defp with_delivery(delivery, fun) do
    Process.put(:mqttx_listener, delivery)

    try do
      fun.()
    after
      Process.delete(:mqttx_listener)
    end
  end
end
