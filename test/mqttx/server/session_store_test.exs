defmodule MqttX.Server.SessionStoreTest do
  use ExUnit.Case, async: true

  alias MqttX.Server.SessionStore, as: Store

  setup do
    {:ok, store: Store.new()}
  end

  defp sub(store, client, filter, opts \\ []) do
    Store.subscribe(store, client, filter, Map.new(Keyword.put_new(opts, :qos, 0)))
  end

  defp clients(matches), do: matches |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  describe "subscription index" do
    test "literal, single-level and multi-level filters match like the Router", %{store: s} do
      sub(s, "lit", "a/b/c")
      sub(s, "plus", "a/+/c")
      sub(s, "hash", "a/#")
      sub(s, "root", "#")
      sub(s, "other", "x/y")
      sub(s, "deeper", "a/b/c/d")
      sub(s, "parent-hash", "a/b/c/#")

      assert clients(Store.match(s, "a/b/c")) == ["hash", "lit", "parent-hash", "plus", "root"]
      assert clients(Store.match(s, "a/b")) == ["hash", "root"]
      assert clients(Store.match(s, "a")) == ["hash", "root"]
      assert clients(Store.match(s, "x/y")) == ["other", "root"]
      assert clients(Store.match(s, "z")) == ["root"]
      assert Store.match(Store.new(), "a/b/c") == []
    end

    test "a + filter does not match across levels and # matches the parent level", %{store: s} do
      sub(s, "plus", "a/+")
      sub(s, "hash", "a/#")

      assert clients(Store.match(s, "a/b")) == ["hash", "plus"]
      assert clients(Store.match(s, "a/b/c")) == ["hash"]
      assert clients(Store.match(s, "a")) == ["hash"]
    end

    test "$-prefixed topics are only matched by filters naming that first level (§4.7.2)",
         %{store: s} do
      sub(s, "root", "#")
      sub(s, "plus", "+/broker")
      sub(s, "sys", "$SYS/#")
      sub(s, "sys-exact", "$SYS/broker")

      assert clients(Store.match(s, "$SYS/broker")) == ["sys", "sys-exact"]
      assert clients(Store.match(s, "other/broker")) == ["plus", "root"]
    end

    test "a client with several matching subscriptions gets one entry at the highest QoS with every identifier",
         %{store: s} do
      sub(s, "c", "a/#", qos: 0, subscription_identifier: 1)
      sub(s, "c", "a/b", qos: 2, subscription_identifier: 7)
      sub(s, "c", "+/b", qos: 1)

      assert [{"c", %{qos: 2, subscription_identifier: ids}}] = Store.match(s, "a/b")
      assert Enum.sort(ids) == [1, 7]
    end

    test "no_local skips the publisher's own subscriptions only", %{store: s} do
      sub(s, "me", "t", no_local: true)
      sub(s, "you", "t", no_local: true)

      assert clients(Store.match(s, "t", "me")) == ["you"]
      assert clients(Store.match(s, "t", nil)) == ["me", "you"]
    end

    test "re-subscribing replaces the options; unsubscribing removes the filter", %{store: s} do
      sub(s, "c", "a/+", qos: 0)
      sub(s, "c", "a/+", qos: 1)
      assert [{"c", %{qos: 1}}] = Store.match(s, "a/x")
      assert [%{filter: "a/+", opts: %{qos: 1}}] = Store.subscriptions(s, "c")

      Store.unsubscribe(s, "c", "a/+")
      assert Store.match(s, "a/x") == []
      assert Store.subscriptions(s, "c") == []
    end

    test "shared subscriptions deliver to one member per group, rotating among online ones",
         %{store: s} do
      sub(s, "w1", "$share/pool/jobs/#", qos: 1)
      sub(s, "w2", "$share/pool/jobs/#", qos: 1)
      sub(s, "w3", "$share/pool/jobs/#", qos: 1)
      sub(s, "audit", "jobs/#", qos: 0)

      online = fn client -> client in ["w1", "w3"] end

      picks =
        for _ <- 1..6 do
          matches = Store.match(s, "jobs/1", nil, online)
          assert "audit" in clients(matches)
          [worker] = clients(matches) -- ["audit"]
          worker
        end

      assert Enum.sort(Enum.uniq(picks)) == ["w1", "w3"]
      refute "w2" in picks
    end

    test "with no member online a shared message still goes to one member", %{store: s} do
      sub(s, "w1", "$share/pool/jobs", qos: 1)
      sub(s, "w2", "$share/pool/jobs", qos: 1)

      assert [{worker, %{qos: 1}}] = Store.match(s, "jobs", nil, fn _ -> false end)
      assert worker in ["w1", "w2"]
    end

    test "a client is not delivered twice when a normal subscription and a share both match",
         %{store: s} do
      sub(s, "c", "$share/g/t")
      sub(s, "c", "t")

      assert [{"c", _}] = Store.match(s, "t")
    end
  end

  describe "sessions" do
    test "put/get/delete and expiry", %{store: s} do
      refute Store.exists?(s, "c")
      Store.put(s, "c", %{protocol_version: 5, expires_at: :infinity})
      assert %{protocol_version: 5} = Store.get(s, "c")

      Store.set_expiry(s, "c", System.system_time(:second) - 1)
      assert Store.get(s, "c") == nil
      refute Store.exists?(s, "c")
    end

    test "delete removes subscriptions, in-flight entries and the queue", %{store: s} do
      Store.put(s, "c", %{protocol_version: 5, expires_at: :infinity})
      sub(s, "c", "a/#")
      Store.put_inflight(s, "c", {:tx1, 1}, :packet)
      Store.enqueue(s, "c", :msg, nil)
      sub(s, "other", "a/#")

      Store.delete(s, "c")

      assert Store.match(s, "a/b") |> clients() == ["other"]
      assert Store.subscriptions(s, "c") == []
      assert Store.inflight(s, "c") == []
      assert Store.dequeue(s, "c") == :empty
      assert Store.queue_length(s, "c") == 0
    end
  end

  describe "in-flight state" do
    test "entries come back oldest first and an update keeps its place", %{store: s} do
      Store.put_inflight(s, "c", {:tx1, 5}, :a)
      Store.put_inflight(s, "c", {:tx2, 6}, %{phase: :pubrec_pending})
      Store.put_inflight(s, "c", {:rx2, 9}, :c)
      Store.put_inflight(s, "c", {:tx2, 6}, %{phase: :pubrel_sent})
      Store.delete_inflight(s, "c", {:rx2, 9})
      Store.put_inflight(s, "other", {:tx1, 1}, :x)

      assert Store.inflight(s, "c") == [{{:tx1, 5}, :a}, {{:tx2, 6}, %{phase: :pubrel_sent}}]
    end
  end

  describe "queue" do
    test "FIFO per client, bounded, and independent between clients", %{store: s} do
      assert :ok = Store.enqueue(s, "c", 1, 2)
      assert :ok = Store.enqueue(s, "c", 2, 2)
      assert {:error, :full} = Store.enqueue(s, "c", 3, 2)
      assert :ok = Store.enqueue(s, "d", :d1, 2)
      assert Store.queue_length(s, "c") == 2

      assert {:ok, 1} = Store.dequeue(s, "c")
      assert {:ok, 2} = Store.dequeue(s, "c")
      assert :empty = Store.dequeue(s, "c")
      assert Store.queue_length(s, "c") == 0
      assert {:ok, :d1} = Store.dequeue(s, "d")
    end
  end

  describe "shared groups across nodes" do
    test "a member on another node is a candidate, and comes back as :remote" do
      s = Store.new()
      :ok = Store.subscribe(s, "here", "$share/g/t/#", %{qos: 1})
      :ok = Store.put_remote_shared(s, :b@host, ["t", :multi_level], "g", "there", %{qos: 1})

      picks = for _ <- 1..4, do: Store.match(s, "t/x")

      assert {"here", %{qos: 1}} in List.flatten(picks)
      assert {:remote, :b@host, "there", %{qos: 1}} in List.flatten(picks)
      assert Enum.all?(picks, &(length(&1) == 1))
    end

    test "shared: :skip leaves shared groups out" do
      s = Store.new()
      :ok = Store.subscribe(s, "here", "$share/g/t", %{qos: 1})
      :ok = Store.subscribe(s, "plain", "t", %{qos: 0})
      assert Store.match(s, "t", nil, fn _ -> true end, :skip) == [{"plain", %{qos: 0}}]
    end

    test "a remove from a node that no longer holds the member is ignored" do
      s = Store.new()
      :ok = Store.put_remote_shared(s, :new@host, ["t"], "g", "moved", %{qos: 0})
      :ok = Store.delete_remote_shared(s, :old@host, ["t"], "g", "moved")
      assert [{:remote, :new@host, "moved", _}] = Store.match(s, "t")

      :ok = Store.drop_remote_node(s, :new@host)
      assert Store.match(s, "t") == []
    end

    test "local_shared lists this node's shared subscriptions only" do
      s = Store.new()
      :ok = Store.subscribe(s, "a", "$share/g/x/+", %{qos: 1})
      :ok = Store.subscribe(s, "a", "y", %{qos: 1})
      assert Store.local_shared(s) == [{["x", :single_level], "g", "a", %{qos: 1}}]
    end
  end

  describe "export/import" do
    test "a session moves with its subscriptions, in-flight state and queue in order" do
      from = Store.new()
      :ok = Store.put(from, "m", %{protocol_version: 5, expires_at: :infinity, persistent: true})
      :ok = Store.subscribe(from, "m", "a/+", %{qos: 1})
      :ok = Store.put_inflight(from, "m", {:tx1, 1}, :p1)
      :ok = Store.put_inflight(from, "m", {:rx2, 2}, :p2)
      now = System.monotonic_time(:millisecond)
      for n <- 1..3, do: :ok = Store.enqueue(from, "m", {"a/b", "#{n}", %{qos: 1}, now}, nil)

      record = Store.export(from, "m")
      to = Store.new()
      :ok = Store.import(to, "m", record)

      assert Store.get(to, "m").persistent
      assert [%{filter: "a/+"}] = Store.subscriptions(to, "m")
      assert Store.inflight(to, "m") == [{{:tx1, 1}, :p1}, {{:rx2, 2}, :p2}]

      assert for(_ <- 1..3, do: elem(Store.dequeue(to, "m"), 1) |> elem(1)) == ["1", "2", "3"]
      assert Store.export(Store.new(), "nobody") == nil
    end
  end
end
