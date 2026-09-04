defmodule MqttX.Server.RouterTest do
  use ExUnit.Case, async: true

  alias MqttX.Server.Router

  describe "new/0" do
    test "creates empty router" do
      router = Router.new()
      assert Router.count(router) == 0
      assert Router.client_count(router) == 0
    end
  end

  describe "subscribe/4" do
    test "adds subscription" do
      router = Router.new()
      router = Router.subscribe(router, "test/topic", :client1, qos: 1)

      assert Router.count(router) == 1
      assert Router.client_count(router) == 1
    end

    test "adds multiple subscriptions for same client" do
      router = Router.new()
      router = Router.subscribe(router, "topic/a", :client1, qos: 0)
      router = Router.subscribe(router, "topic/b", :client1, qos: 1)

      assert Router.count(router) == 2
      assert Router.client_count(router) == 1
    end

    test "adds subscriptions for multiple clients" do
      router = Router.new()
      router = Router.subscribe(router, "topic", :client1)
      router = Router.subscribe(router, "topic", :client2)

      assert Router.count(router) == 2
      assert Router.client_count(router) == 2
    end

    test "a resubscribe replaces the options without inflating the count (§3.8.4)" do
      router = Router.new()
      router = Router.subscribe(router, "topic/a", :client1, qos: 0)
      router = Router.subscribe(router, "topic/a", :client1, qos: 2, no_local: true)

      assert Router.count(router) == 1
      assert [{:client1, %{qos: 2, no_local: true}}] = Router.match(router, "topic/a")

      # A single unsubscribe fully removes it
      router = Router.unsubscribe(router, "topic/a", :client1)
      assert Router.match(router, "topic/a") == []
      assert Router.count(router) == 0
      assert Router.client_count(router) == 0
    end

    test "a shared resubscribe replaces the member options in place" do
      router = Router.new()
      router = Router.subscribe(router, "$share/g/jobs/#", :client1, qos: 0)
      router = Router.subscribe(router, "$share/g/jobs/#", :client2, qos: 0)
      router = Router.subscribe(router, "$share/g/jobs/#", :client1, qos: 2)

      {matches, router} = Router.match_and_advance(router, "jobs/t")
      assert [{:client1, %{qos: 2}}] = matches

      # Round-robin order is preserved — client2 is next
      {matches, _router} = Router.match_and_advance(router, "jobs/t")
      assert [{:client2, %{qos: 0}}] = matches
    end
  end

  describe "subscription identifier merging" do
    test "identifiers of all matching subscriptions are merged into a list (§3.3.4)" do
      router = Router.new()
      router = Router.subscribe(router, "a/#", :client1, qos: 0, subscription_identifier: 1)
      router = Router.subscribe(router, "a/b", :client1, qos: 1, subscription_identifier: 9)

      assert [{:client1, opts}] = Router.match(router, "a/b")
      # The collapsed delivery keeps the maximum QoS
      assert opts.qos == 1
      assert Enum.sort(opts.subscription_identifier) == [1, 9]
    end

    test "subscriptions without identifiers add nothing" do
      router = Router.new()
      router = Router.subscribe(router, "a/#", :client1, qos: 0)
      router = Router.subscribe(router, "a/b", :client1, qos: 0, subscription_identifier: 5)

      assert [{:client1, opts}] = Router.match(router, "a/b")
      assert opts.subscription_identifier == [5]

      router2 = Router.new()
      router2 = Router.subscribe(router2, "b/#", :client1, qos: 0)
      assert [{:client1, opts2}] = Router.match(router2, "b/x")
      refute Map.has_key?(opts2, :subscription_identifier)
    end
  end

  describe "unsubscribe/3" do
    test "removes subscription" do
      router = Router.new()
      router = Router.subscribe(router, "test/topic", :client1)
      router = Router.unsubscribe(router, "test/topic", :client1)

      assert Router.count(router) == 0
    end

    test "removes only matching subscription" do
      router = Router.new()
      router = Router.subscribe(router, "topic/a", :client1)
      router = Router.subscribe(router, "topic/b", :client1)
      router = Router.unsubscribe(router, "topic/a", :client1)

      assert Router.count(router) == 1
    end
  end

  describe "unsubscribe_all/2" do
    test "removes all subscriptions for client" do
      router = Router.new()
      router = Router.subscribe(router, "topic/a", :client1)
      router = Router.subscribe(router, "topic/b", :client1)
      router = Router.subscribe(router, "topic/c", :client2)
      router = Router.unsubscribe_all(router, :client1)

      assert Router.count(router) == 1
      assert Router.client_count(router) == 1
    end
  end

  describe "match/2" do
    test "matches exact topic" do
      router = Router.new()
      router = Router.subscribe(router, "test/topic", :client1, qos: 1)

      matches = Router.match(router, "test/topic")
      assert length(matches) == 1
      assert {:client1, %{qos: 1}} in matches
    end

    test "does not match non-matching topic" do
      router = Router.new()
      router = Router.subscribe(router, "test/topic", :client1)

      assert Router.match(router, "other/topic") == []
    end

    test "matches single-level wildcard" do
      router = Router.new()
      router = Router.subscribe(router, "sensors/+/temp", :client1, qos: 1)

      matches = Router.match(router, "sensors/room1/temp")
      assert {:client1, %{qos: 1}} in matches

      matches = Router.match(router, "sensors/room2/temp")
      assert {:client1, %{qos: 1}} in matches

      # Should not match
      assert Router.match(router, "sensors/room1/humidity") == []
    end

    test "matches multi-level wildcard" do
      router = Router.new()
      router = Router.subscribe(router, "devices/#", :client1, qos: 0)

      assert [{:client1, _}] = Router.match(router, "devices")
      assert [{:client1, _}] = Router.match(router, "devices/a")
      assert [{:client1, _}] = Router.match(router, "devices/a/b/c")

      # Should not match
      assert Router.match(router, "other/topic") == []
    end

    test "returns unique clients" do
      router = Router.new()
      router = Router.subscribe(router, "topic/+", :client1)
      router = Router.subscribe(router, "topic/#", :client1)

      matches = Router.match(router, "topic/a")
      assert length(matches) == 1
    end

    test "matches multiple clients" do
      router = Router.new()
      router = Router.subscribe(router, "topic/#", :client1, qos: 0)
      router = Router.subscribe(router, "topic/+", :client2, qos: 1)

      matches = Router.match(router, "topic/a")
      assert length(matches) == 2
      clients = Enum.map(matches, fn {c, _} -> c end)
      assert :client1 in clients
      assert :client2 in clients
    end
  end

  describe "subscriptions_for/2" do
    test "returns subscriptions for client" do
      router = Router.new()
      router = Router.subscribe(router, "topic/a", :client1, qos: 0)
      router = Router.subscribe(router, "topic/b", :client1, qos: 1)

      subs = Router.subscriptions_for(router, :client1)
      assert length(subs) == 2
    end

    test "returns empty list for unknown client" do
      router = Router.new()
      assert Router.subscriptions_for(router, :unknown) == []
    end
  end

  describe "shared subscriptions" do
    test "subscribe to shared group" do
      router = Router.new()
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)

      assert map_size(router.shared_groups) == 1

      assert router.shared_groups[{"workers", ["jobs", :multi_level]}].filter == [
               "jobs",
               :multi_level
             ]

      assert length(router.shared_groups[{"workers", ["jobs", :multi_level]}].members) == 1
    end

    test "multiple clients in same shared group" do
      router = Router.new()
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)
      router = Router.subscribe(router, "$share/workers/jobs/#", :client2, qos: 1)

      assert map_size(router.shared_groups) == 1
      assert length(router.shared_groups[{"workers", ["jobs", :multi_level]}].members) == 2
    end

    test "same client can only join group once" do
      router = Router.new()
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)

      assert length(router.shared_groups[{"workers", ["jobs", :multi_level]}].members) == 1
    end

    test "one group name spans multiple filters (§4.8.2 share = {group, filter} pair)" do
      router = Router.new()
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)
      router = Router.subscribe(router, "$share/workers/alerts/#", :client2, qos: 1)

      # Both shares exist independently
      assert map_size(router.shared_groups) == 2

      # Each filter routes to its own subscriber
      assert [{:client1, _}] = Router.match(router, "jobs/task1")
      assert [{:client2, _}] = Router.match(router, "alerts/cpu")

      # Unsubscribing one filter leaves the other share intact
      router = Router.unsubscribe(router, "$share/workers/alerts/#", :client2)
      assert [{:client1, _}] = Router.match(router, "jobs/task1")
      assert Router.match(router, "alerts/cpu") == []
    end

    test "match shared subscription returns one client per group" do
      router = Router.new()
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)
      router = Router.subscribe(router, "$share/workers/jobs/#", :client2, qos: 1)

      matches = Router.match(router, "jobs/task1")
      assert length(matches) == 1
    end

    test "match_and_advance distributes round-robin" do
      router = Router.new()
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)
      router = Router.subscribe(router, "$share/workers/jobs/#", :client2, qos: 1)

      # First match
      {matches1, router} = Router.match_and_advance(router, "jobs/task1")
      assert length(matches1) == 1
      [{first_client, _}] = matches1

      # Second match should go to the other client
      {matches2, router} = Router.match_and_advance(router, "jobs/task2")
      assert length(matches2) == 1
      [{second_client, _}] = matches2

      assert first_client != second_client

      # Third match should cycle back
      {matches3, _router} = Router.match_and_advance(router, "jobs/task3")
      [{third_client, _}] = matches3
      assert third_client == first_client
    end

    test "regular and shared subscriptions can coexist" do
      router = Router.new()
      router = Router.subscribe(router, "jobs/#", :regular_client, qos: 0)
      router = Router.subscribe(router, "$share/workers/jobs/#", :shared1, qos: 1)
      router = Router.subscribe(router, "$share/workers/jobs/#", :shared2, qos: 1)

      matches = Router.match(router, "jobs/task1")
      # Regular client always gets it, plus one from shared group
      assert length(matches) == 2
      clients = Enum.map(matches, fn {c, _} -> c end)
      assert :regular_client in clients
    end

    test "unsubscribe from shared group" do
      router = Router.new()
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)
      router = Router.subscribe(router, "$share/workers/jobs/#", :client2, qos: 1)
      router = Router.unsubscribe(router, "$share/workers/jobs/#", :client1)

      assert length(router.shared_groups[{"workers", ["jobs", :multi_level]}].members) == 1
    end

    test "shared group removed when last member leaves" do
      router = Router.new()
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)
      router = Router.unsubscribe(router, "$share/workers/jobs/#", :client1)

      assert map_size(router.shared_groups) == 0
    end

    test "unsubscribe_all removes from shared groups" do
      router = Router.new()
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)
      router = Router.subscribe(router, "$share/workers/jobs/#", :client2, qos: 1)
      router = Router.unsubscribe_all(router, :client1)

      assert length(router.shared_groups[{"workers", ["jobs", :multi_level]}].members) == 1
    end
  end

  describe "no_local support" do
    test "match/3 with no_local excludes publisher from results" do
      router = Router.new()
      router = Router.subscribe(router, "topic/a", :client1, qos: 1, no_local: true)
      router = Router.subscribe(router, "topic/a", :client2, qos: 1)

      # When client1 is the publisher, it should not receive its own message
      matches = Router.match(router, "topic/a", :client1)
      clients = Enum.map(matches, fn {c, _} -> c end)
      refute :client1 in clients
      assert :client2 in clients
    end

    test "match/3 without no_local includes publisher in results" do
      router = Router.new()
      router = Router.subscribe(router, "topic/a", :client1, qos: 1)
      router = Router.subscribe(router, "topic/a", :client2, qos: 1)

      matches = Router.match(router, "topic/a", :client1)
      clients = Enum.map(matches, fn {c, _} -> c end)
      assert :client1 in clients
      assert :client2 in clients
    end

    test "match/2 without publisher does not filter no_local" do
      router = Router.new()
      router = Router.subscribe(router, "topic/a", :client1, qos: 1, no_local: true)

      matches = Router.match(router, "topic/a")
      assert length(matches) == 1
    end

    test "match_and_advance/3 with no_local excludes publisher" do
      router = Router.new()
      router = Router.subscribe(router, "topic/a", :client1, qos: 1, no_local: true)
      router = Router.subscribe(router, "topic/a", :client2, qos: 1)

      {matches, _router} = Router.match_and_advance(router, "topic/a", :client1)
      clients = Enum.map(matches, fn {c, _} -> c end)
      refute :client1 in clients
      assert :client2 in clients
    end

    test "no_local is per subscription: a non-no_local overlap still delivers (§3.8.3.1)" do
      router = Router.new()
      # The higher-QoS subscription is no_local; the exact one is not. The
      # client must still receive the message via the non-no_local
      # subscription — no_local must be filtered before per-client collapse.
      router = Router.subscribe(router, "a/#", :client1, qos: 1, no_local: true)
      router = Router.subscribe(router, "a/b", :client1, qos: 0)

      assert [{:client1, opts}] = Router.match(router, "a/b", :client1)
      assert opts.qos == 0

      {[{:client1, _}], _} = Router.match_and_advance(router, "a/b", :client1)

      # And when the client only has no_local subscriptions, it gets nothing
      router2 = Router.new()
      router2 = Router.subscribe(router2, "b/#", :client1, qos: 1, no_local: true)
      assert Router.match(router2, "b/x", :client1) == []
    end
  end

  describe "$-topic guard (§4.7.2)" do
    test "wildcard-first filters do not match $-prefixed topics" do
      router = Router.new()
      router = Router.subscribe(router, "#", :client1, qos: 0)
      router = Router.subscribe(router, "+/broker/uptime", :client2, qos: 0)

      assert Router.match(router, "$SYS/broker/uptime") == []
      assert [{:client1, _}] = Router.match(router, "regular/topic")
    end

    test "an explicit $-prefixed filter does match" do
      router = Router.new()
      router = Router.subscribe(router, "$SYS/#", :client1, qos: 0)

      assert [{:client1, _}] = Router.match(router, "$SYS/broker/uptime")
      # ...but only $SYS topics, and '#' below the literal level is fine
      assert Router.match(router, "other/topic") == []
    end
  end
end
