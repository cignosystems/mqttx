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
(retained, with clears remembered). There is no consensus protocol.

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
   sends `{:deliver, id, topic, payload, opts}` to each remote member, which fans
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
   lets go of it (below); for `:clean` it deletes it. The connecting node imports the
   export before `begin_session/4`, so the rest of the connect path is the
   single-node one. Replies go to an `:erlang.alias/0` that is dropped after
   the deadline (5 s), so a late reply cannot reach the connection's
   mailbox; a node that answers late has deleted its copy and the client
   gets a fresh session.

   Messages published during the move: every `deliver` carries an id
   (`make_ref/0`) that all nodes see. Before claiming, the new node puts a
   placeholder down (`SessionStore.hold/3`: no subscriptions, a queue). The
   old node marks its copy as moved (`mark_moved/4`) *before* exporting it,
   so from then on a message it matches for the client is forwarded to the
   new node (`{:deliver_to, ...}`) rather than queued behind the export.
   Forwarded messages land in the placeholder's queue, and `import/3` puts
   them after the exported queue. The old node keeps forwarding for 5 s
   after the hand-over, then sends on whatever a fan-out that read the
   session just before the mark queued after the export, and deletes its
   copy (`finish_move/3`, only if the copy is still the one it moved). For
   15 s from the claim, the new node drops a message whose id it has
   already queued or sent for the client (`seen` table, swept by the
   member). The new node's member imports the session
   (`Cluster.import_moved/3`) — forwarded messages arrive at that member,
   so none lands in the middle of the imported queue — and raises its fence
   (phase 7), which keeps each publisher's order and removes the 5 s bound:
   none missed, none duplicated. A client that comes back to the
   old node within the 5 s gets a placeholder there; the stub's leftovers
   go into it. A moved stub or a placeholder is not a session
   (`exists?/2`), and the backend flush skips both; with a shared backend,
   a node deletes a record only if it saved it itself.
3. **Retained messages cluster-wide.** Every accepted retained write goes
   through `Cluster.store_retained/7`, which writes locally
   (`RetainedStore.write/6` returns the row) and sends it to every remote
   member. Rows carry a version `{microseconds, node, unique}`; a local
   write takes one later than the row it replaces, so it wins wherever that
   row went even against a clock running ahead.
   `RetainedStore.apply_replica/3` keeps whichever row has the higher
   version and respects the cap for messages on topics new to that node. On
   a distributed node a clear leaves its row with a `nil` payload (never
   matched), replicated like any row, so a copy written before the clear —
   from a node that was cut off — loses to it, live or in the join sync.
   Cleared rows are swept after an hour (and count toward the cap until
   then); a node cut off for longer can still bring a cleared message back.
   When a member sees another join, it sends
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
   rotating; offline local members only when there are none), and the
   broadcast fan-out on the other nodes skips shared groups
   (`shared: :skip`). A remote pick goes to the publishing node's member,
   which sends `{:deliver_shared, ...}` to that node and keeps the message
   until it answers: `:ok` (taken), `:offline` (a session without a
   connection) or `:gone` (no session there, or QoS 0 for an offline
   client). Anything but `:ok`, or the node's member leaving the group
   first, re-picks among the members not yet tried
   (`SessionStore.pick_shared/6`); members that answered `:offline` are
   sent the message again with `force` only once no other member is left.
   Erlang distribution does not lose a message between connected nodes, so
   no timer is needed: an answer or a `:pg` leave always comes. A node
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

6. **Routes, and relays to send them in order.** Each listener has a few
   relays per node (`Cluster.Relay`, one per scheduler up to 8, started
   with its member). Everything a node sends other nodes for delivery —
   `{:deliver, ...}`, forwards, fence answers — goes through the relay
   picked by the sender's pid, so one process's messages leave in the
   order it sent them, whichever node they go to. Relay 0 also keeps the
   route table: a normal subscription coming or going makes it check
   whether this node still has that filter at all (`SessionStore.route?/2`)
   and, if that changed, tell relay 0 on every other node; a relay 0 that
   joins is sent the full list. Those land in the store's `routes` table
   (keyed like the subscription index, the node in the key), and a relay
   sends a `{:deliver, ...}` only to the nodes with a filter matching the
   topic (`SessionStore.route_nodes/2`) — every node until its routes have
   arrived. Routes are written by relay 0 alone, so the order it applies
   them in is the order they were announced in. Shared subscriptions keep
   their own replication (phase 4).
7. **Order while a session moves (the fence).** After the import, the new
   node's member sends `{:fence, ...}` to its relay 0 — after the routes
   the import announced, from the same process. Relay 0 sends it to relay
   0 on every node, which sends it to that node's other relays; every relay
   then sends `{:fence_pass, ...}` to the old node's member, behind every
   message it sent there before. That member answers the new node through
   its own relay, behind what it forwarded for those messages. Until every
   relay of every node (as of the fence) has answered — or 5 s pass, or a
   node leaves — a message the new node matches for the session itself is
   held (`held` table, `hold_message/3`); forwarded ones go straight
   through. Then the held messages are delivered in order, the copies
   already forwarded dropped by id. A message the new node matched is
   therefore never ahead of an earlier one from the same publisher that
   reached the old node; once the fence is down, every node routes to the
   new node and the old node's forwarding only produces duplicates. The
   fence is a key of its own (`{:fence, client_id}` in `sessions`), so a
   connection rewriting the session's metadata cannot raise it again; a
   process that holds a message as the fence comes down asks the member to
   let the held ones out first (`Cluster.release/2`).
8. **Sessions that outlive their node.** `SessionBackend.Replicated` keeps
   a table of every saved session on every node, owned by a process in the
   `{Replicated, listener}` `:pg` group: a save or delete is applied
   locally and sent to the others, and a joining node is sent everything.
   Versions are a hybrid clock (`{max(now, stored + 1), node}`), so a late
   save of a session that moved cannot replace the newer one; a delete
   applies only to a record the deleting node saved and leaves a `nil`
   record for an hour so a late save cannot bring it back. When a node
   leaves, its sessions saved while connected start their expiry clock;
   expired ones are swept on every node.

9. **A network split heals.** While apart, each side runs on its own; a
   client may connect on both. When a member sees another join, it also
   sends it the sessions it holds with when each began (`began_at` in the
   session's metadata: the CONNECT's wall clock and node,
   `SessionStore.began/1`), in chunks. The receiving node compares them
   with its own: where its copy began earlier, it takes the connection over
   (0x8E), cancels the timers and deletes the copy, as a `:clean` claim
   does. Both sides compare, so exactly one copy survives — last connect
   wins, as for a live CONNECT; what was queued in the losing copy is
   lost. Retained rows converge by version (phase 3), shared members and
   routes are re-sent on join, and the replicated backend keeps the newest
   version of each record. Join syncs (retained rows, sessions, the
   replicated backend's table) go 500 rows per message.

## Costs

- Every CONNECT on a clustered listener waits for one round trip to each
  other node (the claim), plus one more for Clean Start 0 when the session
  is not local (the peek). Bounded by the 5 s deadline.
- A publish goes to the nodes with a matching filter, through the
  publisher's relay: one local message and a walk of the route table per
  publish when the listener is clustered. Each `deliver` makes one
  reference; a queued message carries it.
- A subscription to a filter new to its node, or the last one going, is
  announced to every node. A moved session's fence is a round trip
  through every relay of every node; what the new node matches for it
  waits that long.
- A shared delivery to another node goes through the publishing node's
  member and is answered: two messages more than a direct send, and the
  payload is held there for that round trip.
- A move keeps a forwarding stub for 5 s and message ids for 15 s on the
  nodes involved; cleared retained topics are kept for an hour.
- A node joining is sent every node's retained table, session list and
  shared members, 500 rows per message.
- Measured (`bench/cluster.exs`, two nodes on one machine, 4 publishers,
  10 subscribers, QoS 1): subscribers on the publishing node or split
  across both deliver at 95–98% of the single-node rate, all on the other
  node at 80–86%.
- With a backend, one ETS insert per session change and one record save per
  changed session per flush interval; with `Replicated`, every node holds
  every persistent session and each save is sent to every node.

## Later

- A subscription is announced to the other nodes asynchronously: a
  message published elsewhere right after a SUBACK, before the
  announcement arrives, does not reach it (it is concurrent with the
  subscription across nodes).
- Replicated sessions are lost when the whole cluster restarts; a
  database backend keeps them.
- A shared delivery to a node that leaves after taking it but before
  answering is delivered again elsewhere (at least once). Exactly once
  across a node loss would need the member's session to outlive the node.
- After a split heals, the losing copy of a session is discarded, not
  merged: what was queued in it, or delivered to it while apart, is not
  carried over. Wall clocks decide which copy began last.
- Splits are tested with two nodes on one machine; not under real network
  partitions or with more than two nodes.
- A database backend example (Ecto/Postgres) in the guides.

## Operational notes

Nodes must be connected (libcluster or manual `Node.connect/1`) and share the
handler module and listener names. A node that goes down takes the sessions
it held with it, unless a backend every node reaches has them
(`SessionBackend.Replicated`, or one over a shared database).
