defmodule MqttX.ClusterTest do
  @moduledoc """
  Two real BEAM nodes (the test node and a `:peer`), each running a listener
  with the same `:name`: delivery reaches subscribers on both nodes, a
  CONNECT on one node takes the client, its timers and its session from the
  other, retained messages are replicated, and a shared subscription with
  members on both nodes delivers each message once.

  Needs Erlang distribution: the tests fail with "distribution unavailable"
  when the test node cannot be made distributed (no epmd).
  """
  use ExUnit.Case, async: false

  @moduletag :cluster
  @moduletag timeout: 60_000

  @persistent [clean_session: false, connect_properties: %{session_expiry_interval: 300}]

  alias MqttX.Packet.Codec
  alias MqttX.Server.Cluster
  alias MqttX.Server.Delivery
  alias MqttX.Server.RetainedStore
  alias MqttX.Server.SessionStore
  alias MqttX.Test.ClusterBroker
  alias MqttX.Test.ForwardingHandler

  setup_all do
    case ensure_distributed() do
      :ok ->
        # Not linked: the setup_all process exits before on_exit runs, and a
        # linked peer would go with it — before its coverage counts are fetched
        {:ok, peer, node} =
          :peer.start(%{name: :"mqttx_peer_#{System.unique_integer([:positive])}"})

        :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
        :ok = :erpc.call(node, Logger, :configure, [[level: :warning]])
        MqttX.Test.Cover.start(node)
        {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:mqttx])
        {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:thousand_island])

        on_exit(fn ->
          MqttX.Test.Cover.flush(node)

          try do
            :peer.stop(peer)
          catch
            :exit, _ -> :ok
          end
        end)

        {:ok, peer_node: node}

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

  defp connect(port, client_id, opts \\ []) do
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
            handler_state: %{pid: self()}
          ],
          opts
        )
      )

    client
  end

  defp start_pair(ctx, name) do
    local_port = start_local(name)
    remote_port = start_remote(ctx, name)
    {local_port, remote_port}
  end

  defp start_local(name) do
    port = free_port()
    {:ok, server, owner} = ClusterBroker.start_listener(name, port)

    on_exit(fn ->
      ThousandIsland.stop(server)
      Process.exit(owner, :kill)
    end)

    port
  end

  defp start_remote(ctx, name) do
    port = free_port()

    {:ok, server, owner} =
      :erpc.call(ctx.peer_node, ClusterBroker, :start_listener, [name, port])

    on_exit(fn ->
      :erpc.call(ctx.peer_node, ThousandIsland, :stop, [server])
      :erpc.call(ctx.peer_node, Process, :exit, [owner, :kill])
    end)

    # Both members are in the group before anyone delivers
    wait_until(fn -> length(MqttX.Server.Cluster.members(name)) == 2 end)
    port
  end

  # A client whose events reach the test process tagged, so two clients'
  # messages can be told apart
  defp tagged_connect(port, client_id, tag, opts \\ []) do
    test = self()

    relay =
      spawn_link(fn ->
        Stream.repeatedly(fn -> receive(do: (msg -> send(test, {tag, msg}))) end)
        |> Stream.run()
      end)

    connect(port, client_id, Keyword.put(opts, :handler_state, %{pid: relay}))
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "deliver on one node reaches a subscriber connected to the other", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_deliver_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    # Subscriber on the peer node, publisher on this one
    sub = connect(remote_port, "cl-sub")
    {:ok, [1]} = MqttX.Client.subscribe(sub, "cl/#", qos: 1)
    pub = connect(local_port, "cl-pub")

    :ok = MqttX.Client.publish(pub, "cl/1", "across nodes", qos: 1)
    assert_receive {:mqtt_event, :message, {["cl", "1"], "across nodes", _}}, 3_000

    # And by listener name from any process on this node
    assert {:ok, 0} = MqttX.Server.deliver(name, "cl/2", "by name", %{qos: 1})
    assert_receive {:mqtt_event, :message, {["cl", "2"], "by name", _}}, 3_000

    # A subscriber on the publishing node still gets it exactly once
    local_sub = connect(local_port, "cl-local-sub")
    {:ok, [0]} = MqttX.Client.subscribe(local_sub, "local/#", qos: 0)
    :ok = MqttX.Client.publish(pub, "local/x", "here", qos: 0)
    assert_receive {:mqtt_event, :message, {["local", "x"], "here", _}}, 3_000
    refute_receive {:mqtt_event, :message, {["local", "x"], _, _}}, 300

    Enum.each([sub, pub, local_sub], &MqttX.Client.disconnect/1)
  end

  test "a persistent session away on the other node gets the message queued there", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_queue_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    sub = connect(remote_port, "cl-away", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(sub, "away/#", qos: 1)
    :ok = MqttX.Client.disconnect(sub)

    # Wait until the peer no longer counts the client as connected
    key = {:"mqttx_retained_#{remote_port}", "cl-away"}

    wait_until(fn ->
      :erpc.call(ctx.peer_node, Registry, :lookup, [MqttX.Server.ConnectionRegistry, key]) == []
    end)

    assert {:ok, 0} = MqttX.Server.deliver(name, "away/1", "queued remotely", %{qos: 1})

    sub = connect(remote_port, "cl-away", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000
    assert_receive {:mqtt_event, :message, {["away", "1"], "queued remotely", _}}, 3_000
    MqttX.Client.disconnect(sub)
    _ = local_port
  end

  test "a CONNECT on one node cancels the other node's pending Will Delay", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_will_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    watcher = connect(local_port, "cl-watcher")
    {:ok, [0]} = MqttX.Client.subscribe(watcher, "will/#", qos: 0)

    # A client with a delayed Will connects on the peer and drops abruptly
    will = [
      clean_session: false,
      connect_properties: %{session_expiry_interval: 60},
      will_topic: "will/dev",
      will_payload: "gone",
      will_properties: %{will_delay_interval: 2}
    ]

    dev = connect(remote_port, "cl-dev", will)
    Process.unlink(dev)
    Process.exit(dev, :kill)

    # It comes back on THIS node within the delay: the peer's Will must not fire
    Process.sleep(300)
    dev = connect(local_port, "cl-dev", clean_session: false)
    refute_receive {:mqtt_event, :message, {["will", "dev"], _, _}}, 3_000

    Enum.each([watcher, dev], &MqttX.Client.disconnect/1)
  end

  # Disconnect and wait until the node no longer counts the client connected
  defp disconnect_on(node, port, client, client_id) do
    :ok = MqttX.Client.disconnect(client)
    key = {:"mqttx_retained_#{port}", client_id}

    wait_until(fn ->
      :erpc.call(node, Registry, :lookup, [MqttX.Server.ConnectionRegistry, key]) == []
    end)
  end

  test "a persistent session moves to the node its client reconnects to", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_move_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    # Subscribed on the peer, away, with a message queued there
    sub = connect(remote_port, "cl-mover", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(sub, "move/#", qos: 1)
    disconnect_on(ctx.peer_node, remote_port, sub, "cl-mover")
    assert {:ok, 0} = MqttX.Server.deliver(name, "move/1", "while away", %{qos: 1})

    # Back on THIS node: the session, its subscription and its queue came along
    sub = connect(local_port, "cl-mover", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000
    assert_receive {:mqtt_event, :message, {["move", "1"], "while away", _}}, 3_000

    # Delivered once from either node, now that only this node holds it
    {:ok, 1} = MqttX.Server.deliver(name, "move/2", "here now", %{qos: 1})
    assert_receive {:mqtt_event, :message, {["move", "2"], "here now", _}}, 3_000

    {:ok, _} =
      :erpc.call(ctx.peer_node, MqttX.Server, :deliver, [name, "move/3", "from peer", %{qos: 1}])

    assert_receive {:mqtt_event, :message, {["move", "3"], "from peer", _}}, 3_000
    refute_receive {:mqtt_event, :message, _}, 300

    MqttX.Client.disconnect(sub)
  end

  test "messages published while a session moves arrive once each, in order", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_moving_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    sub = connect(remote_port, "cl-moving", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(sub, "moving/#", qos: 1)
    disconnect_on(ctx.peer_node, remote_port, sub, "cl-moving")

    # Both nodes keep publishing while the client moves from the peer to this
    # node: whatever the hand-over overlaps, each message arrives exactly once
    {:ok, here} = ClusterBroker.publish_loop(name, "moving/l", "l", 10, self())

    {:ok, there} =
      :erpc.call(ctx.peer_node, ClusterBroker, :publish_loop, [name, "moving/r", "r", 10, self()])

    Process.sleep(20)
    sub = connect(local_port, "cl-moving", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000
    Process.sleep(50)
    Enum.each([here, there], &send(&1, :stop))
    assert_receive {:published, "l", local_count}, 5_000
    assert_receive {:published, "r", remote_count}, 5_000
    counts = %{"l" => local_count, "r" => remote_count}

    received =
      for _ <- 1..(local_count + remote_count) do
        receive do
          {:mqtt_event, :message, {["moving", _], payload, _}} -> payload
        after
          10_000 -> flunk("a message published during the move never arrived")
        end
      end

    refute_receive {:mqtt_event, :message, {["moving", _], _, _}}, 500
    expected = for {p, n} <- counts, i <- 1..n, do: "#{p}-#{i}"
    assert Enum.sort(received) == Enum.sort(expected)

    # And each publisher's in the order it published (§4.6)
    for {prefix, n} <- counts do
      sent = for i <- 1..n, do: "#{prefix}-#{i}"
      assert Enum.filter(received, &String.starts_with?(&1, prefix <> "-")) == sent
    end

    MqttX.Client.disconnect(sub)
  end

  test "the node a session left forwards what reaches it late, and a copy arriving both ways counts once",
       ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_forward_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    sub = connect(remote_port, "cl-forward", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(sub, "fwd/#", qos: 1)
    disconnect_on(ctx.peer_node, remote_port, sub, "cl-forward")
    sub = connect(local_port, "cl-forward", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000

    [here] = Enum.filter(Cluster.members(name), &(node(&1) == node()))
    [there] = Enum.filter(Cluster.members(name), &(node(&1) == ctx.peer_node))
    local_ctx = :sys.get_state(here).ctx
    peer_ctx = :erpc.call(ctx.peer_node, :sys, :get_state, [there]).ctx

    # A message that reaches the old node only now, after the session left
    # it (this node fanned it out before it had the session)
    late = make_ref()

    :erpc.call(ctx.peer_node, Delivery, :deliver_local, [
      peer_ctx,
      late,
      "fwd/1",
      "late",
      %{qos: 1}
    ])

    assert_receive {:mqtt_event, :message, {["fwd", "1"], "late", _}}, 3_000

    # The same message fanned out here too: already delivered
    {:ok, _} = Delivery.deliver_local(local_ctx, late, "fwd/1", "late", %{qos: 1})

    # And the other way round: here first, then forwarded from there
    both = make_ref()
    {:ok, 1} = Delivery.deliver_local(local_ctx, both, "fwd/2", "both", %{qos: 1})

    :erpc.call(ctx.peer_node, Delivery, :deliver_local, [
      peer_ctx,
      both,
      "fwd/2",
      "both",
      %{qos: 1}
    ])

    assert_receive {:mqtt_event, :message, {["fwd", "2"], "both", _}}, 3_000
    refute_receive {:mqtt_event, :message, _}, 500

    MqttX.Client.disconnect(sub)
  end

  test "a client back on the node its session just left gets the session back", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_bounce_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    sub = connect(remote_port, "cl-bounce", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(sub, "bounce/#", qos: 1)
    disconnect_on(ctx.peer_node, remote_port, sub, "cl-bounce")

    # To this node, away again, and back to the peer while the peer still
    # forwards for the first move
    sub = connect(local_port, "cl-bounce", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000
    disconnect_on(node(), local_port, sub, "cl-bounce")
    {:ok, 1} = MqttX.Server.deliver(name, "bounce/1", "while away", %{qos: 1})

    sub = connect(remote_port, "cl-bounce", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000
    assert_receive {:mqtt_event, :message, {["bounce", "1"], "while away", _}}, 3_000

    {:ok, _} = MqttX.Server.deliver(name, "bounce/2", "from here", %{qos: 1})

    {:ok, _} =
      :erpc.call(ctx.peer_node, MqttX.Server, :deliver, [
        name,
        "bounce/3",
        "from there",
        %{qos: 1}
      ])

    assert_receive {:mqtt_event, :message, {["bounce", "2"], "from here", _}}, 3_000
    assert_receive {:mqtt_event, :message, {["bounce", "3"], "from there", _}}, 3_000
    refute_receive {:mqtt_event, :message, _}, 500

    MqttX.Client.disconnect(sub)
  end

  test "a CONNECT on one node takes over the client's connection on the other", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_takeover_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    first = tagged_connect(remote_port, "cl-twice", :first, @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(first, "twice/#", qos: 1)
    Process.unlink(first)

    second = tagged_connect(local_port, "cl-twice", :second, @persistent)

    assert_receive {:first, {:mqtt_event, :disconnected, {:server_disconnect, 0x8E, _}}}, 3_000
    # (it would reconnect and take the session back)
    Process.exit(first, :kill)
    assert_receive {:second, {:mqtt_event, :connected, %{session_present: true}}}, 3_000

    # The subscription came along with the session
    {:ok, 1} = MqttX.Server.deliver(name, "twice/1", "taken over", %{qos: 1})
    assert_receive {:second, {:mqtt_event, :message, {["twice", "1"], "taken over", _}}}, 3_000

    MqttX.Client.disconnect(second)
  end

  test "Clean Start 1 on one node discards the session held on the other", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_clean_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    sub = connect(remote_port, "cl-clean", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(sub, "clean/#", qos: 1)
    disconnect_on(ctx.peer_node, remote_port, sub, "cl-clean")

    fresh = connect(local_port, "cl-clean", clean_session: true)
    assert_receive {:mqtt_event, :connected, %{session_present: false}}, 3_000

    # No node has the subscription any more
    assert {:ok, 0} = MqttX.Server.deliver(name, "clean/1", "nobody", %{qos: 1})

    assert {:ok, 0} =
             :erpc.call(ctx.peer_node, MqttX.Server, :deliver, [
               name,
               "clean/2",
               "nobody",
               %{qos: 1}
             ])

    refute_receive {:mqtt_event, :message, _}, 300
    MqttX.Client.disconnect(fresh)
  end

  test "retained messages are replicated, and a joining node gets the others'", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_retained_#{System.unique_integer([:positive])}"

    # Retained before the peer's listener exists
    local_port = start_local(name)
    pub = connect(local_port, "cl-ret-pub")
    :ok = MqttX.Client.publish(pub, "ret/early", "before join", qos: 1, retain: true)
    Process.sleep(100)

    remote_port = start_remote(ctx, name)
    :ok = MqttX.Client.publish(pub, "ret/late", "after join", qos: 1, retain: true)

    # The peer serves both to a new subscriber
    wait_until(fn ->
      rows = :erpc.call(ctx.peer_node, :ets, :tab2list, [:"mqttx_retained_#{remote_port}"])
      length(rows) == 2
    end)

    sub = connect(remote_port, "cl-ret-sub")
    {:ok, [1]} = MqttX.Client.subscribe(sub, "ret/#", qos: 1)
    assert_receive {:mqtt_event, :message, {["ret", "early"], "before join", _}}, 3_000
    assert_receive {:mqtt_event, :message, {["ret", "late"], "after join", _}}, 3_000

    # Clearing on one node clears everywhere
    [before_clear] = :ets.lookup(:"mqttx_retained_#{local_port}", ["ret", "early"])
    :ok = MqttX.Client.publish(pub, "ret/early", "", qos: 1, retain: true)
    remote_table = :"mqttx_retained_#{remote_port}"

    wait_until(fn ->
      :erpc.call(ctx.peer_node, RetainedStore, :match, [remote_table, "ret/#"]) |> length() == 1
    end)

    # The message as it was before the clear, from a node that missed the
    # clear while cut off, does not come back: not live, not on rejoin
    :erpc.call(ctx.peer_node, RetainedStore, :apply_replica, [remote_table, before_clear, nil])
    [peer_member] = Enum.filter(Cluster.members(name), &(node(&1) == ctx.peer_node))
    send(peer_member, {:sync, :"cut-off@host", [before_clear], []})
    Process.sleep(100)

    assert :erpc.call(ctx.peer_node, RetainedStore, :match, [remote_table, "ret/#"]) |> length() ==
             1

    Enum.each([pub, sub], &MqttX.Client.disconnect/1)
  end

  test "a shared subscription with members on both nodes delivers each message once", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_shared_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    here = tagged_connect(local_port, "cl-sh-here", :here)
    there = tagged_connect(remote_port, "cl-sh-there", :there)
    {:ok, [1]} = MqttX.Client.subscribe(here, "$share/g/sh/#", qos: 1)
    {:ok, [1]} = MqttX.Client.subscribe(there, "$share/g/sh/#", qos: 1)

    # Each node knows the other's member
    wait_until(fn -> :ets.info(:"mqttx_#{local_port}_remote", :size) == 1 end)

    wait_until(fn ->
      :erpc.call(ctx.peer_node, :ets, :info, [:"mqttx_#{remote_port}_remote", :size]) == 1
    end)

    pub = connect(local_port, "cl-sh-pub")
    for i <- 1..20, do: :ok = MqttX.Client.publish(pub, "sh/#{i}", "m#{i}", qos: 1)

    received =
      for _ <- 1..20 do
        receive do
          {tag, {:mqtt_event, :message, {["sh", _], payload, _}}} -> {tag, payload}
        after
          3_000 -> flunk("a shared message never arrived")
        end
      end

    refute_receive {_, {:mqtt_event, :message, {["sh", _], _, _}}}, 300

    assert received |> Enum.map(&elem(&1, 1)) |> Enum.sort() ==
             Enum.sort(for i <- 1..20, do: "m#{i}")

    tags = received |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()
    assert tags[:here] > 0 and tags[:there] > 0

    Enum.each([here, there, pub], &MqttX.Client.disconnect/1)
  end

  test "a shared message goes to a member that takes it, not one that is offline or gone", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_shared_away_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    # A member there with a session but no connection, and one here online
    away = connect(remote_port, "cl-sha-away", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(away, "$share/g/sha/#", qos: 1)
    disconnect_on(ctx.peer_node, remote_port, away, "cl-sha-away")

    here = tagged_connect(local_port, "cl-sha-here", :here)
    {:ok, [1]} = MqttX.Client.subscribe(here, "$share/g/sha/#", qos: 1)
    wait_until(fn -> :ets.info(:"mqttx_#{local_port}_remote", :size) == 1 end)

    # And one this node believes is there, whose session is not
    [member] = Enum.filter(Cluster.members(name), &(node(&1) == node()))
    sessions = :sys.get_state(member).ctx.sessions

    :ok =
      SessionStore.put_remote_shared(
        sessions,
        ctx.peer_node,
        ["sha", :multi_level],
        "g",
        "cl-sha-ghost",
        %{qos: 1}
      )

    for i <- 1..12, do: {:ok, _} = MqttX.Server.deliver(name, "sha/#{i}", "m#{i}", %{qos: 1})

    received =
      for _ <- 1..12 do
        receive do
          {:here, {:mqtt_event, :message, {["sha", _], payload, _}}} -> payload
        after
          3_000 -> flunk("a shared message never arrived")
        end
      end

    assert Enum.sort(received) == Enum.sort(for i <- 1..12, do: "m#{i}")

    # With no connected member left, the offline one gets it queued
    MqttX.Client.disconnect(here)

    wait_until(fn ->
      Registry.lookup(
        MqttX.Server.ConnectionRegistry,
        {:"mqttx_retained_#{local_port}", "cl-sha-here"}
      ) == []
    end)

    {:ok, _} = MqttX.Server.deliver(name, "sha/last", "last", %{qos: 1})

    away = connect(remote_port, "cl-sha-away", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000
    assert_receive {:mqtt_event, :message, {["sha", "last"], "last", _}}, 3_000
    refute_receive {:mqtt_event, :message, {["sha", _], _, _}}, 300
    MqttX.Client.disconnect(away)
  end

  test "a shared message sent to a node whose member leaves before answering goes to another member",
       ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_shared_gone_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    here = tagged_connect(local_port, "cl-shg-here", :here)
    there = tagged_connect(remote_port, "cl-shg-there", :there)
    {:ok, [1]} = MqttX.Client.subscribe(here, "$share/g/shg/#", qos: 1)
    {:ok, [1]} = MqttX.Client.subscribe(there, "$share/g/shg/#", qos: 1)
    wait_until(fn -> :ets.info(:"mqttx_#{local_port}_remote", :size) == 1 end)

    # The member there takes what it is sent but never answers, then goes
    [peer_member] = Enum.filter(Cluster.members(name), &(node(&1) == ctx.peer_node))
    :ok = :erpc.call(ctx.peer_node, :sys, :suspend, [peer_member])

    for i <- 1..10, do: {:ok, _} = MqttX.Server.deliver(name, "shg/#{i}", "m#{i}", %{qos: 1})
    Process.exit(peer_member, :kill)

    received =
      for _ <- 1..10 do
        receive do
          {:here, {:mqtt_event, :message, {["shg", _], payload, _}}} -> payload
        after
          3_000 -> flunk("a shared message never arrived")
        end
      end

    assert Enum.sort(received) == Enum.sort(for i <- 1..10, do: "m#{i}")
    refute_receive {_, {:mqtt_event, :message, {["shg", _], _, _}}}, 300

    Enum.each([here, there], &MqttX.Client.disconnect/1)
  end

  test "what the new node matches for a session that just arrived waits behind what the old node forwards",
       ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_fence_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    sub = connect(remote_port, "cl-fence", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(sub, "fen/#", qos: 1)
    disconnect_on(ctx.peer_node, remote_port, sub, "cl-fence")

    # The old node's relay 0 holds the fence up until it is resumed
    peer_relay = :erpc.call(ctx.peer_node, Cluster, :relays, [name]) |> elem(0)
    :ok = :erpc.call(ctx.peer_node, :sys, :suspend, [peer_relay])

    sub = connect(local_port, "cl-fence", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000

    [member] = Enum.filter(Cluster.members(name), &(node(&1) == node()))
    local_ctx = :sys.get_state(member).ctx

    # Matched here: held
    {:ok, 1} = Delivery.deliver_local(local_ctx, make_ref(), "fen/2", "matched here", %{qos: 1})
    refute_receive {:mqtt_event, :message, _}, 300

    # Forwarded from the old node: goes ahead
    send(
      member,
      {:deliver_to, "cl-fence",
       {make_ref(), "fen/1", "forwarded", %{qos: 1, retain: false, properties: %{}}, 0}}
    )

    assert_receive {:mqtt_event, :message, {["fen", "1"], "forwarded", _}}, 3_000
    refute_receive {:mqtt_event, :message, _}, 300

    :ok = :erpc.call(ctx.peer_node, :sys, :resume, [peer_relay])
    assert_receive {:mqtt_event, :message, {["fen", "2"], "matched here", _}}, 3_000

    # And with the fence down, straight through
    {:ok, 1} = Delivery.deliver_local(local_ctx, make_ref(), "fen/3", "after", %{qos: 1})
    assert_receive {:mqtt_event, :message, {["fen", "3"], "after", _}}, 3_000

    MqttX.Client.disconnect(sub)
  end

  test "a node is sent only the messages its subscriptions match", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_routes_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    [member] = Enum.filter(Cluster.members(name), &(node(&1) == node()))
    [peer_member] = Enum.filter(Cluster.members(name), &(node(&1) == ctx.peer_node))
    sessions = :sys.get_state(member).ctx.sessions

    sub = connect(remote_port, "cl-routes", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(sub, "rt/a/+", qos: 1)

    wait_until(fn ->
      SessionStore.route_nodes(sessions, "rt/a/1") == MapSet.new([ctx.peer_node])
    end)

    assert SessionStore.route_nodes(sessions, "rt/b/1") == MapSet.new()

    queued = fn ->
      :erpc.call(ctx.peer_node, Process, :info, [peer_member, :message_queue_len])
    end

    :ok = :erpc.call(ctx.peer_node, :sys, :suspend, [peer_member])

    for i <- 1..5, do: {:ok, 0} = MqttX.Server.deliver(name, "rt/b/#{i}", "x", %{qos: 1})
    {:ok, 0} = MqttX.Server.deliver(name, "rt/a/1", "for the peer", %{qos: 1})
    wait_until(fn -> queued.() == {:message_queue_len, 1} end)
    Process.sleep(100)
    assert queued.() == {:message_queue_len, 1}

    :ok = :erpc.call(ctx.peer_node, :sys, :resume, [peer_member])
    assert_receive {:mqtt_event, :message, {["rt", "a", "1"], "for the peer", _}}, 3_000

    # Gone with the last subscription to it
    :ok = MqttX.Client.unsubscribe(sub, "rt/a/+")
    wait_until(fn -> SessionStore.route_nodes(sessions, "rt/a/1") == MapSet.new() end)

    MqttX.Client.disconnect(sub)
    _ = local_port
  end

  test "a joining node gets a retained table larger than one sync message", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_retained_big_#{System.unique_integer([:positive])}"

    local_port = start_local(name)
    table = :"mqttx_retained_#{local_port}"

    for i <- 1..1_201,
        do: RetainedStore.write(table, "big/#{i}", "v#{i}", 0, nil, nil)

    remote_port = start_remote(ctx, name)
    remote_table = :"mqttx_retained_#{remote_port}"

    wait_until(fn ->
      :erpc.call(ctx.peer_node, :ets, :info, [remote_table, :size]) == 1_201
    end)

    assert [{_, "v1201", _, _, _, _}] =
             :erpc.call(ctx.peer_node, RetainedStore, :match, [remote_table, "big/1201"])
  end

  test "with the replicated backend, a session outlives the node that held it", ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_durable_#{System.unique_integer([:positive])}"
    opts = [session_backend: MqttX.Server.SessionBackend.Replicated, session_flush_interval: 50]

    # A node of its own, to take down
    {:ok, peer, doomed} =
      :peer.start(%{name: :"mqttx_doomed_#{System.unique_integer([:positive])}"})

    :ok = :erpc.call(doomed, :code, :add_paths, [:code.get_path()])
    :ok = :erpc.call(doomed, Logger, :configure, [[level: :warning]])
    MqttX.Test.Cover.start(doomed)
    {:ok, _} = :erpc.call(doomed, Application, :ensure_all_started, [:mqttx])
    {:ok, _} = :erpc.call(doomed, Application, :ensure_all_started, [:thousand_island])

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    local_port = free_port()
    {:ok, server, owner} = ClusterBroker.start_listener(name, local_port, opts)

    on_exit(fn ->
      ThousandIsland.stop(server)
      Process.exit(owner, :kill)
    end)

    doomed_port = free_port()
    {:ok, _, _} = :erpc.call(doomed, ClusterBroker, :start_listener, [name, doomed_port, opts])
    wait_until(fn -> length(Cluster.members(name)) == 2 end)

    sub = connect(doomed_port, "cl-durable", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(sub, "dur/#", qos: 1)
    disconnect_on(doomed, doomed_port, sub, "cl-durable")
    {:ok, 0} = MqttX.Server.deliver(name, "dur/1", "kept", %{qos: 1})

    # This node has the session as the doomed one last saved it
    [member] = Enum.filter(Cluster.members(name), &(node(&1) == node()))
    sessions = :sys.get_state(member).ctx.sessions

    wait_until(fn ->
      match?(%{queue: [_]}, SessionStore.load(sessions, "cl-durable"))
    end)

    MqttX.Test.Cover.flush(doomed)
    :peer.stop(peer)
    wait_until(fn -> length(Cluster.members(name)) == 1 end)

    sub = connect(local_port, "cl-durable", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000
    assert_receive {:mqtt_event, :message, {["dur", "1"], "kept", _}}, 3_000

    # Still subscribed
    {:ok, _} = MqttX.Server.deliver(name, "dur/2", "after", %{qos: 1})
    assert_receive {:mqtt_event, :message, {["dur", "2"], "after", _}}, 3_000
    MqttX.Client.disconnect(sub)
  end

  # A raw v5 CONNECT with a persistent session, sent and not waited for
  defp raw_connect(port, client_id) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

    {:ok, connect} =
      Codec.encode(5, %{
        type: :connect,
        protocol_version: 5,
        client_id: client_id,
        username: nil,
        password: nil,
        will: nil,
        clean_session: false,
        keep_alive: 60,
        properties: %{session_expiry_interval: 300}
      })

    :ok = :gen_tcp.send(socket, connect)
    socket
  end

  defp member_on(name, node) do
    [member] = Enum.filter(Cluster.members(name), &(node(&1) == node))
    member
  end

  defp registered?(node, port, client_id) do
    key = {:"mqttx_retained_#{port}", client_id}
    :erpc.call(node, Registry, :lookup, [MqttX.Server.ConnectionRegistry, key]) != []
  end

  test "a session claimed by a connection that dies before the export arrives stays where it was",
       ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_orphan_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    owner = connect(local_port, "cl-orphan", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(owner, "orphan/#", qos: 1)
    disconnect_on(node(), local_port, owner, "cl-orphan")

    # The claim from the peer waits while this node's member is suspended;
    # meanwhile the connection that made it dies
    member = member_on(name, node())
    :sys.suspend(member)
    socket = raw_connect(remote_port, "cl-orphan")
    # Registered once the peek before handle_connect has waited out the
    # suspended member (5 s)
    wait_until(fn -> registered?(ctx.peer_node, remote_port, "cl-orphan") end, 400)
    key = {:"mqttx_retained_#{remote_port}", "cl-orphan"}

    [{pid, _}] =
      :erpc.call(ctx.peer_node, Registry, :lookup, [MqttX.Server.ConnectionRegistry, key])

    :erpc.call(ctx.peer_node, Process, :exit, [pid, :kill])
    :gen_tcp.close(socket)
    :sys.resume(member)

    # Served, exported to no one, and after the forwarding window kept here
    sessions = :sys.get_state(member).ctx.sessions
    Process.sleep(6_500)
    assert SessionStore.exists?(sessions, "cl-orphan")
    assert [%{filter: "orphan/#"}] = SessionStore.subscriptions(sessions, "cl-orphan")

    # Resumable from either node
    back = connect(remote_port, "cl-orphan", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000
    MqttX.Client.disconnect(back)
  end

  test "two CONNECTs for one client id at once, one per node: one keeps the session, the other ends before CONNACK",
       ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_twin_#{System.unique_integer([:positive])}"
    {local_port, remote_port} = start_pair(ctx, name)

    local_member = member_on(name, node())
    peer_member = member_on(name, ctx.peer_node)
    :sys.suspend(local_member)
    :sys.suspend(peer_member)

    here = raw_connect(local_port, "cl-twin")
    there = raw_connect(remote_port, "cl-twin")
    # Registered once each peek has waited out the other node's suspended
    # member (5 s)
    wait_until(fn -> registered?(node(), local_port, "cl-twin") end, 400)
    wait_until(fn -> registered?(ctx.peer_node, remote_port, "cl-twin") end, 400)

    :sys.resume(local_member)
    :sys.resume(peer_member)

    results = for socket <- [here, there], do: :gen_tcp.recv(socket, 0, 8_000)

    # One CONNACK, one close with nothing sent — never both kicked
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :closed}, &1)) == 1
    [{:ok, connack}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:ok, {%{type: :connack, reason_code: 0}, <<>>}} = Codec.decode(5, connack)

    # The winner stays connected; the loser's node holds no session for the id
    Process.sleep(200)

    winners =
      for {node, port} <- [{node(), local_port}, {ctx.peer_node, remote_port}],
          registered?(node, port, "cl-twin"),
          do: node

    assert [winner] = winners
    loser = if winner == node(), do: ctx.peer_node, else: node()
    loser_sessions = :sys.get_state(member_on(name, loser)).ctx.sessions
    refute :erpc.call(loser, SessionStore, :exists?, [loser_sessions, "cl-twin"])

    Enum.each([here, there], &:gen_tcp.close/1)
  end

  test "with the replicated backend, a node starting again under its name gets its sessions back",
       ctx do
    if ctx[:skip], do: flunk("distribution unavailable: #{inspect(ctx.skip)}")
    name = :"cluster_reborn_#{System.unique_integer([:positive])}"
    opts = [session_backend: MqttX.Server.SessionBackend.Replicated, session_flush_interval: 50]
    node_name = :"mqttx_reborn_#{System.unique_integer([:positive])}"

    start_node = fn ->
      {:ok, peer, node} = :peer.start(%{name: node_name})
      :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
      :ok = :erpc.call(node, Logger, :configure, [[level: :warning]])
      MqttX.Test.Cover.start(node)
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:mqttx])
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:thousand_island])
      {peer, node}
    end

    stop_node = fn {peer, node} ->
      MqttX.Test.Cover.flush(node)

      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end

    local_port = free_port()
    {:ok, server, owner} = ClusterBroker.start_listener(name, local_port, opts)

    on_exit(fn ->
      ThousandIsland.stop(server)
      Process.exit(owner, :kill)
    end)

    {peer, node} = start_node.()
    peer_port = free_port()
    {:ok, _, _} = :erpc.call(node, ClusterBroker, :start_listener, [name, peer_port, opts])
    wait_until(fn -> length(Cluster.members(name)) == 2 end)

    sub = connect(peer_port, "cl-reborn", @persistent)
    {:ok, [1]} = MqttX.Client.subscribe(sub, "reborn/#", qos: 1)
    disconnect_on(node, peer_port, sub, "cl-reborn")

    # This node holds the record as the peer saved it
    sessions = :sys.get_state(member_on(name, node())).ctx.sessions
    wait_until(fn -> SessionStore.load(sessions, "cl-reborn") != nil end)

    stop_node.({peer, node})
    wait_until(fn -> length(Cluster.members(name)) == 1 end)

    # The same node again, fresh: its sessions reach it after its listener
    # started, and are restored then — subscriptions included, no client
    {peer, node} = start_node.()
    on_exit(fn -> stop_node.({peer, node}) end)
    {:ok, _, _} = :erpc.call(node, ClusterBroker, :start_listener, [name, peer_port, opts])
    wait_until(fn -> length(Cluster.members(name)) == 2 end)

    wait_until(fn ->
      peer_sessions = :sys.get_state(member_on(name, node)).ctx.sessions
      :erpc.call(node, SessionStore, :exists?, [peer_sessions, "cl-reborn"])
    end)

    {:ok, 0} = MqttX.Server.deliver(name, "reborn/1", "kept", %{qos: 1})
    sub = connect(peer_port, "cl-reborn", @persistent)
    assert_receive {:mqtt_event, :connected, %{session_present: true}}, 3_000
    assert_receive {:mqtt_event, :message, {["reborn", "1"], "kept", _}}, 3_000
    MqttX.Client.disconnect(sub)
  end
end
