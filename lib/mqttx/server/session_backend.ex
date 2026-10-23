defmodule MqttX.Server.SessionBackend do
  @moduledoc """
  Durable storage for the broker's sessions.

  `MqttX.Server` keeps Session State (MQTT §4.1) in ETS, which ends with the
  node. A backend saves each session as a whole record, so a node that
  restarts takes its sessions back, and — with a backend every node can
  reach — a client whose node is gone resumes its session on another one.

  Configure it per listener:

      MqttX.Server.start_link(MyBroker, [],
        name: MyApp.Broker,
        port: 1883,
        session_backend: {MqttX.Server.SessionBackend.DETS, path: "/var/lib/broker/sessions.dets"}
      )

  Built in: `MqttX.Server.SessionBackend.DETS` (a local file, for one node's
  restarts) and `MqttX.Server.SessionBackend.Replicated` (every node of a
  cluster, in memory, so another node resumes a dead node's sessions). For
  sessions that survive a restart of the whole cluster, implement the
  behaviour over a database; the server guide ("Durable sessions") has a
  worked Ecto/Postgres backend.

  ETS stays the working copy: the subscription index and the queues are read
  there, and the backend is written behind it. A session changed since the
  last save is marked, and the listener saves the marked sessions every
  `:session_flush_interval` milliseconds (default 1000), so a node that dies
  loses at most that much of its sessions' changes. Each save is the whole
  record: its subscriptions, its in-flight QoS 1/2 messages and its queue.
  A `save/3` or `delete/2` that raises is logged, the session stays marked,
  and the next flush tries again.

  ## Records

  A record is a map with `:meta` (protocol version, `:expires_at`,
  `:lifetime`), `:subscriptions`, `:inflight`, `:queue` and `:node`, the node
  that saved it. Treat it as opaque and store it as a term
  (`:erlang.term_to_binary/1` for an external database).

  When the listener starts, the sessions `list/1` returns that this node
  saved are loaded back, and the ones that expired are deleted. A session
  saved by another node is loaded only when its client connects here and no
  running node holds it. A record saved while its client was connected starts
  its expiry clock when it is loaded.
  """

  @type state :: term()
  @type client_id :: binary()
  @type session :: map()

  @doc """
  Open the backend for one listener, named `listener` (its `:name`, or the
  port). Runs in the process that starts the listener.
  """
  @callback init(listener :: term(), opts :: keyword()) :: {:ok, state()}

  @doc "Save (insert or replace) a session."
  @callback save(state(), client_id(), session()) :: :ok

  @doc "The saved session for a client id."
  @callback load(state(), client_id()) :: {:ok, session()} | :none

  @doc "Forget a session (it ended or expired)."
  @callback delete(state(), client_id()) :: :ok

  @doc "Every saved session, for the listener's start."
  @callback list(state()) :: [{client_id(), session()}]
end
