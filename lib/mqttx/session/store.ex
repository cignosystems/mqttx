defmodule MqttX.Session.Store do
  @moduledoc """
  Behaviour for MQTT session persistence.

  Implement this behaviour to provide custom session storage for MQTT clients
  and servers. Sessions store subscriptions, pending messages, and packet IDs
  for clients with `clean_session: false`.

  ## Built-in Implementations

  - `MqttX.Session.ETSStore` - In-memory ETS-based storage (default)

  ## Session Data Structure

  Sessions are opaque maps written by `MqttX.Client`; a store only needs to
  round-trip them. The fields (all additive — older records lacking a key
  load fine):

      %{
        # next packet identifier to allocate
        packet_id: 42,
        # granted subscriptions, replayed after a reconnect with
        # session_present=false
        subscriptions: %{"sensors/#" => %{spec: %{qos: 1}, properties: %{}}},
        # in-flight QoS 1/2 state, outbound ({:tx, id}) AND inbound QoS 2
        # ({:rx, id}) so neither side of a handshake is lost across restarts
        pending_acks: %{{:tx, 1} => %{...}, {:rx, 7} => %{...}},
        # unix seconds the record was written
        saved_at: 1_756_600_000,
        # unix seconds after which the broker may have discarded the session
        # (from the negotiated Session Expiry Interval); nil = never
        expires_at: 1_756_603_600
      }

  ## Expiry

  `expires_at` is derived from the MQTT 5.0 Session Expiry Interval —
  the CONNECT property, overridden by CONNACK, revisable on DISCONNECT.
  Pre-5 sessions and `0xFFFFFFFF` never expire (`nil`). The client discards
  (and deletes) an expired record on load rather than replaying stale
  in-flight state against a broker that already dropped the session.

  `MqttX.Session.ETSStore` sweeps expired records periodically. A custom
  store is expected to do the same in whatever way suits its backend
  (a TTL, a scheduled `DELETE WHERE expires_at <= now`, …); nothing in the
  client enumerates sessions, so the behaviour has no sweep callback.

  ## Usage

  Configure session storage when starting a client or server:

      # Using the built-in ETS store
      {:ok, client} = MqttX.Client.connect(
        host: "localhost",
        client_id: "persistent_client",
        clean_session: false,
        session_store: MqttX.Session.ETSStore
      )

      # Using a custom store with options
      {:ok, client} = MqttX.Client.connect(
        host: "localhost",
        client_id: "persistent_client",
        clean_session: false,
        session_store: {MyApp.EctoSessionStore, repo: MyApp.Repo}
      )

  ## Implementing a Custom Store

      defmodule MyApp.EctoSessionStore do
        @behaviour MqttX.Session.Store

        @impl true
        def init(opts) do
          repo = Keyword.fetch!(opts, :repo)
          {:ok, %{repo: repo}}
        end

        @impl true
        def save(client_id, session, %{repo: repo}) do
          # Save to database
          :ok
        end

        @impl true
        def load(client_id, %{repo: repo}) do
          # Load from database
          {:ok, session} | :not_found
        end

        @impl true
        def delete(client_id, %{repo: repo}) do
          # Delete from database
          :ok
        end
      end
  """

  @type client_id :: binary()
  @type session :: %{
          optional(:packet_id) => non_neg_integer(),
          optional(:subscriptions) => %{binary() => map()},
          optional(:pending_acks) => %{{:tx | :rx, non_neg_integer()} => map()},
          optional(:saved_at) => integer(),
          optional(:expires_at) => integer() | nil
        }
  @type state :: term()

  @doc """
  Initialize the session store.

  Called once when the client or server starts. Returns initial store state
  that will be passed to subsequent callbacks.

  ## Parameters

  - `opts` - Options passed when configuring the session store

  ## Returns

  - `{:ok, state}` - Store initialized successfully
  - `{:error, reason}` - Failed to initialize
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Save a session.

  Called when a client disconnects with `clean_session: false` to persist
  the session state for later restoration.

  ## Parameters

  - `client_id` - The MQTT client identifier
  - `session` - Session data to persist
  - `state` - Store state from init/1

  ## Returns

  - `:ok` - Session saved successfully
  - `{:error, reason}` - Failed to save session
  """
  @callback save(client_id(), session(), state()) :: :ok | {:error, term()}

  @doc """
  Load a session.

  Called when a client connects with `clean_session: false` to restore
  a previously saved session.

  ## Parameters

  - `client_id` - The MQTT client identifier
  - `state` - Store state from init/1

  ## Returns

  - `{:ok, session}` - Session found and loaded
  - `:not_found` - No session exists for this client
  - `{:error, reason}` - Failed to load session
  """
  @callback load(client_id(), state()) :: {:ok, session()} | :not_found | {:error, term()}

  @doc """
  Delete a session.

  Called when a client connects with `clean_session: true` to remove
  any previously saved session.

  ## Parameters

  - `client_id` - The MQTT client identifier
  - `state` - Store state from init/1

  ## Returns

  - `:ok` - Session deleted (or didn't exist)
  - `{:error, reason}` - Failed to delete session
  """
  @callback delete(client_id(), state()) :: :ok | {:error, term()}
end
