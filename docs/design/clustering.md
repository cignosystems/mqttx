# Clustering — design notes

Contributor notes; the user-facing text is the "Clustering" and "Durable
sessions" sections of `guides/server.md`.

## Goal

Several broker nodes run the same handler module behind a load balancer. A
device may connect to any node, and the single-node guarantees extend across
the cluster: `MqttX.Server.deliver/3` reaches every subscribed session on
every node, a persistent session can be resumed from any node, a reconnect
anywhere cancels Will Delay and Session Expiry anywhere, retained messages
are visible everywhere, and a shared subscription delivers once per message
cluster-wide.

Conflicts resolve as "last connect wins" (sessions) and "latest write wins"
(retained). There is no consensus protocol.

## Building blocks

- Erlang distribution and `:pg` (`:pg.monitor/2`, OTP 25.1+). The
  application starts the `MqttX.Server.Cluster` scope; on a node that is not
  distributed it is idle.
- One `:pg` group per listener name (`:name` from `start_link`, the port when
  unnamed). Clustered listeners therefore use the same `:name` on every node.
- `MqttX.Server.Cluster`: a member process per listener per node, started by
  `MqttX.Server.register_listener/2` under a DynamicSupervisor in the
  application tree. It joins the listener's group holding the listener's
  context (session store, retained table, bounds) and acts on what other
  nodes send it. A listener restarted under the same name updates the
  member's context instead of adding a second member. It monitors the group,
  so it sees nodes join and leave.

## Phases (all done, 0.13)

1. **Delivery and timers across nodes.** `deliver` fans out locally, then
   sends `{:deliver, topic, payload, opts}` to each remote member, which fans
   out on its node with its own context. The payload is already
   codec-encoded, so remote nodes need no codec. `deliver` returns the local
   count only.
2. **Resume a session from any node.** Before `handle_connect/4`, a Clean
   Start 0 CONNECT whose session is not local asks the other members
   (`:peek`, read-only) so `connect_info` reports `session_present` and the
   subscriptions truthfully. After authorization, every CONNECT sends
   `{:claim, alias, client_id, :take | :clean}` to every remote member; each
   answers from a spawned process (deliveries keep flowing through the
   member): it runs the usual takeover handshake against its own connection
   for the client id, cancels its Will Delay and Session Expiry, and for
   `:take` exports the session (`SessionStore.export/2`: subscriptions,
   in-flight entries, the queue in order with wall-clock enqueue times) and
   deletes it; for `:clean` it deletes it. The connecting node imports the
   export before `begin_session/4`, so the rest of the connect path is the
   single-node one. Replies go to an `:erlang.alias/0` that is dropped after
   the deadline (5 s), so a late reply cannot reach the connection's
   mailbox; a node that answers late has deleted its copy and the client
   gets a fresh session.
3. **Retained messages cluster-wide.** Every accepted retained write goes
   through `Cluster.store_retained/7`, which writes locally
   (`RetainedStore.write/6` returns the row, or the clear) and sends the
   change to every remote member. `RetainedStore.apply_replica/3` keeps the
   newer row by its timestamp (seconds; a tie applies) and respects the cap
   for topics new to that node. When a member sees another join, it sends
   its whole retained table (and its shared subscriptions) to the newcomer;
   both sides do this, so two nodes that connect late converge.
4. **Shared subscriptions cluster-wide.** `SessionStore.subscribe/4`,
   `unsubscribe/3` and `delete/2` announce shared-subscription changes; each
   node keeps the other nodes' members in a `remote` table keyed like the
   subscription index, with the owning node in the value. A remove applies
   only if the stored node matches, so a session that moved (add from the
   new node, remove from the old) cannot lose its entry to reordering. The
   publishing node walks both tables and picks one member per group
   (connected local members and all remote members are candidates,
   rotating; offline local members only when there are none); a remote pick
   becomes a targeted `{:deliver_to, ...}` to that node, and the broadcast
   fan-out on the other nodes skips shared groups (`shared: :skip`). A node
   leaving drops its members from every `remote` table.
5. **Durable, pluggable store.** `MqttX.Server.SessionBackend` (init, save,
   load, delete, list) stores whole session records. ETS stays the working
   copy: every change marks the session in a `dirty` table (only when a
   backend is configured), and the listener's member flushes the marked
   sessions every `:session_flush_interval` ms (export, or delete if gone)
   and sweeps sessions whose expiry passed. Records carry the node that
   saved them; a starting listener restores its own node's records (a
   session saved while connected starts its expiry clock then, from the
   `lifetime` kept in its metadata). A record from another node is loaded
   only on CONNECT when no running node holds the session — with a shared
   database that is how a dead node's sessions move. The bundled
   `SessionBackend.DETS` is a local file.

## Costs

- Every CONNECT on a clustered listener waits for one round trip to each
  other node (the claim), plus one more for Clean Start 0 when the session
  is not local (the peek). Bounded by the 5 s deadline.
- Delivery is a broadcast, O(nodes) per publish.
- With a backend, one ETS insert per session change and one record save per
  changed session per flush interval.

## Later

- A route table of filters per node, so delivery skips nodes with no
  matching subscription instead of broadcasting.
- The moving window: messages delivered while a session is being exported
  and imported can miss it (the old node has deleted it, the new one has not
  imported it yet). Queuing on the new node from the claim onward would
  close it.
- Remote shared members are assumed reachable; replicating whether they are
  connected would let the pick prefer online members cluster-wide.
- A database backend example (Ecto/Postgres) in the guides.
- Retained clears are not tombstoned: a node that was partitioned during a
  clear can bring the cleared message back when it rejoins.

## Operational notes

Nodes must be connected (libcluster or manual `Node.connect/1`) and share the
handler module and listener names. A node that goes down takes the sessions
it held with it, unless a backend every node reaches has them.
