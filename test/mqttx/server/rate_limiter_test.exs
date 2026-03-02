defmodule MqttX.Server.RateLimiterTest do
  use ExUnit.Case, async: true

  alias MqttX.Server.RateLimiter

  setup do
    # Use a long interval so the reset timer doesn't interfere with tests
    limiter = RateLimiter.new(max_connections: 5, max_messages: 10, interval: 60_000)
    on_exit(fn -> RateLimiter.cleanup(limiter) end)
    %{limiter: limiter}
  end

  describe "allow_connection?/1" do
    test "allows connections under limit", %{limiter: limiter} do
      assert :ok = RateLimiter.allow_connection?(limiter)
      assert :ok = RateLimiter.allow_connection?(limiter)
      assert :ok = RateLimiter.allow_connection?(limiter)
    end

    test "rejects connections over limit", %{limiter: limiter} do
      for _ <- 1..5 do
        assert :ok = RateLimiter.allow_connection?(limiter)
      end

      assert {:error, :rate_limited} = RateLimiter.allow_connection?(limiter)
    end

    test "unlimited when max_connections is nil" do
      limiter = RateLimiter.new(max_connections: nil, interval: 60_000)
      on_exit(fn -> RateLimiter.cleanup(limiter) end)

      for _ <- 1..100 do
        assert :ok = RateLimiter.allow_connection?(limiter)
      end
    end
  end

  describe "allow_message?/2" do
    test "allows messages under per-client limit", %{limiter: limiter} do
      for _ <- 1..10 do
        assert :ok = RateLimiter.allow_message?(limiter, "client1")
      end
    end

    test "rejects messages over per-client limit", %{limiter: limiter} do
      for _ <- 1..10 do
        assert :ok = RateLimiter.allow_message?(limiter, "client2")
      end

      assert {:error, :rate_limited} = RateLimiter.allow_message?(limiter, "client2")
    end

    test "per-client limits are independent", %{limiter: limiter} do
      # Exhaust client_a's limit
      for _ <- 1..10 do
        assert :ok = RateLimiter.allow_message?(limiter, "client_a")
      end

      assert {:error, :rate_limited} = RateLimiter.allow_message?(limiter, "client_a")

      # client_b should still have quota
      assert :ok = RateLimiter.allow_message?(limiter, "client_b")
    end

    test "unlimited when max_messages is nil" do
      limiter = RateLimiter.new(max_messages: nil, interval: 60_000)
      on_exit(fn -> RateLimiter.cleanup(limiter) end)

      for _ <- 1..100 do
        assert :ok = RateLimiter.allow_message?(limiter, "client")
      end
    end
  end

  describe "reset/1" do
    test "resets all counters", %{limiter: limiter} do
      # Exhaust connection limit
      for _ <- 1..5 do
        RateLimiter.allow_connection?(limiter)
      end

      assert {:error, :rate_limited} = RateLimiter.allow_connection?(limiter)

      # Exhaust message limit for a client
      for _ <- 1..10 do
        RateLimiter.allow_message?(limiter, "client_reset")
      end

      assert {:error, :rate_limited} = RateLimiter.allow_message?(limiter, "client_reset")

      # Reset
      :ok = RateLimiter.reset(limiter)

      # Should be allowed again
      assert :ok = RateLimiter.allow_connection?(limiter)
      assert :ok = RateLimiter.allow_message?(limiter, "client_reset")
    end
  end

  describe "automatic reset" do
    test "counters reset after interval" do
      # Use a short interval for testing
      limiter = RateLimiter.new(max_connections: 2, max_messages: 3, interval: 100)
      on_exit(fn -> RateLimiter.cleanup(limiter) end)

      # Exhaust limits
      for _ <- 1..2 do
        RateLimiter.allow_connection?(limiter)
      end

      assert {:error, :rate_limited} = RateLimiter.allow_connection?(limiter)

      # Wait for reset
      Process.sleep(150)

      # Should be allowed again
      assert :ok = RateLimiter.allow_connection?(limiter)
    end
  end

  describe "concurrent access" do
    test "handles concurrent connection checks safely" do
      limiter = RateLimiter.new(max_connections: 50, interval: 60_000)
      on_exit(fn -> RateLimiter.cleanup(limiter) end)

      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            RateLimiter.allow_connection?(limiter)
          end)
        end

      results = Task.await_many(tasks)
      ok_count = Enum.count(results, &(&1 == :ok))
      assert ok_count == 50
    end

    test "handles concurrent message checks safely" do
      limiter = RateLimiter.new(max_messages: 20, interval: 60_000)
      on_exit(fn -> RateLimiter.cleanup(limiter) end)

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            RateLimiter.allow_message?(limiter, "concurrent_client_#{rem(i, 5)}")
          end)
        end

      results = Task.await_many(tasks)
      ok_count = Enum.count(results, &(&1 == :ok))
      assert ok_count == 20
    end
  end

  describe "cleanup/1" do
    test "cleans up ETS table and timer" do
      limiter = RateLimiter.new(max_connections: 5, interval: 60_000)

      assert Process.alive?(limiter.timer_pid)

      :ok = RateLimiter.cleanup(limiter)

      Process.sleep(50)
      refute Process.alive?(limiter.timer_pid)
    end
  end
end
