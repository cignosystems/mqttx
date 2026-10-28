defmodule MqttX.Packet.BufferDetachTest do
  use ExUnit.Case, async: true

  alias MqttX.Packet.Buffer

  test "a small payload is copied out of a large read; one that is most of it is kept" do
    read = :binary.copy("x", 70_000)
    <<small::binary-size(100), _::binary>> = read
    assert :binary.referenced_byte_size(small) == 70_000

    detached = Buffer.detach(small)
    assert detached == small
    assert :binary.referenced_byte_size(detached) == 100

    <<most::binary-size(60_000), _::binary>> = read
    assert :binary.referenced_byte_size(Buffer.detach(most)) == 70_000
  end

  test "anything else is left alone" do
    assert Buffer.detach(<<>>) == <<>>
    assert Buffer.detach(nil) == nil
    assert Buffer.detach("own") == "own"
  end
end
