defmodule MqttX.Test.Cover do
  @moduledoc """
  Coverage on peer nodes. Under `mix test --cover` the cluster tests' peers
  run half of every scenario — where a forwarded message lands, where a
  shared delivery is taken — so cover is started on each peer as well and
  its counts are fetched before it stops. Without `--cover` both calls do
  nothing.
  """

  @doc "Start cover on `node`, before the application starts there."
  # apply/3: :cover (the tools application) is loaded only under --cover,
  # and a direct call would be a compile warning otherwise
  def start(node) do
    if on?(), do: {:ok, [^node]} = apply(:cover, :start, [[node]])
    :ok
  end

  @doc "Fetch `node`'s counts into this node's, before it stops."
  def flush(node) do
    if on?() and node in apply(:cover, :which_nodes, []),
      do: :ok = apply(:cover, :flush, [[node]])

    :ok
  end

  defp on?, do: Process.whereis(:cover_server) != nil
end
