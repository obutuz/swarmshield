defmodule Swarmshield.Deliberation.PromptTemplateTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Deliberation.PromptTemplate
  alias Swarmshield.DeliberationFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = DeliberationFixtures.valid_prompt_template_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      changeset = PromptTemplate.changeset(%PromptTemplate{workspace_id: workspace.id}, attrs)

      assert changeset.valid?
    end

    test "requires name" do
      attrs = DeliberationFixtures.valid_prompt_template_attributes(%{name: nil})
      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires template" do
      attrs = DeliberationFixtures.valid_prompt_template_attributes(%{template: nil})
      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)

      refute changeset.valid?
      assert %{template: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name max length" do
      long_name = String.duplicate("a", 256)
      attrs = DeliberationFixtures.valid_prompt_template_attributes(%{name: long_name})
      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)

      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "validates description max length" do
      long_desc = String.duplicate("a", 2001)
      attrs = DeliberationFixtures.valid_prompt_template_attributes(%{description: long_desc})
      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)

      refute changeset.valid?
      assert %{description: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 2000"
    end

    test "validates category max length" do
      long_cat = String.duplicate("a", 256)
      attrs = DeliberationFixtures.valid_prompt_template_attributes(%{category: long_cat})
      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)

      refute changeset.valid?
      assert %{category: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "template can be up to 100KB" do
      large_template = String.duplicate("a", 102_400)
      attrs = DeliberationFixtures.valid_prompt_template_attributes(%{template: large_template})
      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)

      assert changeset.valid?
    end

    test "template exceeding 100KB is rejected" do
      oversized_template = String.duplicate("a", 102_401)

      attrs =
        DeliberationFixtures.valid_prompt_template_attributes(%{template: oversized_template})

      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)

      refute changeset.valid?
      assert %{template: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most"
    end

    test "template with no variables is valid" do
      attrs =
        DeliberationFixtures.valid_prompt_template_attributes(%{template: "No variables here"})

      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)

      assert changeset.valid?
    end

    test "version defaults to 1" do
      changeset = PromptTemplate.changeset(%PromptTemplate{}, %{})
      assert Ecto.Changeset.get_field(changeset, :version) == 1
    end

    test "enabled defaults to true" do
      changeset = PromptTemplate.changeset(%PromptTemplate{}, %{})
      assert Ecto.Changeset.get_field(changeset, :enabled) == true
    end

    test "auto-extracts variables from template on change" do
      attrs =
        DeliberationFixtures.valid_prompt_template_attributes(%{
          template: "Hello {{name}}, analyze {{event_type}} for {{threat_level}}"
        })

      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)

      variables = Ecto.Changeset.get_change(changeset, :variables)
      assert variables == ["event_type", "name", "threat_level"]
    end

    test "auto-extracts empty list when no variables" do
      attrs =
        DeliberationFixtures.valid_prompt_template_attributes(%{
          template: "No variables at all"
        })

      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)

      variables = Ecto.Changeset.get_field(changeset, :variables)
      assert variables == []
    end
  end

  describe "extract_variables/1" do
    test "returns empty list for template with no variables" do
      assert PromptTemplate.extract_variables("No variables here") == []
    end

    test "extracts single variable" do
      assert PromptTemplate.extract_variables("Hello {{name}}") == ["name"]
    end

    test "extracts multiple variables" do
      result = PromptTemplate.extract_variables("{{greeting}} {{name}}, your {{role}} is ready")
      assert result == ["greeting", "name", "role"]
    end

    test "returns unique variable names (no duplicates)" do
      result = PromptTemplate.extract_variables("Duplicate {{name}} and {{name}}")
      assert result == ["name"]
    end

    test "returns sorted variable names" do
      result = PromptTemplate.extract_variables("{{zebra}} and {{apple}}")
      assert result == ["apple", "zebra"]
    end

    test "handles nested braces gracefully" do
      result = PromptTemplate.extract_variables("{{{{var}}}}")
      assert "var" in result
    end

    test "handles underscored variable names" do
      result = PromptTemplate.extract_variables("{{event_type}} and {{threat_level}}")
      assert result == ["event_type", "threat_level"]
    end

    test "returns empty list for nil input" do
      assert PromptTemplate.extract_variables(nil) == []
    end
  end

  describe "render/2" do
    test "replaces single variable" do
      result = PromptTemplate.render("Hello {{name}}", %{"name" => "World"})
      assert result == "Hello World"
    end

    test "replaces multiple variables" do
      result =
        PromptTemplate.render(
          "{{greeting}} {{name}}, your {{role}} is ready",
          %{"greeting" => "Hi", "name" => "Alice", "role" => "analysis"}
        )

      assert result == "Hi Alice, your analysis is ready"
    end

    test "leaves unreplaced variables as-is" do
      result = PromptTemplate.render("Hello {{name}}, {{missing}}", %{"name" => "World"})
      assert result == "Hello World, {{missing}}"
    end

    test "handles empty variables map" do
      result = PromptTemplate.render("Hello {{name}}", %{})
      assert result == "Hello {{name}}"
    end

    test "converts non-string values to string" do
      result = PromptTemplate.render("Count: {{count}}", %{"count" => 42})
      assert result == "Count: 42"
    end
  end

  describe "render/2 security" do
    test "Elixir code in variable values is not executed" do
      # Ensure render uses String.replace, not Code.eval_string
      result =
        PromptTemplate.render(
          "Result: {{code}}",
          %{"code" => "System.cmd(\"rm\", [\"-rf\", \"/\"])"}
        )

      # The code string should be literally inserted, not executed
      assert result == "Result: System.cmd(\"rm\", [\"-rf\", \"/\"])"
    end

    test "EEx-style tags in variable values are not evaluated" do
      result =
        PromptTemplate.render(
          "Output: {{data}}",
          %{"data" => "<%= System.halt() %>"}
        )

      assert result == "Output: <%= System.halt() %>"
    end

    test "Erlang function calls in variable values are treated as strings" do
      result =
        PromptTemplate.render(
          "Value: {{input}}",
          %{"input" => ":os.cmd('whoami')"}
        )

      assert result == "Value: :os.cmd('whoami')"
    end

    test "nested template syntax in variable values is not re-processed" do
      result =
        PromptTemplate.render(
          "Hello {{name}}",
          %{"name" => "{{malicious}}"}
        )

      # The inner {{malicious}} should be literal, not re-interpolated
      assert result == "Hello {{malicious}}"
    end

    test "HTML/script injection in variables is passed through as-is" do
      result =
        PromptTemplate.render(
          "Output: {{data}}",
          %{"data" => "<script>alert('xss')</script>"}
        )

      # render/2 does not sanitize HTML - that's the template consumer's job
      assert result == "Output: <script>alert('xss')</script>"
    end
  end

  describe "version auto-increment" do
    test "version does not increment on create (new record)" do
      attrs =
        DeliberationFixtures.valid_prompt_template_attributes(%{
          template: "Version {{v1}}"
        })

      changeset = PromptTemplate.changeset(%PromptTemplate{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :version) == 1
    end

    test "version increments on update (existing record with id)" do
      attrs =
        DeliberationFixtures.valid_prompt_template_attributes(%{
          template: "Updated {{v2}}"
        })

      existing = %PromptTemplate{id: Ecto.UUID.generate(), version: 3}
      changeset = PromptTemplate.changeset(existing, attrs)

      assert Ecto.Changeset.get_field(changeset, :version) == 4
    end

    test "version does not increment if template unchanged" do
      attrs = %{name: "Updated name only"}
      existing = %PromptTemplate{id: Ecto.UUID.generate(), version: 3, template: "same"}
      changeset = PromptTemplate.changeset(existing, attrs)

      assert Ecto.Changeset.get_field(changeset, :version) == 3
    end
  end

  describe "fixture and database persistence" do
    test "creates a prompt template with default attributes" do
      template = DeliberationFixtures.prompt_template_fixture()

      assert template.id
      assert template.workspace_id
      assert template.name
      assert template.template =~ "{{event_type}}"
      assert template.category == "analysis"
      assert template.version == 1
      assert template.enabled == true
      assert "content" in template.variables
      assert "event_type" in template.variables
    end

    test "creates a prompt template with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      template =
        DeliberationFixtures.prompt_template_fixture(%{
          workspace_id: workspace.id,
          template: "Custom {{var1}} template",
          category: "debate"
        })

      assert template.template == "Custom {{var1}} template"
      assert template.category == "debate"
      assert template.variables == ["var1"]
    end

    test "reloaded template matches inserted data" do
      template = DeliberationFixtures.prompt_template_fixture()
      reloaded = Repo.get!(PromptTemplate, template.id)

      assert reloaded.name == template.name
      assert reloaded.template == template.template
      assert reloaded.variables == template.variables
    end
  end
end
