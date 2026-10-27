defmodule MqttX.Topic do
  @moduledoc """
  MQTT Topic validation, normalization, and wildcard matching.

  ## Topic Format

  Topics are `/`-separated strings. Wildcards are:
  - `+` - Single-level wildcard (matches exactly one level)
  - `#` - Multi-level wildcard (matches zero or more levels, must be last)

  ## Shared Subscriptions (MQTT 5.0)

  Shared subscriptions use the format `$share/group_name/topic_filter`.
  Messages are distributed among subscribers in a group using round-robin.

  ## Examples

      # Validation
      iex> MqttX.Topic.validate("sensors/temperature")
      {:ok, ["sensors", "temperature"]}

      iex> MqttX.Topic.validate("sensors/+/humidity")
      {:ok, ["sensors", :single_level, "humidity"]}

      iex> MqttX.Topic.validate("sensors/#")
      {:ok, ["sensors", :multi_level]}

      # Matching
      iex> MqttX.Topic.matches?(["sensors", :single_level, "temp"], ["sensors", "room1", "temp"])
      true

      iex> MqttX.Topic.matches?(["sensors", :multi_level], ["sensors", "room1", "temp"])
      true

      # Shared subscriptions
      iex> MqttX.Topic.shared?("$share/group1/sensors/#")
      true

      iex> MqttX.Topic.parse_shared("$share/group1/sensors/#")
      {:shared, "group1", "sensors/#"}
  """

  @type wildcard :: :single_level | :multi_level
  @type normalized_topic :: [binary() | wildcard()]

  @doc """
  Validate and normalize a topic filter.

  Returns `{:ok, normalized_topic}` or `{:error, :invalid_topic}`.

  A filter starting with `$share/` is a Shared Subscription (MQTT 5.0
  §4.8.2) and must have the shape `$share/{ShareName}/{filter}`: the
  ShareName is at least one character and contains none of `/`, `+`, `#`,
  and the Topic Filter after it is non-empty. Anything else that starts with
  `$share/` (`"$share//t"`, `"$share/g"`, `"$share/g/"`, `"$share/+/t"`) is
  rejected rather than installed as a literal subscription.
  """
  # MQTT §1.5.4: 16-bit length-prefixed UTF-8 strings cap at 65535 bytes
  @max_topic_bytes 65_535
  # Levels per topic. The spec sets none; matching costs grow with the depth
  # (the subscription index is walked level by level), so a topic of tens of
  # thousands of levels would be a way to burn CPU on every node. 128 is
  # what EMQX allows.
  @max_topic_levels 128

  @spec validate(binary() | list()) :: {:ok, normalized_topic()} | {:error, :invalid_topic}
  def validate(topic), do: do_validate(topic, :filter)

  @doc """
  Validate a topic for publishing (no wildcards allowed).

  Returns `{:ok, normalized_topic}` or `{:error, :invalid_topic}`.

  This validates a Topic *Name*: the `$share/` structure rules of
  `validate/1` apply to filters only, so a PUBLISH to a topic literally
  named `$share/g/t` is just a topic name.
  """
  @spec validate_publish(binary() | list()) ::
          {:ok, normalized_topic()} | {:error, :invalid_topic}
  def validate_publish(topic) do
    case do_validate(topic, :name) do
      {:ok, normalized} ->
        if wildcard?(normalized) do
          {:error, :invalid_topic}
        else
          {:ok, normalized}
        end

      error ->
        error
    end
  end

  defp do_validate(topic, _kind) when is_binary(topic) and byte_size(topic) > @max_topic_bytes do
    {:error, :invalid_topic}
  end

  defp do_validate(topic, kind) when is_binary(topic) do
    topic
    |> normalize()
    |> validate_normalized(kind)
  end

  defp do_validate(topic, kind) when is_list(topic) do
    # Same §1.5.4 byte cap as the binary form: segment bytes + separators
    byte_total =
      Enum.reduce(topic, max(length(topic) - 1, 0), fn
        seg, acc when is_binary(seg) -> acc + byte_size(seg)
        # wildcard atoms (:single_level/:multi_level) encode as 1 byte
        _atom, acc -> acc + 1
      end)

    if byte_total > @max_topic_bytes do
      {:error, :invalid_topic}
    else
      topic
      |> normalize()
      |> validate_normalized(kind)
    end
  end

  @doc """
  Check if a topic is valid.
  """
  @spec valid?(binary() | list()) :: boolean()
  def valid?(topic) do
    case validate(topic) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc "The most levels a topic or filter may have (#{@max_topic_levels})."
  @spec max_levels() :: pos_integer()
  def max_levels, do: @max_topic_levels

  @doc """
  Normalize a topic to a list.

  Wildcards are converted to atoms `:single_level` (+) and `:multi_level` (#).
  """
  @spec normalize(binary() | list()) :: normalized_topic()
  def normalize(<<>>) do
    []
  end

  def normalize(topic) when is_binary(topic) do
    topic
    |> :binary.split("/", [:global])
    |> Enum.map(&normalize_part/1)
  end

  def normalize(topic) when is_list(topic) do
    Enum.map(topic, &normalize_part/1)
  end

  defp normalize_part("+"), do: :single_level
  defp normalize_part("#"), do: :multi_level
  defp normalize_part(:single_level), do: :single_level
  defp normalize_part(:multi_level), do: :multi_level
  # Legacy support for :+ atom
  defp normalize_part(:+), do: :single_level
  defp normalize_part(n) when is_integer(n), do: Integer.to_string(n)
  defp normalize_part(b) when is_binary(b), do: b
  defp normalize_part(a) when is_atom(a), do: Atom.to_string(a)

  @doc """
  Flatten a normalized topic back to a binary string.
  """
  @spec flatten(normalized_topic()) :: binary()
  def flatten([]) do
    <<>>
  end

  def flatten(topic) when is_list(topic) do
    topic
    |> Enum.map(&part_to_binary/1)
    |> Enum.intersperse("/")
    |> IO.iodata_to_binary()
  end

  def flatten(topic) when is_binary(topic) do
    topic
  end

  defp part_to_binary(:single_level), do: "+"
  defp part_to_binary(:multi_level), do: "#"
  defp part_to_binary(b) when is_binary(b), do: b

  @doc """
  Check if a topic contains wildcards.
  """
  @spec wildcard?(normalized_topic()) :: boolean()
  def wildcard?(topic) when is_list(topic) do
    Enum.any?(topic, &is_wildcard?/1)
  end

  def wildcard?(topic) when is_binary(topic) do
    String.contains?(topic, ["+", "#"])
  end

  defp is_wildcard?(:single_level), do: true
  defp is_wildcard?(:multi_level), do: true
  defp is_wildcard?(_), do: false

  @doc """
  Match a topic filter against a concrete topic.

  The filter can contain wildcards, the topic should not.

  ## Examples

      iex> MqttX.Topic.matches?(["sensors", :single_level, "temp"], ["sensors", "room1", "temp"])
      true

      iex> MqttX.Topic.matches?(["sensors", :multi_level], ["sensors", "room1", "temp"])
      true

      iex> MqttX.Topic.matches?(["sensors", "room1"], ["sensors", "room2"])
      false
  """
  @spec matches?(normalized_topic(), normalized_topic()) :: boolean()
  def matches?(filter, topic) when is_binary(filter) do
    matches?(normalize(filter), topic)
  end

  def matches?(filter, topic) when is_binary(topic) do
    matches?(filter, normalize(topic))
  end

  # §4.7.2: filters starting with a wildcard at the first level MUST NOT match
  # topic names beginning with '$' (e.g. $SYS/...). Detect at the entry point;
  # once a literal level is matched, the remainder is structural.
  def matches?([:single_level | _] = filter, [<<"$", _::binary>> | _] = topic) do
    matches_inner?(filter, topic, true)
  end

  def matches?([:multi_level | _] = filter, [<<"$", _::binary>> | _] = topic) do
    matches_inner?(filter, topic, true)
  end

  def matches?(filter, topic) do
    matches_inner?(filter, topic, false)
  end

  # `dollar_blocked` is true while we're still at the head of a topic that begins
  # with $ AND have not yet consumed a literal first-level filter segment.
  defp matches_inner?([], [], _), do: true
  defp matches_inner?([:multi_level], _topic, true), do: false
  defp matches_inner?([:multi_level], _topic, false), do: true
  defp matches_inner?([:multi_level | _], _topic, true), do: false
  defp matches_inner?([:multi_level | _], _topic, false), do: true

  defp matches_inner?([:single_level | _filter_rest], [_topic_head | _topic_rest], true),
    do: false

  defp matches_inner?([:single_level | filter_rest], [_topic_head | topic_rest], false) do
    matches_inner?(filter_rest, topic_rest, false)
  end

  defp matches_inner?([same | filter_rest], [same | topic_rest], _) do
    # Once a literal filter segment matches a topic segment we're past the
    # first-level $-guard.
    matches_inner?(filter_rest, topic_rest, false)
  end

  defp matches_inner?([], [_ | _], _), do: false
  defp matches_inner?([_ | _], [], _), do: false
  defp matches_inner?(_, _, _), do: false

  # Validation helpers

  defp validate_normalized([], _kind) do
    {:error, :invalid_topic}
  end

  defp validate_normalized(normalized, _kind) when length(normalized) > @max_topic_levels do
    {:error, :invalid_topic}
  end

  defp validate_normalized(normalized, kind) do
    if valid_normalized?(normalized) and (kind == :name or valid_share_structure?(normalized)) do
      {:ok, normalized}
    else
      {:error, :invalid_topic}
    end
  end

  # §4.8.2 (MQTT-4.8.2-1, MQTT-4.8.2-2): a filter beginning with "$share/"
  # MUST be "$share/{ShareName}/{filter}" where ShareName is at least one
  # character with no '/', '+' or '#' (so never a wildcard atom here) and the
  # filter that follows is non-empty. `[""]` is "$share/g/" — empty filter.
  defp valid_share_structure?(["$share", group | filter])
       when is_binary(group) and group != "" and filter != [] do
    filter != [""]
  end

  defp valid_share_structure?(["$share", _group | _filter]), do: false
  # A bare "$share" (no slash) is not a shared subscription — just a $-topic.
  defp valid_share_structure?(_), do: true

  defp valid_normalized?([]) do
    true
  end

  # # must be last
  defp valid_normalized?([:multi_level]) do
    true
  end

  defp valid_normalized?([:multi_level | _rest]) do
    false
  end

  defp valid_normalized?([head | tail]) do
    valid_part?(head) and valid_normalized?(tail)
  end

  # Integer clause kept for API completeness even though normalize_part converts them
  @dialyzer {:nowarn_function, valid_part?: 1}
  defp valid_part?(:multi_level), do: true
  defp valid_part?(:single_level), do: true
  defp valid_part?(n) when is_integer(n), do: true
  defp valid_part?(b) when is_binary(b), do: valid_topic_chars?(b)

  defp valid_topic_chars?(<<>>) do
    true
  end

  defp valid_topic_chars?(<<"+", _rest::binary>>) do
    false
  end

  defp valid_topic_chars?(<<"#", _rest::binary>>) do
    false
  end

  defp valid_topic_chars?(<<"/", _rest::binary>>) do
    false
  end

  defp valid_topic_chars?(<<0, _rest::binary>>) do
    false
  end

  defp valid_topic_chars?(<<_::utf8, rest::binary>>) do
    valid_topic_chars?(rest)
  end

  defp valid_topic_chars?(_) do
    false
  end

  # ============================================================================
  # Shared Subscriptions (MQTT 5.0)
  # ============================================================================

  @doc """
  Check if a topic filter is a shared subscription.

  Shared subscriptions use the format `$share/group_name/topic_filter`.

  ## Examples

      iex> MqttX.Topic.shared?("$share/group1/sensors/#")
      true

      iex> MqttX.Topic.shared?("sensors/#")
      false
  """
  @spec shared?(binary()) :: boolean()
  def shared?("$share/" <> _rest), do: true
  def shared?(_), do: false

  @doc """
  Parse a shared subscription filter.

  Returns `{:shared, group_name, topic_filter}` for shared subscriptions,
  or `{:normal, topic_filter}` for regular subscriptions.

  Only a well-formed `$share/{ShareName}/{filter}` (§4.8.2) is reported as
  `:shared`; malformed `$share/...` forms come back as `:normal` and are the
  same forms `validate/1` rejects, so they never reach a subscription table.

  ## Examples

      iex> MqttX.Topic.parse_shared("$share/group1/sensors/#")
      {:shared, "group1", "sensors/#"}

      iex> MqttX.Topic.parse_shared("sensors/#")
      {:normal, "sensors/#"}
  """
  @spec parse_shared(binary()) :: {:shared, binary(), binary()} | {:normal, binary()}
  def parse_shared("$share/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [group, topic_filter] when group != "" and topic_filter != "" ->
        # §4.8.2: ShareName MUST NOT contain '/', '+', or '#'. The `parts: 2`
        # split already excludes '/'. Reject filters that smuggled '+' or '#'.
        if String.contains?(group, ["+", "#"]) do
          {:normal, "$share/" <> rest}
        else
          {:shared, group, topic_filter}
        end

      _ ->
        {:normal, "$share/" <> rest}
    end
  end

  def parse_shared(topic) do
    {:normal, topic}
  end
end
