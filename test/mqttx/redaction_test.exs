defmodule MqttX.RedactionTest do
  @moduledoc """
  Crash reports and `:sys.get_status/1` show a process's state and its last
  message. Neither may carry a password, proxy credentials, TLS key
  material or raw socket bytes — on the client, and on both TCP transports
  of the broker (where the CONNECT, password included, is kept during
  enhanced authentication).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MqttX.Transport.Handler, as: Proto

  test "the client's status shows no password, proxy secret, key or bytes" do
    capture_log(fn ->
      {:ok, pid} =
        MqttX.Client.connect(
          host: "127.0.0.1",
          port: 1,
          client_id: "redacted",
          username: "user",
          password: "s3cret-pass",
          proxy: [host: "127.0.0.1", port: 1, auth: {"proxy-user", "s3cret-proxy"}],
          transport: :ssl,
          ssl_opts: [key: {:RSAPrivateKey, "s3cret-key"}, password: "s3cret-key-pass"]
        )

      shown = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)
      GenServer.stop(pid)

      refute shown =~ "s3cret"
      assert shown =~ "[redacted]"
      assert shown =~ "proxy-user"
    end)
  end

  test "the broker's connection state shows no password, and a socket message no bytes" do
    table = MqttX.Server.RetainedStore.new_table()
    {:ok, state} = Proto.init(MqttX.Test.ClusterBroker, [], table, nil, fn _ -> :ok end)

    # As it is mid enhanced authentication, the CONNECT waiting for its CONNACK
    pending = %{packet: %{client_id: "c", username: "u", password: "s3cret"}, start_time: 0}
    state = %{state | pending_connect: pending, buffer: "CONNECT s3cret"}

    for status <- [
          MqttX.Transport.ThousandIsland.Handler.format_status(%{
            state: {:socket, state},
            message: {:tcp, :port, "s3cret bytes"}
          }),
          MqttX.Transport.Ranch.Protocol.format_status(%{
            state: %{proto: state, socket: :s, transport: :t, draining: false, closed: false},
            message: {:ssl, :port, "s3cret bytes"}
          })
        ] do
      shown = inspect(status, limit: :infinity, printable_limit: :infinity)
      refute shown =~ "s3cret"
      assert shown =~ "[redacted]"
      assert shown =~ "{:redacted, 12}"
    end
  end
end
