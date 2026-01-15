defmodule MqttX.Topic do
  @moduledoc """
  MQTT Topic validation, normalization, and wildcard matching.

  ## Topic Format

  Topics are `/`-separated strings. Wildcards are:
  - `+` - Single-level wildcard (matches exactly one level)
  - `#` - Multi-level wildcard (matches zero or more levels, must be last)

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
  """

  @type wildcard :: :single_level | :multi_level
  @type normalized_topic :: [binary() | wildcard()]

  @doc """
  Validate and normalize a topic.

  Returns `{:ok, normalized_topic}` or `{:error, :invalid_topic}`.
  """
  @spec validate(binary() | list()) :: {:ok, normalized_topic()} | {:error, :invalid_topic}
  def validate(topic) when is_binary(topic) do
    topic
    |> normalize()
    |> validate_normalized()
  end

  def validate(topic) when is_list(topic) do
    topic
    |> normalize()
    |> validate_normalized()
  end

  @doc """
  Validate a topic for publishing (no wildcards allowed).

  Returns `{:ok, normalized_topic}` or `{:error, :invalid_topic}`.
  """
  @spec validate_publish(binary() | list()) ::
          {:ok, normalized_topic()} | {:error, :invalid_topic}
  def validate_publish(topic) do
    case validate(topic) do
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

  def flatten([head | tail]) do
    flatten_loop(tail, part_to_binary(head))
  end

  def flatten(topic) when is_binary(topic) do
    topic
  end

  defp flatten_loop([], acc) do
    acc
  end

  defp flatten_loop([head | tail], acc) do
    flatten_loop(tail, <<acc::binary, "/", part_to_binary(head)::binary>>)
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

  def matches?([], []) do
    true
  end

  def matches?([:multi_level], _topic) do
    true
  end

  def matches?([:multi_level | _], _topic) do
    true
  end

  def matches?([:single_level | filter_rest], [_topic_head | topic_rest]) do
    matches?(filter_rest, topic_rest)
  end

  def matches?([same | filter_rest], [same | topic_rest]) do
    matches?(filter_rest, topic_rest)
  end

  def matches?([], [_ | _]) do
    false
  end

  def matches?([_ | _], []) do
    false
  end

  def matches?(_, _) do
    false
  end

  # Validation helpers

  defp validate_normalized([]) do
    {:error, :invalid_topic}
  end

  defp validate_normalized(normalized) do
    if valid_normalized?(normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_topic}
    end
  end

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
end
