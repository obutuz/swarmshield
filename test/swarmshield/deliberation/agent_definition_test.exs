defmodule Swarmshield.Deliberation.AgentDefinitionTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Deliberation.AgentDefinition
  alias Swarmshield.DeliberationFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      changeset = AgentDefinition.changeset(%AgentDefinition{workspace_id: workspace.id}, attrs)

      assert changeset.valid?
    end

    test "requires name" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{name: nil})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires role" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{role: nil})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{role: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires system_prompt" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{system_prompt: nil})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{system_prompt: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name max length" do
      long_name = String.duplicate("a", 256)
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{name: long_name})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "validates description max length" do
      long_desc = String.duplicate("a", 2001)
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{description: long_desc})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{description: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 2000"
    end

    test "validates role max length" do
      long_role = String.duplicate("a", 256)
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{role: long_role})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{role: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "system_prompt can be up to 100KB" do
      large_prompt = String.duplicate("a", 102_400)

      attrs =
        DeliberationFixtures.valid_agent_definition_attributes(%{system_prompt: large_prompt})

      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      assert changeset.valid?
    end

    test "system_prompt exceeding 100KB is rejected" do
      oversized_prompt = String.duplicate("a", 102_401)

      attrs =
        DeliberationFixtures.valid_agent_definition_attributes(%{system_prompt: oversized_prompt})

      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{system_prompt: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most"
    end

    test "expertise empty array is valid (generalist agent)" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{expertise: []})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      assert changeset.valid?
    end

    test "model defaults to claude-opus-4-6" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes()
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :model) == "claude-opus-4-6"
    end

    test "enabled defaults to true" do
      changeset = AgentDefinition.changeset(%AgentDefinition{}, %{})
      assert Ecto.Changeset.get_field(changeset, :enabled) == true
    end
  end

  describe "temperature validation" do
    test "temperature exactly 0.0 is valid" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{temperature: 0.0})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      assert changeset.valid?
    end

    test "temperature exactly 1.0 is valid" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{temperature: 1.0})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      assert changeset.valid?
    end

    test "temperature 1.01 is rejected" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{temperature: 1.01})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{temperature: [msg]} = errors_on(changeset)
      assert msg =~ "less than or equal to 1.0"
    end

    test "temperature -0.1 is rejected" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{temperature: -0.1})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{temperature: [msg]} = errors_on(changeset)
      assert msg =~ "greater than or equal to 0.0"
    end

    test "temperature defaults to 0.3" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes()
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :temperature) == 0.3
    end
  end

  describe "max_tokens validation" do
    test "max_tokens 0 is rejected" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{max_tokens: 0})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{max_tokens: [msg]} = errors_on(changeset)
      assert msg =~ "greater than or equal to 1"
    end

    test "max_tokens 1 is valid (minimum)" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{max_tokens: 1})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      assert changeset.valid?
    end

    test "max_tokens 32768 is valid (maximum)" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{max_tokens: 32_768})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      assert changeset.valid?
    end

    test "max_tokens 32769 is rejected" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{max_tokens: 32_769})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{max_tokens: [msg]} = errors_on(changeset)
      assert msg =~ "less than or equal to 32768"
    end

    test "max_tokens defaults to 4096" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes()
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :max_tokens) == 4096
    end
  end

  describe "model validation" do
    test "accepts all approved models" do
      for model <- AgentDefinition.approved_models() do
        attrs = DeliberationFixtures.valid_agent_definition_attributes(%{model: model})
        changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

        assert changeset.valid?, "Expected model #{model} to be valid"
      end
    end

    test "rejects unapproved model" do
      attrs = DeliberationFixtures.valid_agent_definition_attributes(%{model: "gpt-4"})
      changeset = AgentDefinition.changeset(%AgentDefinition{}, attrs)

      refute changeset.valid?
      assert %{model: [_msg]} = errors_on(changeset)
    end

    test "approved_models returns expected list" do
      models = AgentDefinition.approved_models()

      assert "claude-opus-4-6" in models
      assert "claude-sonnet-4-5-20250929" in models
      assert "claude-haiku-4-5-20251001" in models
    end
  end

  describe "fixture and database persistence" do
    test "creates an agent definition with default attributes" do
      definition = DeliberationFixtures.agent_definition_fixture()

      assert definition.id
      assert definition.workspace_id
      assert definition.name
      assert definition.role == "security_analyst"
      assert definition.model == "claude-opus-4-6"
      assert definition.temperature == 0.3
      assert definition.max_tokens == 4096
      assert definition.enabled == true
    end

    test "creates an agent definition with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      definition =
        DeliberationFixtures.agent_definition_fixture(%{
          workspace_id: workspace.id,
          role: "ethics_reviewer",
          temperature: 0.7,
          max_tokens: 8192,
          model: "claude-sonnet-4-5-20250929"
        })

      assert definition.role == "ethics_reviewer"
      assert definition.temperature == 0.7
      assert definition.max_tokens == 8192
      assert definition.model == "claude-sonnet-4-5-20250929"
    end

    test "reloaded definition matches inserted data" do
      definition = DeliberationFixtures.agent_definition_fixture()
      reloaded = Repo.get!(AgentDefinition, definition.id)

      assert reloaded.name == definition.name
      assert reloaded.role == definition.role
      assert reloaded.model == definition.model
      assert reloaded.temperature == definition.temperature
    end
  end
end
