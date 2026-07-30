defmodule MqttX.Server.SessionExpiry do
  @moduledoc false

  # Owns Session Expiry Interval timers (§3.1.2.11.2).
  #
  # Replaces a `Task.start/1 + Process.sleep/1` implementation that was
  # unsupervised (lost on app restart), uncancellable, and — critically —
  # kept firing for clients that had already reconnected, expiring live
  # sessions. Mirrors MqttX.Server.WillDelay.
  #
  # Keyed by {retained_table, client_id} — the same scope session takeover
  # uses, so two listeners in one VM cannot cancel each other's timers. A
  # fresh CONNECT for that key MUST cancel the pending expiry (the session
  # resumed before it expired).

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec schedule(term(), non_neg_integer(), module(), term()) :: :ok
  def schedule(key, interval_ms, handler, handler_state) do
    GenServer.cast(__MODULE__, {:schedule, key, interval_ms, handler, handler_state})
  end

  @spec cancel(term()) :: :ok
  def cancel(key) do
    GenServer.cast(__MODULE__, {:cancel, key})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:schedule, client_id, interval_ms, handler, handler_state}, pending) do
    pending = drop_existing(pending, client_id)
    ref = make_ref()

    timer =
      Process.send_after(self(), {:expire, client_id, ref, handler, handler_state}, interval_ms)

    {:noreply, Map.put(pending, client_id, {timer, ref})}
  end

  def handle_cast({:cancel, client_id}, pending) do
    {:noreply, drop_existing(pending, client_id)}
  end

  @impl true
  def handle_info({:expire, client_id, ref, handler, handler_state}, pending) do
    # Only fire if the entry's ref still matches — guards against the race
    # where cancel/1 runs after the timer message is already in our mailbox.
    case Map.get(pending, client_id) do
      {_timer, ^ref} ->
        # The map is keyed by the scoped {retained_table, client_id} tuple,
        # but the callback contract is the bare client_id.
        handler.handle_session_expired(callback_client_id(client_id), handler_state)
        {:noreply, Map.delete(pending, client_id)}

      _ ->
        {:noreply, pending}
    end
  end

  defp callback_client_id({_scope, client_id}), do: client_id
  defp callback_client_id(client_id), do: client_id

  defp drop_existing(pending, client_id) do
    case Map.pop(pending, client_id) do
      {nil, p} ->
        p

      {{timer, _ref}, p} ->
        Process.cancel_timer(timer)
        p
    end
  end
end
