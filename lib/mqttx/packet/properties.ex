defmodule MqttX.Packet.Properties do
  @moduledoc """
  MQTT 5.0 Properties encoding and decoding.

  Supports all 28 MQTT 5.0 property types.
  """

  alias MqttX.Packet.Varint

  # Property identifiers
  @prop_payload_format_indicator 0x01
  @prop_message_expiry_interval 0x02
  @prop_content_type 0x03
  @prop_response_topic 0x08
  @prop_correlation_data 0x09
  @prop_subscription_identifier 0x0B
  @prop_session_expiry_interval 0x11
  @prop_assigned_client_identifier 0x12
  @prop_server_keep_alive 0x13
  @prop_authentication_method 0x15
  @prop_authentication_data 0x16
  @prop_request_problem_information 0x17
  @prop_will_delay_interval 0x18
  @prop_request_response_information 0x19
  @prop_response_information 0x1A
  @prop_server_reference 0x1C
  @prop_reason_string 0x1F
  @prop_receive_maximum 0x21
  @prop_topic_alias_maximum 0x22
  @prop_topic_alias 0x23
  @prop_maximum_qos 0x24
  @prop_retain_available 0x25
  @prop_user_property 0x26
  @prop_maximum_packet_size 0x27
  @prop_wildcard_subscription_available 0x28
  @prop_subscription_identifier_available 0x29
  @prop_shared_subscription_available 0x2A

  @doc """
  Encode properties map to binary with length prefix.

  Only encodes properties for MQTT 5.0. Returns empty varint (0) for other versions.
  """
  @spec encode(integer(), map()) :: iodata()
  def encode(5, properties) when is_map(properties) and map_size(properties) > 0 do
    props_binary = encode_properties(properties)
    props_len = IO.iodata_length(props_binary)
    [Varint.encode(props_len), props_binary]
  end

  def encode(5, _properties) do
    [<<0>>]
  end

  def encode(_version, _properties) do
    []
  end

  @doc """
  Decode properties from binary.

  Returns `{:ok, properties_map, rest}` or `{:error, reason}`.
  """
  @spec decode(integer(), binary()) :: {:ok, map(), binary()} | {:error, atom()}
  def decode(5, data) do
    case Varint.decode(data) do
      {:ok, 0, rest} ->
        {:ok, %{}, rest}

      {:ok, len, rest} when byte_size(rest) >= len ->
        <<props_bin::binary-size(len), remaining::binary>> = rest

        case decode_properties(props_bin, %{}) do
          {:ok, props} -> {:ok, props, remaining}
          {:error, _} = err -> err
        end

      {:ok, _len, _rest} ->
        {:error, :incomplete}

      :incomplete ->
        {:error, :incomplete}

      {:error, _} = err ->
        err
    end
  end

  def decode(_version, data) do
    {:ok, %{}, data}
  end

  # Encode individual properties
  defp encode_properties(props) do
    Enum.flat_map(props, &encode_property/1)
  end

  defp encode_property({:payload_format_indicator, val}) do
    [<<@prop_payload_format_indicator, bool_byte(val)>>]
  end

  defp encode_property({:message_expiry_interval, val}) when is_integer(val) do
    [<<@prop_message_expiry_interval, val::32-big>>]
  end

  defp encode_property({:content_type, val}) when is_binary(val) do
    [<<@prop_content_type>>, encode_utf8(val)]
  end

  defp encode_property({:response_topic, val}) when is_binary(val) do
    [<<@prop_response_topic>>, encode_utf8(val)]
  end

  defp encode_property({:correlation_data, val}) when is_binary(val) do
    [<<@prop_correlation_data>>, encode_binary(val)]
  end

  defp encode_property({:subscription_identifier, vals}) when is_list(vals) do
    Enum.map(vals, fn val ->
      [<<@prop_subscription_identifier>>, Varint.encode(val)]
    end)
  end

  defp encode_property({:subscription_identifier, val}) when is_integer(val) do
    [<<@prop_subscription_identifier>>, Varint.encode(val)]
  end

  defp encode_property({:session_expiry_interval, val}) when is_integer(val) do
    [<<@prop_session_expiry_interval, val::32-big>>]
  end

  defp encode_property({:assigned_client_identifier, val}) when is_binary(val) do
    [<<@prop_assigned_client_identifier>>, encode_utf8(val)]
  end

  defp encode_property({:server_keep_alive, val}) when is_integer(val) do
    [<<@prop_server_keep_alive, val::16-big>>]
  end

  defp encode_property({:authentication_method, val}) when is_binary(val) do
    [<<@prop_authentication_method>>, encode_utf8(val)]
  end

  defp encode_property({:authentication_data, val}) when is_binary(val) do
    [<<@prop_authentication_data>>, encode_binary(val)]
  end

  defp encode_property({:request_problem_information, val}) do
    [<<@prop_request_problem_information, bool_byte(val)>>]
  end

  defp encode_property({:will_delay_interval, val}) when is_integer(val) do
    [<<@prop_will_delay_interval, val::32-big>>]
  end

  defp encode_property({:request_response_information, val}) do
    [<<@prop_request_response_information, bool_byte(val)>>]
  end

  defp encode_property({:response_information, val}) when is_binary(val) do
    [<<@prop_response_information>>, encode_utf8(val)]
  end

  defp encode_property({:server_reference, val}) when is_binary(val) do
    [<<@prop_server_reference>>, encode_utf8(val)]
  end

  defp encode_property({:reason_string, val}) when is_binary(val) do
    [<<@prop_reason_string>>, encode_utf8(val)]
  end

  defp encode_property({:receive_maximum, val}) when is_integer(val) do
    [<<@prop_receive_maximum, val::16-big>>]
  end

  defp encode_property({:topic_alias_maximum, val}) when is_integer(val) do
    [<<@prop_topic_alias_maximum, val::16-big>>]
  end

  defp encode_property({:topic_alias, val}) when is_integer(val) do
    [<<@prop_topic_alias, val::16-big>>]
  end

  defp encode_property({:maximum_qos, val}) when val in [0, 1, 2] do
    [<<@prop_maximum_qos, val::8>>]
  end

  defp encode_property({:retain_available, val}) do
    [<<@prop_retain_available, bool_byte(val)>>]
  end

  # User properties - key is binary
  defp encode_property({key, val}) when is_binary(key) and is_binary(val) do
    [<<@prop_user_property>>, encode_utf8(key), encode_utf8(val)]
  end

  defp encode_property({:maximum_packet_size, val}) when is_integer(val) do
    [<<@prop_maximum_packet_size, val::32-big>>]
  end

  defp encode_property({:wildcard_subscription_available, val}) do
    [<<@prop_wildcard_subscription_available, bool_byte(val)>>]
  end

  defp encode_property({:subscription_identifier_available, val}) do
    [<<@prop_subscription_identifier_available, bool_byte(val)>>]
  end

  defp encode_property({:shared_subscription_available, val}) do
    [<<@prop_shared_subscription_available, bool_byte(val)>>]
  end

  defp encode_property(_other) do
    []
  end

  # Decode properties from binary
  defp decode_properties(<<>>, props) do
    {:ok, props}
  end

  defp decode_properties(<<@prop_payload_format_indicator, val::8, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :payload_format_indicator, val == 1))
  end

  defp decode_properties(<<@prop_message_expiry_interval, val::32-big, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :message_expiry_interval, val))
  end

  defp decode_properties(<<@prop_content_type, rest::binary>>, props) do
    with {:ok, val, rest2} <- decode_utf8(rest) do
      decode_properties(rest2, Map.put(props, :content_type, val))
    end
  end

  defp decode_properties(<<@prop_response_topic, rest::binary>>, props) do
    with {:ok, val, rest2} <- decode_utf8(rest) do
      decode_properties(rest2, Map.put(props, :response_topic, val))
    end
  end

  defp decode_properties(<<@prop_correlation_data, rest::binary>>, props) do
    with {:ok, val, rest2} <- decode_binary(rest) do
      decode_properties(rest2, Map.put(props, :correlation_data, val))
    end
  end

  defp decode_properties(<<@prop_subscription_identifier, rest::binary>>, props) do
    with {:ok, val, rest2} <- Varint.decode(rest) do
      existing = Map.get(props, :subscription_identifier)

      new_val =
        case existing do
          nil -> val
          list when is_list(list) -> list ++ [val]
          single -> [single, val]
        end

      decode_properties(rest2, Map.put(props, :subscription_identifier, new_val))
    end
  end

  defp decode_properties(<<@prop_session_expiry_interval, val::32-big, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :session_expiry_interval, val))
  end

  defp decode_properties(<<@prop_assigned_client_identifier, rest::binary>>, props) do
    with {:ok, val, rest2} <- decode_utf8(rest) do
      decode_properties(rest2, Map.put(props, :assigned_client_identifier, val))
    end
  end

  defp decode_properties(<<@prop_server_keep_alive, val::16-big, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :server_keep_alive, val))
  end

  defp decode_properties(<<@prop_authentication_method, rest::binary>>, props) do
    with {:ok, val, rest2} <- decode_utf8(rest) do
      decode_properties(rest2, Map.put(props, :authentication_method, val))
    end
  end

  defp decode_properties(<<@prop_authentication_data, rest::binary>>, props) do
    with {:ok, val, rest2} <- decode_binary(rest) do
      decode_properties(rest2, Map.put(props, :authentication_data, val))
    end
  end

  defp decode_properties(<<@prop_request_problem_information, val::8, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :request_problem_information, val == 1))
  end

  defp decode_properties(<<@prop_will_delay_interval, val::32-big, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :will_delay_interval, val))
  end

  defp decode_properties(<<@prop_request_response_information, val::8, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :request_response_information, val == 1))
  end

  defp decode_properties(<<@prop_response_information, rest::binary>>, props) do
    with {:ok, val, rest2} <- decode_utf8(rest) do
      decode_properties(rest2, Map.put(props, :response_information, val))
    end
  end

  defp decode_properties(<<@prop_server_reference, rest::binary>>, props) do
    with {:ok, val, rest2} <- decode_utf8(rest) do
      decode_properties(rest2, Map.put(props, :server_reference, val))
    end
  end

  defp decode_properties(<<@prop_reason_string, rest::binary>>, props) do
    with {:ok, val, rest2} <- decode_utf8(rest) do
      decode_properties(rest2, Map.put(props, :reason_string, val))
    end
  end

  defp decode_properties(<<@prop_receive_maximum, val::16-big, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :receive_maximum, val))
  end

  defp decode_properties(<<@prop_topic_alias_maximum, val::16-big, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :topic_alias_maximum, val))
  end

  defp decode_properties(<<@prop_topic_alias, val::16-big, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :topic_alias, val))
  end

  defp decode_properties(<<@prop_maximum_qos, val::8, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :maximum_qos, val))
  end

  defp decode_properties(<<@prop_retain_available, val::8, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :retain_available, val == 1))
  end

  defp decode_properties(<<@prop_user_property, rest::binary>>, props) do
    with {:ok, key, rest2} <- decode_utf8(rest),
         {:ok, val, rest3} <- decode_utf8(rest2) do
      decode_properties(rest3, Map.put(props, key, val))
    end
  end

  defp decode_properties(<<@prop_maximum_packet_size, val::32-big, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :maximum_packet_size, val))
  end

  defp decode_properties(<<@prop_wildcard_subscription_available, val::8, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :wildcard_subscription_available, val == 1))
  end

  defp decode_properties(<<@prop_subscription_identifier_available, val::8, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :subscription_identifier_available, val == 1))
  end

  defp decode_properties(<<@prop_shared_subscription_available, val::8, rest::binary>>, props) do
    decode_properties(rest, Map.put(props, :shared_subscription_available, val == 1))
  end

  defp decode_properties(_invalid, _props) do
    {:error, :invalid_property}
  end

  # Helper functions
  defp bool_byte(true), do: 1
  defp bool_byte(false), do: 0
  defp bool_byte(1), do: 1
  defp bool_byte(0), do: 0

  defp encode_utf8(str) when is_binary(str) do
    <<byte_size(str)::16-big, str::binary>>
  end

  defp encode_binary(bin) when is_binary(bin) do
    <<byte_size(bin)::16-big, bin::binary>>
  end

  defp decode_utf8(<<len::16-big, str::binary-size(len), rest::binary>>) do
    {:ok, str, rest}
  end

  defp decode_utf8(_) do
    {:error, :incomplete}
  end

  defp decode_binary(<<len::16-big, bin::binary-size(len), rest::binary>>) do
    {:ok, bin, rest}
  end

  defp decode_binary(_) do
    {:error, :incomplete}
  end
end
