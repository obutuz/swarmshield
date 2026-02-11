defmodule Swarmshield.Gateway.AgentEventTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Gateway.AgentEvent
  alias Swarmshield.GatewayFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = GatewayFixtures.valid_agent_event_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      agent = GatewayFixtures.registered_agent_fixture(%{workspace_id: workspace.id})

      changeset =
        AgentEvent.changeset(
          %AgentEvent{workspace_id: workspace.id, registered_agent_id: agent.id},
          attrs
        )

      assert changeset.valid?
    end

    test "requires event_type" do
      attrs = GatewayFixtures.valid_agent_event_attributes(%{event_type: nil})
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      refute changeset.valid?
      assert %{event_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires content" do
      attrs = GatewayFixtures.valid_agent_event_attributes(%{content: nil})
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      refute changeset.valid?
      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts all valid event_types" do
      for event_type <- [:action, :output, :tool_call, :message, :error] do
        attrs = GatewayFixtures.valid_agent_event_attributes(%{event_type: event_type})
        changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

        assert changeset.valid?, "Expected event_type #{event_type} to be valid"
      end
    end

    test "rejects invalid event_type" do
      attrs = GatewayFixtures.valid_agent_event_attributes(%{event_type: :invalid})
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      refute changeset.valid?
      assert %{event_type: [_msg]} = errors_on(changeset)
    end

    test "severity defaults to :info" do
      attrs = GatewayFixtures.valid_agent_event_attributes()
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :severity) == :info
    end

    test "accepts all valid severities" do
      for severity <- [:info, :warning, :error, :critical] do
        attrs = GatewayFixtures.valid_agent_event_attributes(%{severity: severity})
        changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

        assert changeset.valid?, "Expected severity #{severity} to be valid"
      end
    end

    test "status defaults to :pending" do
      changeset = AgentEvent.changeset(%AgentEvent{}, %{})
      assert Ecto.Changeset.get_field(changeset, :status) == :pending
    end

    test "payload defaults to empty map" do
      attrs = GatewayFixtures.valid_agent_event_attributes()
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :payload) == %{"key" => "value"}
    end

    test "changeset does NOT cast status" do
      attrs = GatewayFixtures.valid_agent_event_attributes(%{status: :blocked})
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :status) == :pending
    end

    test "changeset does NOT cast evaluation_result" do
      attrs =
        GatewayFixtures.valid_agent_event_attributes(%{
          evaluation_result: %{"injected" => true}
        })

      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :evaluation_result) == %{}
    end

    test "changeset does NOT cast evaluated_at" do
      attrs =
        GatewayFixtures.valid_agent_event_attributes(%{
          evaluated_at: DateTime.utc_now(:second)
        })

      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :evaluated_at) == nil
    end

    test "changeset does NOT cast flagged_reason" do
      attrs = GatewayFixtures.valid_agent_event_attributes(%{flagged_reason: "injected"})
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :flagged_reason) == nil
    end

    test "changeset does NOT cast source_ip" do
      attrs = GatewayFixtures.valid_agent_event_attributes(%{source_ip: "1.2.3.4"})
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :source_ip) == nil
    end

    test "content accepts up to 1MB of text" do
      large_content = String.duplicate("a", 1_048_576)
      attrs = GatewayFixtures.valid_agent_event_attributes(%{content: large_content})
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      assert changeset.valid?
    end

    test "content exceeding 1MB is rejected" do
      oversized_content = String.duplicate("a", 1_048_577)
      attrs = GatewayFixtures.valid_agent_event_attributes(%{content: oversized_content})
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      refute changeset.valid?
      assert %{content: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most"
    end

    test "payload accepts complex nested JSON structures" do
      complex_payload = %{
        "level1" => %{
          "level2" => %{
            "level3" => [1, 2, %{"deep" => true}]
          }
        },
        "array" => [1, "two", %{"three" => 3}]
      }

      attrs = GatewayFixtures.valid_agent_event_attributes(%{payload: complex_payload})
      workspace = AccountsFixtures.workspace_fixture()
      agent = GatewayFixtures.registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, event} =
        %AgentEvent{workspace_id: workspace.id, registered_agent_id: agent.id}
        |> AgentEvent.changeset(attrs)
        |> Repo.insert()

      assert event.payload == complex_payload
    end

    test "oversized payload is rejected" do
      # Build a payload > 1MB
      large_value = String.duplicate("x", 1_048_576)
      attrs = GatewayFixtures.valid_agent_event_attributes(%{payload: %{"data" => large_value}})
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      refute changeset.valid?
      assert %{payload: [msg]} = errors_on(changeset)
      assert msg =~ "exceeds maximum size"
    end

    test "event with nil source_ip is valid" do
      attrs = GatewayFixtures.valid_agent_event_attributes()
      changeset = AgentEvent.changeset(%AgentEvent{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :source_ip) == nil
    end
  end

  describe "evaluation_changeset/2" do
    test "sets status and evaluation_result" do
      changeset =
        AgentEvent.evaluation_changeset(%AgentEvent{}, %{
          status: :allowed,
          evaluation_result: %{"matched_rules" => []},
          evaluated_at: DateTime.utc_now(:second)
        })

      assert changeset.valid?
    end

    test "requires status" do
      changeset =
        AgentEvent.evaluation_changeset(%AgentEvent{status: nil}, %{
          evaluation_result: %{"matched_rules" => []}
        })

      refute changeset.valid?
      assert %{status: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts all valid statuses" do
      for status <- [:allowed, :flagged, :blocked, :pending] do
        changeset =
          AgentEvent.evaluation_changeset(%AgentEvent{}, %{status: status})

        assert changeset.valid?, "Expected status #{status} to be valid"
      end
    end

    test "sets flagged_reason" do
      changeset =
        AgentEvent.evaluation_changeset(%AgentEvent{}, %{
          status: :flagged,
          flagged_reason: "Pattern match on PII"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :flagged_reason) == "Pattern match on PII"
    end
  end

  describe "source_changeset/2" do
    test "sets source_ip" do
      changeset = AgentEvent.source_changeset(%AgentEvent{}, %{source_ip: "192.168.1.1"})

      assert Ecto.Changeset.get_change(changeset, :source_ip) == "192.168.1.1"
    end
  end

  describe "fixture and database persistence" do
    test "creates event with default attributes" do
      event = GatewayFixtures.agent_event_fixture()

      assert event.id
      assert event.workspace_id
      assert event.registered_agent_id
      assert event.event_type == :action
      assert event.content == "Test agent event content"
      assert event.severity == :info
      assert event.status == :pending
      assert event.payload == %{"key" => "value"}
    end

    test "creates event with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      event =
        GatewayFixtures.agent_event_fixture(%{
          workspace_id: workspace.id,
          event_type: :tool_call,
          content: "Custom content",
          severity: :critical
        })

      assert event.event_type == :tool_call
      assert event.content == "Custom content"
      assert event.severity == :critical
    end

    test "reloaded event matches inserted data" do
      event = GatewayFixtures.agent_event_fixture()
      reloaded = Repo.get!(AgentEvent, event.id)

      assert reloaded.event_type == event.event_type
      assert reloaded.content == event.content
      assert reloaded.workspace_id == event.workspace_id
    end
  end
end
