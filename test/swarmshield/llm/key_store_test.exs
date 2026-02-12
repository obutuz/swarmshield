defmodule Swarmshield.LLM.KeyStoreTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Accounts
  alias Swarmshield.LLM.KeyStore

  setup do
    {:ok, workspace} =
      Accounts.create_workspace(%{
        name: "KeyStore Test",
        slug: "keystore-test-#{System.unique_integer([:positive])}"
      })

    %{workspace: workspace}
  end

  describe "store_key/2 and get_key/1" do
    test "stores and retrieves an encrypted API key", %{workspace: workspace} do
      api_key = "sk-ant-test-#{System.unique_integer([:positive])}"

      assert :ok = KeyStore.store_key(workspace.id, api_key)
      assert {:ok, ^api_key} = KeyStore.get_key(workspace.id)
    end

    test "encrypted key is stored in workspace settings", %{workspace: workspace} do
      api_key = "sk-ant-encrypted-check"

      :ok = KeyStore.store_key(workspace.id, api_key)

      updated = Swarmshield.Repo.get!(Accounts.Workspace, workspace.id)
      settings = updated.settings

      assert is_binary(settings["llm_api_key_encrypted"])
      assert settings["llm_api_key_encrypted"] != api_key
      assert settings["llm_api_key_prefix"] == "sk-ant-e"
    end

    test "overwrites existing key", %{workspace: workspace} do
      :ok = KeyStore.store_key(workspace.id, "sk-ant-first-key")
      assert {:ok, "sk-ant-first-key"} = KeyStore.get_key(workspace.id)

      :ok = KeyStore.store_key(workspace.id, "sk-ant-second-key")
      assert {:ok, "sk-ant-second-key"} = KeyStore.get_key(workspace.id)
    end
  end

  describe "has_key?/1" do
    test "returns false when no key configured", %{workspace: workspace} do
      refute KeyStore.has_key?(workspace.id)
    end

    test "returns true after key stored", %{workspace: workspace} do
      :ok = KeyStore.store_key(workspace.id, "sk-ant-has-key-test")
      assert KeyStore.has_key?(workspace.id)
    end

    test "returns false for non-existent workspace" do
      refute KeyStore.has_key?(Ecto.UUID.generate())
    end

    test "returns false for nil" do
      refute KeyStore.has_key?(nil)
    end
  end

  describe "delete_key/1" do
    test "removes stored key", %{workspace: workspace} do
      :ok = KeyStore.store_key(workspace.id, "sk-ant-to-delete")
      assert KeyStore.has_key?(workspace.id)

      :ok = KeyStore.delete_key(workspace.id)
      refute KeyStore.has_key?(workspace.id)
      assert :error = KeyStore.get_key(workspace.id)
    end

    test "clears settings fields", %{workspace: workspace} do
      :ok = KeyStore.store_key(workspace.id, "sk-ant-clear-check")
      :ok = KeyStore.delete_key(workspace.id)

      updated = Swarmshield.Repo.get!(Accounts.Workspace, workspace.id)
      refute Map.has_key?(updated.settings, "llm_api_key_encrypted")
      refute Map.has_key?(updated.settings, "llm_api_key_prefix")
    end
  end

  describe "get_key_prefix/1" do
    test "returns nil when no key", %{workspace: workspace} do
      assert is_nil(KeyStore.get_key_prefix(workspace.id))
    end

    test "returns prefix after key stored", %{workspace: workspace} do
      :ok = KeyStore.store_key(workspace.id, "sk-ant-prefix-test")
      assert KeyStore.get_key_prefix(workspace.id) == "sk-ant-p"
    end

    test "returns nil for non-existent workspace" do
      assert is_nil(KeyStore.get_key_prefix(Ecto.UUID.generate()))
    end
  end

  describe "get_key/1 edge cases" do
    test "returns :error for non-existent workspace" do
      assert :error = KeyStore.get_key(Ecto.UUID.generate())
    end

    test "returns :error for nil" do
      assert :error = KeyStore.get_key(nil)
    end

    test "preserves other workspace settings", %{workspace: workspace} do
      Accounts.update_workspace(workspace, %{
        settings: %{"default_timeout_seconds" => 600, "custom_flag" => true}
      })

      :ok = KeyStore.store_key(workspace.id, "sk-ant-preserve-test")

      updated = Swarmshield.Repo.get!(Accounts.Workspace, workspace.id)
      assert updated.settings["default_timeout_seconds"] == 600
      assert updated.settings["custom_flag"] == true
      assert is_binary(updated.settings["llm_api_key_encrypted"])
    end
  end

  describe "workspace struct API (zero DB queries)" do
    test "get_key/1 with struct retrieves key without DB query", %{workspace: workspace} do
      api_key = "sk-ant-struct-test"
      :ok = KeyStore.store_key(workspace.id, api_key)

      # Reload workspace to have settings with encrypted key
      updated = Swarmshield.Repo.get!(Accounts.Workspace, workspace.id)

      # Clear ETS to force decrypt path (not DB path)
      :ets.delete(:llm_key_store, workspace.id)

      assert {:ok, ^api_key} = KeyStore.get_key(updated)
    end

    test "get_key/1 with struct returns :error when no key configured", %{workspace: workspace} do
      assert :error = KeyStore.get_key(workspace)
    end

    test "has_key?/1 with struct returns true after key stored", %{workspace: workspace} do
      :ok = KeyStore.store_key(workspace.id, "sk-ant-struct-has")
      updated = Swarmshield.Repo.get!(Accounts.Workspace, workspace.id)

      assert KeyStore.has_key?(updated)
    end

    test "has_key?/1 with struct returns false when no key", %{workspace: workspace} do
      refute KeyStore.has_key?(workspace)
    end

    test "get_key_prefix/1 with struct reads from settings directly", %{workspace: workspace} do
      :ok = KeyStore.store_key(workspace.id, "sk-ant-pfx-struct")
      updated = Swarmshield.Repo.get!(Accounts.Workspace, workspace.id)

      assert KeyStore.get_key_prefix(updated) == "sk-ant-p"
    end

    test "get_key_prefix/1 with struct returns nil when no key", %{workspace: workspace} do
      assert is_nil(KeyStore.get_key_prefix(workspace))
    end
  end
end
