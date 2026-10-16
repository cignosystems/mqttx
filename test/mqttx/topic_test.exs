defmodule MqttX.TopicTest do
  use ExUnit.Case, async: true

  alias MqttX.Topic

  describe "validate/1" do
    test "validates simple topic" do
      assert {:ok, ["test"]} = Topic.validate("test")
      assert {:ok, ["a", "b", "c"]} = Topic.validate("a/b/c")
    end

    test "validates topic with single-level wildcard" do
      assert {:ok, ["a", :single_level, "c"]} = Topic.validate("a/+/c")
      assert {:ok, [:single_level]} = Topic.validate("+")
    end

    test "validates topic with multi-level wildcard" do
      assert {:ok, ["a", :multi_level]} = Topic.validate("a/#")
      assert {:ok, [:multi_level]} = Topic.validate("#")
    end

    test "rejects empty topic" do
      assert {:error, :invalid_topic} = Topic.validate("")
    end

    test "rejects multi-level wildcard not at end" do
      assert {:error, :invalid_topic} = Topic.validate("a/#/b")
    end
  end

  describe "validate/1 shared subscription structure (§4.8.2, MQTT-4.8.2-1/-2)" do
    test "accepts $share/{ShareName}/{filter} with any valid filter" do
      assert {:ok, ["$share", "g", "t"]} = Topic.validate("$share/g/t")
      assert {:ok, ["$share", "g", :multi_level]} = Topic.validate("$share/g/#")
      assert {:ok, ["$share", "g", :single_level, "x"]} = Topic.validate("$share/g/+/x")
      assert {:ok, ["$share", "g", "$SYS", "x"]} = Topic.validate("$share/g/$SYS/x")
    end

    test "rejects an empty ShareName" do
      assert {:error, :invalid_topic} = Topic.validate("$share//t")
      assert {:error, :invalid_topic} = Topic.validate("$share/")
    end

    test "rejects a missing or empty Topic Filter" do
      assert {:error, :invalid_topic} = Topic.validate("$share/g")
      assert {:error, :invalid_topic} = Topic.validate("$share/g/")
    end

    test "rejects wildcards in the ShareName" do
      assert {:error, :invalid_topic} = Topic.validate("$share/+/t")
      assert {:error, :invalid_topic} = Topic.validate("$share/#/t")
      assert {:error, :invalid_topic} = Topic.validate("$share/g+/t")
    end

    test "applies the same rules to the list form" do
      assert {:ok, _} = Topic.validate(["$share", "g", "t"])
      assert {:error, :invalid_topic} = Topic.validate(["$share", "", "t"])
      assert {:error, :invalid_topic} = Topic.validate(["$share", :single_level, "t"])
      assert {:error, :invalid_topic} = Topic.validate(["$share", "g"])
      assert {:error, :invalid_topic} = Topic.validate(["$share", "g", ""])
    end

    test "a bare \"$share\" is an ordinary $-filter, not a shared subscription" do
      assert {:ok, ["$share"]} = Topic.validate("$share")
      assert {:normal, "$share"} = Topic.parse_shared("$share")
    end

    test "parse_shared/1 agrees with validate/1" do
      for f <- ["$share//t", "$share/", "$share/g", "$share/g/", "$share/+/t", "$share/#/t"] do
        assert {:error, :invalid_topic} = Topic.validate(f)
        assert {:normal, ^f} = Topic.parse_shared(f), "#{f} must not parse as shared"
      end

      assert {:shared, "g", "t"} = Topic.parse_shared("$share/g/t")
      assert {:shared, "g", "#"} = Topic.parse_shared("$share/g/#")
      assert {:shared, "g", "+/x"} = Topic.parse_shared("$share/g/+/x")
      assert {:shared, "g", "$SYS/x"} = Topic.parse_shared("$share/g/$SYS/x")
    end
  end

  describe "validate_publish/1" do
    test "validates simple topic" do
      assert {:ok, ["test"]} = Topic.validate_publish("test")
    end

    test "rejects wildcards" do
      assert {:error, :invalid_topic} = Topic.validate_publish("a/+")
      assert {:error, :invalid_topic} = Topic.validate_publish("a/#")
    end

    test "treats $share/... as an ordinary topic name — filter rules do not apply" do
      assert {:ok, ["$share", "g", "t"]} = Topic.validate_publish("$share/g/t")
      # Legal (if odd) topic names: empty levels are allowed in a Topic Name
      assert {:ok, ["$share", "", "t"]} = Topic.validate_publish("$share//t")
      assert {:ok, ["$share", "g"]} = Topic.validate_publish("$share/g")
    end
  end

  describe "normalize/1" do
    test "normalizes binary topic to list" do
      assert ["a", "b", "c"] = Topic.normalize("a/b/c")
    end

    test "converts wildcards to atoms" do
      assert [:single_level, :multi_level] = Topic.normalize("+/#")
    end

    test "normalizes list input" do
      assert ["a", "b"] = Topic.normalize(["a", "b"])
    end
  end

  describe "flatten/1" do
    test "flattens list to binary" do
      assert "a/b/c" = Topic.flatten(["a", "b", "c"])
    end

    test "converts wildcards back to strings" do
      assert "a/+/#" = Topic.flatten(["a", :single_level, :multi_level])
    end

    test "returns binary input unchanged" do
      assert "a/b" = Topic.flatten("a/b")
    end
  end

  describe "wildcard?/1" do
    test "detects wildcards in list" do
      assert Topic.wildcard?(["a", :single_level, "b"])
      assert Topic.wildcard?(["a", :multi_level])
      refute Topic.wildcard?(["a", "b", "c"])
    end

    test "detects wildcards in string" do
      assert Topic.wildcard?("a/+/b")
      assert Topic.wildcard?("a/#")
      refute Topic.wildcard?("a/b/c")
    end
  end

  describe "matches?/2" do
    test "matches exact topics" do
      assert Topic.matches?(["a", "b"], ["a", "b"])
      refute Topic.matches?(["a", "b"], ["a", "c"])
    end

    test "matches single-level wildcard" do
      assert Topic.matches?(["a", :single_level, "c"], ["a", "b", "c"])
      assert Topic.matches?(["a", :single_level, "c"], ["a", "x", "c"])
      refute Topic.matches?(["a", :single_level, "c"], ["a", "b", "d"])
    end

    test "matches multi-level wildcard at end" do
      assert Topic.matches?(["a", :multi_level], ["a"])
      assert Topic.matches?(["a", :multi_level], ["a", "b"])
      assert Topic.matches?(["a", :multi_level], ["a", "b", "c", "d"])
    end

    test "matches multi-level wildcard alone" do
      assert Topic.matches?([:multi_level], [])
      assert Topic.matches?([:multi_level], ["a"])
      assert Topic.matches?([:multi_level], ["a", "b", "c"])
    end

    test "handles binary inputs" do
      assert Topic.matches?("a/+", "a/b")
      assert Topic.matches?("a/#", "a/b/c")
    end

    test "does not match when filter is longer than topic" do
      refute Topic.matches?(["a", "b", "c"], ["a", "b"])
    end

    test "does not match when topic is longer than filter (without #)" do
      refute Topic.matches?(["a", "b"], ["a", "b", "c"])
    end
  end
end
