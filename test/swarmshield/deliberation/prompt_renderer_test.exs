defmodule Swarmshield.Deliberation.PromptRendererTest do
  use ExUnit.Case, async: true

  alias Swarmshield.Deliberation.PromptRenderer

  # ---------------------------------------------------------------------------
  # render/2
  # ---------------------------------------------------------------------------
  describe "render/2" do
    test "replaces a single variable" do
      assert {:ok, "Hello World"} =
               PromptRenderer.render("Hello {{name}}", %{"name" => "World"})
    end

    test "replaces multiple distinct variables" do
      template = "{{greeting}} {{name}}, your {{role}} is ready"
      variables = %{"greeting" => "Hi", "name" => "Alice", "role" => "analysis"}

      assert {:ok, "Hi Alice, your analysis is ready"} =
               PromptRenderer.render(template, variables)
    end

    test "replaces the same variable used multiple times" do
      template = "{{name}} met {{name}} and said hello to {{name}}"

      assert {:ok, "Alice met Alice and said hello to Alice"} =
               PromptRenderer.render(template, %{"name" => "Alice"})
    end

    test "returns error when required variables are missing" do
      assert {:error, :missing_variables, ["name"]} =
               PromptRenderer.render("Hello {{name}}", %{})
    end

    test "returns sorted list of all missing variables" do
      template = "{{zebra}} and {{apple}} with {{middle}}"

      assert {:error, :missing_variables, ["apple", "middle", "zebra"]} =
               PromptRenderer.render(template, %{})
    end

    test "returns error listing only the missing variables when some are provided" do
      template = "{{a}} and {{b}} and {{c}}"

      assert {:error, :missing_variables, ["b", "c"]} =
               PromptRenderer.render(template, %{"a" => "ok"})
    end

    test "empty template returns ok with empty string" do
      assert {:ok, ""} = PromptRenderer.render("", %{"unused" => "value"})
    end

    test "template without variables ignores provided variables" do
      assert {:ok, "No variables here"} =
               PromptRenderer.render("No variables here", %{"extra" => "ignored"})
    end

    test "empty braces {{}} are treated as literal text" do
      assert {:ok, "Value is {{}}"} =
               PromptRenderer.render("Value is {{}}", %{})
    end

    test "does NOT recursively expand variables in values" do
      template = "Hello {{name}}"
      variables = %{"name" => "{{malicious}}"}

      assert {:ok, "Hello {{malicious}}"} =
               PromptRenderer.render(template, variables)
    end

    test "converts non-string values to string via to_string/1" do
      template = "Count: {{count}}, Active: {{active}}"
      variables = %{"count" => 42, "active" => true}

      assert {:ok, "Count: 42, Active: true"} =
               PromptRenderer.render(template, variables)
    end

    test "handles atom keys in variables map" do
      assert {:ok, "Hello World"} =
               PromptRenderer.render("Hello {{name}}", %{name: "World"})
    end

    test "handles multiline templates" do
      template = """
      Line 1: {{first}}
      Line 2: {{second}}
      """

      assert {:ok, rendered} =
               PromptRenderer.render(template, %{"first" => "A", "second" => "B"})

      assert rendered =~ "Line 1: A"
      assert rendered =~ "Line 2: B"
    end
  end

  # ---------------------------------------------------------------------------
  # render/2 - security
  # ---------------------------------------------------------------------------
  describe "render/2 security" do
    test "Elixir code in variable values is not executed" do
      assert {:ok, result} =
               PromptRenderer.render(
                 "Result: {{code}}",
                 %{"code" => ~s|System.cmd("rm", ["-rf", "/"])|}
               )

      assert result == ~s|Result: System.cmd("rm", ["-rf", "/"])|
    end

    test "EEx-style tags in variable values are not evaluated" do
      assert {:ok, result} =
               PromptRenderer.render(
                 "Output: {{data}}",
                 %{"data" => "<%= System.halt() %>"}
               )

      assert result == "Output: <%= System.halt() %>"
    end

    test "HTML/script injection is passed through as-is" do
      assert {:ok, result} =
               PromptRenderer.render(
                 "Output: {{data}}",
                 %{"data" => "<script>alert('xss')</script>"}
               )

      assert result == "Output: <script>alert('xss')</script>"
    end
  end

  # ---------------------------------------------------------------------------
  # extract_variables/1
  # ---------------------------------------------------------------------------
  describe "extract_variables/1" do
    test "returns empty list for template with no variables" do
      assert PromptRenderer.extract_variables("No variables here") == []
    end

    test "extracts a single variable" do
      assert PromptRenderer.extract_variables("Hello {{name}}") == ["name"]
    end

    test "extracts multiple variables sorted alphabetically" do
      result = PromptRenderer.extract_variables("{{zebra}} and {{apple}}")
      assert result == ["apple", "zebra"]
    end

    test "deduplicates repeated variable names" do
      result = PromptRenderer.extract_variables("{{name}} and {{name}} again")
      assert result == ["name"]
    end

    test "handles underscored variable names" do
      result = PromptRenderer.extract_variables("{{event_type}} and {{threat_level}}")
      assert result == ["event_type", "threat_level"]
    end

    test "ignores empty braces {{}}" do
      assert PromptRenderer.extract_variables("Value {{}} here") == []
    end

    test "returns empty list for empty string" do
      assert PromptRenderer.extract_variables("") == []
    end

    test "handles variables adjacent to other text with no space" do
      result = PromptRenderer.extract_variables("pre{{var}}post")
      assert result == ["var"]
    end
  end

  # ---------------------------------------------------------------------------
  # validate_template/2
  # ---------------------------------------------------------------------------
  describe "validate_template/2" do
    test "returns :ok when all variables are available" do
      assert :ok = PromptRenderer.validate_template("Hello {{name}}", ["name", "extra"])
    end

    test "returns :ok for template with no variables" do
      assert :ok = PromptRenderer.validate_template("No vars", [])
    end

    test "returns error with missing variable names" do
      assert {:error, :missing_variables, ["b"]} =
               PromptRenderer.validate_template("{{a}} and {{b}}", ["a"])
    end

    test "returns sorted missing variables" do
      assert {:error, :missing_variables, ["x", "y", "z"]} =
               PromptRenderer.validate_template("{{z}} {{x}} {{y}}", [])
    end

    test "returns :ok when available list is a superset" do
      template = "{{name}}"
      available = ["age", "name", "role"]
      assert :ok = PromptRenderer.validate_template(template, available)
    end
  end
end
