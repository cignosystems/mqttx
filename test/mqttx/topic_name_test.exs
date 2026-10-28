defmodule MqttX.TopicNameTest do
  @moduledoc """
  `Topic.validate_publish/1` and `Topic.valid_name?/1` check a Topic Name
  in one pass over its bytes. They must agree, on every input, with the
  rule as it was written before — split into levels, each level checked —
  which is kept here as the reference.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MqttX.Topic

  @max_bytes 65_535
  @max_levels 128

  # The rule as the levels-first implementation applied it to a binary
  defp reference(topic) when byte_size(topic) > @max_bytes, do: {:error, :invalid_topic}
  defp reference(<<>>), do: {:error, :invalid_topic}

  defp reference(topic) do
    levels = :binary.split(topic, "/", [:global])

    cond do
      length(levels) > @max_levels -> {:error, :invalid_topic}
      Enum.all?(levels, &level_ok?/1) -> {:ok, levels}
      true -> {:error, :invalid_topic}
    end
  end

  defp level_ok?(<<>>), do: true
  defp level_ok?(<<c, _::binary>>) when c in [?+, ?#, ?/, 0], do: false
  defp level_ok?(<<_::utf8, rest::binary>>), do: level_ok?(rest)
  defp level_ok?(_), do: false

  # Pieces that exercise every clause: separators, wildcards, NUL, multi-byte
  # characters, and bytes that are not UTF-8 (a lone 0xFF, an overlong
  # encoding, an encoded surrogate)
  @pieces [
    "a",
    "b",
    "sensor",
    "/",
    "/",
    "+",
    "#",
    <<0>>,
    "é",
    "✓",
    "😀",
    "$",
    " ",
    <<0xFF>>,
    <<0xC0, 0x80>>,
    <<0xED, 0xA0, 0x80>>,
    <<0xE2, 0x9C>>
  ]

  property "the one-pass check agrees with the reference" do
    check all(pieces <- list_of(member_of(@pieces), max_length: 40), max_runs: 3_000) do
      topic = IO.iodata_to_binary(pieces)
      expected = reference(topic)
      assert Topic.validate_publish(topic) == expected
      assert Topic.valid_name?(topic) == match?({:ok, _}, expected)
    end
  end

  test "the levels come back as they were split" do
    assert Topic.validate_publish("a/b/c") == {:ok, ["a", "b", "c"]}
    assert Topic.validate_publish("/") == {:ok, ["", ""]}
    assert Topic.validate_publish("a//b/") == {:ok, ["a", "", "b", ""]}
    assert Topic.validate_publish("é/✓/😀") == {:ok, ["é", "✓", "😀"]}
    assert Topic.validate_publish("$SYS/broker") == {:ok, ["$SYS", "broker"]}
  end

  test "the caps: levels and bytes" do
    at_cap = Enum.join(List.duplicate("l", @max_levels), "/")
    assert {:ok, levels} = Topic.validate_publish(at_cap)
    assert length(levels) == @max_levels
    assert Topic.valid_name?(at_cap)

    over = at_cap <> "/l"
    assert Topic.validate_publish(over) == {:error, :invalid_topic}
    refute Topic.valid_name?(over)

    long = :binary.copy("x", @max_bytes)
    assert {:ok, [^long]} = Topic.validate_publish(long)
    assert Topic.valid_name?(long)
    assert Topic.validate_publish(long <> "x") == {:error, :invalid_topic}
    refute Topic.valid_name?(long <> "x")
  end

  test "what a name may not contain, wherever it is" do
    for bad <- ["", "+", "#", "a/+", "a/#", "a+b", "a#b", "+/a", "a/b#", <<0>>, "a\0b", "a/\0"] do
      assert Topic.validate_publish(bad) == {:error, :invalid_topic}, inspect(bad)
      refute Topic.valid_name?(bad), inspect(bad)
    end

    for bad <- [<<0xFF>>, "a/" <> <<0xC0, 0x80>>, <<0xED, 0xA0, 0x80>>, "ok/" <> <<0xE2, 0x9C>>] do
      assert Topic.validate_publish(bad) == {:error, :invalid_topic}, inspect(bad)
      refute Topic.valid_name?(bad), inspect(bad)
    end
  end

  test "a list is checked as before" do
    assert Topic.validate_publish(["a", "b"]) == {:ok, ["a", "b"]}
    assert Topic.validate_publish(["a", "+"]) == {:error, :invalid_topic}
    assert Topic.validate_publish([]) == {:error, :invalid_topic}
  end
end
