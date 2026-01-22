defmodule MqttX.Client.BackoffTest do
  use ExUnit.Case, async: true

  alias MqttX.Client.Backoff

  describe "new/1" do
    test "creates backoff with default values" do
      backoff = Backoff.new()

      assert backoff.initial == 1000
      assert backoff.max == 30_000
      assert backoff.current == 1000
      assert backoff.multiplier == 2.0
      assert backoff.jitter == 0.1
    end

    test "creates backoff with custom values" do
      backoff = Backoff.new(initial: 500, max: 10_000, multiplier: 1.5, jitter: 0.2)

      assert backoff.initial == 500
      assert backoff.max == 10_000
      assert backoff.current == 500
      assert backoff.multiplier == 1.5
      assert backoff.jitter == 0.2
    end
  end

  describe "next/1" do
    test "returns delay and updates state with exponential increase" do
      backoff = Backoff.new(initial: 1000, max: 30_000, multiplier: 2.0, jitter: 0)

      {delay1, backoff} = Backoff.next(backoff)
      assert delay1 == 1000
      assert backoff.current == 2000

      {delay2, backoff} = Backoff.next(backoff)
      assert delay2 == 2000
      assert backoff.current == 4000

      {delay3, backoff} = Backoff.next(backoff)
      assert delay3 == 4000
      assert backoff.current == 8000
    end

    test "caps at max value" do
      backoff = Backoff.new(initial: 1000, max: 5000, multiplier: 2.0, jitter: 0)

      {_, backoff} = Backoff.next(backoff)
      {_, backoff} = Backoff.next(backoff)
      {_, backoff} = Backoff.next(backoff)

      # After 1000 -> 2000 -> 4000 -> 8000 (capped to 5000)
      assert backoff.current == 5000

      {delay, backoff} = Backoff.next(backoff)
      assert delay == 5000
      assert backoff.current == 5000
    end

    test "applies jitter within expected range" do
      backoff = Backoff.new(initial: 1000, max: 30_000, multiplier: 2.0, jitter: 0.1)

      # Run multiple times to test jitter
      delays =
        for _ <- 1..100 do
          {delay, _} = Backoff.next(backoff)
          delay
        end

      # All delays should be within 10% of 1000 (900-1100)
      assert Enum.all?(delays, fn d -> d >= 900 and d <= 1100 end)
      # With 100 samples, we should see some variation
      assert Enum.uniq(delays) |> length() > 1
    end
  end

  describe "reset/1" do
    test "resets current to initial value" do
      backoff = Backoff.new(initial: 1000, max: 30_000, jitter: 0)

      {_, backoff} = Backoff.next(backoff)
      {_, backoff} = Backoff.next(backoff)
      assert backoff.current == 4000

      backoff = Backoff.reset(backoff)
      assert backoff.current == 1000
    end

    test "preserves other settings after reset" do
      backoff = Backoff.new(initial: 500, max: 10_000, multiplier: 1.5, jitter: 0.2)

      {_, backoff} = Backoff.next(backoff)
      backoff = Backoff.reset(backoff)

      assert backoff.initial == 500
      assert backoff.max == 10_000
      assert backoff.multiplier == 1.5
      assert backoff.jitter == 0.2
    end
  end

  describe "current/1" do
    test "returns current delay without advancing" do
      backoff = Backoff.new(initial: 1000, max: 30_000, jitter: 0)

      delay1 = Backoff.current(backoff)
      delay2 = Backoff.current(backoff)

      assert delay1 == 1000
      assert delay2 == 1000
      assert backoff.current == 1000
    end

    test "applies jitter to current value" do
      backoff = Backoff.new(initial: 1000, max: 30_000, jitter: 0.1)

      delays =
        for _ <- 1..50 do
          Backoff.current(backoff)
        end

      # Should have variation due to jitter
      assert Enum.uniq(delays) |> length() > 1
    end
  end

  describe "edge cases" do
    test "handles zero jitter" do
      backoff = Backoff.new(initial: 1000, jitter: 0)

      {delay, _} = Backoff.next(backoff)
      assert delay == 1000
    end

    test "handles small initial value" do
      backoff = Backoff.new(initial: 1, max: 100, jitter: 0)

      {delay1, backoff} = Backoff.next(backoff)
      assert delay1 == 1

      {delay2, _} = Backoff.next(backoff)
      assert delay2 == 2
    end

    test "handles max equal to initial" do
      backoff = Backoff.new(initial: 1000, max: 1000, jitter: 0)

      {delay1, backoff} = Backoff.next(backoff)
      assert delay1 == 1000

      {delay2, _} = Backoff.next(backoff)
      assert delay2 == 1000
    end
  end
end
