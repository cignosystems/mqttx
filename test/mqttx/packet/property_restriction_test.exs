defmodule MqttX.Packet.PropertyRestrictionTest do
  @moduledoc """
  MQTT 5.0 §2.2.2.2: a Control Packet carrying a property that is not valid
  for its packet type is a Malformed Packet. The codec refuses to decode one
  and refuses to encode one.
  """
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec
  alias MqttX.Packet.Properties

  # Hand-assembled packets: the unrestricted Properties.encode/2 builds the
  # property bytes the restricted codec must reject
  defp props(map), do: IO.iodata_to_binary(Properties.encode(5, map))

  defp with_length(first_byte, body) do
    len = byte_size(body)
    assert len < 128
    <<first_byte, len>> <> body
  end

  defp publish_wire(properties) do
    with_length(0x30, <<0, 1, "t">> <> props(properties) <> "payload")
  end

  defp connack_wire(properties), do: with_length(0x20, <<0, 0>> <> props(properties))

  defp subscribe_wire(properties),
    do: with_length(0x82, <<0, 1>> <> props(properties) <> <<0, 1, "t", 0>>)

  defp puback_wire(properties), do: with_length(0x40, <<0, 1, 0>> <> props(properties))
  defp auth_wire(properties), do: with_length(0xF0, <<0x18>> <> props(properties))
  defp disconnect_wire(properties), do: with_length(0xE0, <<0>> <> props(properties))

  describe "decoding" do
    test "a property the packet type does not define makes it malformed" do
      assert {:error, :malformed_packet} =
               Codec.decode(5, publish_wire(%{session_expiry_interval: 10}))

      assert {:error, :malformed_packet} =
               Codec.decode(5, connack_wire(%{will_delay_interval: 5}))

      assert {:error, :malformed_packet} =
               Codec.decode(5, subscribe_wire(%{message_expiry_interval: 60}))

      assert {:error, :malformed_packet} = Codec.decode(5, puback_wire(%{topic_alias: 3}))
      assert {:error, :malformed_packet} = Codec.decode(5, auth_wire(%{receive_maximum: 10}))
      assert {:error, :malformed_packet} = Codec.decode(5, disconnect_wire(%{maximum_qos: 1}))
    end

    test "properties the packet type defines still decode" do
      assert {:ok, {%{type: :publish, properties: %{topic_alias: 3}}, <<>>}} =
               Codec.decode(5, publish_wire(%{topic_alias: 3, message_expiry_interval: 9}))

      assert {:ok, {%{type: :connack, properties: %{server_keep_alive: 30}}, <<>>}} =
               Codec.decode(5, connack_wire(%{server_keep_alive: 30, maximum_qos: 1}))

      assert {:ok, {%{type: :puback, properties: %{reason_string: "ok"}}, <<>>}} =
               Codec.decode(5, puback_wire(%{reason_string: "ok"}))

      assert {:ok, {%{type: :disconnect, properties: %{session_expiry_interval: 0}}, <<>>}} =
               Codec.decode(
                 5,
                 disconnect_wire(%{session_expiry_interval: 0, server_reference: "x"})
               )
    end

    test "user properties are valid in every packet" do
      user = %{user_properties: [{"k", "v"}]}

      for wire <- [
            publish_wire(user),
            connack_wire(user),
            subscribe_wire(user),
            puback_wire(user),
            auth_wire(Map.put(user, :authentication_method, "m")),
            disconnect_wire(user)
          ] do
        assert {:ok, {%{properties: %{user_properties: [{"k", "v"}]}}, <<>>}} =
                 Codec.decode(5, wire)
      end
    end
  end

  describe "encoding" do
    test "refuses a property the packet type does not define, naming both" do
      assert {:error, {:property_not_allowed, :message_expiry_interval, :subscribe}} =
               Codec.encode(5, %{
                 type: :subscribe,
                 packet_id: 1,
                 topics: [%{topic: "t", qos: 0}],
                 properties: %{message_expiry_interval: 60}
               })

      assert {:error, {:property_not_allowed, :topic_alias, :will}} =
               Codec.encode(5, %{
                 type: :connect,
                 protocol_version: 5,
                 client_id: "c",
                 clean_session: true,
                 keep_alive: 0,
                 username: nil,
                 password: nil,
                 properties: %{},
                 will: %{
                   topic: "w",
                   payload: "",
                   qos: 0,
                   retain: false,
                   properties: %{topic_alias: 1}
                 }
               })

      assert {:error, {:property_not_allowed, :will_delay_interval, :connack}} =
               Codec.encode(5, %{
                 type: :connack,
                 session_present: false,
                 reason_code: 0,
                 properties: %{will_delay_interval: 1}
               })

      assert {:error, {:property_not_allowed, :maximum_qos, :ack}} =
               Codec.encode(5, %{
                 type: :puback,
                 packet_id: 1,
                 reason_code: 0,
                 properties: %{maximum_qos: 1}
               })
    end

    test "the unrestricted two-argument forms are unchanged" do
      bytes = IO.iodata_to_binary(Properties.encode(5, %{maximum_qos: 1, topic_alias: 2}))
      assert {:ok, %{maximum_qos: 1, topic_alias: 2}, <<>>} = Properties.decode(5, bytes)
      assert Properties.disallowed(%{maximum_qos: 1, topic_alias: 2}, :publish) == :maximum_qos
      assert Properties.disallowed(%{"k" => "v", topic_alias: 2}, :publish) == nil
    end
  end
end
