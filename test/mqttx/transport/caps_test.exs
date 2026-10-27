defmodule MqttX.Transport.CapsTest do
  @moduledoc """
  The caps a client runs into: filters per session (`:max_subscriptions`,
  SUBACK 0x97 past it) and sessions per listener (`:max_sessions`, CONNACK
  0x97 for a new one).
  """
  use ExUnit.Case, async: true

  alias MqttX.Packet.Codec
  alias MqttX.Server.SessionStore
  alias MqttX.Transport.Handler, as: Proto

  defmodule Handler do
    use MqttX.Server

    def init(_opts), do: %{}
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}
    def handle_subscribe(topics, state), do: {:ok, Enum.map(topics, & &1.qos), state}
    def handle_disconnect(_reason, _state), do: :ok
  end

  defp init(transport_opts, sessions) do
    table = MqttX.Server.RetainedStore.new_table()
    test = self()
    send_fn = fn data -> send(test, {:sent, data}) end
    opts = [transport_opts: transport_opts]
    {:ok, state} = Proto.init(Handler, opts, table, nil, send_fn, sessions)
    state
  end

  defp encode(version, packet), do: elem(Codec.encode(version, packet), 1)

  defp sent(version) do
    assert_receive {:sent, data}
    {:ok, {packet, <<>>}} = Codec.decode(version, IO.iodata_to_binary(data))
    packet
  end

  defp connect(state, client_id, version \\ 5) do
    connect =
      encode(version, %{
        type: :connect,
        protocol_version: version,
        client_id: client_id,
        username: nil,
        password: nil,
        will: nil,
        clean_session: false,
        keep_alive: 60,
        properties: %{session_expiry_interval: 300}
      })

    {result, connack} = {Proto.handle_data(connect, state), sent(version)}
    {result, connack}
  end

  defp subscribe(state, packet_id, filters, version \\ 5) do
    subscribe =
      encode(version, %{
        type: :subscribe,
        packet_id: packet_id,
        topics: Enum.map(filters, &%{topic: &1, qos: 0}),
        properties: %{}
      })

    {:ok, state} = Proto.handle_data(subscribe, state)
    {state, sent(version)}
  end

  describe ":max_subscriptions" do
    test "a new filter past the cap is refused with 0x97; existing ones may be changed" do
      state = init(%{max_subscriptions: 2}, SessionStore.new())
      {{:ok, state}, %{type: :connack, reason_code: 0}} = connect(state, "caps-subs")

      {state, suback} = subscribe(state, 1, ["a", "b", "c"])
      assert suback.acks == [{:ok, 0}, {:ok, 0}, {:error, 0x97}]

      # Re-subscribing a filter the session has does not count; a new one still does
      {_state, suback} = subscribe(state, 2, ["a", "d"])
      assert suback.acks == [{:ok, 0}, {:error, 0x97}]
    end

    test "a 3.1.1 client gets the only failure code it has, 0x80" do
      state = init(%{max_subscriptions: 1}, SessionStore.new())
      {{:ok, state}, %{type: :connack}} = connect(state, "caps-subs-v4", 4)
      {_state, suback} = subscribe(state, 1, ["a", "b"], 4)
      assert suback.acks == [{:ok, 0}, {:error, 0x80}]
    end

    test ":infinity lifts the cap" do
      state = init(%{max_subscriptions: :infinity}, SessionStore.new())
      {{:ok, state}, _} = connect(state, "caps-subs-inf")
      {_state, suback} = subscribe(state, 1, Enum.map(1..50, &"f/#{&1}"))
      assert Enum.all?(suback.acks, &match?({:ok, 0}, &1))
    end
  end

  describe ":max_sessions" do
    test "a CONNECT needing a new session past the cap is refused with 0x97; a known one is not" do
      sessions = SessionStore.new()

      {{:ok, _state}, %{type: :connack, reason_code: 0}} =
        connect(init(%{max_sessions: 1}, sessions), "caps-first")

      assert {{:close, _, _state}, %{type: :connack, reason_code: 0x97}} =
               connect(init(%{max_sessions: 1}, sessions), "caps-second")

      # The session that exists resumes
      assert {{:ok, _state}, %{type: :connack, reason_code: 0, session_present: true}} =
               connect(init(%{max_sessions: 1}, sessions), "caps-first")
    end
  end
end
