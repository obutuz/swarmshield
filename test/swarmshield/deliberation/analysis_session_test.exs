defmodule Swarmshield.Deliberation.AnalysisSessionTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Deliberation.AnalysisSession
  alias Swarmshield.DeliberationFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = DeliberationFixtures.valid_analysis_session_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      workflow = DeliberationFixtures.workflow_fixture(%{workspace_id: workspace.id})
      policy = DeliberationFixtures.consensus_policy_fixture(%{workspace_id: workspace.id})

      event =
        Swarmshield.GatewayFixtures.agent_event_fixture(%{workspace_id: workspace.id})

      changeset =
        AnalysisSession.changeset(
          %AnalysisSession{
            workspace_id: workspace.id,
            workflow_id: workflow.id,
            consensus_policy_id: policy.id,
            agent_event_id: event.id
          },
          attrs
        )

      assert changeset.valid?
    end

    test "requires status" do
      attrs = DeliberationFixtures.valid_analysis_session_attributes(%{status: nil})
      changeset = AnalysisSession.changeset(%AnalysisSession{}, attrs)

      refute changeset.valid?
      assert %{status: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires trigger" do
      attrs = DeliberationFixtures.valid_analysis_session_attributes(%{trigger: nil})
      changeset = AnalysisSession.changeset(%AnalysisSession{}, attrs)

      refute changeset.valid?
      assert %{trigger: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts all valid statuses" do
      for status <- [
            :pending,
            :analyzing,
            :deliberating,
            :voting,
            :completed,
            :failed,
            :timed_out
          ] do
        attrs = DeliberationFixtures.valid_analysis_session_attributes(%{status: status})
        changeset = AnalysisSession.changeset(%AnalysisSession{}, attrs)

        assert changeset.valid?, "Expected status #{status} to be valid"
      end
    end

    test "rejects invalid status" do
      attrs = DeliberationFixtures.valid_analysis_session_attributes(%{status: :invalid})
      changeset = AnalysisSession.changeset(%AnalysisSession{}, attrs)

      refute changeset.valid?
      assert %{status: [_msg]} = errors_on(changeset)
    end

    test "accepts all valid triggers" do
      for trigger <- [:automatic, :manual] do
        attrs = DeliberationFixtures.valid_analysis_session_attributes(%{trigger: trigger})
        changeset = AnalysisSession.changeset(%AnalysisSession{}, attrs)

        assert changeset.valid?, "Expected trigger #{trigger} to be valid"
      end
    end

    test "rejects invalid trigger" do
      attrs = DeliberationFixtures.valid_analysis_session_attributes(%{trigger: :invalid})
      changeset = AnalysisSession.changeset(%AnalysisSession{}, attrs)

      refute changeset.valid?
      assert %{trigger: [_msg]} = errors_on(changeset)
    end

    test "status defaults to :pending" do
      attrs = DeliberationFixtures.valid_analysis_session_attributes()
      changeset = AnalysisSession.changeset(%AnalysisSession{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :status) == :pending
    end

    test "metadata defaults to empty map" do
      changeset = AnalysisSession.changeset(%AnalysisSession{}, %{})
      assert Ecto.Changeset.get_field(changeset, :metadata) == %{}
    end

    test "total_tokens_used defaults to 0" do
      changeset = AnalysisSession.changeset(%AnalysisSession{}, %{})
      assert Ecto.Changeset.get_field(changeset, :total_tokens_used) == 0
    end

    test "total_cost_cents defaults to 0" do
      changeset = AnalysisSession.changeset(%AnalysisSession{}, %{})
      assert Ecto.Changeset.get_field(changeset, :total_cost_cents) == 0
    end
  end

  describe "status_changeset/2" do
    test "updates status and timing fields" do
      now = DateTime.utc_now(:second)

      changeset =
        AnalysisSession.status_changeset(%AnalysisSession{status: :pending}, %{
          status: :analyzing,
          started_at: now
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == :analyzing
      assert Ecto.Changeset.get_change(changeset, :started_at) == now
    end

    test "sets completed_at on completion" do
      now = DateTime.utc_now(:second)

      changeset =
        AnalysisSession.status_changeset(%AnalysisSession{status: :voting}, %{
          status: :completed,
          completed_at: now,
          total_tokens_used: 5000,
          total_cost_cents: 25
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :total_tokens_used) == 5000
      assert Ecto.Changeset.get_change(changeset, :total_cost_cents) == 25
    end

    test "sets error_message on failure" do
      changeset =
        AnalysisSession.status_changeset(%AnalysisSession{status: :analyzing}, %{
          status: :failed,
          error_message: "Agent timeout exceeded"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :error_message) == "Agent timeout exceeded"
    end

    test "requires status" do
      changeset =
        AnalysisSession.status_changeset(%AnalysisSession{status: nil}, %{})

      refute changeset.valid?
      assert %{status: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "FK cascade behavior" do
    test "deleting workspace cascades to analysis sessions" do
      session = DeliberationFixtures.analysis_session_fixture()
      workspace = Repo.get!(Swarmshield.Accounts.Workspace, session.workspace_id)

      Repo.delete!(workspace)

      assert Repo.get(AnalysisSession, session.id) == nil
    end

    test "deleting workflow cascades to analysis sessions" do
      session = DeliberationFixtures.analysis_session_fixture()
      workflow = Repo.get!(Swarmshield.Deliberation.Workflow, session.workflow_id)

      Repo.delete!(workflow)

      assert Repo.get(AnalysisSession, session.id) == nil
    end

    test "deleting agent_event cascades to analysis sessions" do
      session = DeliberationFixtures.analysis_session_fixture()
      event = Repo.get!(Swarmshield.Gateway.AgentEvent, session.agent_event_id)

      Repo.delete!(event)

      assert Repo.get(AnalysisSession, session.id) == nil
    end
  end

  describe "fixture and database persistence" do
    test "creates a session with default attributes" do
      session = DeliberationFixtures.analysis_session_fixture()

      assert session.id
      assert session.workspace_id
      assert session.workflow_id
      assert session.consensus_policy_id
      assert session.agent_event_id
      assert session.status == :pending
      assert session.trigger == :automatic
      assert session.metadata == %{}
      assert session.total_tokens_used == 0
      assert session.total_cost_cents == 0
    end

    test "creates a session with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      session =
        DeliberationFixtures.analysis_session_fixture(%{
          workspace_id: workspace.id,
          trigger: :manual,
          metadata: %{"initiated_by" => "admin"}
        })

      assert session.trigger == :manual
      assert session.metadata == %{"initiated_by" => "admin"}
    end

    test "completed session has non-nil completed_at" do
      session = DeliberationFixtures.analysis_session_fixture()
      now = DateTime.utc_now(:second)

      {:ok, updated} =
        session
        |> AnalysisSession.status_changeset(%{status: :completed, completed_at: now})
        |> Repo.update()

      assert updated.completed_at == now
    end

    test "failed session has non-nil error_message" do
      session = DeliberationFixtures.analysis_session_fixture()

      {:ok, updated} =
        session
        |> AnalysisSession.status_changeset(%{
          status: :failed,
          error_message: "Timeout exceeded"
        })
        |> Repo.update()

      assert updated.error_message == "Timeout exceeded"
    end

    test "reloaded session matches inserted data" do
      session = DeliberationFixtures.analysis_session_fixture()
      reloaded = Repo.get!(AnalysisSession, session.id)

      assert reloaded.status == session.status
      assert reloaded.trigger == session.trigger
      assert reloaded.workspace_id == session.workspace_id
    end
  end
end
