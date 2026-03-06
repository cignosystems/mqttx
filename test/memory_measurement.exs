# Memory Measurement Script
# Run with: mix run test/memory_measurement.exs
#
# Measures actual per-connection memory for MqttX server + client connections.

defmodule MemoryMeasurement do
  @num_clients 500
  @settle_time 2000

  defmodule MinimalHandler do
    use MqttX.Server

    @impl true
    def init(_opts), do: %{}

    @impl true
    def handle_connect(_client_id, _credentials, state), do: {:ok, state}

    @impl true
    def handle_publish(_topic, _payload, _opts, state), do: {:ok, state}

    @impl true
    def handle_subscribe(topics, state) do
      {:ok, Enum.map(topics, fn t -> Map.get(t, :qos, 0) end), state}
    end

    @impl true
    def handle_disconnect(_reason, _state), do: :ok
  end

  def run do
    IO.puts("=== MqttX Per-Connection Memory Measurement ===\n")

    # Get a free port
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    # Force GC and measure baseline
    gc_all()
    Process.sleep(500)
    baseline_memory = :erlang.memory(:total)
    baseline_processes = length(Process.list())

    IO.puts("Baseline: #{format_bytes(baseline_memory)} RAM, #{baseline_processes} processes")

    # Start server
    {:ok, server_pid} =
      MqttX.Server.start_link(
        MinimalHandler,
        [],
        transport: MqttX.Transport.ThousandIsland,
        port: port
      )

    Process.sleep(100)

    gc_all()
    Process.sleep(200)
    server_memory = :erlang.memory(:total)
    server_processes = length(Process.list())

    IO.puts(
      "After server start: #{format_bytes(server_memory)} RAM, #{server_processes} processes"
    )

    IO.puts("Server overhead: #{format_bytes(server_memory - baseline_memory)}\n")

    # Connect clients
    IO.puts("Connecting #{@num_clients} clients...")

    clients =
      Enum.map(1..@num_clients, fn i ->
        {:ok, client} =
          MqttX.Client.connect(
            host: "127.0.0.1",
            port: port,
            client_id: "mem-test-#{i}",
            protocol_version: 4,
            keepalive: 300
          )

        if rem(i, 100) == 0, do: IO.puts("  #{i} connected")
        client
      end)

    # Wait for all connections to settle
    Process.sleep(@settle_time)

    # Verify all connected
    connected_count = Enum.count(clients, &MqttX.Client.connected?/1)
    IO.puts("  #{connected_count}/#{@num_clients} confirmed connected\n")

    # Force GC on all processes and measure
    gc_all()
    Process.sleep(500)
    loaded_memory = :erlang.memory(:total)
    loaded_processes = length(Process.list())

    total_connection_memory = loaded_memory - server_memory
    per_connection = div(total_connection_memory, @num_clients)

    IO.puts(
      "After #{@num_clients} connections: #{format_bytes(loaded_memory)} RAM, #{loaded_processes} processes"
    )

    IO.puts("Connection memory: #{format_bytes(total_connection_memory)} total")
    IO.puts("Per connection: #{format_bytes(per_connection)}")

    IO.puts(
      "Processes per connection: #{Float.round((loaded_processes - server_processes) / @num_clients, 1)}"
    )

    # Measure individual server-side process memory
    IO.puts("\n--- Server-side process memory sample ---")
    # ThousandIsland handler processes should be in the process list
    sample_server_processes(server_pid)

    # Measure individual client process memory
    IO.puts("\n--- Client process memory sample ---")
    sample = Enum.take(clients, 5)

    Enum.each(sample, fn client ->
      case Process.info(client, [:memory, :heap_size, :stack_size, :message_queue_len]) do
        info when is_list(info) ->
          mem = Keyword.get(info, :memory, 0)
          heap = Keyword.get(info, :heap_size, 0)
          IO.puts("  Client PID #{inspect(client)}: #{format_bytes(mem)} (heap: #{heap} words)")

        nil ->
          IO.puts("  Client PID #{inspect(client)}: process not alive")
      end
    end)

    # BEAM memory breakdown
    IO.puts("\n--- BEAM memory breakdown ---")
    mem = :erlang.memory()
    IO.puts("  Total:     #{format_bytes(mem[:total])}")
    IO.puts("  Processes: #{format_bytes(mem[:processes])}")
    IO.puts("  ETS:       #{format_bytes(mem[:ets])}")
    IO.puts("  Binary:    #{format_bytes(mem[:binary])}")
    IO.puts("  Code:      #{format_bytes(mem[:code])}")
    IO.puts("  System:    #{format_bytes(mem[:system])}")

    # Process-only memory per connection
    process_memory_per_conn = div(mem[:processes] - baseline_process_memory(), @num_clients)
    IO.puts("\n  Process memory per connection: ~#{format_bytes(process_memory_per_conn)}")

    # Cleanup
    IO.puts("\nCleaning up...")

    Enum.each(clients, fn client ->
      try do
        GenServer.stop(client, :normal, 500)
      catch
        :exit, _ -> :ok
      end
    end)

    Process.sleep(500)
    ThousandIsland.stop(server_pid)

    gc_all()
    Process.sleep(500)
    final_memory = :erlang.memory(:total)

    IO.puts(
      "After cleanup: #{format_bytes(final_memory)} RAM (baseline was #{format_bytes(baseline_memory)})"
    )

    IO.puts("\nDone.")
  end

  defp gc_all do
    Enum.each(Process.list(), fn pid ->
      try do
        :erlang.garbage_collect(pid)
      catch
        _, _ -> :ok
      end
    end)
  end

  defp baseline_process_memory do
    # Approximate: we'll use a rough estimate from before connections
    0
  end

  defp sample_server_processes(server_pid) do
    # Find ThousandIsland connection processes
    children =
      try do
        Supervisor.which_children(server_pid)
      catch
        _, _ -> []
      end

    IO.puts("  Server supervisor children: #{length(children)}")

    # Sample some processes with larger memory (likely connection handlers)
    all_procs =
      Process.list()
      |> Enum.map(fn pid ->
        case Process.info(pid, [:memory, :dictionary, :current_function]) do
          info when is_list(info) ->
            {pid, Keyword.get(info, :memory, 0), Keyword.get(info, :current_function)}

          nil ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn {_, mem, _} -> -mem end)
      |> Enum.take(10)

    IO.puts("  Top 10 processes by memory:")

    Enum.each(all_procs, fn {pid, mem, func} ->
      IO.puts("    #{inspect(pid)}: #{format_bytes(mem)} (#{inspect(func)})")
    end)
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 2)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{Float.round(bytes / 1024, 2)} KB"
  end

  defp format_bytes(bytes) do
    "#{bytes} B"
  end
end

MemoryMeasurement.run()
