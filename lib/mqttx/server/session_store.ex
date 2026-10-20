defmodule MqttX.Server.SessionStore do
  @moduledoc false

  # Per-listener ETS tables holding the broker's Session State (§4.1): the
  # existence of a session and when it ends, its subscriptions, the QoS 1/2
  # messages in flight in either direction, and the messages queued for it
  # while it is not connected. Everything a connection process knows about a
  # session is written through here as it changes, so a session survives the
  # connection process and a takeover needs no hand-off: the new connection
  # reads what the old one last wrote.
  #
  # Tables (all `:public`, created by whoever starts the listener — the same
  # ownership as the retained table, so they live as long as that process):
  #
  #   sessions    set          {client_id, meta}
  #                            {{:qlen, client_id}, n}        queue length
  #                            {{:rr, filter, group}, n}      shared round-robin
  #                            {:seq, n}                      global sequence
  #   subs        ordered_set  {{filter_segments, subscriber}, opts}
  #   client_subs ordered_set  {{client_id, filter_binary}, {filter_segments, subscriber}}
  #   inflight    ordered_set  {{client_id, {kind, packet_id}}, seq, value}
  #   queue       ordered_set  {{client_id, seq}, entry}
  #   remote      ordered_set  {{filter_segments, {:share, group, client_id}}, {node, opts}}
  #                            shared subscriptions held on other nodes (§4.8),
  #                            replicated by MqttX.Server.Cluster
  #   dirty       set          {client_id} sessions changed since the backend
  #                            last saved them (only with a :backend)
  #
  # `subscriber` is the client id for a normal subscription and
  # `{:share, group, client_id}` for a shared one (§4.8). `subs` is the
  # node-wide subscription index: a topic is matched by walking it level by
  # level, and because the table is ordered by filter segments, "does any
  # filter start with this prefix?" is one `:ets.next/2` — the trie lives in
  # the key order, not in a structure of its own, and reads are concurrent.
  #
  # The per-client tables are keyed `{client_id, …}` so one client's rows are
  # a contiguous range an `:ets.select/2` with a bound prefix walks directly.

  alias MqttX.Topic

  defstruct [
    :listener,
    :sessions,
    :subs,
    :client_subs,
    :inflight,
    :queue,
    :remote,
    :dirty,
    :backend
  ]

  @type t :: %__MODULE__{
          # The listener's name across the cluster (nil for standalone tables)
          listener: term() | nil,
          sessions: :ets.table(),
          subs: :ets.table(),
          client_subs: :ets.table(),
          inflight: :ets.table(),
          queue: :ets.table(),
          remote: :ets.table(),
          dirty: :ets.table(),
          # A durable MqttX.Server.SessionBackend and its state, or nil
          backend: {module(), term()} | nil
        }

  @typedoc """
  A whole session, as moved between nodes and saved to a backend. Queued
  messages carry the wall-clock millisecond they were queued at, so Message
  Expiry keeps counting on another node or after a restart.
  """
  @type session_record :: %{
          meta: meta(),
          subscriptions: [%{filter: binary(), opts: map()}],
          inflight: [{inflight_key(), term()}],
          queue: [{binary(), binary(), map(), integer()}]
        }

  @type client_id :: binary()
  @type meta :: %{
          optional(:lifetime) => non_neg_integer(),
          protocol_version: 3 | 4 | 5,
          expires_at: :infinity | integer(),
          persistent: boolean()
        }
  @type inflight_key :: {:tx1 | :tx2 | :rx2, non_neg_integer()}

  # ---------- Creation ----------

  @doc """
  Create (or reuse) the named tables for a listener, derived from `base`.
  Idempotent, like `MqttX.Server.RetainedStore.create_table/1`: a listener
  restart within the same BEAM finds the sessions still there.
  """
  @spec create(atom(), term(), module() | {module(), keyword()} | nil) :: t()
  def create(base, listener \\ nil, backend \\ nil) when is_atom(base) do
    %__MODULE__{
      listener: listener,
      sessions: named(:"#{base}_sessions", :set),
      subs: named(:"#{base}_subs", :ordered_set),
      client_subs: named(:"#{base}_client_subs", :ordered_set),
      inflight: named(:"#{base}_inflight", :ordered_set),
      queue: named(:"#{base}_queue", :ordered_set),
      remote: named(:"#{base}_remote", :ordered_set),
      dirty: named(:"#{base}_dirty", :set),
      backend: init_backend(backend, listener || base)
    }
  end

  @doc "Anonymous tables, for tests and for connections built without a listener."
  @spec new(term(), module() | {module(), keyword()} | nil) :: t()
  def new(listener \\ nil, backend \\ nil) do
    %__MODULE__{
      listener: listener,
      sessions: anonymous(:set),
      subs: anonymous(:ordered_set),
      client_subs: anonymous(:ordered_set),
      inflight: anonymous(:ordered_set),
      queue: anonymous(:ordered_set),
      remote: anonymous(:ordered_set),
      dirty: anonymous(:set),
      backend: init_backend(backend, listener || make_ref())
    }
  end

  defp init_backend(nil, _name), do: nil
  defp init_backend(module, name) when is_atom(module), do: init_backend({module, []}, name)

  defp init_backend({module, opts}, name) when is_atom(module) and is_list(opts) do
    {:ok, state} = module.init(name, opts)
    {module, state}
  end

  defp named(name, type) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [
          :named_table,
          :public,
          type,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ref ->
        name
    end
  end

  defp anonymous(type) do
    :ets.new(__MODULE__, [:public, type, read_concurrency: true, write_concurrency: true])
  end

  # ---------- Sessions ----------

  @doc "Record that a session exists (replacing any previous metadata)."
  @spec put(t(), client_id(), meta()) :: :ok
  def put(store, client_id, meta) when is_binary(client_id) and is_map(meta) do
    :ets.insert(store.sessions, {client_id, meta})
    touch(store, client_id)
  end

  @doc """
  The session's metadata, or `nil` if there is no session. One whose expiry
  time has passed is discarded on the way (the expiry timer is the primary
  mechanism; this is the safety net).
  """
  @spec get(t(), client_id()) :: meta() | nil
  def get(store, client_id) when is_binary(client_id) do
    case :ets.lookup(store.sessions, client_id) do
      [{_, %{expires_at: at} = meta}] ->
        if at == :infinity or at > System.system_time(:second) do
          meta
        else
          delete(store, client_id)
          nil
        end

      [] ->
        nil
    end
  end

  @spec exists?(t(), client_id()) :: boolean()
  def exists?(store, client_id), do: get(store, client_id) != nil

  @doc "Set when the session ends (`:infinity` while it is connected or never expires)."
  @spec set_expiry(t(), client_id(), :infinity | integer()) :: :ok
  def set_expiry(store, client_id, expires_at) do
    case :ets.lookup(store.sessions, client_id) do
      [{_, meta}] -> put(store, client_id, %{meta | expires_at: expires_at})
      [] -> :ok
    end
  end

  @doc "Discard the session and everything that belongs to it."
  @spec delete(t(), client_id()) :: :ok
  def delete(store, client_id) when is_binary(client_id) do
    # An expiry timer can outlive the listener (and so its tables)
    if :ets.info(store.sessions) == :undefined, do: :ok, else: do_delete(store, client_id)
  end

  defp do_delete(store, client_id) do
    for {{^client_id, _filter}, {segments, subscriber}} <-
          :ets.select(store.client_subs, [{{{client_id, :_}, :_}, [], [:"$_"]}]) do
      :ets.delete(store.subs, {segments, subscriber})
      announce_shared(store, :remove, segments, subscriber, nil)
    end

    :ets.select_delete(store.client_subs, [{{{client_id, :_}, :_}, [], [true]}])
    :ets.select_delete(store.inflight, [{{{client_id, :_}, :_, :_}, [], [true]}])
    :ets.select_delete(store.queue, [{{{client_id, :_}, :_}, [], [true]}])
    :ets.delete(store.sessions, {:qlen, client_id})
    :ets.delete(store.sessions, client_id)
    touch(store, client_id)
  end

  # ---------- Subscriptions ----------

  @doc """
  Add or replace (§3.8.4) a subscription. `filter` is the canonical binary
  form, `$share/group/…` included; `opts` carries `:qos`, `:no_local`,
  `:retain_as_published` and optionally `:subscription_identifier`.
  """
  @spec subscribe(t(), client_id(), binary(), map()) :: :ok
  def subscribe(store, client_id, filter, opts) when is_binary(filter) and is_map(opts) do
    {segments, subscriber} = index_key(filter, client_id)

    # A re-subscribe under a different spelling of the same filter would leave
    # the old index row behind — remove whatever this (client, filter) held.
    case :ets.lookup(store.client_subs, {client_id, filter}) do
      [{_, {old_segments, old_subscriber} = old_key}] when old_key != {segments, subscriber} ->
        :ets.delete(store.subs, old_key)
        announce_shared(store, :remove, old_segments, old_subscriber, nil)

      _ ->
        :ok
    end

    :ets.insert(store.subs, {{segments, subscriber}, opts})
    :ets.insert(store.client_subs, {{client_id, filter}, {segments, subscriber}})
    announce_shared(store, :add, segments, subscriber, opts)
    touch(store, client_id)
  end

  @spec unsubscribe(t(), client_id(), binary()) :: :ok
  def unsubscribe(store, client_id, filter) when is_binary(filter) do
    case :ets.lookup(store.client_subs, {client_id, filter}) do
      [{_, {segments, subscriber} = key}] ->
        :ets.delete(store.subs, key)
        :ets.delete(store.client_subs, {client_id, filter})
        announce_shared(store, :remove, segments, subscriber, nil)
        touch(store, client_id)

      [] ->
        :ok
    end
  end

  @doc "A client's subscriptions as `%{filter: binary, opts: map}` maps."
  @spec subscriptions(t(), client_id()) :: [%{filter: binary(), opts: map()}]
  def subscriptions(store, client_id) do
    for {{_client, filter}, key} <-
          :ets.select(store.client_subs, [{{{client_id, :_}, :_}, [], [:"$_"]}]),
        [{_, opts}] <- [:ets.lookup(store.subs, key)] do
      %{filter: filter, opts: opts}
    end
  end

  defp index_key(filter, client_id) do
    case Topic.parse_shared(filter) do
      {:shared, group, topic_filter} ->
        {Topic.normalize(topic_filter), {:share, group, client_id}}

      {:normal, _} ->
        {Topic.normalize(filter), client_id}
    end
  end

  @doc """
  The subscribers a published topic reaches, as `{client_id, opts}` — the same
  contract as `MqttX.Server.Router.match/3`: one entry per client at the
  highest matching QoS with every matching Subscription Identifier merged
  (§3.3.4), `no_local` subscriptions skipped when `publisher` is the
  subscriber (§3.8.3.1), and one member per shared group (§4.8.2).

  A shared group's member is picked across the cluster: among this node's
  members for which `online?` returns true and the members other nodes hold
  (replicated into the `remote` table), rotating; with none of those, one
  offline local member is chosen so the message is queued for its session.
  A member on another node comes back as `{:remote, node, client_id, opts}`.
  `shared: :skip` leaves shared groups out — a node fanning out a message
  another node delivered does that, because the delivering node picked the
  group's member already.
  """
  @spec match(
          t(),
          binary() | Topic.normalized_topic(),
          term(),
          (client_id() -> boolean()),
          :all | :skip
        ) :: [{client_id(), map()} | {:remote, node(), client_id(), map()}]
  def match(store, topic, publisher \\ nil, online? \\ fn _ -> true end, shared \\ :all) do
    segments = Topic.normalize(topic)
    hits = walk(store.subs, segments)

    normal =
      for {_filter, client, opts} <- hits,
          is_binary(client),
          not (client == publisher and Map.get(opts, :no_local, false)),
          do: {client, opts}

    normal = collapse_per_client(normal)

    case shared do
      :skip -> normal
      :all -> normal ++ shared_picks(store, segments, hits, normal, publisher, online?)
    end
  end

  defp shared_picks(store, segments, hits, normal, publisher, online?) do
    taken = MapSet.new(normal, fn {client, _} -> client end)

    local =
      for {filter, {:share, group, client}, opts} <- hits,
          do: {{filter, group}, {:local, client, opts}}

    # Not :ets.info(_, :size): on a write_concurrency table that sums
    # per-scheduler counters, and once per publish it halved deliver/3's
    # end-to-end rate
    remote =
      if :ets.first(store.remote) == :"$end_of_table" do
        []
      else
        for {filter, {:share, group, client}, {node, opts}} <- walk(store.remote, segments),
            not (client == publisher and Map.get(opts, :no_local, false)),
            do: {{filter, group}, {:remote, node, client, opts}}
      end

    (local ++ remote)
    |> Enum.group_by(fn {key, _member} -> key end, fn {_key, member} -> member end)
    |> Enum.flat_map(fn {{filter, group}, members} ->
      pick_shared_member(store, filter, group, members, online?)
    end)
    |> Enum.reject(fn
      {client, _opts} -> MapSet.member?(taken, client)
      {:remote, _node, _client, _opts} -> false
    end)
  end

  # Walk the topic one level at a time. `prefixes` are the filter prefixes
  # still alive; each level extends them with the literal segment and with
  # `+`, keeping only prefixes some filter actually starts with. A `#` child
  # of any live prefix matches here and everything below (§4.7.1.2), so it is
  # collected at every level — including the end, where `a/#` matches `a`.
  # A topic whose first level starts with `$` is matched only by filters
  # whose first level is that literal (§4.7.2).
  defp walk(tab, [<<"$", _::binary>> = first | rest]) do
    if prefix_exists?(tab, [first]), do: walk_levels(tab, [[first]], rest, []), else: []
  end

  defp walk(tab, segments), do: walk_levels(tab, [[]], segments, [])

  defp walk_levels(tab, prefixes, [], acc) do
    Enum.reduce(prefixes, acc, fn prefix, acc ->
      collect(tab, prefix) ++ collect(tab, prefix ++ [:multi_level]) ++ acc
    end)
  end

  defp walk_levels(tab, prefixes, [segment | rest], acc) do
    acc = Enum.reduce(prefixes, acc, &(collect(tab, &1 ++ [:multi_level]) ++ &2))

    next =
      for prefix <- prefixes,
          candidate <- [prefix ++ [segment], prefix ++ [:single_level]],
          prefix_exists?(tab, candidate),
          do: candidate

    walk_levels(tab, next, rest, acc)
  end

  # Keys are {segments, subscriber}; 0 sorts below every subscriber term, so
  # the first key after {prefix, 0} is the first filter at or below prefix.
  defp prefix_exists?(tab, prefix) do
    case :ets.next(tab, {prefix, 0}) do
      {segments, _} -> List.starts_with?(segments, prefix)
      :"$end_of_table" -> false
    end
  end

  # Every subscriber of exactly this filter: {filter, subscriber, opts}.
  defp collect(tab, filter), do: collect(tab, filter, :ets.next(tab, {filter, 0}), [])

  defp collect(tab, filter, {filter, subscriber} = key, acc) do
    acc =
      case :ets.lookup(tab, key) do
        [{_, opts}] -> [{filter, subscriber, opts} | acc]
        [] -> acc
      end

    collect(tab, filter, :ets.next(tab, key), acc)
  end

  defp collect(_tab, _filter, _other_key, acc), do: acc

  # One delivery per client at the highest matching QoS; the Subscription
  # Identifiers of every matching subscription ride along (§3.3.4).
  defp collapse_per_client(matches) do
    matches
    |> Enum.group_by(fn {client, _} -> client end)
    |> Enum.map(fn {_client, entries} ->
      {client, opts} = Enum.max_by(entries, fn {_, o} -> Map.get(o, :qos, 0) end)

      ids =
        Enum.flat_map(entries, fn {_, o} -> List.wrap(Map.get(o, :subscription_identifier)) end)

      case ids do
        [] -> {client, Map.delete(opts, :subscription_identifier)}
        [id] -> {client, Map.put(opts, :subscription_identifier, id)}
        _ -> {client, Map.put(opts, :subscription_identifier, ids)}
      end
    end)
  end

  defp pick_shared_member(store, filter, group, members, online?) do
    members = Enum.sort_by(members, &member_sort_key/1)

    # Members on other nodes count as reachable: their node queues for them
    # if they are away
    reachable =
      Enum.filter(members, fn
        {:local, client, _opts} -> online?.(client)
        {:remote, _node, _client, _opts} -> true
      end)

    candidates = if reachable == [], do: members, else: reachable

    case candidates do
      [] ->
        []

      _ ->
        n =
          :ets.update_counter(
            store.sessions,
            {:rr, filter, group},
            {2, 1},
            {{:rr, filter, group}, 0}
          )

        case Enum.at(candidates, rem(n, length(candidates))) do
          {:local, client, opts} -> [{client, opts}]
          remote -> [remote]
        end
    end
  end

  defp member_sort_key({:local, client, _opts}), do: {client, node()}
  defp member_sort_key({:remote, node, client, _opts}), do: {client, node}

  # ---------- Shared subscriptions on other nodes ----------

  # Tell the other nodes of the listener's group that a shared subscription
  # came or went here; a normal subscription stays node-local
  defp announce_shared(%{listener: nil}, _op, _segments, _subscriber, _opts), do: :ok

  defp announce_shared(store, op, segments, {:share, group, client}, opts) do
    MqttX.Server.Cluster.shared_changed(store.listener, {op, segments, group, client, opts})
  end

  defp announce_shared(_store, _op, _segments, _subscriber, _opts), do: :ok

  @doc false
  # A shared subscription another node announced
  def put_remote_shared(store, node, segments, group, client_id, opts) do
    :ets.insert(store.remote, {{segments, {:share, group, client_id}}, {node, opts}})
    :ok
  end

  @doc false
  # Removed only if `node` still holds it: a session that moved announces the
  # add from its new node, possibly before the old node's remove arrives
  def delete_remote_shared(store, node, segments, group, client_id) do
    key = {segments, {:share, group, client_id}}

    case :ets.lookup(store.remote, key) do
      [{_, {^node, _opts}}] -> :ets.delete(store.remote, key)
      _ -> :ok
    end

    :ok
  end

  @doc false
  # Every shared subscription held on `node` (it left the cluster)
  def drop_remote_node(store, node) do
    :ets.select_delete(store.remote, [{{:_, {node, :_}}, [], [true]}])
    :ok
  end

  @doc false
  # This node's shared subscriptions, for a node that just joined
  def local_shared(store) do
    for {{segments, {:share, group, client}}, opts} <-
          :ets.select(store.subs, [{{{:_, {:share, :_, :_}}, :_}, [], [:"$_"]}]),
        do: {segments, group, client, opts}
  end

  # ---------- In-flight QoS 1/2 state ----------

  @doc """
  Record (or update in place, keeping its position) an in-flight entry:
  `{:tx1, id}` a PUBLISH awaiting PUBACK, `{:tx2, id}` one awaiting
  PUBREC/PUBCOMP, `{:rx2, id}` a received PUBLISH awaiting PUBREL.
  """
  @spec put_inflight(t(), client_id(), inflight_key(), term()) :: :ok
  def put_inflight(store, client_id, key, value) do
    seq =
      case :ets.lookup(store.inflight, {client_id, key}) do
        [{_, seq, _}] -> seq
        [] -> next_seq(store)
      end

    :ets.insert(store.inflight, {{client_id, key}, seq, value})
    touch(store, client_id)
  end

  @spec delete_inflight(t(), client_id(), inflight_key()) :: :ok
  def delete_inflight(store, client_id, key) do
    :ets.delete(store.inflight, {client_id, key})
    touch(store, client_id)
  end

  @doc "A client's in-flight entries as `{key, value}`, oldest first (§4.6 ordering on re-send)."
  @spec inflight(t(), client_id()) :: [{inflight_key(), term()}]
  def inflight(store, client_id) do
    store.inflight
    |> :ets.select([{{{client_id, :_}, :_, :_}, [], [:"$_"]}])
    |> Enum.sort_by(fn {_key, seq, _value} -> seq end)
    |> Enum.map(fn {{_client, key}, _seq, value} -> {key, value} end)
  end

  # ---------- Queue of messages awaiting delivery ----------

  @doc """
  Append an entry to the client's queue, bounded by `max` entries (`nil`
  for no bound). Any process may enqueue; only the session's connection
  dequeues.
  """
  @spec enqueue(t(), client_id(), term(), pos_integer() | nil) :: :ok | {:error, :full}
  def enqueue(store, client_id, entry, max) do
    key = {:qlen, client_id}
    len = :ets.update_counter(store.sessions, key, {2, 1}, {key, 0})

    if max && len > max do
      :ets.update_counter(store.sessions, key, {2, -1})
      {:error, :full}
    else
      :ets.insert(store.queue, {{client_id, next_seq(store)}, entry})
      touch(store, client_id)
    end
  end

  @spec dequeue(t(), client_id()) :: {:ok, term()} | :empty
  def dequeue(store, client_id) do
    case :ets.next(store.queue, {client_id, 0}) do
      {^client_id, seq} = key when is_integer(seq) ->
        case :ets.take(store.queue, key) do
          [{_, entry}] ->
            :ets.update_counter(
              store.sessions,
              {:qlen, client_id},
              {2, -1},
              {{:qlen, client_id}, 0}
            )

            touch(store, client_id)
            {:ok, entry}

          [] ->
            dequeue(store, client_id)
        end

      _ ->
        :empty
    end
  end

  @spec queue_length(t(), client_id()) :: non_neg_integer()
  def queue_length(store, client_id) do
    case :ets.lookup(store.sessions, {:qlen, client_id}) do
      [{_, n}] -> max(n, 0)
      [] -> 0
    end
  end

  defp next_seq(store), do: :ets.update_counter(store.sessions, :seq, {2, 1}, {:seq, 0})

  # ---------- Whole sessions: moving between nodes, durable backend ----------

  @doc """
  Everything the store holds for a session, or `nil` if there is none. Queue
  entries carry wall-clock time instead of this node's monotonic clock.
  """
  @spec export(t(), client_id()) :: session_record() | nil
  def export(store, client_id) do
    case get(store, client_id) do
      nil ->
        nil

      meta ->
        offset = System.system_time(:millisecond) - System.monotonic_time(:millisecond)

        queue =
          for {_key, {topic, payload, opts, queued_at}} <-
                :ets.select(store.queue, [{{{client_id, :_}, :_}, [], [:"$_"]}]),
              do: {topic, payload, opts, queued_at + offset}

        %{
          meta: meta,
          subscriptions: subscriptions(store, client_id),
          inflight: inflight(store, client_id),
          queue: queue
        }
    end
  end

  @doc """
  Install an exported session, replacing whatever the store held for it. The
  queue is not bounded here: what was queued elsewhere was within its bound.
  """
  @spec import(t(), client_id(), session_record()) :: :ok
  def import(store, client_id, %{meta: meta} = record) do
    delete(store, client_id)
    put(store, client_id, meta)

    for %{filter: filter, opts: opts} <- record.subscriptions,
        do: subscribe(store, client_id, filter, opts)

    for {key, value} <- record.inflight, do: put_inflight(store, client_id, key, value)

    offset = System.system_time(:millisecond) - System.monotonic_time(:millisecond)

    for {topic, payload, opts, queued_at} <- record.queue,
        do: enqueue(store, client_id, {topic, payload, opts, queued_at - offset}, nil)

    :ok
  end

  # Remember that a session changed, for the next backend save
  defp touch(%{backend: nil}, _client_id), do: :ok

  defp touch(store, client_id) do
    :ets.insert(store.dirty, {client_id})
    :ok
  end

  @doc false
  # Save every session changed since the last flush to the backend (delete
  # the ones that are gone). Called periodically by the listener's
  # MqttX.Server.Cluster member.
  @spec flush(t()) :: :ok
  def flush(%{backend: nil}), do: :ok

  def flush(%{backend: {module, state}} = store) do
    for {client_id} <- :ets.tab2list(store.dirty) do
      :ets.delete(store.dirty, client_id)

      case export(store, client_id) do
        nil -> module.delete(state, client_id)
        record -> module.save(state, client_id, saved_record(record))
      end
    end

    :ok
  end

  # A session saved while connected never expires in the store, but if the
  # node dies it must still end `lifetime` seconds later: restore/1 starts
  # that clock. The owning node is recorded so a restarting node takes back
  # its own sessions, and another node claims one only when asked to.
  defp saved_record(record), do: Map.put(record, :node, node())

  @doc false
  # Load one session from the backend (another node's, whose node is gone)
  @spec load(t(), client_id()) :: session_record() | nil
  def load(%{backend: nil}, _client_id), do: nil

  def load(%{backend: {module, state}}, client_id) do
    case module.load(state, client_id) do
      {:ok, record} -> if live?(record), do: resumable(record)
      _ -> nil
    end
  end

  @doc false
  # Bring back this node's saved sessions when the listener starts. A session
  # already in the tables (the listener restarted, the tables did not) is
  # left as it is; an expired one is deleted from the backend.
  @spec restore(t()) :: non_neg_integer()
  def restore(%{backend: nil}), do: 0

  def restore(%{backend: {module, state}} = store) do
    Enum.count(module.list(state), fn {client_id, record} ->
      cond do
        Map.get(record, :node, node()) != node() ->
          false

        not live?(record) ->
          module.delete(state, client_id)
          false

        :ets.member(store.sessions, client_id) ->
          false

        true ->
          import(store, client_id, resumable(record))
          :ets.delete(store.dirty, client_id)
          true
      end
    end)
  end

  defp live?(%{meta: %{expires_at: :infinity}}), do: true
  defp live?(%{meta: %{expires_at: at}}), do: at > System.system_time(:second)

  # A record saved while its client was connected: the connection is gone,
  # so the expiry clock starts now
  defp resumable(%{meta: %{expires_at: :infinity} = meta} = record) do
    record = Map.delete(record, :node)

    case Map.get(meta, :lifetime) do
      lifetime when is_integer(lifetime) and lifetime < 0xFFFFFFFF ->
        %{record | meta: %{meta | expires_at: System.system_time(:second) + lifetime}}

      _ ->
        record
    end
  end

  defp resumable(record), do: Map.delete(record, :node)

  @doc false
  # Discard sessions whose expiry passed without a timer noticing (restored
  # or moved sessions have no timer). Returns how many went.
  @spec sweep(t()) :: non_neg_integer()
  def sweep(store) do
    now = System.system_time(:second)

    expired =
      :ets.select(store.sessions, [
        {{:"$1", %{expires_at: :"$2"}},
         [{:is_binary, :"$1"}, {:is_integer, :"$2"}, {:"=<", :"$2", now}], [:"$1"]}
      ])

    Enum.each(expired, &delete(store, &1))
    length(expired)
  end
end
