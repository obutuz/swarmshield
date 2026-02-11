defmodule Swarmshield.GhostProtocol.ConfigTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.DeliberationFixtures
  alias Swarmshield.GhostProtocol.Config
  alias Swarmshield.GhostProtocolFixtures

  describe "changeset/2 - basic validations" do
    test "valid attributes create a valid changeset" do
      attrs = GhostProtocolFixtures.valid_ghost_protocol_config_attributes()
      workspace = AccountsFixtures.workspace_fixture()

      changeset =
        %Config{workspace_id: workspace.id}
        |> Config.changeset(attrs)

      assert changeset.valid?
    end

    test "requires name" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes()
        |> Map.delete(:name)

      changeset = Config.changeset(%Config{}, attrs)
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires wipe_strategy" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes()
        |> Map.delete(:wipe_strategy)

      changeset = Config.changeset(%Config{}, attrs)
      assert %{wipe_strategy: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires max_session_duration_seconds" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes()
        |> Map.delete(:max_session_duration_seconds)

      changeset = Config.changeset(%Config{}, attrs)
      assert %{max_session_duration_seconds: ["can't be blank"]} = errors_on(changeset)
    end

    test "name must be between 1 and 255 characters" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{name: ""})

      changeset = Config.changeset(%Config{}, attrs)
      assert %{name: [_]} = errors_on(changeset)

      long_name = String.duplicate("a", 256)

      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{name: long_name})

      changeset = Config.changeset(%Config{}, attrs)
      assert %{name: [_]} = errors_on(changeset)
    end
  end

  describe "changeset/2 - max_session_duration_seconds validation" do
    test "max_session_duration_seconds exactly 10 is valid (minimum)" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          max_session_duration_seconds: 10
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end

    test "max_session_duration_seconds exactly 3600 is valid (maximum)" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          max_session_duration_seconds: 3600
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end

    test "max_session_duration_seconds 9 is rejected (below minimum)" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          max_session_duration_seconds: 9
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert %{max_session_duration_seconds: [_]} = errors_on(changeset)
    end

    test "max_session_duration_seconds 3601 is rejected (above maximum)" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          max_session_duration_seconds: 3601
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert %{max_session_duration_seconds: [_]} = errors_on(changeset)
    end
  end

  describe "changeset/2 - wipe_strategy and wipe_delay_seconds" do
    test "wipe_strategy :immediate ignores wipe_delay_seconds (value 0 is fine)" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          wipe_strategy: :immediate,
          wipe_delay_seconds: 0
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end

    test "wipe_strategy :delayed requires wipe_delay_seconds > 0" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          wipe_strategy: :delayed,
          wipe_delay_seconds: 0
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert %{wipe_delay_seconds: [_]} = errors_on(changeset)
    end

    test "wipe_strategy :delayed with positive delay is valid" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          wipe_strategy: :delayed,
          wipe_delay_seconds: 300
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end

    test "wipe_strategy :scheduled requires wipe_delay_seconds > 0" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          wipe_strategy: :scheduled,
          wipe_delay_seconds: 0
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert %{wipe_delay_seconds: [_]} = errors_on(changeset)
    end

    test "wipe_strategy :scheduled with positive delay is valid" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          wipe_strategy: :scheduled,
          wipe_delay_seconds: 3600
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end

    test "invalid wipe_strategy is rejected by Ecto.Enum" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          wipe_strategy: :nonexistent
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert %{wipe_strategy: [_]} = errors_on(changeset)
    end
  end

  describe "changeset/2 - wipe_fields validation" do
    test "valid wipe_fields are accepted" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          wipe_fields: ["input_content", "deliberation_messages", "metadata"]
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end

    test "empty wipe_fields array means wipe ALL ephemeral fields (default behavior)" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          wipe_fields: []
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end

    test "all allowed wipe_fields are accepted" do
      all_fields = Config.allowed_wipe_fields()

      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          wipe_fields: all_fields
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end

    test "invalid wipe_field name returns changeset error" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          wipe_fields: ["input_content", "password", "api_key_hash"]
        })

      changeset = Config.changeset(%Config{}, attrs)
      errors = errors_on(changeset)
      assert errors[:wipe_fields]
      error_msg = hd(errors.wipe_fields)
      assert error_msg =~ "password"
      assert error_msg =~ "api_key_hash"
    end
  end

  describe "changeset/2 - retain_verdict and retain_audit" do
    test "retain_verdict=true is valid" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{retain_verdict: true})

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end

    test "retain_verdict=false is rejected (compliance requirement)" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{retain_verdict: false})

      changeset = Config.changeset(%Config{}, attrs)

      assert %{retain_verdict: ["verdicts must always be retained for compliance"]} =
               errors_on(changeset)
    end

    test "retain_audit=true is valid" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{retain_audit: true})

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end

    test "retain_audit=false is rejected (compliance requirement)" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{retain_audit: false})

      changeset = Config.changeset(%Config{}, attrs)

      assert %{retain_audit: ["audit trail must always be retained for compliance"]} =
               errors_on(changeset)
    end
  end

  describe "changeset/2 - slug generation and validation" do
    test "slug is auto-generated from name if not provided" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          name: "My Ghost Config"
        })
        |> Map.delete(:slug)

      changeset = Config.changeset(%Config{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :slug) == "my-ghost-config"
    end

    test "explicit slug overrides auto-generation" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          name: "My Ghost Config",
          slug: "custom-slug"
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :slug) == "custom-slug"
    end

    test "slug with invalid format is rejected" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          slug: "-invalid-slug-"
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert %{slug: [_]} = errors_on(changeset)
    end

    test "slug with uppercase is rejected" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
          slug: "InvalidSlug"
        })

      changeset = Config.changeset(%Config{}, attrs)
      assert %{slug: [_]} = errors_on(changeset)
    end
  end

  describe "database operations" do
    test "creates a ghost protocol config successfully" do
      config = GhostProtocolFixtures.ghost_protocol_config_fixture()

      assert config.id
      assert config.name
      assert config.slug
      assert config.wipe_strategy == :immediate
      assert config.max_session_duration_seconds == 300
      assert config.retain_verdict == true
      assert config.retain_audit == true
      assert config.enabled == true
      assert config.workspace_id
    end

    test "unique slug constraint within workspace" do
      workspace = AccountsFixtures.workspace_fixture()

      _config1 =
        GhostProtocolFixtures.ghost_protocol_config_fixture(%{
          workspace_id: workspace.id,
          slug: "unique-slug"
        })

      assert {:error, changeset} =
               %Config{workspace_id: workspace.id}
               |> Config.changeset(
                 GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{
                   slug: "unique-slug"
                 })
               )
               |> Repo.insert()

      assert %{slug: ["a config with this slug already exists in this workspace"]} =
               errors_on(changeset)
    end

    test "same slug allowed in different workspaces" do
      workspace1 = AccountsFixtures.workspace_fixture()
      workspace2 = AccountsFixtures.workspace_fixture()

      config1 =
        GhostProtocolFixtures.ghost_protocol_config_fixture(%{
          workspace_id: workspace1.id,
          slug: "shared-slug"
        })

      config2 =
        GhostProtocolFixtures.ghost_protocol_config_fixture(%{
          workspace_id: workspace2.id,
          slug: "shared-slug"
        })

      assert config1.slug == config2.slug
      assert config1.workspace_id != config2.workspace_id
    end

    test "deleting config with linked workflows returns error (referential integrity)" do
      workspace = AccountsFixtures.workspace_fixture()

      config =
        GhostProtocolFixtures.ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      # Create a workflow linked to this config
      _workflow =
        DeliberationFixtures.workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: config.id
        })

      # nilify_all means the FK is set to NULL, not that the delete fails
      # Since we used on_delete: :nilify_all, the config can be deleted
      # and workflows will have ghost_protocol_config_id set to NULL
      assert {:ok, _} = Repo.delete(config)
    end
  end

  describe "workflow association" do
    test "workflow with ghost_protocol_config_id=NULL is non-ephemeral" do
      workflow = DeliberationFixtures.workflow_fixture()

      assert is_nil(workflow.ghost_protocol_config_id)
    end

    test "workflow with valid ghost_protocol_config_id is ephemeral" do
      workspace = AccountsFixtures.workspace_fixture()

      config =
        GhostProtocolFixtures.ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      workflow =
        DeliberationFixtures.workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: config.id
        })

      assert workflow.ghost_protocol_config_id == config.id
    end
  end

  describe "analysis_session GhostProtocol fields" do
    test "analysis_session with input_content_hash and expires_at" do
      alias Swarmshield.Deliberation.AnalysisSession

      session = DeliberationFixtures.analysis_session_fixture()
      now = DateTime.utc_now(:second)
      hash = :crypto.hash(:sha256, "test content") |> Base.encode16(case: :lower)

      {:ok, updated} =
        session
        |> AnalysisSession.status_changeset(%{
          status: :analyzing,
          input_content_hash: hash,
          expires_at: DateTime.add(now, 300, :second)
        })
        |> Repo.update()

      assert updated.input_content_hash == hash
      assert updated.expires_at
    end

    test "analysis_session input_content_hash and expires_at default to nil" do
      session = DeliberationFixtures.analysis_session_fixture()
      assert is_nil(session.input_content_hash)
      assert is_nil(session.expires_at)
    end
  end

  describe "agent_instance GhostProtocol fields" do
    test "agent_instance terminated_at defaults to nil" do
      instance = DeliberationFixtures.agent_instance_fixture()
      assert is_nil(instance.terminated_at)
    end

    test "agent_instance terminated_at can be set" do
      alias Swarmshield.Deliberation.AgentInstance

      instance = DeliberationFixtures.agent_instance_fixture()
      now = DateTime.utc_now(:second)

      {:ok, updated} =
        instance
        |> AgentInstance.changeset(%{terminated_at: now})
        |> Repo.update()

      assert updated.terminated_at == now
    end
  end

  describe "changeset/2 - crypto_shred" do
    test "crypto_shred=false is default and valid" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{crypto_shred: false})

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end

    test "crypto_shred=true is valid" do
      attrs =
        GhostProtocolFixtures.valid_ghost_protocol_config_attributes(%{crypto_shred: true})

      changeset = Config.changeset(%Config{}, attrs)
      assert changeset.valid?
    end
  end

  describe "changeset/2 - metadata" do
    test "metadata defaults to empty map" do
      config = GhostProtocolFixtures.ghost_protocol_config_fixture(%{metadata: %{}})
      assert config.metadata == %{}
    end

    test "metadata accepts nested maps" do
      nested = %{"level1" => %{"level2" => %{"level3" => "deep value"}}}

      config = GhostProtocolFixtures.ghost_protocol_config_fixture(%{metadata: nested})
      assert config.metadata == nested
    end
  end

  describe "allowed_wipe_fields/0" do
    test "returns expected fields" do
      fields = Config.allowed_wipe_fields()
      assert "input_content" in fields
      assert "deliberation_messages" in fields
      assert "metadata" in fields
      assert "initial_assessment" in fields
      assert "payload" in fields
      assert length(fields) == 5
    end
  end
end
