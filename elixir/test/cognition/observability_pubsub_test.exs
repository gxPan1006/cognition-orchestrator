defmodule Cognition.ObservabilityPubSubTest do
  use Cognition.TestSupport

  alias CognitionWeb.ObservabilityPubSub

  test "subscribe and broadcast_update deliver dashboard updates" do
    assert :ok = ObservabilityPubSub.subscribe()
    assert :ok = ObservabilityPubSub.broadcast_update()
    assert_receive :observability_updated
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    pubsub_child_id = Phoenix.PubSub.Supervisor

    on_exit(fn ->
      if Process.whereis(Cognition.PubSub) == nil do
        assert {:ok, _pid} =
                 Supervisor.restart_child(Cognition.Supervisor, pubsub_child_id)
      end
    end)

    assert is_pid(Process.whereis(Cognition.PubSub))
    assert :ok = Supervisor.terminate_child(Cognition.Supervisor, pubsub_child_id)
    refute Process.whereis(Cognition.PubSub)

    assert :ok = ObservabilityPubSub.broadcast_update()
  end
end
