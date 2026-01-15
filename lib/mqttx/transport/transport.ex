defmodule MqttX.Transport do
  @moduledoc """
  Behaviour for MQTT transport adapters.

  Transport adapters handle the underlying network connections
  (TCP, TLS, WebSocket, etc.) and forward data to the MQTT protocol handler.

  ## Implementing a Transport

      defmodule MyTransport do
        @behaviour MqttX.Transport

        @impl true
        def start_link(handler, handler_opts, transport_opts) do
          # Start the transport server
        end

        @impl true
        def send(socket, data) do
          # Send data over the connection
        end

        @impl true
        def close(socket) do
          # Close the connection
        end

        @impl true
        def peername(socket) do
          # Get the peer address
        end
      end
  """

  @type socket :: term()
  @type handler :: module()
  @type handler_opts :: term()
  @type transport_opts :: keyword()

  @doc """
  Start the transport server.

  The handler module will receive callbacks for connection events.
  """
  @callback start_link(handler, handler_opts, transport_opts) :: {:ok, pid()} | {:error, term()}

  @doc """
  Send data over the connection.
  """
  @callback send(socket, iodata()) :: :ok | {:error, term()}

  @doc """
  Close the connection.
  """
  @callback close(socket) :: :ok

  @doc """
  Get the remote address of the connection.
  """
  @callback peername(socket) ::
              {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}

  @doc """
  Get socket options.
  """
  @callback getopts(socket, [:inet.socket_getopt()]) ::
              {:ok, [:inet.socket_setopt()]} | {:error, term()}

  @doc """
  Set socket options.
  """
  @callback setopts(socket, [:inet.socket_setopt()]) :: :ok | {:error, term()}

  @optional_callbacks [getopts: 2, setopts: 2]
end
