defmodule Swarmshield.DeliberationFixtures do
  @moduledoc """
  Test helpers for creating entities in the `Swarmshield.Deliberation` context.
  """

  alias Swarmshield.Deliberation.AgentDefinition
  alias Swarmshield.Deliberation.AgentInstance
  alias Swarmshield.Deliberation.AnalysisSession
  alias Swarmshield.Deliberation.ConsensusPolicy
  alias Swarmshield.Deliberation.DeliberationMessage
  alias Swarmshield.Deliberation.PromptTemplate
  alias Swarmshield.Deliberation.Verdict
  alias Swarmshield.Deliberation.Workflow
  alias Swarmshield.Deliberation.WorkflowStep
  alias Swarmshield.Repo

  import Swarmshield.AccountsFixtures, only: [workspace_fixture: 0]
  import Swarmshield.GatewayFixtures, only: [agent_event_fixture: 1]

  # AgentDefinition fixtures

  def unique_agent_definition_name, do: "agent-def-#{System.unique_integer([:positive])}"

  def valid_agent_definition_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_agent_definition_name(),
      description: "A test agent definition",
      role: "security_analyst",
      expertise: ["prompt_injection", "data_privacy"],
      system_prompt: "You are a security analyst. Analyze the following content for threats.",
      model: "claude-opus-4-6",
      temperature: 0.3,
      max_tokens: 4096,
      enabled: true
    })
  end

  def agent_definition_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    def_attrs = valid_agent_definition_attributes(attrs)

    {:ok, definition} =
      %AgentDefinition{workspace_id: workspace_id}
      |> AgentDefinition.changeset(def_attrs)
      |> Repo.insert()

    definition
  end

  # PromptTemplate fixtures

  def unique_prompt_template_name, do: "template-#{System.unique_integer([:positive])}"

  def valid_prompt_template_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_prompt_template_name(),
      description: "A test prompt template",
      template: "Analyze the following {{event_type}} event: {{content}}",
      category: "analysis",
      enabled: true
    })
  end

  def prompt_template_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    template_attrs = valid_prompt_template_attributes(attrs)

    {:ok, template} =
      %PromptTemplate{workspace_id: workspace_id}
      |> PromptTemplate.changeset(template_attrs)
      |> Repo.insert()

    template
  end

  # Workflow fixtures

  def unique_workflow_name, do: "workflow-#{System.unique_integer([:positive])}"

  def valid_workflow_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_workflow_name(),
      description: "A test workflow",
      trigger_on: :flagged,
      enabled: true,
      timeout_seconds: 300,
      max_retries: 2
    })
  end

  def workflow_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    workflow_attrs = valid_workflow_attributes(attrs)

    {:ok, workflow} =
      %Workflow{workspace_id: workspace_id}
      |> Workflow.changeset(workflow_attrs)
      |> Repo.insert()

    workflow
  end

  # WorkflowStep fixtures

  def valid_workflow_step_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      position: 1,
      name: "Step #{System.unique_integer([:positive])}",
      execution_mode: :sequential,
      timeout_seconds: 120,
      retry_count: 1,
      config: %{}
    })
  end

  def workflow_step_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    {workflow_id, attrs} =
      case Map.pop(attrs, :workflow_id) do
        {nil, rest} ->
          workflow = workflow_fixture(%{workspace_id: workspace_id})
          {workflow.id, rest}

        {wfid, rest} ->
          {wfid, rest}
      end

    {agent_definition_id, attrs} =
      case Map.pop(attrs, :agent_definition_id) do
        {nil, rest} ->
          definition = agent_definition_fixture(%{workspace_id: workspace_id})
          {definition.id, rest}

        {adid, rest} ->
          {adid, rest}
      end

    step_attrs =
      attrs
      |> valid_workflow_step_attributes()
      |> Map.put(:workflow_id, workflow_id)
      |> Map.put(:agent_definition_id, agent_definition_id)

    {:ok, step} =
      %WorkflowStep{}
      |> WorkflowStep.changeset(step_attrs)
      |> Repo.insert()

    step
  end

  # ConsensusPolicy fixtures

  def unique_consensus_policy_name, do: "policy-#{System.unique_integer([:positive])}"

  def valid_consensus_policy_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_consensus_policy_name(),
      description: "A test consensus policy",
      strategy: :majority,
      threshold: 0.5,
      weights: %{},
      require_unanimous_on: [],
      enabled: true
    })
  end

  def consensus_policy_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    policy_attrs = valid_consensus_policy_attributes(attrs)

    {:ok, policy} =
      %ConsensusPolicy{workspace_id: workspace_id}
      |> ConsensusPolicy.changeset(policy_attrs)
      |> Repo.insert()

    policy
  end

  # AnalysisSession fixtures

  def valid_analysis_session_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      status: :pending,
      trigger: :automatic,
      metadata: %{}
    })
  end

  def analysis_session_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    {workflow_id, attrs} =
      case Map.pop(attrs, :workflow_id) do
        {nil, rest} ->
          workflow = workflow_fixture(%{workspace_id: workspace_id})
          {workflow.id, rest}

        {wfid, rest} ->
          {wfid, rest}
      end

    {consensus_policy_id, attrs} =
      case Map.pop(attrs, :consensus_policy_id) do
        {nil, rest} ->
          policy = consensus_policy_fixture(%{workspace_id: workspace_id})
          {policy.id, rest}

        {cpid, rest} ->
          {cpid, rest}
      end

    {agent_event_id, attrs} =
      case Map.pop(attrs, :agent_event_id) do
        {nil, rest} ->
          event = agent_event_fixture(%{workspace_id: workspace_id})
          {event.id, rest}

        {aeid, rest} ->
          {aeid, rest}
      end

    session_attrs = valid_analysis_session_attributes(attrs)

    {:ok, session} =
      %AnalysisSession{
        workspace_id: workspace_id,
        workflow_id: workflow_id,
        consensus_policy_id: consensus_policy_id,
        agent_event_id: agent_event_id
      }
      |> AnalysisSession.changeset(session_attrs)
      |> Repo.insert()

    session
  end

  # AgentInstance fixtures

  def valid_agent_instance_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      status: :pending,
      role: "security_analyst"
    })
  end

  def agent_instance_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    {analysis_session_id, attrs} =
      case Map.pop(attrs, :analysis_session_id) do
        {nil, rest} ->
          session = analysis_session_fixture(%{workspace_id: workspace_id})
          {session.id, rest}

        {asid, rest} ->
          {asid, rest}
      end

    {agent_definition_id, attrs} =
      case Map.pop(attrs, :agent_definition_id) do
        {nil, rest} ->
          definition = agent_definition_fixture(%{workspace_id: workspace_id})
          {definition.id, rest}

        {adid, rest} ->
          {adid, rest}
      end

    instance_attrs = valid_agent_instance_attributes(attrs)

    {:ok, instance} =
      %AgentInstance{
        analysis_session_id: analysis_session_id,
        agent_definition_id: agent_definition_id
      }
      |> AgentInstance.changeset(instance_attrs)
      |> Repo.insert()

    instance
  end

  # DeliberationMessage fixtures

  def valid_deliberation_message_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      message_type: :analysis,
      content: "Initial analysis of the flagged event indicates potential prompt injection.",
      round: 1,
      tokens_used: 150,
      metadata: %{}
    })
  end

  def deliberation_message_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    {analysis_session_id, attrs} =
      case Map.pop(attrs, :analysis_session_id) do
        {nil, rest} ->
          session = analysis_session_fixture(%{workspace_id: workspace_id})
          {session.id, rest}

        {asid, rest} ->
          {asid, rest}
      end

    {agent_instance_id, attrs} =
      case Map.pop(attrs, :agent_instance_id) do
        {nil, rest} ->
          instance =
            agent_instance_fixture(%{
              workspace_id: workspace_id,
              analysis_session_id: analysis_session_id
            })

          {instance.id, rest}

        {aiid, rest} ->
          {aiid, rest}
      end

    msg_attrs = valid_deliberation_message_attributes(attrs)

    {:ok, message} =
      %DeliberationMessage{
        analysis_session_id: analysis_session_id,
        agent_instance_id: agent_instance_id
      }
      |> DeliberationMessage.changeset(msg_attrs)
      |> Repo.insert()

    message
  end

  # Verdict fixtures

  def valid_verdict_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      decision: :allow,
      confidence: 0.85,
      reasoning: "All agents agreed the content is safe based on analysis.",
      dissenting_opinions: [],
      vote_breakdown: %{"allow" => 3, "flag" => 0, "block" => 0},
      recommended_actions: [],
      consensus_reached: true,
      consensus_strategy_used: "majority"
    })
  end

  def verdict_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    {analysis_session_id, attrs} =
      case Map.pop(attrs, :analysis_session_id) do
        {nil, rest} ->
          session = analysis_session_fixture(%{workspace_id: workspace_id})
          {session.id, rest}

        {asid, rest} ->
          {asid, rest}
      end

    verdict_attrs = valid_verdict_attributes(attrs)

    {:ok, verdict} =
      %Verdict{analysis_session_id: analysis_session_id}
      |> Verdict.create_changeset(verdict_attrs)
      |> Repo.insert()

    verdict
  end
end
