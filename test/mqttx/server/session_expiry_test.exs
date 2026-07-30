defmodule MqttX.Server.SessionExpiryTest do
  # Unit tests for the supervised session-expiry timer service. The bug this
  # module replaced (unsupervised Task.start + Process.sleep) fired expiry for
  # clients that had already reconnected, wiping live sessions — so the
  # cancel-on-reconnect path is the core regression to pin.
  use ExUnit.Case, async: false

  alias MqttX.Server.SessionExpiry

  defmodule ExpiryHandler do
    def handle_session_expired(client_id, %{test_pid: pid}) do
      send(pid, {:session_expired, client_id})
      :ok
    end
  end

  @table :session_expiry_test_table

  defp scope(client_id), do: {@table, client_id}

  test "fires handle_session_expired after the interval" do
    SessionExpiry.schedule(scope("expires"), 40, ExpiryHandler, %{test_pid: self()})
    assert_receive {:session_expired, "expires"}, 1_000
  end

  test "passes the bare client_id to the callback, not the internal scoped key" do
    SessionExpiry.schedule(scope("bare-id"), 40, ExpiryHandler, %{test_pid: self()})
    assert_receive {:session_expired, client_id}, 1_000
    assert client_id == "bare-id"
  end

  test "cancel/1 before expiry prevents the callback — the reconnect case" do
    SessionExpiry.schedule(scope("reconnects"), 200, ExpiryHandler, %{test_pid: self()})
    # Client reconnects well within its expiry window
    SessionExpiry.cancel(scope("reconnects"))
    refute_receive {:session_expired, "reconnects"}, 500
  end

  test "rescheduling the same key replaces the pending timer (fires once)" do
    SessionExpiry.schedule(scope("resched"), 40, ExpiryHandler, %{test_pid: self()})
    SessionExpiry.schedule(scope("resched"), 60, ExpiryHandler, %{test_pid: self()})

    assert_receive {:session_expired, "resched"}, 1_000
    refute_receive {:session_expired, "resched"}, 300
  end

  test "keys are scoped per listener — cancelling one does not affect another" do
    other_table = :other_listener_table

    SessionExpiry.schedule({@table, "same-id"}, 120, ExpiryHandler, %{test_pid: self()})
    SessionExpiry.schedule({other_table, "same-id"}, 120, ExpiryHandler, %{test_pid: self()})

    # Cancelling one listener's timer must leave the other listener's intact
    SessionExpiry.cancel({@table, "same-id"})

    assert_receive {:session_expired, "same-id"}, 1_000
    refute_receive {:session_expired, "same-id"}, 300
  end

  test "cancelling an unknown key is a no-op" do
    assert :ok = SessionExpiry.cancel(scope("never-scheduled"))
  end
end
