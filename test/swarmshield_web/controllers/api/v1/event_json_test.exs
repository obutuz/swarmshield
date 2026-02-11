defmodule SwarmshieldWeb.Api.V1.EventJSONTest do
  use Swarmshield.DataCase, async: true

  alias SwarmshieldWeb.Api.V1.EventJSON

  import Swarmshield.GatewayFixtures

  describe "show/1" do
    test "renders a single event with expected fields" do
      event = agent_event_fixture()

      result = EventJSON.show(%{event: event})

      assert %{data: data} = result
      assert data.id == event.id
      assert data.event_type == event.event_type
      assert data.content == event.content
      assert data.severity == event.severity
      assert data.status == event.status
      assert data.registered_agent_id == event.registered_agent_id
      assert data.inserted_at == event.inserted_at
    end

    test "does not expose workspace_id" do
      event = agent_event_fixture()

      %{data: data} = EventJSON.show(%{event: event})

      refute Map.has_key?(data, :workspace_id)
    end

    test "renders nil evaluation_result as nil" do
      event = agent_event_fixture()

      %{data: data} = EventJSON.show(%{event: event})

      assert data.evaluation_result == %{}
    end

    test "renders datetime fields" do
      event = agent_event_fixture()

      %{data: data} = EventJSON.show(%{event: event})

      assert %DateTime{} = data.inserted_at
    end
  end

  describe "index/1" do
    test "renders list of events with total_count" do
      event1 = agent_event_fixture()
      event2 = agent_event_fixture()

      result = EventJSON.index(%{events: [event1, event2], total_count: 2})

      assert %{data: data, total_count: 2} = result
      assert length(data) == 2
      assert Enum.all?(data, &Map.has_key?(&1, :id))
    end

    test "renders empty list" do
      result = EventJSON.index(%{events: [], total_count: 0})

      assert %{data: [], total_count: 0} = result
    end
  end
end
