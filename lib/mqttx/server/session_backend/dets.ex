defmodule MqttX.Server.SessionBackend.DETS do
  @moduledoc """
  A `MqttX.Server.SessionBackend` in a local DETS file: sessions survive a
  restart of the node. The file is local, so it does not move a session to
  another node — for that, implement the behaviour over a store every node
  reaches (a database).

  Options:

    * `:path` — the file (default `"mqttx_sessions_<listener>.dets"` in the
      current directory)

  The file is owned by the process that starts the listener and closed when
  it exits.
  """

  @behaviour MqttX.Server.SessionBackend

  @impl true
  def init(listener, opts) do
    path =
      Keyword.get_lazy(opts, :path, fn -> "mqttx_sessions_#{inspect_name(listener)}.dets" end)

    path = path |> to_string() |> Path.expand()
    File.mkdir_p!(Path.dirname(path))

    # One table per file; a listener restart reopens it under the same name
    name = {__MODULE__, path}

    {:ok, ^name} =
      :dets.open_file(name, file: String.to_charlist(path), type: :set, auto_save: 1_000)

    {:ok, name}
  end

  @impl true
  def save(table, client_id, record) do
    :ok = :dets.insert(table, {client_id, record})
  end

  @impl true
  def load(table, client_id) do
    case :dets.lookup(table, client_id) do
      [{_, record}] -> {:ok, record}
      _ -> :none
    end
  end

  @impl true
  def delete(table, client_id) do
    :ok = :dets.delete(table, client_id)
  end

  @impl true
  def list(table) do
    :dets.foldl(fn entry, acc -> [entry | acc] end, [], table)
  end

  defp inspect_name(name) when is_atom(name) or is_integer(name),
    do: name |> to_string() |> String.replace(~r/[^\w.-]/, "_")

  defp inspect_name(name), do: :erlang.phash2(name) |> Integer.to_string()
end
