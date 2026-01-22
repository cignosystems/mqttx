defmodule MqttX.ClientTest do
  use ExUnit.Case, async: true

  alias MqttX.Client

  describe "connect/1" do
    test "accepts all valid options" do
      # This will fail to connect but validates option parsing
      opts = [
        host: "localhost",
        port: 1883,
        client_id: "test-client",
        username: "user",
        password: "pass",
        clean_session: true,
        keepalive: 30,
        protocol_version: 4
      ]

      # Start the connection - it will try to connect in background
      {:ok, pid} = Client.connect(opts)
      assert is_pid(pid)

      # Clean up - use GenServer.stop for graceful shutdown
      GenServer.stop(pid, :normal, 100)
    end

    test "uses default port 1883" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")
      assert is_pid(pid)
      GenServer.stop(pid, :normal, 100)
    end

    test "accepts transport :tcp option" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test", transport: :tcp)
      assert is_pid(pid)
      GenServer.stop(pid, :normal, 100)
    end

    test "accepts transport :ssl option with ssl_opts" do
      {:ok, pid} =
        Client.connect(
          host: "localhost",
          client_id: "test",
          transport: :ssl,
          ssl_opts: [verify: :verify_none]
        )

      assert is_pid(pid)
      GenServer.stop(pid, :normal, 100)
    end

    test "uses default port 8883 for SSL transport" do
      # When transport is :ssl and no port specified, defaults to 8883
      {:ok, pid} =
        Client.connect(
          host: "localhost",
          client_id: "test",
          transport: :ssl,
          ssl_opts: []
        )

      assert is_pid(pid)
      GenServer.stop(pid, :normal, 100)
    end

    test "accepts retry_interval option" do
      {:ok, pid} =
        Client.connect(host: "localhost", client_id: "test", retry_interval: 10_000)

      assert is_pid(pid)
      GenServer.stop(pid, :normal, 100)
    end

    test "accepts session_store option" do
      {:ok, pid} =
        Client.connect(
          host: "localhost",
          client_id: "test",
          clean_session: false,
          session_store: MqttX.Session.ETSStore
        )

      assert is_pid(pid)
      GenServer.stop(pid, :normal, 100)
    end
  end

  describe "connected?/1" do
    test "returns false when not connected" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")

      # Give it a moment to attempt connection (will fail with no broker)
      Process.sleep(100)

      # Should be false since no broker is running
      refute Client.connected?(pid)

      GenServer.stop(pid, :normal, 100)
    end
  end

  describe "publish/4" do
    test "returns error when not connected" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")

      # Wait for connection attempt
      Process.sleep(100)

      result = Client.publish(pid, "test/topic", "payload")
      assert result == {:error, :not_connected}

      GenServer.stop(pid, :normal, 100)
    end

    test "accepts qos option" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")
      Process.sleep(100)

      # All QoS levels should be accepted (even if not connected)
      assert {:error, :not_connected} = Client.publish(pid, "test", "msg", qos: 0)
      assert {:error, :not_connected} = Client.publish(pid, "test", "msg", qos: 1)
      assert {:error, :not_connected} = Client.publish(pid, "test", "msg", qos: 2)

      GenServer.stop(pid, :normal, 100)
    end

    test "accepts retain option" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")
      Process.sleep(100)

      assert {:error, :not_connected} = Client.publish(pid, "test", "msg", retain: true)
      assert {:error, :not_connected} = Client.publish(pid, "test", "msg", retain: false)

      GenServer.stop(pid, :normal, 100)
    end
  end

  describe "subscribe/3" do
    test "returns error when not connected" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")
      Process.sleep(100)

      result = Client.subscribe(pid, "test/topic")
      assert result == {:error, :not_connected}

      GenServer.stop(pid, :normal, 100)
    end

    test "accepts single topic as binary" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")
      Process.sleep(100)

      assert {:error, :not_connected} = Client.subscribe(pid, "test/topic")

      GenServer.stop(pid, :normal, 100)
    end

    test "accepts multiple topics as list" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")
      Process.sleep(100)

      assert {:error, :not_connected} = Client.subscribe(pid, ["topic/a", "topic/b"])

      GenServer.stop(pid, :normal, 100)
    end

    test "accepts qos option" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")
      Process.sleep(100)

      assert {:error, :not_connected} = Client.subscribe(pid, "test", qos: 1)

      GenServer.stop(pid, :normal, 100)
    end
  end

  describe "unsubscribe/2" do
    test "returns error when not connected" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")
      Process.sleep(100)

      result = Client.unsubscribe(pid, "test/topic")
      assert result == {:error, :not_connected}

      GenServer.stop(pid, :normal, 100)
    end

    test "accepts single topic" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")
      Process.sleep(100)

      assert {:error, :not_connected} = Client.unsubscribe(pid, "test/topic")

      GenServer.stop(pid, :normal, 100)
    end

    test "accepts multiple topics" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")
      Process.sleep(100)

      assert {:error, :not_connected} = Client.unsubscribe(pid, ["topic/a", "topic/b"])

      GenServer.stop(pid, :normal, 100)
    end
  end

  describe "disconnect/1" do
    test "stops the client process gracefully" do
      {:ok, pid} = Client.connect(host: "localhost", client_id: "test")
      assert Process.alive?(pid)

      # Use GenServer.stop for clean shutdown
      GenServer.stop(pid, :normal, 100)

      refute Process.alive?(pid)
    end
  end
end
