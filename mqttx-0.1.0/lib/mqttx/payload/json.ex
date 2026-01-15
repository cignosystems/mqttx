defmodule MqttX.Payload.JSON do
  @moduledoc """
  JSON payload codec using the built-in Erlang/BEAM JSON encoder.

  Uses the native JSON module available in OTP 27+ / Elixir 1.18+.

  ## Usage

      {:ok, json} = MqttX.Payload.JSON.encode(%{temp: 25.5})
      {:ok, data} = MqttX.Payload.JSON.decode(json)
  """

  @behaviour MqttX.Payload

  @impl true
  def encode(term) do
    try do
      {:ok, JSON.encode!(term)}
    rescue
      e -> {:error, {:json_encode_error, e}}
    end
  end

  @impl true
  def decode(binary) when is_binary(binary) do
    try do
      {:ok, JSON.decode!(binary)}
    rescue
      e -> {:error, {:json_decode_error, e}}
    end
  end
end
