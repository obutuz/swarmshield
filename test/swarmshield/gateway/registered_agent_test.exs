defmodule Swarmshield.Gateway.RegisteredAgentTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Gateway.RegisteredAgent
  alias Swarmshield.GatewayFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = GatewayFixtures.valid_registered_agent_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      changeset = RegisteredAgent.changeset(%RegisteredAgent{workspace_id: workspace.id}, attrs)

      assert changeset.valid?
    end

    test "requires name" do
      attrs = GatewayFixtures.valid_registered_agent_attributes(%{name: nil})
      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name max length" do
      long_name = String.duplicate("a", 256)
      attrs = GatewayFixtures.valid_registered_agent_attributes(%{name: long_name})
      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)

      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "validates description max length" do
      long_desc = String.duplicate("a", 2001)
      attrs = GatewayFixtures.valid_registered_agent_attributes(%{description: long_desc})
      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)

      refute changeset.valid?
      assert %{description: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 2000"
    end

    test "agent_type defaults to :autonomous" do
      attrs = GatewayFixtures.valid_registered_agent_attributes()
      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :agent_type) == :autonomous
    end

    test "agent_type enum rejects invalid values" do
      attrs = GatewayFixtures.valid_registered_agent_attributes(%{agent_type: :invalid_type})
      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)

      refute changeset.valid?
      assert %{agent_type: [_msg]} = errors_on(changeset)
    end

    test "accepts all valid agent_types" do
      for agent_type <- [:autonomous, :semi_autonomous, :tool_agent, :chatbot] do
        attrs = GatewayFixtures.valid_registered_agent_attributes(%{agent_type: agent_type})
        changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)

        assert changeset.valid?, "Expected agent_type #{agent_type} to be valid"
      end
    end

    test "status defaults to :active" do
      attrs = GatewayFixtures.valid_registered_agent_attributes()
      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :status) == :active
    end

    test "rejects invalid status values" do
      attrs = GatewayFixtures.valid_registered_agent_attributes(%{status: :invalid})
      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)

      refute changeset.valid?
      assert %{status: [_msg]} = errors_on(changeset)
    end

    test "risk_level defaults to :medium" do
      attrs = GatewayFixtures.valid_registered_agent_attributes()
      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :risk_level) == :medium
    end

    test "accepts all valid risk levels" do
      for level <- [:low, :medium, :high, :critical] do
        attrs = GatewayFixtures.valid_registered_agent_attributes(%{risk_level: level})
        changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)

        assert changeset.valid?, "Expected risk_level #{level} to be valid"
      end
    end

    test "metadata defaults to empty map" do
      attrs = GatewayFixtures.valid_registered_agent_attributes()
      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :metadata) == %{}
    end

    test "metadata field accepts deeply nested maps" do
      workspace = AccountsFixtures.workspace_fixture()

      deep_metadata = %{
        "level1" => %{
          "level2" => %{
            "level3" => %{
              "value" => "deeply nested"
            }
          }
        }
      }

      attrs = GatewayFixtures.valid_registered_agent_attributes(%{metadata: deep_metadata})

      {:ok, agent} =
        %RegisteredAgent{workspace_id: workspace.id}
        |> RegisteredAgent.changeset(attrs)
        |> Ecto.Changeset.change(%{
          api_key_hash: attrs.api_key_hash,
          api_key_prefix: attrs.api_key_prefix
        })
        |> Repo.insert()

      assert agent.metadata == deep_metadata
    end

    test "changeset does NOT cast api_key_hash" do
      attrs =
        GatewayFixtures.valid_registered_agent_attributes(%{api_key_hash: "injected_hash"})

      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :api_key_hash) == nil
    end

    test "changeset does NOT cast api_key_prefix" do
      attrs =
        GatewayFixtures.valid_registered_agent_attributes(%{api_key_prefix: "injected_"})

      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :api_key_prefix) == nil
    end

    test "changeset does NOT cast event_count" do
      attrs =
        GatewayFixtures.valid_registered_agent_attributes(%{event_count: 9999})

      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :event_count) == 0
    end

    test "changeset does NOT cast last_seen_at" do
      attrs =
        GatewayFixtures.valid_registered_agent_attributes(%{
          last_seen_at: DateTime.utc_now(:second)
        })

      changeset = RegisteredAgent.changeset(%RegisteredAgent{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :last_seen_at) == nil
    end

    test "name uniqueness within workspace (same name allowed in different workspaces)" do
      workspace1 = AccountsFixtures.workspace_fixture()
      workspace2 = AccountsFixtures.workspace_fixture()

      _agent1 =
        GatewayFixtures.registered_agent_fixture(%{
          workspace_id: workspace1.id,
          name: "shared-name"
        })

      agent2 =
        GatewayFixtures.registered_agent_fixture(%{
          workspace_id: workspace2.id,
          name: "shared-name"
        })

      assert agent2.name == "shared-name"
    end

    test "duplicate name in same workspace is rejected" do
      workspace = AccountsFixtures.workspace_fixture()

      _agent1 =
        GatewayFixtures.registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "duplicate-name"
        })

      attrs = GatewayFixtures.valid_registered_agent_attributes(%{name: "duplicate-name"})

      {:error, changeset} =
        %RegisteredAgent{workspace_id: workspace.id}
        |> RegisteredAgent.changeset(attrs)
        |> Ecto.Changeset.change(%{
          api_key_hash: attrs.api_key_hash,
          api_key_prefix: attrs.api_key_prefix
        })
        |> Repo.insert()

      assert %{workspace_id: [msg]} = errors_on(changeset)
      assert msg =~ "an agent with this name already exists"
    end
  end

  describe "status transitions" do
    test "suspended agent cannot be reactivated to active directly" do
      changeset =
        RegisteredAgent.changeset(
          %RegisteredAgent{status: :suspended},
          %{status: :active}
        )

      refute changeset.valid?
      assert %{status: [msg]} = errors_on(changeset)
      assert msg =~ "must go through review"
    end

    test "revoked agent cannot be reactivated" do
      changeset =
        RegisteredAgent.changeset(
          %RegisteredAgent{status: :revoked},
          %{status: :active}
        )

      refute changeset.valid?
      assert %{status: [msg]} = errors_on(changeset)
      assert msg =~ "revoked agents cannot be reactivated"
    end

    test "revoked agent cannot be set to suspended" do
      changeset =
        RegisteredAgent.changeset(
          %RegisteredAgent{status: :revoked},
          %{status: :suspended}
        )

      refute changeset.valid?
      assert %{status: [msg]} = errors_on(changeset)
      assert msg =~ "revoked agents cannot be reactivated"
    end

    test "active agent can be suspended" do
      attrs = GatewayFixtures.valid_registered_agent_attributes(%{status: :suspended})

      changeset =
        RegisteredAgent.changeset(
          %RegisteredAgent{status: :active},
          attrs
        )

      assert changeset.valid?
    end

    test "active agent can be revoked" do
      attrs = GatewayFixtures.valid_registered_agent_attributes(%{status: :revoked})

      changeset =
        RegisteredAgent.changeset(
          %RegisteredAgent{status: :active},
          attrs
        )

      assert changeset.valid?
    end

    test "no status change is valid" do
      attrs = GatewayFixtures.valid_registered_agent_attributes()
      attrs = Map.delete(attrs, :status)

      changeset =
        RegisteredAgent.changeset(
          %RegisteredAgent{status: :suspended},
          attrs
        )

      assert changeset.valid?
    end
  end

  describe "api_key_changeset/2" do
    test "sets api_key_hash and api_key_prefix" do
      changeset =
        RegisteredAgent.api_key_changeset(%RegisteredAgent{}, %{
          api_key_hash: "abc123hash",
          api_key_prefix: "12345678"
        })

      assert changeset.valid?
    end

    test "requires api_key_hash" do
      changeset =
        RegisteredAgent.api_key_changeset(%RegisteredAgent{}, %{
          api_key_prefix: "12345678"
        })

      refute changeset.valid?
      assert %{api_key_hash: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires api_key_prefix" do
      changeset =
        RegisteredAgent.api_key_changeset(%RegisteredAgent{}, %{
          api_key_hash: "abc123hash"
        })

      refute changeset.valid?
      assert %{api_key_prefix: ["can't be blank"]} = errors_on(changeset)
    end

    test "api_key_prefix must be exactly 8 characters" do
      changeset =
        RegisteredAgent.api_key_changeset(%RegisteredAgent{}, %{
          api_key_hash: "abc123hash",
          api_key_prefix: "short"
        })

      refute changeset.valid?
      assert %{api_key_prefix: [msg]} = errors_on(changeset)
      assert msg =~ "should be 8 character(s)"
    end
  end

  describe "workspace_changeset/2" do
    test "sets workspace_id" do
      workspace_id = Ecto.UUID.generate()
      changeset = RegisteredAgent.workspace_changeset(%RegisteredAgent{}, workspace_id)

      assert Ecto.Changeset.get_field(changeset, :workspace_id) == workspace_id
    end

    test "requires workspace_id to be binary" do
      workspace_id = Ecto.UUID.generate()
      changeset = RegisteredAgent.workspace_changeset(%RegisteredAgent{}, workspace_id)

      assert changeset.valid?
    end
  end

  describe "generate_api_key/0" do
    test "returns {raw_key, hash, prefix} tuple" do
      {raw_key, hash, prefix} = RegisteredAgent.generate_api_key()

      assert is_binary(raw_key)
      assert is_binary(hash)
      assert is_binary(prefix)
    end

    test "raw_key is base64url encoded" do
      {raw_key, _hash, _prefix} = RegisteredAgent.generate_api_key()

      assert {:ok, _decoded} = Base.url_decode64(raw_key, padding: false)
    end

    test "hash is SHA256 hex encoded (64 characters)" do
      {_raw_key, hash, _prefix} = RegisteredAgent.generate_api_key()

      assert String.length(hash) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, hash)
    end

    test "prefix is exactly 8 characters" do
      {_raw_key, _hash, prefix} = RegisteredAgent.generate_api_key()

      assert String.length(prefix) == 8
    end

    test "produces unique keys across 1000 iterations" do
      keys =
        for _i <- 1..1000 do
          {raw_key, _hash, _prefix} = RegisteredAgent.generate_api_key()
          raw_key
        end

      unique_keys = Enum.uniq(keys)
      assert length(unique_keys) == 1000
    end

    test "hash is deterministic for the same raw key" do
      {raw_key, hash, _prefix} = RegisteredAgent.generate_api_key()

      recomputed_hash = :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
      assert hash == recomputed_hash
    end

    test "prefix matches first 8 characters of raw key" do
      {raw_key, _hash, prefix} = RegisteredAgent.generate_api_key()

      assert prefix == String.slice(raw_key, 0, 8)
    end
  end

  describe "registered_agent_fixture/1" do
    test "creates an agent with default attributes" do
      agent = GatewayFixtures.registered_agent_fixture()

      assert agent.id
      assert agent.name
      assert agent.workspace_id
      assert agent.api_key_hash
      assert agent.api_key_prefix
      assert agent.status == :active
      assert agent.agent_type == :autonomous
      assert agent.risk_level == :medium
      assert agent.event_count == 0
      assert agent.metadata == %{}
    end

    test "creates an agent with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      agent =
        GatewayFixtures.registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "custom-agent",
          agent_type: :chatbot,
          risk_level: :high
        })

      assert agent.name == "custom-agent"
      assert agent.workspace_id == workspace.id
      assert agent.agent_type == :chatbot
      assert agent.risk_level == :high
    end

    test "creates workspace automatically if not provided" do
      agent = GatewayFixtures.registered_agent_fixture()

      assert agent.workspace_id
      workspace = Repo.get!(Swarmshield.Accounts.Workspace, agent.workspace_id)
      assert workspace
    end
  end

  describe "database persistence" do
    test "event_count defaults to 0 in database" do
      agent = GatewayFixtures.registered_agent_fixture()

      reloaded = Repo.get!(RegisteredAgent, agent.id)
      assert reloaded.event_count == 0
    end

    test "last_seen_at is nil for new agents" do
      agent = GatewayFixtures.registered_agent_fixture()

      reloaded = Repo.get!(RegisteredAgent, agent.id)
      assert is_nil(reloaded.last_seen_at)
    end

    test "api_key_hash unique constraint enforced at database level" do
      workspace = AccountsFixtures.workspace_fixture()
      {_raw, hash, prefix} = RegisteredAgent.generate_api_key()

      attrs1 = GatewayFixtures.valid_registered_agent_attributes(%{name: "agent-1"})

      {:ok, _agent1} =
        %RegisteredAgent{workspace_id: workspace.id}
        |> RegisteredAgent.changeset(attrs1)
        |> Ecto.Changeset.change(%{api_key_hash: hash, api_key_prefix: prefix})
        |> Ecto.Changeset.unique_constraint(:api_key_hash)
        |> Repo.insert()

      attrs2 = GatewayFixtures.valid_registered_agent_attributes(%{name: "agent-2"})

      {:error, changeset} =
        %RegisteredAgent{workspace_id: workspace.id}
        |> RegisteredAgent.changeset(attrs2)
        |> Ecto.Changeset.change(%{api_key_hash: hash, api_key_prefix: prefix})
        |> Ecto.Changeset.unique_constraint(:api_key_hash)
        |> Repo.insert()

      assert %{api_key_hash: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
