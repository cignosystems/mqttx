defmodule MqttX.Transport.CrashCleanupTest do
  @moduledoc """
  A handler callback that raises must not skip the connection's close work:
  the Will still goes out and the session's expiry still starts — when the
  connection process itself dies (an exception in `handle_publish`) and
  when a callback on the close path raises (`handle_disconnect`). On both
  TCP transports.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MqttX.Server.Cluster
  alias MqttX.Server.SessionStore
  alias MqttX.Test.ForwardingHandler

  # Delivers like the guide's broker; raises on cue
  defmodule Raiser do
    use MqttX.Server

    def init(opts), do: %{on: Keyword.get(opts, :raise_on, :publish)}
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    def handle_publish(["boom"], _payload, _opts, %{on: :publish}), do: raise("boom")

    def handle_publish(topic, payload, opts, state) do
      {:ok, _} = MqttX.Server.deliver(topic, payload, opts)
      {:ok, state}
    end

    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}

    def handle_disconnect(_reason, %{on: :disconnect}), do: raise("boom")
    def handle_disconnect(_reason, _state), do: :ok
  end

  defp start(MqttX.Transport.Ranch, handler_opts) do
    refs_before = MapSet.new(Map.keys(:ranch.info()))
    name = :"crash_ranch_#{System.unique_integer([:positive])}"

    {:ok, listener} =
      MqttX.Server.start_link(Raiser, handler_opts,
        transport: MqttX.Transport.Ranch,
        port: 0,
        name: name
      )

    [ref] = Map.keys(:ranch.info()) |> Enum.reject(&MapSet.member?(refs_before, &1))
    on_exit(fn -> if Process.alive?(listener), do: Process.exit(listener, :shutdown) end)
    {name, :ranch.get_port(ref)}
  end

  defp start(MqttX.Transport.ThousandIsland, handler_opts) do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    name = :"crash_ti_#{port}"
    parent = self()

    owner =
      spawn(fn ->
        {:ok, server} = MqttX.Server.start_link(Raiser, handler_opts, port: port, name: name)
        send(parent, {:started, server})
        Process.sleep(:infinity)
      end)

    server =
      receive do
        {:started, server} -> server
      after
        5_000 -> flunk("listener did not start")
      end

    on_exit(fn ->
      ThousandIsland.stop(server)
      Process.exit(owner, :kill)
    end)

    {name, port}
  end

  defp connect(port, client_id, opts) do
    {:ok, client} =
      MqttX.Client.connect(
        [
          host: "127.0.0.1",
          port: port,
          client_id: client_id,
          protocol_version: 5,
          await_connect: true,
          handler: ForwardingHandler,
          handler_state: %{pid: self()}
        ] ++ opts
      )

    client
  end

  defp sessions(name) do
    [member] = Enum.filter(Cluster.members(name), &(node(&1) == node()))
    :sys.get_state(member).ctx.sessions
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  for transport <- [MqttX.Transport.ThousandIsland, MqttX.Transport.Ranch] do
    test "#{inspect(transport)}: a connection killed by a raising handle_publish publishes its Will and ends its session" do
      {name, port} = start(unquote(transport), raise_on: :publish)

      watcher = connect(port, "crash-watcher", [])
      {:ok, [1]} = MqttX.Client.subscribe(watcher, "will/#", qos: 1)

      victim =
        connect(port, "crash-victim",
          clean_session: false,
          connect_properties: %{session_expiry_interval: 300},
          will_topic: "will/victim",
          will_payload: "died",
          will_qos: 1
        )

      Process.unlink(victim)

      capture_log(fn ->
        :ok = MqttX.Client.publish(victim, "boom", "x", qos: 0)
        assert_receive {:mqtt_event, :message, {["will", "victim"], "died", _}}, 3_000
      end)

      # The session outlives the connection: its expiry clock is running
      wait_until(fn ->
        match?(
          %{expires_at: at} when is_integer(at),
          SessionStore.get(sessions(name), "crash-victim")
        )
      end)

      MqttX.Client.disconnect(watcher)
    end

    test "#{inspect(transport)}: a raising handle_disconnect does not stop the session from ending" do
      {name, port} = start(unquote(transport), raise_on: :disconnect)

      client =
        connect(port, "crash-leaver",
          clean_session: false,
          connect_properties: %{session_expiry_interval: 300}
        )

      assert %{expires_at: :infinity} = SessionStore.get(sessions(name), "crash-leaver")
      capture_log(fn -> :ok = MqttX.Client.disconnect(client) end)

      wait_until(fn ->
        match?(
          %{expires_at: at} when is_integer(at),
          SessionStore.get(sessions(name), "crash-leaver")
        )
      end)
    end
  end
end
