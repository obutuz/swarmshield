defmodule Swarmshield.AgentsTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Agents
  alias Swarmshield.Deliberation.{AgentDefinition, PromptTemplate, WorkflowStep}

  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures

  setup do
    workspace = workspace_fixture()
    %{workspace: workspace}
  end

  # ---------------------------------------------------------------------------
  # AgentDefinition - List
  # ---------------------------------------------------------------------------

  describe "list_agent_definitions/2" do
    test "returns paginated definitions for workspace", %{workspace: workspace} do
      definition = agent_definition_fixture(%{workspace_id: workspace.id})

      {results, total_count} = Agents.list_agent_definitions(workspace.id)

      assert total_count == 1
      [found] = results
      assert found.id == definition.id
    end

    test "filters by enabled", %{workspace: workspace} do
      agent_definition_fixture(%{workspace_id: workspace.id, enabled: true})
      agent_definition_fixture(%{workspace_id: workspace.id, enabled: false})

      {results, total_count} = Agents.list_agent_definitions(workspace.id, enabled: true)

      assert total_count == 1
      [found] = results
      assert found.enabled == true
    end

    test "filters by search on name and role", %{workspace: workspace} do
      agent_definition_fixture(%{
        workspace_id: workspace.id,
        name: "Sentinel Alpha",
        role: "guard"
      })

      agent_definition_fixture(%{workspace_id: workspace.id, name: "Other", role: "reviewer"})

      {results, total_count} = Agents.list_agent_definitions(workspace.id, search: "Sentinel")

      assert total_count == 1
      [found] = results
      assert found.name == "Sentinel Alpha"
    end

    test "paginates results", %{workspace: workspace} do
      for _i <- 1..5, do: agent_definition_fixture(%{workspace_id: workspace.id})

      {results, total_count} =
        Agents.list_agent_definitions(workspace.id, page: 1, page_size: 2)

      assert total_count == 5
      assert length(results) == 2
    end

    test "does not return definitions from other workspaces", %{workspace: workspace} do
      other_workspace = workspace_fixture()
      agent_definition_fixture(%{workspace_id: other_workspace.id})

      {results, total_count} = Agents.list_agent_definitions(workspace.id)

      assert total_count == 0
      assert results == []
    end
  end

  # ---------------------------------------------------------------------------
  # AgentDefinition - CRUD
  # ---------------------------------------------------------------------------

  describe "get_agent_definition!/1" do
    test "returns the definition", %{workspace: workspace} do
      definition = agent_definition_fixture(%{workspace_id: workspace.id})
      found = Agents.get_agent_definition!(definition.id)
      assert found.id == definition.id
    end

    test "raises for missing id" do
      assert_raise Ecto.NoResultsError, fn ->
        Agents.get_agent_definition!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_agent_definition/2" do
    test "creates with valid attrs and sets workspace_id server-side", %{workspace: workspace} do
      attrs = valid_agent_definition_attributes(%{name: "New Agent"})

      assert {:ok, %AgentDefinition{} = definition} =
               Agents.create_agent_definition(workspace.id, attrs)

      assert definition.name == "New Agent"
      assert definition.workspace_id == workspace.id
    end

    test "returns error with invalid attrs", %{workspace: workspace} do
      assert {:error, %Ecto.Changeset{}} =
               Agents.create_agent_definition(workspace.id, %{})
    end
  end

  describe "update_agent_definition/2" do
    test "updates with valid attrs", %{workspace: workspace} do
      definition = agent_definition_fixture(%{workspace_id: workspace.id})

      assert {:ok, %AgentDefinition{} = updated} =
               Agents.update_agent_definition(definition, %{name: "Updated Name"})

      assert updated.name == "Updated Name"
    end

    test "returns error with invalid attrs", %{workspace: workspace} do
      definition = agent_definition_fixture(%{workspace_id: workspace.id})

      assert {:error, %Ecto.Changeset{}} =
               Agents.update_agent_definition(definition, %{name: ""})
    end
  end

  describe "delete_agent_definition/1" do
    test "deletes when not referenced by workflow_steps", %{workspace: workspace} do
      definition = agent_definition_fixture(%{workspace_id: workspace.id})

      assert {:ok, %AgentDefinition{}} = Agents.delete_agent_definition(definition)

      assert_raise Ecto.NoResultsError, fn ->
        Agents.get_agent_definition!(definition.id)
      end
    end

    test "returns error when referenced by workflow_steps", %{workspace: workspace} do
      definition = agent_definition_fixture(%{workspace_id: workspace.id})

      _step =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          agent_definition_id: definition.id
        })

      assert {:error, :has_workflow_steps} = Agents.delete_agent_definition(definition)

      found = Agents.get_agent_definition!(definition.id)
      assert found.id == definition.id
    end
  end

  describe "list_enabled_agent_definitions/1" do
    test "returns only enabled definitions for workspace", %{workspace: workspace} do
      enabled = agent_definition_fixture(%{workspace_id: workspace.id, enabled: true})
      _disabled = agent_definition_fixture(%{workspace_id: workspace.id, enabled: false})

      results = Agents.list_enabled_agent_definitions(workspace.id)

      assert length(results) == 1
      [found] = results
      assert found.id == enabled.id
    end
  end

  # ---------------------------------------------------------------------------
  # PromptTemplate - List
  # ---------------------------------------------------------------------------

  describe "list_prompt_templates/2" do
    test "returns paginated templates for workspace", %{workspace: workspace} do
      template = prompt_template_fixture(%{workspace_id: workspace.id})

      {results, total_count} = Agents.list_prompt_templates(workspace.id)

      assert total_count == 1
      [found] = results
      assert found.id == template.id
    end

    test "filters by category", %{workspace: workspace} do
      prompt_template_fixture(%{workspace_id: workspace.id, category: "analysis"})
      prompt_template_fixture(%{workspace_id: workspace.id, category: "summary"})

      {results, total_count} =
        Agents.list_prompt_templates(workspace.id, category: "analysis")

      assert total_count == 1
      [found] = results
      assert found.category == "analysis"
    end

    test "filters by enabled", %{workspace: workspace} do
      prompt_template_fixture(%{workspace_id: workspace.id, enabled: true})
      prompt_template_fixture(%{workspace_id: workspace.id, enabled: false})

      {results, total_count} =
        Agents.list_prompt_templates(workspace.id, enabled: false)

      assert total_count == 1
      [found] = results
      assert found.enabled == false
    end

    test "does not return templates from other workspaces", %{workspace: workspace} do
      other_workspace = workspace_fixture()
      prompt_template_fixture(%{workspace_id: other_workspace.id})

      {results, total_count} = Agents.list_prompt_templates(workspace.id)

      assert total_count == 0
      assert results == []
    end
  end

  # ---------------------------------------------------------------------------
  # PromptTemplate - CRUD
  # ---------------------------------------------------------------------------

  describe "get_prompt_template!/1" do
    test "returns the template", %{workspace: workspace} do
      template = prompt_template_fixture(%{workspace_id: workspace.id})
      found = Agents.get_prompt_template!(template.id)
      assert found.id == template.id
    end

    test "raises for missing id" do
      assert_raise Ecto.NoResultsError, fn ->
        Agents.get_prompt_template!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_prompt_template/2" do
    test "creates with valid attrs and sets workspace_id server-side", %{workspace: workspace} do
      attrs = valid_prompt_template_attributes(%{name: "New Template"})

      assert {:ok, %PromptTemplate{} = template} =
               Agents.create_prompt_template(workspace.id, attrs)

      assert template.name == "New Template"
      assert template.workspace_id == workspace.id
    end

    test "returns error with invalid attrs", %{workspace: workspace} do
      assert {:error, %Ecto.Changeset{}} =
               Agents.create_prompt_template(workspace.id, %{})
    end
  end

  describe "update_prompt_template/2" do
    test "updates with valid attrs", %{workspace: workspace} do
      template = prompt_template_fixture(%{workspace_id: workspace.id})

      assert {:ok, %PromptTemplate{} = updated} =
               Agents.update_prompt_template(template, %{name: "Updated Template"})

      assert updated.name == "Updated Template"
    end
  end

  describe "delete_prompt_template/1" do
    test "deletes when not referenced by workflow_steps", %{workspace: workspace} do
      template = prompt_template_fixture(%{workspace_id: workspace.id})

      assert {:ok, %PromptTemplate{}} = Agents.delete_prompt_template(template)

      assert_raise Ecto.NoResultsError, fn ->
        Agents.get_prompt_template!(template.id)
      end
    end

    test "returns error when referenced by workflow_steps", %{workspace: workspace} do
      template = prompt_template_fixture(%{workspace_id: workspace.id})
      definition = agent_definition_fixture(%{workspace_id: workspace.id})

      workflow = workflow_fixture(%{workspace_id: workspace.id})

      {:ok, _step} =
        %WorkflowStep{}
        |> WorkflowStep.changeset(%{
          position: 1,
          name: "Step with template",
          workflow_id: workflow.id,
          agent_definition_id: definition.id,
          prompt_template_id: template.id
        })
        |> Repo.insert()

      assert {:error, :has_workflow_steps} = Agents.delete_prompt_template(template)

      found = Agents.get_prompt_template!(template.id)
      assert found.id == template.id
    end
  end
end
