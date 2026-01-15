defmodule MqttX.Packet.Types do
  @moduledoc """
  MQTT packet type constants, reason codes, and property identifiers.

  Supports MQTT 3.1, 3.1.1, and 5.0 protocols.
  """

  # Protocol versions
  @mqtt_v3 3
  @mqtt_v311 4
  @mqtt_v5 5

  # Protocol names
  @protocol_name_3 "MQIsdp"
  @protocol_name "MQTT"

  # Packet type codes (upper 4 bits of fixed header)
  @connect 1
  @connack 2
  @publish 3
  @puback 4
  @pubrec 5
  @pubrel 6
  @pubcomp 7
  @subscribe 8
  @suback 9
  @unsubscribe 10
  @unsuback 11
  @pingreq 12
  @pingresp 13
  @disconnect 14
  @auth 15

  # Maximum values
  @max_packet_size 268_435_455
  @max_varint 268_435_455

  # MQTT 5.0 Reason Codes (used)
  @rc_success 0x00
  @rc_unsupported_protocol 0x84
  @rc_client_id_not_valid 0x85
  @rc_bad_username_password 0x86
  @rc_not_authorized 0x87

  # MQTT 5.0 Reason Codes - complete reference
  @reason_codes %{
    success: 0x00,
    normal_disconnect: 0x00,
    granted_qos_0: 0x00,
    granted_qos_1: 0x01,
    granted_qos_2: 0x02,
    disconnect_with_will: 0x04,
    no_matching_subscribers: 0x10,
    no_subscription_existed: 0x11,
    continue_auth: 0x18,
    reauthenticate: 0x19,
    unspecified_error: 0x80,
    malformed_packet: 0x81,
    protocol_error: 0x82,
    implementation_error: 0x83,
    unsupported_protocol: 0x84,
    client_id_not_valid: 0x85,
    bad_username_password: 0x86,
    not_authorized: 0x87,
    server_unavailable: 0x88,
    server_busy: 0x89,
    banned: 0x8A,
    server_shutting_down: 0x8B,
    bad_auth_method: 0x8C,
    keepalive_timeout: 0x8D,
    session_taken_over: 0x8E,
    topic_filter_invalid: 0x8F,
    topic_name_invalid: 0x90,
    packet_id_in_use: 0x91,
    packet_id_not_found: 0x92,
    receive_max_exceeded: 0x93,
    topic_alias_invalid: 0x94,
    packet_too_large: 0x95,
    message_rate_too_high: 0x96,
    quota_exceeded: 0x97,
    administrative_action: 0x98,
    payload_format_invalid: 0x99,
    retain_not_supported: 0x9A,
    qos_not_supported: 0x9B,
    use_another_server: 0x9C,
    server_moved: 0x9D,
    shared_subs_not_supported: 0x9E,
    connection_rate_exceeded: 0x9F,
    max_connect_time: 0xA0,
    subscription_ids_not_supported: 0xA1,
    wildcard_subs_not_supported: 0xA2
  }

  # MQTT 5.0 Property Identifiers
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

  # Public accessors for constants
  def mqtt_v3, do: @mqtt_v3
  def mqtt_v311, do: @mqtt_v311
  def mqtt_v5, do: @mqtt_v5

  def protocol_name_3, do: @protocol_name_3
  def protocol_name, do: @protocol_name

  def connect, do: @connect
  def connack, do: @connack
  def publish, do: @publish
  def puback, do: @puback
  def pubrec, do: @pubrec
  def pubrel, do: @pubrel
  def pubcomp, do: @pubcomp
  def subscribe, do: @subscribe
  def suback, do: @suback
  def unsubscribe, do: @unsubscribe
  def unsuback, do: @unsuback
  def pingreq, do: @pingreq
  def pingresp, do: @pingresp
  def disconnect, do: @disconnect
  def auth, do: @auth

  def max_packet_size, do: @max_packet_size
  def max_varint, do: @max_varint

  # Reason code accessors
  def rc_success, do: @rc_success
  def rc_bad_username_password, do: @rc_bad_username_password
  def rc_not_authorized, do: @rc_not_authorized
  def rc_unsupported_protocol, do: @rc_unsupported_protocol
  def rc_client_id_not_valid, do: @rc_client_id_not_valid

  @doc """
  Get all MQTT 5.0 reason codes as a map.
  """
  def reason_codes, do: @reason_codes

  @doc """
  Get reason code by name.
  """
  def reason_code(name), do: Map.get(@reason_codes, name)

  # Property ID accessors
  def prop_payload_format_indicator, do: @prop_payload_format_indicator
  def prop_message_expiry_interval, do: @prop_message_expiry_interval
  def prop_content_type, do: @prop_content_type
  def prop_response_topic, do: @prop_response_topic
  def prop_correlation_data, do: @prop_correlation_data
  def prop_subscription_identifier, do: @prop_subscription_identifier
  def prop_session_expiry_interval, do: @prop_session_expiry_interval
  def prop_assigned_client_identifier, do: @prop_assigned_client_identifier
  def prop_server_keep_alive, do: @prop_server_keep_alive
  def prop_authentication_method, do: @prop_authentication_method
  def prop_authentication_data, do: @prop_authentication_data
  def prop_request_problem_information, do: @prop_request_problem_information
  def prop_will_delay_interval, do: @prop_will_delay_interval
  def prop_request_response_information, do: @prop_request_response_information
  def prop_response_information, do: @prop_response_information
  def prop_server_reference, do: @prop_server_reference
  def prop_reason_string, do: @prop_reason_string
  def prop_receive_maximum, do: @prop_receive_maximum
  def prop_topic_alias_maximum, do: @prop_topic_alias_maximum
  def prop_topic_alias, do: @prop_topic_alias
  def prop_maximum_qos, do: @prop_maximum_qos
  def prop_retain_available, do: @prop_retain_available
  def prop_user_property, do: @prop_user_property
  def prop_maximum_packet_size, do: @prop_maximum_packet_size
  def prop_wildcard_subscription_available, do: @prop_wildcard_subscription_available
  def prop_subscription_identifier_available, do: @prop_subscription_identifier_available
  def prop_shared_subscription_available, do: @prop_shared_subscription_available

  @doc """
  Convert packet type code to atom.
  """
  @spec type_to_atom(integer()) :: atom()
  def type_to_atom(@connect), do: :connect
  def type_to_atom(@connack), do: :connack
  def type_to_atom(@publish), do: :publish
  def type_to_atom(@puback), do: :puback
  def type_to_atom(@pubrec), do: :pubrec
  def type_to_atom(@pubrel), do: :pubrel
  def type_to_atom(@pubcomp), do: :pubcomp
  def type_to_atom(@subscribe), do: :subscribe
  def type_to_atom(@suback), do: :suback
  def type_to_atom(@unsubscribe), do: :unsubscribe
  def type_to_atom(@unsuback), do: :unsuback
  def type_to_atom(@pingreq), do: :pingreq
  def type_to_atom(@pingresp), do: :pingresp
  def type_to_atom(@disconnect), do: :disconnect
  def type_to_atom(@auth), do: :auth
  def type_to_atom(_), do: :unknown

  @doc """
  Convert packet type atom to code.
  """
  @spec atom_to_type(atom()) :: integer()
  def atom_to_type(:connect), do: @connect
  def atom_to_type(:connack), do: @connack
  def atom_to_type(:publish), do: @publish
  def atom_to_type(:puback), do: @puback
  def atom_to_type(:pubrec), do: @pubrec
  def atom_to_type(:pubrel), do: @pubrel
  def atom_to_type(:pubcomp), do: @pubcomp
  def atom_to_type(:subscribe), do: @subscribe
  def atom_to_type(:suback), do: @suback
  def atom_to_type(:unsubscribe), do: @unsubscribe
  def atom_to_type(:unsuback), do: @unsuback
  def atom_to_type(:pingreq), do: @pingreq
  def atom_to_type(:pingresp), do: @pingresp
  def atom_to_type(:disconnect), do: @disconnect
  def atom_to_type(:auth), do: @auth

  @doc """
  Check if protocol version is valid.
  """
  @spec valid_version?(integer()) :: boolean()
  def valid_version?(@mqtt_v3), do: true
  def valid_version?(@mqtt_v311), do: true
  def valid_version?(@mqtt_v5), do: true
  def valid_version?(_), do: false

  @doc """
  Get protocol name for version.
  """
  @spec protocol_name_for_version(integer()) :: binary()
  def protocol_name_for_version(@mqtt_v3), do: @protocol_name_3
  def protocol_name_for_version(_), do: @protocol_name
end
