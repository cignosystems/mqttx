defmodule MqttX.Session.Store do
  @moduledoc """
  Behaviour for MQTT session persistence.

  Implement this behaviour to provide custom session storage for MQTT clients
  and servers. Sessions store subscriptions, pending messages, and packet IDs
  for clients with `clean_session: false`.

  ## Built-in Implementations

  - `MqttX.Session.ETSStore` - In-memory ETS-based storage (default)

  ## Session Data Structure

  Sessions are stored as maps with the following structure:

      %{
        subscriptions: [%{topic: "sensor/#", qos: 1}],
        pending_messages: [%{packet_id: 1, topic: "...", payload: "..."}],
        packet_id: 42
      }

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
          subscriptions: [%{topic: binary(), qos: 0 | 1 | 2}],
          pending_messages: [map()],
          packet_id: non_neg_integer()
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
