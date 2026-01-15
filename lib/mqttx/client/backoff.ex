defmodule MqttX.Client.Backoff do
  @moduledoc """
  Exponential backoff calculator for reconnection delays.

  ## Usage

      backoff = MqttX.Client.Backoff.new(initial: 1000, max: 30_000)
      {delay, backoff} = MqttX.Client.Backoff.next(backoff)
      # delay = 1000

      {delay, backoff} = MqttX.Client.Backoff.next(backoff)
      # delay = 2000

      backoff = MqttX.Client.Backoff.reset(backoff)
  """

  @type t :: %__MODULE__{
          initial: pos_integer(),
          max: pos_integer(),
          current: pos_integer(),
          multiplier: float(),
          jitter: float()
        }

  defstruct initial: 1000,
            max: 30_000,
            current: 1000,
            multiplier: 2.0,
            jitter: 0.1

  @doc """
  Create a new backoff calculator.

  ## Options

  - `:initial` - Initial delay in milliseconds (default: 1000)
  - `:max` - Maximum delay in milliseconds (default: 30000)
  - `:multiplier` - Multiplier for each retry (default: 2.0)
  - `:jitter` - Random jitter factor 0-1 (default: 0.1)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    initial = Keyword.get(opts, :initial, 1000)
    max = Keyword.get(opts, :max, 30_000)
    multiplier = Keyword.get(opts, :multiplier, 2.0)
    jitter = Keyword.get(opts, :jitter, 0.1)

    %__MODULE__{
      initial: initial,
      max: max,
      current: initial,
      multiplier: multiplier,
      jitter: jitter
    }
  end

  @doc """
  Get the next delay and update the backoff state.

  Returns `{delay_ms, new_backoff}`.
  """
  @spec next(t()) :: {pos_integer(), t()}
  def next(backoff) do
    delay = apply_jitter(backoff.current, backoff.jitter)
    next_current = min(round(backoff.current * backoff.multiplier), backoff.max)

    {delay, %{backoff | current: next_current}}
  end

  @doc """
  Reset the backoff to initial state.
  """
  @spec reset(t()) :: t()
  def reset(backoff) do
    %{backoff | current: backoff.initial}
  end

  @doc """
  Get current delay without advancing.
  """
  @spec current(t()) :: pos_integer()
  def current(backoff) do
    apply_jitter(backoff.current, backoff.jitter)
  end

  defp apply_jitter(value, jitter) when jitter > 0 do
    jitter_range = round(value * jitter)
    value + :rand.uniform(jitter_range * 2 + 1) - jitter_range - 1
  end

  defp apply_jitter(value, _jitter) do
    value
  end
end
