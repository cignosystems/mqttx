defmodule MqttX.ClusterSplitTest do
  @moduledoc """
  A network split between two nodes of a cluster, and its healing: while
  apart, each side accepts the same client and its own retained writes;
  once connected again, the client keeps the session it began last and the
  retained messages converge.

  The peer is driven over its standard I/O, not distribution, so the test
  can reach it while the nodes are apart; a wrong cookie keeps either node
  from connecting to the other until the split heals. A module of its own,
  so no other peer joins the two nodes up through a third.
  """
  use ExUnit.Case, async: false

  @moduletag :cluster
  @moduletag timeout: 60_000

  @persistent [clean_session: false, connect_properties: %{session_expiry_interval: 300}]

  alias MqttX.Server.Cluster
  alias MqttX.Server.RetainedStore
  alias MqttX.Server.SessionStore
  alias MqttX.Test.ClusterBroker
  alias MqttX.Test.ForwardingHandler

  setup_all do
    case ensure_distributed() do
      :ok ->
        {:ok, peer, node} =
          :peer.start_link(%{
            name: :"mqttx_split_#{System.unique_integer([:positive])}",
            connection: :standard_io
          })

        :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
        :ok = :peer.call(peer, Logger, :configure, [[level: :warning]])
        {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:mqttx])
        {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:thousand_island])
        true = Node.connect(node)

        on_exit(fn ->
          try do
            :peer.stop(peer)
          catch
            :exit, _ -> :ok
          end
        end)

        {:ok, peer: peer, peer_node: node}

      {:error, reason} ->
        {:ok, skip: reason}
    end
  end

  defp ensure_distributed do
    if Node.alive?() do
      :ok
    else
      _ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

      case :net_kernel.start([:"mqttx_test_#{System.unique_integer([:positive])}", :shortnames]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    e -> {:error, e}
  end

  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end

  # A client whose events reach the test process tagged
  defp connect(port, client_id, tag, opts) do
    test = self()

    relay =
      spawn_link(fn ->
        Stream.repeatedly(fn -> receive(do: (msg -> send(test, {tag, msg}))) end)
        |> Stream.run()
      end)

    {:ok, client} =
      MqttX.Client.connect(
        Keyword.merge(
          [
            host: "127.0.0.1",
            port: port,
            client_id: client_id,
            protocol_version: 5,
            await_connect: true,
            handler: ForwardingHandler,
            handler_state: %{pid: relay}
          ],
          opts
        )
      )

    client
  end

  defp wait_until(fun, tries \\ 250) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  defp members_on_peer(ctx, name), do: :peer.call(ctx.peer, Cluster, :members, [name])

  defp split(ctx) do
    :erlang.set_cookie(ctx.peer_node, :"mqttx_split_#{System.unique_integer([:positive])}")
    Node.disconnect(ctx.peer_node)
  end

  defp heal(ctx) do
    :erlang.set_cookie(ctx.peer_node, :erlang.get_cookie())
    true = Node.connect(ctx.peer_node)
  end

  test "after a split heals, a client keeps the session it began last and retained messages converge",
       ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_split_#{System.unique_integer([:positive])}"

    local_port = free_port()
    {:ok, server, owner} = ClusterBroker.start_listener(name, local_port)

    on_exit(fn ->
      ThousandIsland.stop(server)
      Process.exit(owner, :kill)
    end)

    remote_port = free_port()
    {:ok, _, _} = :peer.call(ctx.peer, ClusterBroker, :start_listener, [name, remote_port])
    wait_until(fn -> length(Cluster.members(name)) == 2 end)

    # Connected here before the split
    here = connect(local_port, "split-c", :here, @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(here, "split/#", qos: 1)
    pub_here = connect(local_port, "split-pub-here", :pub_here, [])

    split(ctx)
    wait_until(fn -> length(Cluster.members(name)) == 1 end)
    wait_until(fn -> length(members_on_peer(ctx, name)) == 1 end)

    # Each side takes a retained write, the peer's last, and the same client
    :ok = MqttX.Client.publish(pub_here, "split/r", "here", qos: 1, retain: true)
    Process.sleep(50)
    pub_there = connect(remote_port, "split-pub-there", :pub_there, [])
    :ok = MqttX.Client.publish(pub_there, "split/r", "there", qos: 1, retain: true)

    there = connect(remote_port, "split-c", :there, @persistent)
    assert_receive {:there, {:mqtt_event, :connected, %{session_present: false}}}, 3_000
    {:ok, [1]} = MqttX.Client.subscribe(there, "split/#", qos: 1)
    assert_receive {:there, {:mqtt_event, :message, {["split", "r"], "there", _}}}, 3_000

    heal(ctx)
    wait_until(fn -> length(Cluster.members(name)) == 2 end)

    # The copy begun first, here, is taken over and dropped
    assert_receive {:here, {:mqtt_event, :disconnected, {:server_disconnect, 0x8E, _}}}, 5_000
    GenServer.stop(here)

    [member] = Enum.filter(Cluster.members(name), &(node(&1) == node()))
    sessions = :sys.get_state(member).ctx.sessions
    wait_until(fn -> SessionStore.get(sessions, "split-c") == nil end)

    # Both nodes serve the later retained message
    local_table = :"mqttx_retained_#{local_port}"
    remote_table = :"mqttx_retained_#{remote_port}"

    wait_until(fn ->
      match?([{_, "there", _, _, _}], RetainedStore.match(local_table, "split/r")) and
        match?(
          [{_, "there", _, _, _}],
          :peer.call(ctx.peer, RetainedStore, :match, [remote_table, "split/r"])
        )
    end)

    # The surviving session is reached from either node, once
    wait_until(fn -> length(members_on_peer(ctx, name)) == 2 end)
    :ok = MqttX.Client.publish(pub_here, "split/after", "healed", qos: 1)
    assert_receive {:there, {:mqtt_event, :message, {["split", "after"], "healed", _}}}, 3_000
    refute_receive {:there, {:mqtt_event, :message, {["split", "after"], _, _}}}, 300

    Enum.each([there, pub_here, pub_there], &MqttX.Client.disconnect/1)
  end
end
