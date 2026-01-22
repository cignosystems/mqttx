defmodule MqttX.Server.ServerTest do
  use ExUnit.Case, async: true

  describe "behaviour callbacks" do
    test "defines required callbacks" do
      callbacks = MqttX.Server.behaviour_info(:callbacks)

      assert {:init, 1} in callbacks
      assert {:handle_connect, 3} in callbacks
      assert {:handle_publish, 4} in callbacks
      assert {:handle_subscribe, 2} in callbacks
      assert {:handle_disconnect, 2} in callbacks
    end

    test "defines optional callbacks" do
      optional = MqttX.Server.behaviour_info(:optional_callbacks)

      assert {:handle_unsubscribe, 2} in optional
      assert {:handle_puback, 2} in optional
      assert {:handle_info, 2} in optional
    end
  end

  describe "use MqttX.Server" do
    defmodule TestHandler do
      use MqttX.Server

      @impl true
      def init(opts), do: opts

      @impl true
      def handle_connect(_client_id, _credentials, state), do: {:ok, state}

      @impl true
      def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}

      @impl true
      def handle_subscribe(topics, state) do
        qos_list = Enum.map(topics, fn _ -> 0 end)
        {:ok, qos_list, state}
      end

      @impl true
      def handle_disconnect(_reason, _state), do: :ok
    end

    test "provides default handle_unsubscribe implementation" do
      assert {:ok, :state} = TestHandler.handle_unsubscribe(["topic"], :state)
    end

    test "provides default handle_puback implementation" do
      assert {:ok, :state} = TestHandler.handle_puback(123, :state)
    end

    test "provides default handle_info implementation" do
      assert {:ok, :state} = TestHandler.handle_info(:message, :state)
    end
  end

  describe "custom handler with overrides" do
    defmodule CustomHandler do
      use MqttX.Server

      @impl true
      def init(opts), do: Map.new(opts)

      @impl true
      def handle_connect(client_id, _credentials, state) do
        {:ok, Map.put(state, :client_id, client_id)}
      end

      @impl true
      def handle_publish(topic, payload, _opts, state) do
        messages = Map.get(state, :messages, [])
        {:ok, Map.put(state, :messages, [{topic, payload} | messages])}
      end

      @impl true
      def handle_subscribe(topics, state) do
        qos_list = Enum.map(topics, fn t -> Map.get(t, :qos, 0) end)
        {:ok, qos_list, Map.put(state, :subscribed, true)}
      end

      @impl true
      def handle_disconnect(_reason, _state), do: :ok

      @impl true
      def handle_unsubscribe(topics, state) do
        {:ok, Map.put(state, :unsubscribed, topics)}
      end

      @impl true
      def handle_info({:custom, data}, state) do
        {:ok, Map.put(state, :custom_data, data)}
      end

      def handle_info({:publish, topic, payload}, state) do
        {:publish, topic, payload, state}
      end

      def handle_info(_other, state) do
        {:ok, state}
      end
    end

    test "init returns custom state" do
      state = CustomHandler.init(key: "value")
      assert state == %{key: "value"}
    end

    test "handle_connect can modify state" do
      {:ok, state} = CustomHandler.handle_connect("client-123", %{}, %{})
      assert state.client_id == "client-123"
    end

    test "handle_publish accumulates messages" do
      {:ok, state} = CustomHandler.handle_publish(["test"], "payload1", %{}, %{})
      {:ok, state} = CustomHandler.handle_publish(["test"], "payload2", %{}, state)

      assert state.messages == [{["test"], "payload2"}, {["test"], "payload1"}]
    end

    test "handle_subscribe sets subscribed flag" do
      topics = [%{topic: "test", qos: 1}]
      {:ok, qos_list, state} = CustomHandler.handle_subscribe(topics, %{})

      assert qos_list == [1]
      assert state.subscribed == true
    end

    test "handle_unsubscribe can be overridden" do
      {:ok, state} = CustomHandler.handle_unsubscribe(["topic/a"], %{})
      assert state.unsubscribed == ["topic/a"]
    end

    test "handle_info with custom message" do
      {:ok, state} = CustomHandler.handle_info({:custom, "data"}, %{})
      assert state.custom_data == "data"
    end

    test "handle_info can return publish tuple" do
      result = CustomHandler.handle_info({:publish, "topic", "payload"}, %{})
      assert {:publish, "topic", "payload", %{}} = result
    end
  end

  describe "type definitions" do
    test "client_id is binary" do
      # This is a compile-time type, just verify module compiles with types
      assert Code.ensure_loaded?(MqttX.Server)
    end

    test "credentials contains username and password" do
      credentials = %{username: "user", password: "pass"}
      assert is_binary(credentials.username)
      assert is_binary(credentials.password)
    end

    test "publish_opts contains expected keys" do
      opts = %{
        qos: 1,
        retain: false,
        dup: false,
        packet_id: 123,
        properties: %{}
      }

      assert opts.qos in [0, 1, 2]
      assert is_boolean(opts.retain)
      assert is_boolean(opts.dup)
      assert is_integer(opts.packet_id)
      assert is_map(opts.properties)
    end
  end
end
