defmodule MqttX.Client.SupervisorTest do
  use ExUnit.Case

  alias MqttX.Client
  alias MqttX.Client.Supervisor, as: ClientSupervisor

  describe "connect_supervised/1" do
    test "starts a supervised connection" do
      {:ok, pid} =
        Client.connect_supervised(
          host: "localhost",
          port: 1883,
          client_id: "sup_test_1"
        )

      assert is_pid(pid)
      assert Process.alive?(pid)

      ClientSupervisor.stop_child(pid)
    end

    test "connection appears in supervisor children" do
      {:ok, pid} =
        Client.connect_supervised(
          host: "localhost",
          client_id: "sup_test_2"
        )

      children = ClientSupervisor.which_children()
      pids = Enum.map(children, fn {_, p, _, _} -> p end)
      assert pid in pids

      ClientSupervisor.stop_child(pid)
    end
  end

  describe "stop_child/1" do
    test "stops a supervised connection" do
      {:ok, pid} =
        Client.connect_supervised(
          host: "localhost",
          client_id: "sup_test_3"
        )

      assert Process.alive?(pid)

      :ok = ClientSupervisor.stop_child(pid)
      refute Process.alive?(pid)
    end
  end

  describe "count/0" do
    test "counts supervised connections" do
      initial = ClientSupervisor.count()
      initial_active = initial.active

      {:ok, pid1} =
        Client.connect_supervised(host: "localhost", client_id: "sup_count_1")

      {:ok, pid2} =
        Client.connect_supervised(host: "localhost", client_id: "sup_count_2")

      count = ClientSupervisor.count()
      assert count.active == initial_active + 2

      ClientSupervisor.stop_child(pid1)
      ClientSupervisor.stop_child(pid2)
    end
  end

  describe "list/0" do
    test "lists registered connections" do
      {:ok, pid} =
        Client.connect_supervised(
          host: "localhost",
          client_id: "sup_list_1"
        )

      connections = Client.list()
      found = Enum.find(connections, fn {id, _, _} -> id == "sup_list_1" end)
      assert found != nil
      {_, found_pid, meta} = found
      assert found_pid == pid
      assert meta.host == "localhost"

      ClientSupervisor.stop_child(pid)
    end
  end

  describe "whereis/1" do
    test "looks up connection by client_id" do
      {:ok, pid} =
        Client.connect_supervised(
          host: "localhost",
          port: 1883,
          client_id: "sup_whereis_1"
        )

      assert {^pid, meta} = Client.whereis("sup_whereis_1")
      assert meta.host == "localhost"
      assert meta.port == 1883

      ClientSupervisor.stop_child(pid)
    end

    test "returns nil for unknown client_id" do
      assert Client.whereis("nonexistent_client") == nil
    end
  end

  describe "registry uniqueness" do
    test "second connection with same client_id gets different registration" do
      {:ok, pid1} =
        Client.connect_supervised(
          host: "localhost",
          client_id: "sup_unique_1"
        )

      # Second connection with same client_id - Registry will reject duplicate
      {:ok, pid2} =
        Client.connect_supervised(
          host: "localhost",
          client_id: "sup_unique_1"
        )

      assert pid1 != pid2
      # First registration wins
      assert {^pid1, _} = Client.whereis("sup_unique_1")

      ClientSupervisor.stop_child(pid1)
      ClientSupervisor.stop_child(pid2)
    end
  end

  describe "crash recovery" do
    test "supervised connection is restarted after crash" do
      {:ok, pid} =
        Client.connect_supervised(
          host: "localhost",
          client_id: "sup_crash_1"
        )

      ref = Process.monitor(pid)

      # Kill the process
      Process.exit(pid, :kill)

      # Wait for it to be killed
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000

      # Give the supervisor time to restart
      Process.sleep(100)

      # Supervisor should have restarted a new process
      count = ClientSupervisor.count()
      assert count.active >= 1

      # Clean up any restarted children
      children = ClientSupervisor.which_children()

      Enum.each(children, fn
        {_, child_pid, _, _} when is_pid(child_pid) ->
          ClientSupervisor.stop_child(child_pid)

        _ ->
          :ok
      end)
    end
  end
end
