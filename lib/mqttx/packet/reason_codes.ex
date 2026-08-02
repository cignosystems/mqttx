defmodule MqttX.Packet.ReasonCodes do
  @moduledoc """
  Named constants for MQTT reason codes, so protocol code reads by name
  instead of hex literal.

  Covers the MQTT 5.0 reason codes (§2.4) and MQTT 3.1.1 CONNACK return
  codes (§3.2.2.3) this library sends. The full v5 table lives in the spec;
  add codes here as they gain call sites rather than mirroring the whole
  table (an earlier complete-table module ended up as dead code).
  """

  # MQTT 3.1.1 CONNACK return codes (§3.2.2.3) — a different namespace from
  # the v5 reason codes below, hence the v3_ prefix.
  def v3_unacceptable_protocol_version, do: 0x01
  def v3_identifier_rejected, do: 0x02

  # MQTT 5.0 reason codes (§2.4)
  def success, do: 0x00
  def disconnect_with_will_message, do: 0x04
  def continue_authentication, do: 0x18
  def unspecified_error, do: 0x80
  def protocol_error, do: 0x82
  def unsupported_protocol_version, do: 0x84
  def bad_authentication_method, do: 0x8C
  def session_taken_over, do: 0x8E
  def packet_identifier_not_found, do: 0x92
  def receive_maximum_exceeded, do: 0x93
  def topic_alias_invalid, do: 0x94
  def packet_too_large, do: 0x95
  def message_rate_too_high, do: 0x96
  def quota_exceeded, do: 0x97

  @doc "§2.4: codes 0x80 and above indicate failure."
  defguard is_error_code(code) when is_integer(code) and code >= 0x80
end
