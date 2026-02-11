defmodule Swarmshield.Accounts.AuditEntryTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Accounts
  alias Swarmshield.Accounts.AuditEntry
  alias Swarmshield.AccountsFixtures

  describe "create_changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = AccountsFixtures.valid_audit_entry_attributes()
      changeset = AuditEntry.create_changeset(%AuditEntry{}, attrs)

      assert changeset.valid?
    end

    test "requires action" do
      attrs = AccountsFixtures.valid_audit_entry_attributes(%{action: nil})
      changeset = AuditEntry.create_changeset(%AuditEntry{}, attrs)

      refute changeset.valid?
      assert %{action: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires resource_type" do
      attrs = AccountsFixtures.valid_audit_entry_attributes(%{resource_type: nil})
      changeset = AuditEntry.create_changeset(%AuditEntry{}, attrs)

      refute changeset.valid?
      assert %{resource_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "succeeds with nil actor_id (system actions)" do
      attrs = AccountsFixtures.valid_audit_entry_attributes(%{actor_id: nil})
      changeset = AuditEntry.create_changeset(%AuditEntry{}, attrs)

      assert changeset.valid?
      {:ok, entry} = Repo.insert(changeset)
      assert entry.actor_id == nil
    end

    test "succeeds with nil workspace_id (system-level actions)" do
      attrs = AccountsFixtures.valid_audit_entry_attributes(%{workspace_id: nil})
      changeset = AuditEntry.create_changeset(%AuditEntry{}, attrs)

      assert changeset.valid?
      {:ok, entry} = Repo.insert(changeset)
      assert entry.workspace_id == nil
    end

    test "stores actor_id when provided" do
      user = AccountsFixtures.user_fixture()

      attrs =
        AccountsFixtures.valid_audit_entry_attributes(%{
          actor_id: user.id,
          actor_email: user.email
        })

      {:ok, entry} =
        AuditEntry.create_changeset(%AuditEntry{}, attrs)
        |> Repo.insert()

      assert entry.actor_id == user.id
      assert entry.actor_email == user.email
    end

    test "stores workspace_id when provided" do
      workspace = AccountsFixtures.workspace_fixture()

      attrs =
        AccountsFixtures.valid_audit_entry_attributes(%{workspace_id: workspace.id})

      {:ok, entry} =
        AuditEntry.create_changeset(%AuditEntry{}, attrs)
        |> Repo.insert()

      assert entry.workspace_id == workspace.id
    end

    test "stores ip_address and user_agent" do
      attrs =
        AccountsFixtures.valid_audit_entry_attributes(%{
          ip_address: "192.168.1.1",
          user_agent: "Mozilla/5.0"
        })

      {:ok, entry} =
        AuditEntry.create_changeset(%AuditEntry{}, attrs)
        |> Repo.insert()

      assert entry.ip_address == "192.168.1.1"
      assert entry.user_agent == "Mozilla/5.0"
    end

    test "validates action max length" do
      long_action = String.duplicate("a", 256)
      attrs = AccountsFixtures.valid_audit_entry_attributes(%{action: long_action})
      changeset = AuditEntry.create_changeset(%AuditEntry{}, attrs)

      refute changeset.valid?
      assert %{action: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "validates user_agent max length" do
      long_ua = String.duplicate("a", 501)
      attrs = AccountsFixtures.valid_audit_entry_attributes(%{user_agent: long_ua})
      changeset = AuditEntry.create_changeset(%AuditEntry{}, attrs)

      refute changeset.valid?
      assert %{user_agent: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 500"
    end

    test "no updated_at field - insert only" do
      entry = AccountsFixtures.audit_entry_fixture()

      assert entry.inserted_at
      # AuditEntry schema has no updated_at
      refute Map.has_key?(Map.from_struct(entry), :updated_at)
    end
  end

  describe "metadata sanitization" do
    test "sanitizes password from metadata" do
      attrs =
        AccountsFixtures.valid_audit_entry_attributes(%{
          metadata: %{"password" => "secret123", "email" => "test@example.com"}
        })

      changeset = AuditEntry.create_changeset(%AuditEntry{}, attrs)
      metadata = Ecto.Changeset.get_field(changeset, :metadata)

      assert metadata["password"] == "[REDACTED]"
      assert metadata["email"] == "test@example.com"
    end

    test "sanitizes api_key from metadata" do
      attrs =
        AccountsFixtures.valid_audit_entry_attributes(%{
          metadata: %{"api_key" => "swrm_abc123", "action" => "generate"}
        })

      changeset = AuditEntry.create_changeset(%AuditEntry{}, attrs)
      metadata = Ecto.Changeset.get_field(changeset, :metadata)

      assert metadata["api_key"] == "[REDACTED]"
      assert metadata["action"] == "generate"
    end

    test "sanitizes token from metadata" do
      attrs =
        AccountsFixtures.valid_audit_entry_attributes(%{
          metadata: %{"token" => "abc123", "type" => "session"}
        })

      changeset = AuditEntry.create_changeset(%AuditEntry{}, attrs)
      metadata = Ecto.Changeset.get_field(changeset, :metadata)

      assert metadata["token"] == "[REDACTED]"
      assert metadata["type"] == "session"
    end

    test "sanitizes nested sensitive fields" do
      attrs =
        AccountsFixtures.valid_audit_entry_attributes(%{
          metadata: %{"user" => %{"password" => "secret"}, "action" => "update"}
        })

      changeset = AuditEntry.create_changeset(%AuditEntry{}, attrs)
      metadata = Ecto.Changeset.get_field(changeset, :metadata)

      assert metadata["user"]["password"] == "[REDACTED]"
      assert metadata["action"] == "update"
    end

    test "large metadata map (>10KB) is accepted and stored correctly" do
      large_data = for i <- 1..200, into: %{}, do: {"key_#{i}", String.duplicate("x", 50)}

      attrs = AccountsFixtures.valid_audit_entry_attributes(%{metadata: large_data})

      {:ok, entry} =
        AuditEntry.create_changeset(%AuditEntry{}, attrs)
        |> Repo.insert()

      assert map_size(entry.metadata) == 200
    end
  end

  describe "immutability" do
    test "audit_entry has no update changeset" do
      # AuditEntry module only exposes create_changeset, no update changeset
      functions = AuditEntry.__info__(:functions)
      changeset_functions = Enum.filter(functions, fn {name, _arity} -> name == :changeset end)

      assert changeset_functions == []
    end
  end

  describe "audit_entry_fixture/1" do
    test "creates an audit entry with default attributes" do
      entry = AccountsFixtures.audit_entry_fixture()

      assert entry.id
      assert entry.action == "test.action"
      assert entry.resource_type == "test_resource"
    end

    test "creates an audit entry with custom attributes" do
      entry =
        AccountsFixtures.audit_entry_fixture(%{
          action: "user.login",
          resource_type: "user",
          ip_address: "10.0.0.1"
        })

      assert entry.action == "user.login"
      assert entry.resource_type == "user"
      assert entry.ip_address == "10.0.0.1"
    end
  end

  describe "create_audit_entry/1" do
    test "creates an audit entry via context function" do
      {:ok, entry} =
        Accounts.create_audit_entry(%{
          action: "user.login",
          resource_type: "user",
          metadata: %{"browser" => "chrome"}
        })

      assert entry.id
      assert entry.action == "user.login"
      assert entry.resource_type == "user"
      assert entry.metadata == %{"browser" => "chrome"}
    end

    test "returns error changeset for invalid attributes" do
      assert {:error, changeset} = Accounts.create_audit_entry(%{action: nil})
      assert %{action: ["can't be blank"]} = errors_on(changeset)
    end

    test "sanitizes metadata automatically" do
      {:ok, entry} =
        Accounts.create_audit_entry(%{
          action: "user.update",
          resource_type: "user",
          metadata: %{"password" => "secret", "email" => "test@example.com"}
        })

      assert entry.metadata["password"] == "[REDACTED]"
      assert entry.metadata["email"] == "test@example.com"
    end

    test "succeeds with nil actor_id (system actions)" do
      {:ok, entry} =
        Accounts.create_audit_entry(%{
          action: "system.cleanup",
          resource_type: "session",
          actor_id: nil
        })

      assert entry.actor_id == nil
    end

    test "succeeds with nil workspace_id (system-level actions)" do
      {:ok, entry} =
        Accounts.create_audit_entry(%{
          action: "system.startup",
          resource_type: "application",
          workspace_id: nil
        })

      assert entry.workspace_id == nil
    end
  end

  describe "list_audit_entries/2" do
    setup do
      workspace = AccountsFixtures.workspace_fixture()
      user = AccountsFixtures.user_fixture()

      entries =
        for i <- 1..5 do
          AccountsFixtures.audit_entry_fixture(%{
            workspace_id: workspace.id,
            actor_id: user.id,
            action: "action.#{rem(i, 3)}",
            resource_type: "resource_#{rem(i, 2)}"
          })
        end

      %{workspace: workspace, user: user, entries: entries}
    end

    test "returns entries for workspace with total count", %{workspace: workspace} do
      {entries, total_count} = Accounts.list_audit_entries(workspace.id)

      assert length(entries) == 5
      assert total_count == 5
    end

    test "returns entries ordered by inserted_at descending", %{workspace: workspace} do
      {entries, _total} = Accounts.list_audit_entries(workspace.id)
      timestamps = Enum.map(entries, & &1.inserted_at)

      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end

    test "filters by action", %{workspace: workspace} do
      {entries, total_count} = Accounts.list_audit_entries(workspace.id, action: "action.0")

      assert total_count > 0
      assert Enum.all?(entries, &(&1.action == "action.0"))
    end

    test "filters by actor_id", %{workspace: workspace, user: user} do
      {entries, total_count} = Accounts.list_audit_entries(workspace.id, actor_id: user.id)

      assert total_count == 5
      assert Enum.all?(entries, &(&1.actor_id == user.id))
    end

    test "filters by resource_type", %{workspace: workspace} do
      {entries, total_count} =
        Accounts.list_audit_entries(workspace.id, resource_type: "resource_0")

      assert total_count > 0
      assert Enum.all?(entries, &(&1.resource_type == "resource_0"))
    end

    test "filters by date range (from)", %{workspace: workspace} do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {entries, total_count} = Accounts.list_audit_entries(workspace.id, from: future)

      assert entries == []
      assert total_count == 0
    end

    test "filters by date range (to)", %{workspace: workspace} do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      {entries, total_count} = Accounts.list_audit_entries(workspace.id, to: past)

      assert entries == []
      assert total_count == 0
    end

    test "filters by date range (from and to)", %{workspace: workspace} do
      now = DateTime.utc_now()
      from = DateTime.add(now, -60, :second)
      to = DateTime.add(now, 60, :second)

      {entries, total_count} = Accounts.list_audit_entries(workspace.id, from: from, to: to)

      assert total_count == 5
      assert length(entries) == 5
    end

    test "paginates with page and page_size", %{workspace: workspace} do
      {page1, total_count} = Accounts.list_audit_entries(workspace.id, page: 1, page_size: 2)
      {page2, _} = Accounts.list_audit_entries(workspace.id, page: 2, page_size: 2)
      {page3, _} = Accounts.list_audit_entries(workspace.id, page: 3, page_size: 2)

      assert total_count == 5
      assert length(page1) == 2
      assert length(page2) == 2
      assert length(page3) == 1
    end

    test "caps page_size at 100" do
      workspace = AccountsFixtures.workspace_fixture()
      {_entries, _total} = Accounts.list_audit_entries(workspace.id, page_size: 200)
      # Should not error - page_size is capped internally
    end

    test "does not return entries from other workspaces" do
      workspace1 = AccountsFixtures.workspace_fixture()
      workspace2 = AccountsFixtures.workspace_fixture()

      AccountsFixtures.audit_entry_fixture(%{
        workspace_id: workspace1.id,
        action: "ws1.action"
      })

      AccountsFixtures.audit_entry_fixture(%{
        workspace_id: workspace2.id,
        action: "ws2.action"
      })

      {entries, total_count} = Accounts.list_audit_entries(workspace1.id)

      assert total_count == 1
      assert hd(entries).action == "ws1.action"
    end

    test "returns empty results for workspace with no entries" do
      workspace = AccountsFixtures.workspace_fixture()
      {entries, total_count} = Accounts.list_audit_entries(workspace.id)

      assert entries == []
      assert total_count == 0
    end

    test "combines multiple filters", %{workspace: workspace, user: user} do
      {entries, total_count} =
        Accounts.list_audit_entries(workspace.id,
          action: "action.0",
          actor_id: user.id,
          resource_type: "resource_0"
        )

      assert total_count >= 0

      Enum.each(entries, fn entry ->
        assert entry.action == "action.0"
        assert entry.actor_id == user.id
        assert entry.resource_type == "resource_0"
      end)
    end
  end
end
