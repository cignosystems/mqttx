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
      assert router.shared_groups["workers"].filter == ["jobs", :multi_level]
      assert length(router.shared_groups["workers"].members) == 1
    end

    test "multiple clients in same shared group" do
      router = Router.new()
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)
      router = Router.subscribe(router, "$share/workers/jobs/#", :client2, qos: 1)

      assert map_size(router.shared_groups) == 1
      assert length(router.shared_groups["workers"].members) == 2
    end

    test "same client can only join group once" do
      router = Router.new()
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)
      router = Router.subscribe(router, "$share/workers/jobs/#", :client1, qos: 1)

      assert length(router.shared_groups["workers"].members) == 1
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

      assert length(router.shared_groups["workers"].members) == 1
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

      assert length(router.shared_groups["workers"].members) == 1
    end
  end
end
