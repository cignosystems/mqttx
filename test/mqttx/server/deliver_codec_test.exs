defmodule MqttX.Server.DeliverCodecTest do
  @moduledoc """
  `MqttX.Server.deliver/4` with a `:codec`: the term is encoded and the
  message says what the bytes are (`content_type`), the way a client's
  publish with a codec does.
  """
  use ExUnit.Case, async: false

  @moduletag :json

  alias MqttX.Test.ClusterBroker
  alias MqttX.Test.ForwardingHandler

  test "a term delivered with a codec arrives encoded, with its content type" do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    name = :"codec_#{port}"
    {:ok, server, owner} = ClusterBroker.start_listener(name, port)

    on_exit(fn ->
      ThousandIsland.stop(server)
      Process.exit(owner, :kill)
    end)

    {:ok, client} =
      MqttX.Client.connect(
        host: "127.0.0.1",
        port: port,
        client_id: "codec-sub",
        protocol_version: 5,
        await_connect: true,
        handler: ForwardingHandler,
        handler_state: %{pid: self()}
      )

    {:ok, [0]} = MqttX.Client.subscribe(client, "j/#", qos: 0)

    assert {:ok, 1} =
             MqttX.Server.deliver(name, "j/1", %{"a" => 1}, %{qos: 0, codec: MqttX.Payload.JSON})

    assert_receive {:mqtt_event, :message, {["j", "1"], ~s({"a":1}), packet}}, 2_000
    assert packet.properties.content_type == "application/json"

    # A term the codec cannot encode is refused, not sent
    assert {:error, _reason} =
             MqttX.Server.deliver(name, "j/2", {:not, :json}, %{qos: 0, codec: MqttX.Payload.JSON})

    refute_receive {:mqtt_event, :message, {["j", "2"], _, _}}, 200
    MqttX.Client.disconnect(client)
  end
end
