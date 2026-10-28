defmodule MqttX.Packet.Utf8CheckTest do
  @moduledoc """
  The UTF-8 rule for strings on the wire (§1.5.4): well-formed, no U+0000,
  no surrogates. The codec and the properties encoder check ASCII a word at
  a time before handing the rest to the runtime; the result must be the
  runtime's, whatever the string and wherever the offending byte is.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MqttX.Packet.{Codec, Properties}

  defp reference_ok?(string),
    do: not String.contains?(string, <<0>>) and :unicode.characters_to_binary(string) == string

  @pieces [
    "a",
    "b",
    "c",
    "d",
    "e",
    "f",
    "g",
    <<0>>,
    "é",
    "✓",
    "😀",
    <<0xFF>>,
    <<0xED, 0xA0, 0x80>>
  ]

  defp connect(username) do
    %{
      type: :connect,
      protocol_version: 5,
      client_id: "utf8",
      username: username,
      password: nil,
      will: nil,
      clean_session: true,
      keep_alive: 0,
      properties: %{}
    }
  end

  # A v5 CONNECT with `client_id` as its client identifier, byte for byte
  defp connect_bytes(client_id) do
    variable = <<0, 4, "MQTT", 5, 0x02, 0::16, 0, byte_size(client_id)::16, client_id::binary>>
    <<0x10, byte_size(variable), variable::binary>>
  end

  property "encoding a string agrees with the runtime's validator" do
    check all(pieces <- list_of(member_of(@pieces), max_length: 20), max_runs: 3_000) do
      string = IO.iodata_to_binary(pieces)
      ok? = reference_ok?(string)

      # The codec's own strings (CONNECT username) and a property's
      # (content type) take different paths to the same rule
      assert match?({:ok, _}, Codec.encode(5, connect(string))) == ok?, inspect(string)

      publish = %{
        type: :publish,
        topic: "t",
        payload: "",
        qos: 0,
        properties: %{content_type: string}
      }

      assert match?({:ok, _}, Codec.encode(5, publish)) == ok?, inspect(string)
    end
  end

  test "decoding a string: a zero byte or a bad sequence anywhere in it is malformed" do
    for prefix <- 0..9, bad <- [<<0>>, <<0xFF>>, <<0xED, 0xA0, 0x80>>] do
      client_id = :binary.copy("a", prefix) <> bad <> "zz"
      assert Codec.decode(5, connect_bytes(client_id)) == {:error, :malformed_packet}

      property = <<byte_size(client_id)::16, client_id::binary>>
      props = <<byte_size(property) + 1, 0x03, property::binary>>
      assert Properties.decode(5, props, :publish) == {:error, :malformed_packet}
    end

    for prefix <- 0..9 do
      client_id = :binary.copy("a", prefix) <> "é✓😀" <> :binary.copy("b", prefix)
      assert {:ok, {%{client_id: ^client_id}, <<>>}} = Codec.decode(5, connect_bytes(client_id))
    end
  end
end
