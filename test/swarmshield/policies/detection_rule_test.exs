defmodule Swarmshield.Policies.DetectionRuleTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Policies.DetectionRule
  alias Swarmshield.PoliciesFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = PoliciesFixtures.valid_detection_rule_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      changeset = DetectionRule.changeset(%DetectionRule{workspace_id: workspace.id}, attrs)

      assert changeset.valid?
    end

    test "requires name" do
      attrs = PoliciesFixtures.valid_detection_rule_attributes(%{name: nil})
      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires detection_type" do
      attrs = PoliciesFixtures.valid_detection_rule_attributes(%{detection_type: nil})
      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{detection_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name max length" do
      long_name = String.duplicate("a", 256)
      attrs = PoliciesFixtures.valid_detection_rule_attributes(%{name: long_name})
      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "validates description max length" do
      long_desc = String.duplicate("a", 2001)
      attrs = PoliciesFixtures.valid_detection_rule_attributes(%{description: long_desc})
      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{description: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 2000"
    end

    test "validates category max length" do
      long_cat = String.duplicate("a", 256)
      attrs = PoliciesFixtures.valid_detection_rule_attributes(%{category: long_cat})
      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{category: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "accepts all valid detection_types" do
      configs = %{
        regex: %{pattern: "\\btest\\b"},
        keyword: %{keywords: ["test"]},
        semantic: %{}
      }

      for detection_type <- [:regex, :keyword, :semantic] do
        extra = Map.get(configs, detection_type, %{})

        attrs =
          PoliciesFixtures.valid_detection_rule_attributes(
            Map.merge(%{detection_type: detection_type}, extra)
          )

        changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

        assert changeset.valid?,
               "Expected detection_type #{detection_type} to be valid, got: #{inspect(errors_on(changeset))}"
      end
    end

    test "rejects invalid detection_type" do
      attrs = PoliciesFixtures.valid_detection_rule_attributes(%{detection_type: :invalid})
      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{detection_type: [_msg]} = errors_on(changeset)
    end

    test "severity defaults to :medium" do
      attrs = PoliciesFixtures.valid_detection_rule_attributes()
      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :severity) == :medium
    end

    test "enabled defaults to true" do
      changeset = DetectionRule.changeset(%DetectionRule{}, %{})
      assert Ecto.Changeset.get_field(changeset, :enabled) == true
    end

    test "category field accepts custom values" do
      for category <- [
            "pii",
            "toxicity",
            "prompt_injection",
            "data_exfiltration",
            "custom_category"
          ] do
        attrs = PoliciesFixtures.valid_detection_rule_attributes(%{category: category})
        changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

        assert changeset.valid?, "Expected category #{category} to be valid"
      end
    end
  end

  describe "type-specific field validation" do
    test "regex type requires non-empty pattern" do
      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :regex,
          pattern: nil
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{pattern: [msg]} = errors_on(changeset)
      assert msg =~ "required for regex"
    end

    test "regex type rejects empty string pattern" do
      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :regex,
          pattern: ""
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{pattern: [msg]} = errors_on(changeset)
      assert msg =~ "required for regex"
    end

    test "keyword type requires non-empty keywords array" do
      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :keyword,
          keywords: [],
          pattern: nil
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{keywords: [msg]} = errors_on(changeset)
      assert msg =~ "non-empty for keyword"
    end

    test "keyword type with nil keywords is rejected" do
      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :keyword,
          keywords: nil,
          pattern: nil
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{keywords: [_msg]} = errors_on(changeset)
    end

    test "semantic type does not require pattern or keywords" do
      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :semantic,
          pattern: nil,
          keywords: []
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      assert changeset.valid?
    end
  end

  describe "regex validation" do
    test "valid regex pattern compiles" do
      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :regex,
          pattern: "\\b(password|secret|api_key)\\b"
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      assert changeset.valid?
    end

    test "invalid regex pattern returns error" do
      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :regex,
          pattern: "[invalid regex"
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{pattern: [msg]} = errors_on(changeset)
      assert msg =~ "invalid regex"
    end

    test "regex pattern max length is 10,000 characters" do
      long_pattern = String.duplicate("a", 10_001)

      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :regex,
          pattern: long_pattern
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{pattern: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 10000"
    end

    test "regex pattern exactly 10,000 characters is valid" do
      # Build a valid 10,000 char regex: repeated "a"
      pattern = String.duplicate("a", 10_000)

      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :regex,
          pattern: pattern
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      assert changeset.valid?
    end
  end

  describe "keywords limits" do
    test "keywords array max count is 1000" do
      keywords = for i <- 1..1001, do: "keyword_#{i}"

      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :keyword,
          keywords: keywords,
          pattern: nil
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{keywords: [msg]} = errors_on(changeset)
      assert msg =~ "cannot exceed 1000"
    end

    test "keywords exactly 1000 is valid" do
      keywords = for i <- 1..1000, do: "keyword_#{i}"

      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :keyword,
          keywords: keywords,
          pattern: nil
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      assert changeset.valid?
    end

    test "each keyword max length is 500 characters" do
      long_keyword = String.duplicate("a", 501)

      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :keyword,
          keywords: [long_keyword],
          pattern: nil
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      refute changeset.valid?
      assert %{keywords: [msg]} = errors_on(changeset)
      assert msg =~ "at most 500"
    end

    test "keyword exactly 500 characters is valid" do
      keyword = String.duplicate("a", 500)

      attrs =
        PoliciesFixtures.valid_detection_rule_attributes(%{
          detection_type: :keyword,
          keywords: [keyword],
          pattern: nil
        })

      changeset = DetectionRule.changeset(%DetectionRule{}, attrs)

      assert changeset.valid?
    end
  end

  describe "fixture and database persistence" do
    test "creates a detection rule with default attributes" do
      rule = PoliciesFixtures.detection_rule_fixture()

      assert rule.id
      assert rule.workspace_id
      assert rule.name
      assert rule.detection_type == :regex
      assert rule.pattern == "\\b(password|secret)\\b"
      assert rule.severity == :medium
      assert rule.enabled == true
      assert rule.category == "pii"
    end

    test "creates a detection rule with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      rule =
        PoliciesFixtures.detection_rule_fixture(%{
          workspace_id: workspace.id,
          detection_type: :keyword,
          keywords: ["secret", "password"],
          pattern: nil,
          category: "credentials"
        })

      assert rule.detection_type == :keyword
      assert rule.keywords == ["secret", "password"]
      assert rule.category == "credentials"
    end

    test "reloaded rule matches inserted data" do
      rule = PoliciesFixtures.detection_rule_fixture()
      reloaded = Repo.get!(DetectionRule, rule.id)

      assert reloaded.name == rule.name
      assert reloaded.detection_type == rule.detection_type
      assert reloaded.pattern == rule.pattern
    end
  end
end
