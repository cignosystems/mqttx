defmodule MqttX.Server.RetainedStoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MqttX.Server.RetainedStore

  setup do
    {:ok, table: RetainedStore.new_table()}
  end

  defp topics(matches),
    do: matches |> Enum.map(fn {topic, _, _, _, _} -> topic end) |> Enum.sort()

  describe "store/6" do
    test "stores and overwrites by topic", %{table: table} do
      :ok = RetainedStore.store(table, "sensors/room1/temp", "21.5", 0, %{}, nil)
      :ok = RetainedStore.store(table, "sensors/room1/temp", "22.0", 1, %{}, nil)

      assert [{"sensors/room1/temp", "22.0", 1, _, nil}] =
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

      assert [{"a/b", "x", 0, _, _}] = RetainedStore.match(table, "a/b")
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
      assert [{"t/1", "a2", 0, _, _}] = RetainedStore.match(table, "t/1")
    end

    test "records message_expiry_interval from the properties", %{table: table} do
      :ok = RetainedStore.store(table, "e/t", "x", 0, %{message_expiry_interval: 60}, nil)

      assert [{"e/t", "x", 0, ts, 60}] = RetainedStore.match(table, "e/t")
      assert is_integer(ts)
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
      :ets.insert(table, {["old", "t"], "old/t", "x", 0, System.system_time(:second) - 120, 60})
      :ok = RetainedStore.store(table, "old/live", "y", 0, %{message_expiry_interval: 600}, nil)

      assert topics(RetainedStore.match(table, "old/#")) == ["old/live"]
      assert :ets.lookup(table, ["old", "t"]) == []
    end

    test "entries without an expiry never expire", %{table: table} do
      :ets.insert(table, {["keep", "t"], "keep/t", "x", 0, 0, nil})

      assert [{"keep/t", "x", 0, 0, nil}] = RetainedStore.match(table, "keep/t")
    end

    test "expired $-prefixed rows are deleted even by wildcard filters that exclude them",
         %{table: table} do
      # The $-reject must not shield expired rows from the lazy delete —
      # this is the store's only expiry sweep
      :ets.insert(
        table,
        {["$SYS", "old"], "$SYS/old", "x", 0, System.system_time(:second) - 120, 60}
      )

      assert RetainedStore.match(table, "#") == []
      assert :ets.lookup(table, ["$SYS", "old"]) == []
    end
  end
end
