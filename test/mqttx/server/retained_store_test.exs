defmodule MqttX.Server.RetainedStoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MqttX.Server.RetainedStore

  setup do
    {:ok, table: RetainedStore.new_table()}
  end

  defp topics(matches),
    do: matches |> Enum.map(fn {topic, _, _, _, _, _} -> topic end) |> Enum.sort()

  describe "store/6" do
    test "stores and overwrites by topic", %{table: table} do
      :ok = RetainedStore.store(table, "sensors/room1/temp", "21.5", 0, %{}, nil)
      :ok = RetainedStore.store(table, "sensors/room1/temp", "22.0", 1, %{}, nil)

      assert [{"sensors/room1/temp", "22.0", 1, _, nil, _}] =
               RetainedStore.match(table, "sensors/room1/temp")
    end

    test "an empty payload clears the topic", %{table: table} do
      :ok = RetainedStore.store(table, "a/b", "x", 0, %{}, nil)
      :ok = RetainedStore.store(table, "a/b", <<>>, 0, %{}, nil)

      assert RetainedStore.match(table, "a/b") == []
      assert :ets.info(table, :size) == 0
    end

    test "accepts a topic as a segment list", %{table: table} do
      :ok = RetainedStore.store(table, ["a", "b"], "x", 0, %{}, nil)

      assert [{"a/b", "x", 0, _, _, _}] = RetainedStore.match(table, "a/b")
    end

    test "caps distinct topics at max but always allows overwrite", %{table: table} do
      :ok = RetainedStore.store(table, "t/1", "a", 0, %{}, 2)
      :ok = RetainedStore.store(table, "t/2", "b", 0, %{}, 2)

      log =
        capture_log(fn ->
          :ok = RetainedStore.store(table, "t/3", "c", 0, %{}, 2)
        end)

      assert log =~ "Retained store full"
      assert RetainedStore.match(table, "t/3") == []

      # Existing topic can still be overwritten at the cap
      :ok = RetainedStore.store(table, "t/1", "a2", 0, %{}, 2)
      assert [{"t/1", "a2", 0, _, _, _}] = RetainedStore.match(table, "t/1")
    end

    test "records message_expiry_interval from the properties", %{table: table} do
      :ok = RetainedStore.store(table, "e/t", "x", 0, %{message_expiry_interval: 60}, nil)

      assert [{"e/t", "x", 0, ts, 60, %{}}] = RetainedStore.match(table, "e/t")
      assert is_integer(ts)
    end

    test "keeps the properties a subscriber receives, not the connection- or subscription-bound ones",
         %{table: table} do
      properties = %{
        payload_format_indicator: true,
        content_type: "text/plain",
        response_topic: "r",
        correlation_data: "c",
        user_properties: [{"a", "1"}, {"a", "2"}],
        message_expiry_interval: 60,
        topic_alias: 3,
        subscription_identifier: 7
      }

      :ok = RetainedStore.store(table, "p/t", "x", 0, properties, nil)

      assert [{"p/t", "x", 0, _, 60, stored}] = RetainedStore.match(table, "p/t")

      assert stored ==
               Map.drop(properties, [
                 :message_expiry_interval,
                 :topic_alias,
                 :subscription_identifier
               ])
    end
  end

  describe "match/2 with wildcards" do
    setup %{table: table} do
      for topic <- [
            "sensors/room1/temp",
            "sensors/room1/humidity",
            "sensors/room2/temp",
            "sensors/room2/level/deep",
            "alerts/fire",
            "$SYS/broker/uptime"
          ] do
        :ok = RetainedStore.store(table, topic, "payload:" <> topic, 0, %{}, nil)
      end

      :ok
    end

    test "+ matches exactly one level", %{table: table} do
      assert topics(RetainedStore.match(table, "sensors/+/temp")) ==
               ["sensors/room1/temp", "sensors/room2/temp"]
    end

    test "# matches the parent level and everything below", %{table: table} do
      assert topics(RetainedStore.match(table, "sensors/room2/#")) ==
               ["sensors/room2/level/deep", "sensors/room2/temp"]

      :ok = RetainedStore.store(table, "sensors/room2", "parent", 0, %{}, nil)

      assert "sensors/room2" in topics(RetainedStore.match(table, "sensors/room2/#"))
    end

    test "a lone # matches everything except $-prefixed topics", %{table: table} do
      matched = topics(RetainedStore.match(table, "#"))

      refute "$SYS/broker/uptime" in matched
      assert length(matched) == 5
    end

    test "a first-level + does not match $-prefixed topics", %{table: table} do
      assert topics(RetainedStore.match(table, "+/broker/uptime")) == []
      assert topics(RetainedStore.match(table, "+/fire")) == ["alerts/fire"]
    end

    test "an explicit $-prefixed filter does match", %{table: table} do
      assert topics(RetainedStore.match(table, "$SYS/#")) == ["$SYS/broker/uptime"]
      assert topics(RetainedStore.match(table, "$SYS/broker/uptime")) == ["$SYS/broker/uptime"]
    end

    test "a wildcard filter does not match shallower or deeper literals", %{table: table} do
      assert topics(RetainedStore.match(table, "sensors/+")) == []

      assert topics(RetainedStore.match(table, "sensors/+/+")) ==
               ["sensors/room1/humidity", "sensors/room1/temp", "sensors/room2/temp"]
    end
  end

  describe "expiry" do
    test "expired entries are not returned and are deleted on the way", %{table: table} do
      # Insert a row whose timestamp is already past its expiry interval
      :ets.insert(
        table,
        {["old", "t"], "old/t", "x", 0, System.system_time(:second) - 120, 60, %{},
         {0, node(), 0}}
      )

      :ok = RetainedStore.store(table, "old/live", "y", 0, %{message_expiry_interval: 600}, nil)

      assert topics(RetainedStore.match(table, "old/#")) == ["old/live"]
      assert :ets.lookup(table, ["old", "t"]) == []
    end

    test "entries without an expiry never expire", %{table: table} do
      :ets.insert(table, {["keep", "t"], "keep/t", "x", 0, 0, nil, %{}, {0, node(), 0}})

      assert [{"keep/t", "x", 0, 0, nil, %{}}] = RetainedStore.match(table, "keep/t")
    end

    test "expired $-prefixed rows are deleted even by wildcard filters that exclude them",
         %{table: table} do
      # The $-reject must not shield expired rows from the lazy delete —
      # this is the store's only expiry sweep
      :ets.insert(
        table,
        {["$SYS", "old"], "$SYS/old", "x", 0, System.system_time(:second) - 120, 60, %{},
         {0, node(), 0}}
      )

      assert RetainedStore.match(table, "#") == []
      assert :ets.lookup(table, ["$SYS", "old"]) == []
    end
  end

  describe "replicas from other nodes" do
    defp older({segments, topic, _payload, qos, ts, exp, props, {time, node, n}}, new_payload),
      do: {segments, topic, new_payload, qos, ts, exp, props, {time - 1, node, n}}

    defp newer({segments, topic, _payload, qos, ts, exp, props, {time, node, n}}, new_payload),
      do: {segments, topic, new_payload, qos, ts, exp, props, {time + 1, node, n}}

    test "the newer write wins, and the cap applies to new topics" do
      table = RetainedStore.new_table()
      {:ok, row} = RetainedStore.write(table, "r/1", "local", 0, %{}, nil)

      # Older than what is here: ignored
      :ok = RetainedStore.apply_replica(table, older(row, "old"), nil)
      assert [{"r/1", "local", _, _, _, _}] = RetainedStore.match(table, "r/1")

      # The same write again: ignored
      :ok = RetainedStore.apply_replica(table, row, nil)
      assert [{"r/1", "local", _, _, _, _}] = RetainedStore.match(table, "r/1")

      # Newer: replaces
      :ok = RetainedStore.apply_replica(table, newer(row, "new"), nil)
      assert [{"r/1", "new", _, _, _, _}] = RetainedStore.match(table, "r/1")

      # At the cap, a new topic from elsewhere is not added
      other = put_elem(newer(row, "x"), 0, ["r", "2"]) |> put_elem(1, "r/2")
      :ok = RetainedStore.apply_replica(table, other, 1)
      assert RetainedStore.match(table, "r/2") == []
    end

    test "a write here wins over what it replaces, even from a clock ahead of this one" do
      table = RetainedStore.new_table()
      {:ok, row} = RetainedStore.write(table, "k/1", "a", 0, %{}, nil)
      {_, _, _, _, _, _, _, {time, _, _}} = ahead = newer(row, "from the future")
      ahead = put_elem(ahead, 7, {time + 60_000_000, :other@host, 0})
      :ok = RetainedStore.apply_replica(table, ahead, nil)

      {:ok, {_, _, "b", _, _, _, _, version}} =
        RetainedStore.write(table, "k/1", "b", 0, %{}, nil)

      assert version > elem(ahead, 7)
    end

    test "a clear outranks the message it cleared, wherever it arrives first" do
      table = RetainedStore.new_table()
      {:ok, row} = RetainedStore.write(table, "c/1", "x", 0, %{}, nil)
      cleared = newer(row, nil)

      # The clear from elsewhere removes the message here...
      :ok = RetainedStore.apply_replica(table, cleared, nil)
      assert RetainedStore.match(table, "c/1") == []
      assert RetainedStore.match(table, "#") == []

      # ...and the message, arriving again from a node that missed the
      # clear, stays cleared
      :ok = RetainedStore.apply_replica(table, row, nil)
      assert RetainedStore.match(table, "c/1") == []

      # A clear for a topic this node never had is remembered too
      :ok = RetainedStore.apply_replica(table, put_elem(cleared, 0, ["c", "2"]), nil)
      :ok = RetainedStore.apply_replica(table, put_elem(row, 0, ["c", "2"]), nil)
      assert RetainedStore.match(table, "c/2") == []

      # A later message on the topic is stored as usual
      {:ok, _} = RetainedStore.write(table, "c/1", "again", 0, %{}, nil)
      assert [{"c/1", "again", _, _, _, _}] = RetainedStore.match(table, "c/1")
    end

    test "a clear's marker counts toward the cap: clears of topics not here cannot grow the table past it" do
      table = RetainedStore.new_table()
      now = System.system_time(:microsecond)

      marker = fn i ->
        {["gone", "#{i}"], "gone/#{i}", nil, 0, System.system_time(:second), nil, %{},
         {now + i, :other@host, 0}}
      end

      for i <- 1..3, do: :ok = RetainedStore.apply_replica(table, marker.(i), 2)
      assert :ets.info(table, :size) == 2
    end

    test "cleared topics are forgotten after their time" do
      table = RetainedStore.new_table()
      {:ok, row} = RetainedStore.write(table, "c/1", "x", 0, %{}, nil)
      {segments, topic, _, qos, ts, exp, props, {_, node, n}} = row
      hour_ago = System.system_time(:microsecond) - 3_601_000_000
      :ets.insert(table, {segments, topic, nil, qos, ts, exp, props, {hour_ago, node, n}})
      {:ok, _} = RetainedStore.write(table, "c/2", "y", 0, %{}, nil)

      assert RetainedStore.sweep_cleared(table, 3_600) == 1
      assert :ets.lookup(table, segments) == []
      assert [_] = RetainedStore.match(table, "c/2")
    end
  end
end
