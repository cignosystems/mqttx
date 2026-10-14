# Wire codec micro-benchmarks.
#
#     mix run bench/codec.exs
#
# Measures encode (iodata and binary) and decode for representative packets.
# These are per-packet costs on the hot path of every connection; compare
# against `guides/performance.md` and refresh the numbers there when the codec
# changes.

alias MqttX.Packet.Codec

Logger.configure(level: :warning)

publish = fn version, payload_bytes, qos ->
  %{
    type: :publish,
    topic: "sensors/room1/temperature",
    payload: :binary.copy(<<"x">>, payload_bytes),
    qos: qos,
    retain: false,
    dup: false,
    packet_id: if(qos > 0, do: 42, else: nil),
    properties:
      if(version == 5,
        do: %{message_expiry_interval: 60, user_properties: [{"origin", "bench"}]},
        else: %{}
      )
  }
end

connect = %{
  type: :connect,
  protocol_version: 5,
  client_id: "bench-client-0001",
  username: "device",
  password: "secret",
  will: nil,
  clean_session: true,
  keep_alive: 60,
  properties: %{session_expiry_interval: 3600, receive_maximum: 100}
}

subscribe = %{
  type: :subscribe,
  packet_id: 7,
  topics: [
    %{topic: "sensors/+/temperature", qos: 1},
    %{topic: "alerts/#", qos: 2},
    %{topic: "status/room1", qos: 0}
  ],
  properties: %{subscription_identifier: 3}
}

encode! = fn version, packet ->
  {:ok, binary} = Codec.encode(version, packet)
  IO.iodata_to_binary(binary)
end

inputs = %{
  "v4 PUBLISH QoS 0, 100 B" => {4, publish.(4, 100, 0)},
  "v5 PUBLISH QoS 1, 100 B, 2 props" => {5, publish.(5, 100, 1)},
  "v5 PUBLISH QoS 1, 64 KiB" => {5, publish.(5, 65_536, 1)},
  "v5 CONNECT" => {5, connect},
  "v5 SUBSCRIBE, 3 filters" => {5, subscribe}
}

Benchee.run(
  %{
    "encode (iodata, what the socket gets)" => fn {version, packet} ->
      Codec.encode_iodata(version, packet)
    end,
    "encode (binary)" => fn {version, packet} -> Codec.encode(version, packet) end,
    "decode" =>
      {fn {version, binary} -> Codec.decode(version, binary) end,
       before_scenario: fn {version, packet} -> {version, encode!.(version, packet)} end}
  },
  inputs: inputs,
  warmup: 1,
  time: String.to_integer(System.get_env("BENCH_TIME", "3")),
  memory_time: 1,
  print: [configuration: false]
)
