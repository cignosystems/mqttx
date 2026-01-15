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

  describe "validate_publish/1" do
    test "validates simple topic" do
      assert {:ok, ["test"]} = Topic.validate_publish("test")
    end

    test "rejects wildcards" do
      assert {:error, :invalid_topic} = Topic.validate_publish("a/+")
      assert {:error, :invalid_topic} = Topic.validate_publish("a/#")
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
