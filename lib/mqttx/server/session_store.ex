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
  #                            {{:routes_synced, node}, true} that node's routes arrived
  #                            {{:fence, client_id}, ref}     the session's fence is up
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
  #   seen        set          {{client_id, message_id}, until_ms} messages
  #                            already given to a session moving between
  #                            nodes, so a copy arriving by the other way is
  #                            dropped
  #   held        ordered_set  {{client_id, seq}, {id, topic, payload, opts, queued_at}}
  #                            messages matched here for a session that just
  #                            arrived, held until what the node it left
  #                            forwards has gone ahead (its fence)
  #   routes      ordered_set  {{filter_segments, node}, true} the filters of
  #                            normal subscriptions on other nodes, written
  #                            by MqttX.Server.Cluster.Relay
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

  require Logger

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
    :seen,
    :held,
    :routes,
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
          held: :ets.table(),
          routes: :ets.table(),
          remote: :ets.table(),
          dirty: :ets.table(),
          seen: :ets.table(),
          # A durable MqttX.Server.SessionBackend and its state, or nil
          backend: {module(), term()} | nil
        }

  @typedoc """
  A whole session, as moved between nodes and saved to a backend. Queued
  messages carry the wall-clock millisecond they were queued at, so Message
  Expiry keeps counting on another node or after a restart. One handed
  over by another node names it (`:from`); one saved names the node that
  saved it (`:node`).
  """
  @type session_record :: %{
          optional(:from) => node(),
          optional(:node) => node(),
          meta: meta(),
          subscriptions: [%{filter: binary(), opts: map()}],
          inflight: [{inflight_key(), term()}],
          queue: [{binary(), binary(), map(), integer()}]
        }

  @type client_id :: binary()
  # Besides what a connection records, a session moving between nodes (see
  # hold/3, mark_moved/4) carries `:placeholder` (claimed here, not arrived
  # yet), `:moved_to`/`:move_ref` (left here, forwarding to its new node)
  # and `:handoff_until` (wall-clock ms until which duplicates are dropped).
  # `:began_at` is when the connection's CONNECT began it, and where.
  @type meta :: %{
          optional(:lifetime) => non_neg_integer(),
          optional(:began_at) => {integer(), node()},
          optional(:placeholder) => true,
          optional(:moved_to) => node(),
          optional(:move_ref) => reference(),
          optional(:handoff_until) => integer(),
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
      seen: named(:"#{base}_seen", :set),
      held: named(:"#{base}_held", :ordered_set),
      routes: named(:"#{base}_routes", :ordered_set),
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
      seen: anonymous(:set),
      held: anonymous(:ordered_set),
      routes: anonymous(:ordered_set),
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
    # A persistent session (saved, or about to be) replaced by one that ends
    # with its connection: the flush deletes what the backend holds for it
    replaced_saved? =
      store.backend != nil and
        match?([{_, %{persistent: true}}], :ets.lookup(store.sessions, client_id))

    :ets.insert(store.sessions, {client_id, meta})
    if replaced_saved?, do: mark(store, client_id), else: touch(store, client_id)
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

  @doc """
  Whether there is a session to resume: neither a placeholder for one being
  claimed from another node, nor what is left of one that moved away.
  """
  @spec exists?(t(), client_id()) :: boolean()
  def exists?(store, client_id) do
    case get(store, client_id) do
      nil -> false
      %{placeholder: true} -> false
      %{moved_to: _} -> false
      _ -> true
    end
  end

  @doc false
  # When each session here began (its connection's CONNECT), for a node
  # joining after a network split: `[{client_id, {microseconds, node}}]`
  def began(store) do
    for {client_id, meta} <-
          :ets.select(store.sessions, [{{:"$1", :_}, [{:is_binary, :"$1"}], [:"$_"]}]),
        not Map.has_key?(meta, :placeholder),
        not Map.has_key?(meta, :moved_to),
        do: {client_id, began_at(meta)}
  end

  @doc false
  # Sessions from before `began_at` was kept count as the oldest
  def began_at(meta), do: Map.get(meta, :began_at, {0, nil})

  @doc false
  # Sessions here: connected or kept, not the placeholders and stubs of ones
  # moving between nodes, nor the table's bookkeeping rows
  @spec count(t()) :: non_neg_integer()
  def count(store) do
    :ets.select_count(store.sessions, [
      {{:"$1", :"$2"},
       [
         {:is_binary, :"$1"},
         {:not, {:is_map_key, :placeholder, :"$2"}},
         {:not, {:is_map_key, :moved_to, :"$2"}}
       ], [true]}
    ])
  rescue
    ArgumentError -> 0
  end

  # How long a count serves the :max_sessions check
  @count_ttl_ms 1_000

  @doc false
  # Whether a session may begin under a cap of `max` on this node. count/1
  # scans the table, so a count is kept for a second with each session
  # admitted meanwhile added to it: never fewer than the sessions there are.
  # A CONNECT that count would refuse recounts first — a session may have
  # ended since — so a refusal is always from a fresh count.
  @spec admit?(t(), pos_integer()) :: boolean()
  def admit?(store, max) do
    now = System.monotonic_time(:millisecond)

    admitted =
      case :ets.lookup(store.sessions, :session_count) do
        [{_, _n, at}] when now - at < @count_ttl_ms ->
          :ets.update_counter(store.sessions, :session_count, {2, 1})

        _ ->
          recount(store, now)
      end

    admitted <= max or recount(store, now) <= max
  rescue
    ArgumentError -> true
  end

  # The sessions there are, the one being admitted included
  defp recount(store, now) do
    n = count(store) + 1
    :ets.insert(store.sessions, {:session_count, n, now})
    n
  end

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
    # An expiry timer, or a connection closing as its listener stops, can
    # outlive the listener's tables — before this call or partway through it
    if :ets.info(store.sessions) == :undefined, do: :ok, else: do_delete(store, client_id)
  rescue
    ArgumentError -> :ok
  end

  defp do_delete(store, client_id) do
    # Deleted from the backend too, unless it was never saved there (a
    # session that ends with its connection)
    saved? =
      store.backend != nil and
        not match?([{_, %{persistent: false}}], :ets.lookup(store.sessions, client_id))

    drop_state(store, client_id)
    :ets.select_delete(store.queue, [{{{client_id, :_}, :_}, [], [true]}])
    :ets.select_delete(store.held, [{{{client_id, :_}, :_}, [], [true]}])
    :ets.delete(store.sessions, {:qlen, client_id})
    :ets.delete(store.sessions, {:fence, client_id})
    :ets.delete(store.sessions, client_id)
    if saved?, do: mark(store, client_id), else: :ok
  end

  # A session's subscriptions and in-flight state, not its queue or its row
  defp drop_state(store, client_id) do
    for {{^client_id, _filter}, {segments, subscriber}} <-
          :ets.select(store.client_subs, [{{{client_id, :_}, :_}, [], [:"$_"]}]) do
      :ets.delete(store.subs, {segments, subscriber})
      announce_shared(store, :remove, segments, subscriber, nil)
      announce_route(store, segments, subscriber)
      drop_shared_counter(store, segments, subscriber)
    end

    :ets.select_delete(store.client_subs, [{{{client_id, :_}, :_}, [], [true]}])
    :ets.select_delete(store.inflight, [{{{client_id, :_}, :_, :_}, [], [true]}])
  end

  # The round-robin counter of a shared group goes with its last member,
  # here or on another node; a group used once would otherwise leave a row
  # for the VM's life
  defp drop_shared_counter(store, segments, {:share, group, _client}) do
    pattern = {{segments, {:share, group, :_}}, :_}

    if :ets.select_count(store.subs, [{pattern, [], [true]}]) == 0 and
         :ets.select_count(store.remote, [{pattern, [], [true]}]) == 0 do
      :ets.delete(store.sessions, {:rr, segments, group})
    end

    :ok
  end

  defp drop_shared_counter(_store, _segments, _subscriber), do: :ok

  @doc false
  # Every fence down and every held message let go: for a member starting
  # (again) — the fences it was waiting on are no one's now. Returns the
  # clients that had messages held.
  @spec clear_fences(t()) :: [client_id()]
  def clear_fences(store) do
    :ets.match_delete(store.sessions, {{:fence, :_}, :_})

    store.held
    |> :ets.select([{{{:"$1", :_}, :_}, [], [:"$1"]}])
    |> Enum.uniq()
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
        announce_route(store, old_segments, old_subscriber)

      _ ->
        :ok
    end

    new? = :ets.insert_new(store.subs, {{segments, subscriber}, opts})
    if not new?, do: :ets.insert(store.subs, {{segments, subscriber}, opts})
    :ets.insert(store.client_subs, {{client_id, filter}, {segments, subscriber}})
    announce_shared(store, :add, segments, subscriber, opts)
    if new?, do: announce_route(store, segments, subscriber)
    touch(store, client_id)
  end

  @spec unsubscribe(t(), client_id(), binary()) :: :ok
  def unsubscribe(store, client_id, filter) when is_binary(filter) do
    case :ets.lookup(store.client_subs, {client_id, filter}) do
      [{_, {segments, subscriber} = key}] ->
        :ets.delete(store.subs, key)
        :ets.delete(store.client_subs, {client_id, filter})
        announce_shared(store, :remove, segments, subscriber, nil)
        announce_route(store, segments, subscriber)
        drop_shared_counter(store, segments, subscriber)
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
  A member on another node comes back as
  `{:remote, node, client_id, opts, {filter, group}}`; if that node does not
  take the message, `pick_shared/6` picks the group's next member.
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
        ) :: [{client_id(), map()} | {:remote, node(), client_id(), map(), {list(), binary()}}]
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
      case pick_shared_member(store, filter, group, members, online?) do
        [{:remote, node, client, opts}] -> [{:remote, node, client, opts, {filter, group}}]
        local -> local
      end
    end)
    |> Enum.reject(fn
      {client, _opts} -> MapSet.member?(taken, client)
      {:remote, _node, _client, _opts, _key} -> false
    end)
  end

  @doc false
  # Pick a shared group's member again, leaving out the `{node, client_id}`s
  # in `tried` — the node holding the one picked before did not take the
  # message. Returns `{client_id, opts}` (on this node),
  # `{:remote, node, client_id, opts}`, or `nil` with no member left.
  def pick_shared(store, filter, group, publisher, tried, online?) do
    local =
      for [client, opts] <-
            :ets.match(store.subs, {{filter, {:share, group, :"$1"}}, :"$2"}),
          not MapSet.member?(tried, {node(), client}),
          do: {:local, client, opts}

    remote =
      for [client, node, opts] <-
            :ets.match(store.remote, {{filter, {:share, group, :"$1"}}, {:"$2", :"$3"}}),
          not MapSet.member?(tried, {node, client}),
          not (client == publisher and Map.get(opts, :no_local, false)),
          do: {:remote, node, client, opts}

    case pick_shared_member(store, filter, group, local ++ remote, online?) do
      [{client, opts}] -> {client, opts}
      [remote] -> remote
      [] -> nil
    end
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
  # Most of the prefixes the walk probes have none, and the key after
  # {filter, 0} says so; the select, bounded by the filter in the key, runs
  # only when there is one, and reads a filter's thousand subscribers in a
  # fifth of the time stepping through them with next/2 and lookup/2 takes.
  defp collect(tab, filter) do
    case :ets.next(tab, {filter, 0}) do
      {^filter, _subscriber} ->
        :ets.select(tab, [{{{filter, :"$1"}, :"$2"}, [], [{{{:const, filter}, :"$1", :"$2"}}]}])

      _ ->
        []
    end
  end

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

    # Members on other nodes count as reachable: their node answers whether
    # it took the message, and if not the next member is picked
    # (`pick_shared/6`)
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
      [{_, {^node, _opts}}] ->
        :ets.delete(store.remote, key)
        drop_shared_counter(store, segments, {:share, group, client_id})

      _ ->
        :ok
    end

    :ok
  end

  @doc false
  # Every shared subscription held on `node` (it left the cluster)
  def drop_remote_node(store, node) do
    gone = :ets.select(store.remote, [{{:"$1", {node, :_}}, [], [:"$1"]}])
    :ets.select_delete(store.remote, [{{:_, {node, :_}}, [], [true]}])
    for {segments, subscriber} <- gone, do: drop_shared_counter(store, segments, subscriber)
    :ok
  end

  @doc false
  # This node's shared subscriptions, for a node that just joined
  def local_shared(store) do
    for {{segments, {:share, group, client}}, opts} <-
          :ets.select(store.subs, [{{{:_, {:share, :_, :_}}, :_}, [], [:"$_"]}]),
        do: {segments, group, client, opts}
  end

  # ---------- Routes: which nodes have a filter matching a topic ----------

  # A normal subscription came or went here: the listener's relay 0 tells the
  # other nodes if that changed whether this node has the filter at all
  defp announce_route(%{listener: nil}, _segments, _subscriber), do: :ok

  defp announce_route(store, segments, client) when is_binary(client) do
    MqttX.Server.Cluster.route_changed(store.listener, segments)
  end

  defp announce_route(_store, _segments, _subscriber), do: :ok

  @doc false
  # Whether this node has a normal subscription to exactly this filter
  def route?(store, segments) do
    :ets.select(store.subs, [{{{segments, :"$1"}, :_}, [{:is_binary, :"$1"}], [true]}], 1) !=
      :"$end_of_table"
  end

  @doc false
  # Every filter this node has a normal subscription to
  def route_filters(store) do
    store.subs
    |> :ets.select([{{{:"$1", :"$2"}, :_}, [{:is_binary, :"$2"}], [:"$1"]}])
    |> Enum.dedup()
  end

  @doc false
  # The other nodes with a filter matching `topic`
  def route_nodes(store, topic) do
    if :ets.first(store.routes) == :"$end_of_table" do
      MapSet.new()
    else
      for {_filter, node, _} <- walk(store.routes, Topic.normalize(topic)),
          into: MapSet.new(),
          do: node
    end
  end

  @doc false
  # Whether `node`'s routes have arrived (until then it is sent everything)
  def routes_synced?(store, node), do: :ets.member(store.sessions, {:routes_synced, node})

  @doc false
  def put_route(store, node, segments, true) do
    :ets.insert(store.routes, {{segments, node}, true})
    :ok
  end

  def put_route(store, node, segments, false) do
    :ets.delete(store.routes, {segments, node})
    :ok
  end

  @doc false
  # All of `node`'s routes, as it sent them when it joined
  def replace_routes(store, node, filters) do
    :ets.select_delete(store.routes, [{{{:_, node}, :_}, [], [true]}])
    :ets.insert(store.routes, for(segments <- filters, do: {{segments, node}, true}))
    :ets.insert(store.sessions, {{:routes_synced, node}, true})
    :ok
  end

  @doc false
  # `node` left
  def drop_routes(store, node) do
    :ets.delete(store.sessions, {:routes_synced, node})
    :ets.select_delete(store.routes, [{{{:_, node}, :_}, [], [true]}])
    :ok
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

  # Orders a client's queue, held messages and in-flight entries: unique and
  # increasing on this node, as a counter row would be, without every
  # enqueue on the node waiting its turn at one ETS key (under contention
  # that key cost forty times what the insert itself does)
  defp next_seq(_store), do: :erlang.unique_integer([:monotonic, :positive])

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
          for {_key, {topic, payload, opts, queued_at}} <- queued(store, client_id),
              do: {topic, payload, opts, queued_at + offset}

        # A moved session's stub keeps a short expiry of its own (mark_moved);
        # the session carries its lifetime's, as if its client had just left
        exported_meta =
          if Map.has_key?(meta, :moved_to),
            do: %{meta | expires_at: lifetime_expiry(meta)},
            else: meta

        %{
          meta: Map.drop(exported_meta, [:placeholder, :moved_to, :move_ref, :handoff_until]),
          subscriptions: subscriptions(store, client_id),
          inflight: inflight(store, client_id),
          queue: queue
        }
    end
  end

  @doc """
  Install an exported session, replacing whatever the store held for it. The
  queue is not bounded here: what was queued elsewhere was within its bound.
  A placeholder's queue — messages forwarded while the session was on its
  way — follows the imported one (one forwarded while the import runs may
  come first), and its hand-off window carries over. With a `fence`, what
  this node matches for the session is held (`hold_message/3`) until
  `lower_fence/3`; it is raised before the subscriptions go in.
  """
  @spec import(t(), client_id(), session_record(), reference() | nil) :: :ok
  def import(store, client_id, %{meta: meta} = record, fence \\ nil) do
    {forwarded, handoff_until} =
      case :ets.lookup(store.sessions, client_id) do
        # Taken entry by entry and the row replaced, not deleted: a message
        # forwarded meanwhile must neither be wiped with the queue nor find
        # no session at all (it would be dropped)
        [{_, %{placeholder: true} = held}] ->
          {take_queued(store, client_id), Map.get(held, :handoff_until)}

        _ ->
          delete(store, client_id)
          {[], nil}
      end

    meta =
      meta
      |> Map.drop([:placeholder, :moved_to, :move_ref, :handoff_until])
      |> then(&if handoff_until, do: Map.put(&1, :handoff_until, handoff_until), else: &1)

    put(store, client_id, meta)
    if fence, do: :ets.insert(store.sessions, {{:fence, client_id}, fence})

    for %{filter: filter, opts: opts} <- record.subscriptions,
        do: subscribe(store, client_id, filter, opts)

    for {key, value} <- record.inflight, do: put_inflight(store, client_id, key, value)

    offset = System.system_time(:millisecond) - System.monotonic_time(:millisecond)

    for {topic, payload, opts, queued_at} <- record.queue do
      # A message the old node had queued may reach this node again
      if handoff_until && opts[:id], do: seen?(store, client_id, opts[:id], handoff_until)
      enqueue(store, client_id, {topic, payload, opts, queued_at - offset}, nil)
    end

    for entry <- forwarded, do: enqueue(store, client_id, entry, nil)
    :ok
  end

  # ---------- A session moving between nodes ----------
  #
  # The node a client connects to puts a placeholder down before it claims
  # the session (hold/3), so what the old node forwards in the meantime is
  # queued. The old node marks its copy as moved (mark_moved/4) before
  # exporting it: from then on a message it matches for the client goes to
  # the new node, and a few seconds later it hands over anything queued in
  # the gap and drops the copy (finish_move/3). While both nodes match
  # messages for the client, the new one drops the copies it already has,
  # by message id (seen?/4).

  @doc false
  # A session claimed from another node, collecting what that node forwards
  # until the claim is answered. Expires on its own if the connection dies
  # before it begins the session.
  @spec hold(t(), client_id(), integer()) :: :ok
  def hold(store, client_id, handoff_until) do
    # Back where it left from: the copy it left behind goes, but what was
    # queued on it still reaches the client. Its row is replaced below, not
    # deleted, so nothing finds the client without a session meanwhile.
    left =
      case :ets.lookup(store.sessions, client_id) do
        [{_, %{moved_to: _}}] ->
          drop_state(store, client_id)
          take_queued(store, client_id)

        _ ->
          []
      end

    meta = %{
      protocol_version: 5,
      expires_at: System.system_time(:second) + 60,
      persistent: true,
      placeholder: true,
      handoff_until: handoff_until
    }

    :ets.insert(store.sessions, {client_id, meta})
    for entry <- left, do: enqueue(store, client_id, entry, nil)
    :ok
  end

  @doc false
  # Drop duplicates for the session until `until` (it exists here already)
  @spec mark_handoff(t(), client_id(), integer()) :: :ok
  def mark_handoff(store, client_id, until) do
    case :ets.lookup(store.sessions, client_id) do
      [{_, meta}] ->
        :ets.insert(store.sessions, {client_id, Map.put(meta, :handoff_until, until)})

      [] ->
        :ok
    end

    :ok
  end

  @doc false
  # The session left for `node`: forward instead of queueing. Not saved to
  # the backend — the new node saves it — and gone within the minute even if
  # finish_move/3 never runs.
  @spec mark_moved(t(), client_id(), node(), reference()) :: :ok
  def mark_moved(store, client_id, node, ref) do
    case :ets.lookup(store.sessions, client_id) do
      [{_, meta}] ->
        expires_at = System.system_time(:second) + 60
        moved = Map.merge(meta, %{expires_at: expires_at, moved_to: node, move_ref: ref})
        :ets.insert(store.sessions, {client_id, moved})

      [] ->
        :ok
    end

    :ok
  end

  @doc false
  # Discard what a session that moved away left here, if anything: the
  # client is starting afresh on this node
  @spec drop_moved(t(), client_id()) :: :ok
  def drop_moved(store, client_id) do
    case :ets.lookup(store.sessions, client_id) do
      [{_, %{moved_to: _}}] -> delete(store, client_id)
      _ -> :ok
    end
  end

  @doc false
  # The end of a move: what was queued for the client after the export, in
  # order, and the session deleted — unless it is no longer the one moved
  # under `ref` (the client came back here meanwhile).
  @spec finish_move(t(), client_id(), reference()) :: [term()]
  def finish_move(store, client_id, ref) do
    case :ets.lookup(store.sessions, client_id) do
      [{_, %{move_ref: ^ref}}] ->
        left = for {_key, entry} <- queued(store, client_id), do: entry
        delete(store, client_id)
        left

      _ ->
        []
    end
  end

  @doc false
  # The session marked as moved stays: the node it was moving to never
  # imported it (the connection claiming it died first). Its expiry clock
  # runs from now, as after a disconnect.
  @spec unmove(t(), client_id(), reference()) :: boolean()
  def unmove(store, client_id, ref) do
    case :ets.lookup(store.sessions, client_id) do
      [{_, %{move_ref: ^ref} = meta}] ->
        meta =
          meta |> Map.drop([:moved_to, :move_ref]) |> Map.put(:expires_at, lifetime_expiry(meta))

        :ets.insert(store.sessions, {client_id, meta})
        touch(store, client_id)
        true

      _ ->
        false
    end
  end

  # When a session whose client has just left ends: its Session Expiry
  # Interval from now; never, for the protocol's "never"; a minute when the
  # record does not say (it cannot be a session of this broker's making)
  defp lifetime_expiry(meta) do
    case Map.get(meta, :lifetime) do
      lifetime when is_integer(lifetime) and lifetime < 0xFFFFFFFF ->
        System.system_time(:second) + lifetime

      lifetime when is_integer(lifetime) ->
        :infinity

      _ ->
        System.system_time(:second) + 60
    end
  end

  @doc false
  # A session arrived here from another node: remembered for a minute, so
  # the node it came from can tell "imported, then ended or moved on" from
  # "never arrived" before letting its own copy go (Cluster.finish_move)
  @spec mark_imported(t(), client_id()) :: :ok
  def mark_imported(store, client_id) do
    :ets.insert(store.seen, {{:imported, client_id}, System.system_time(:millisecond) + 60_000})
    :ok
  end

  @doc false
  @spec imported_recently?(t(), client_id()) :: boolean()
  def imported_recently?(store, client_id) do
    case :ets.lookup(store.seen, {:imported, client_id}) do
      [{_, until}] -> until > System.system_time(:millisecond)
      [] -> false
    end
  end

  @doc false
  # A message matched here for a session whose fence is up
  @spec hold_message(t(), client_id(), tuple()) :: :ok
  def hold_message(store, client_id, message) do
    :ets.insert(store.held, {{client_id, next_seq(store)}, message})
    :ok
  end

  @doc false
  def held?(store, client_id) do
    case :ets.next(store.held, {client_id, 0}) do
      {^client_id, _} -> true
      _ -> false
    end
  end

  @doc false
  # The held messages, oldest first, taken out
  @spec take_held(t(), client_id()) :: [tuple()]
  def take_held(store, client_id) do
    for seq <- :ets.select(store.held, [{{{client_id, :"$1"}, :_}, [], [:"$1"]}]),
        [{_, message}] <- [:ets.take(store.held, {client_id, seq})],
        do: message
  end

  @doc false
  # The fence `ref` is down: what is matched here is delivered again
  @spec lower_fence(t(), client_id(), reference()) :: :ok
  def lower_fence(store, client_id, ref) do
    :ets.delete_object(store.sessions, {{:fence, client_id}, ref})
    :ok
  end

  @doc false
  # Whether the session's fence is up — a key of its own, so rewriting the
  # session's metadata cannot raise it again
  @spec fenced?(t(), client_id()) :: boolean()
  def fenced?(store, client_id), do: :ets.member(store.sessions, {:fence, client_id})

  @doc false
  # Whether the session already got the message `id`; records it if not
  @spec seen?(t(), client_id(), term(), integer()) :: boolean()
  def seen?(store, client_id, id, until) do
    not :ets.insert_new(store.seen, {{client_id, id}, until})
  end

  @doc false
  # Forget message ids whose hand-off window closed
  @spec sweep_seen(t()) :: non_neg_integer()
  def sweep_seen(store) do
    now = System.system_time(:millisecond)
    :ets.select_delete(store.seen, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end

  defp queued(store, client_id) do
    :ets.select(store.queue, [{{{client_id, :_}, :_}, [], [:"$_"]}])
  end

  defp take_queued(store, client_id) do
    for {key, _entry} <- queued(store, client_id),
        [{_, entry}] <- [:ets.take(store.queue, key)] do
      key = {:qlen, client_id}
      :ets.update_counter(store.sessions, key, {2, -1}, {key, 0})
      entry
    end
  end

  # Remember that a session changed, for the next backend save. One that ends
  # with its connection is never saved: the connection goes, the session with
  # it, and a copy restored after a crash would be dead on arrival.
  defp touch(%{backend: nil}, _client_id), do: :ok

  defp touch(store, client_id) do
    case :ets.lookup(store.sessions, client_id) do
      [{_, %{persistent: false}}] -> :ok
      _ -> mark(store, client_id)
    end
  end

  defp mark(store, client_id) do
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
    Enum.reduce_while(:ets.tab2list(store.dirty), :ok, fn {client_id}, :ok ->
      :ets.delete(store.dirty, client_id)

      try do
        case :ets.lookup(store.sessions, client_id) do
          # On its way here, or gone from here: the node that has it saves it
          [{_, %{placeholder: true}}] -> :ok
          [{_, %{moved_to: _}}] -> :ok
          # Ends with its connection: nothing to keep, and what a persistent
          # session under the id left in the backend goes
          [{_, %{persistent: false}}] -> delete_saved(module, state, client_id)
          [] -> delete_saved(module, state, client_id)
          _ -> save(module, state, client_id, export(store, client_id))
        end

        {:cont, :ok}
      rescue
        e -> retry_later(store, module, client_id, Exception.message(e))
      catch
        :exit, reason -> retry_later(store, module, client_id, inspect(reason))
      end
    end)
  end

  # Marked again, and the rest keep their marks: the next flush retries, so
  # a backend that is down (a database) loses nothing
  defp retry_later(store, module, client_id, why) do
    :ets.insert(store.dirty, {client_id})
    Logger.warning("[MqttX.Server.SessionStore] sessions not saved to #{inspect(module)}: #{why}")
    {:halt, :ok}
  end

  defp save(module, state, client_id, nil), do: delete_saved(module, state, client_id)

  defp save(module, state, client_id, record),
    do: module.save(state, client_id, saved_record(record))

  # With a backend the nodes share, the record may already be another node's:
  # the session moved there and that node saved it
  defp delete_saved(module, state, client_id) do
    case module.load(state, client_id) do
      {:ok, %{node: node}} when node != node() -> :ok
      _ -> module.delete(state, client_id)
    end
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
      restore_record(store, module, state, client_id, record)
    end)
  end

  # A record that cannot be restored (written by something else, corrupt)
  # is logged and deleted; the listener still starts
  defp restore_record(store, module, state, client_id, record) do
    try do
      do_restore_record(store, module, state, client_id, record)
    rescue
      e ->
        Logger.warning(
          "[MqttX.Server.SessionStore] dropping the stored session #{inspect(client_id)}: " <>
            Exception.message(e)
        )

        try do
          module.delete(state, client_id)
          delete(store, client_id)
        rescue
          _ -> :ok
        end

        false
    end
  end

  defp do_restore_record(store, module, state, client_id, record) do
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
