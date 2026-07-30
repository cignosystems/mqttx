defmodule MqttX.Payload.JSON do
  @moduledoc """
  JSON payload codec using the built-in Erlang/BEAM JSON encoder.

  Uses the native JSON module available in OTP 27+ / Elixir 1.18+.

  ## Usage

      {:ok, json} = MqttX.Payload.JSON.encode(%{temp: 25.5})
      {:ok, data} = MqttX.Payload.JSON.decode(json)

  On runtimes without the native `JSON` module, `encode/1` and `decode/1`
  return `{:error, :json_not_available}` instead of raising
  `UndefinedFunctionError` (mirroring `MqttX.Payload.Protobuf`'s graceful
  degradation).
  """

  @behaviour MqttX.Payload

  @impl true
  def encode(term) do
    if Code.ensure_loaded?(JSON) do
      try do
        {:ok, JSON.encode!(term)}
      rescue
        e -> {:error, {:json_encode_error, e}}
      end
    else
      {:error, :json_not_available}
    end
  end

  @impl true
  def decode(binary) when is_binary(binary) do
    if Code.ensure_loaded?(JSON) do
      try do
        {:ok, JSON.decode!(binary)}
      rescue
        e -> {:error, {:json_decode_error, e}}
      end
    else
      {:error, :json_not_available}
    end
  end
end
