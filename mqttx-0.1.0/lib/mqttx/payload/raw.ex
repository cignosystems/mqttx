defmodule MqttX.Payload.Raw do
  @moduledoc """
  Raw binary pass-through codec.

  No encoding or decoding is performed.
  """

  @behaviour MqttX.Payload

  @impl true
  def encode(binary) when is_binary(binary) do
    {:ok, binary}
  end

  def encode(term) do
    {:error, {:not_binary, term}}
  end

  @impl true
  def decode(binary) when is_binary(binary) do
    {:ok, binary}
  end
end
